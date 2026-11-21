import Foundation

/// Direct native YouTube Innertube API client (zero CORS, zero browser overhead).
/// All large JSON trees are parsed inside `autoreleasepool` and immediately discarded
/// so only lean Swift value structs remain in RAM.
final class YouTubeAPI {
    static let shared = YouTubeAPI()

    private let session: URLSession

    private let webClient: [String: Any] = [
        "clientName": "WEB",
        "clientVersion": "2.20260401.00.00",
        "hl": "en",
        "gl": "US"
    ]

    private let androidClient: [String: Any] = [
        "clientName": "ANDROID",
        "clientVersion": "20.10.38",
        "androidSdkVersion": 34,
        "hl": "en",
        "gl": "US",
        "userAgent": "com.google.android.youtube/20.10.38 (Linux; U; Android 14) gzip"
    ]

    private let webUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36"
    private let streamUA = "com.google.android.youtube/20.10.38 (Linux; U; Android 14) gzip"

    static let exploreCategories: [(name: String, browseId: String?, searchQuery: String?)] = [
        ("All", nil, nil),
        ("Music", "UC-9-kyTW8ZkZNDHQJ6FgpwQ", nil),
        ("Gaming", "UCOpNcN46UbXVtpKMrmU4Abg", nil),
        ("Live", "UC4R8DWoMoI7CAwX8_LjQHig", nil),
        ("News", "UCYfdidRxbB8Qhf0Nx7ioOYw", nil),
        ("Sports", "UCEgdi0XIXXZ-qJOFPf4JSKw", nil),
        ("Science", nil, "science engineering documentary"),
        ("Technology", nil, "technology computer engineering"),
        ("Coding", nil, "programming systems engineering"),
        ("Space", nil, "space astronomy physics"),
        ("Podcasts", nil, "podcast full episode"),
        ("Documentaries", nil, "documentary full")
    ]

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = URLCache(memoryCapacity: 1 * 1024 * 1024, diskCapacity: 4 * 1024 * 1024)
        cfg.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - Low-level Innertube POST

    private func postInnertube(endpoint: String, payload: [String: Any], useMobile: Bool = false, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/\(endpoint)?prettyPrint=false") else { return }
        var body = payload
        body["context"] = ["client": useMobile ? androidClient : webClient]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(useMobile ? streamUA : webUA, forHTTPHeaderField: "User-Agent")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        session.dataTask(with: req) { data, _, err in
            if let err = err {
                completion(.failure(err))
                return
            }
            guard let data = data else {
                completion(.failure(NSError(domain: "YouTubeAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Empty response"])))
                return
            }
            autoreleasepool {
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    completion(.success(obj))
                } else {
                    completion(.failure(NSError(domain: "YouTubeAPI", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON"])))
                }
            }
        }.resume()
    }

    // MARK: - 1. Player (Direct Streams via IOS Innertube)

    func fetchPlayer(videoId: String, completion: @escaping (Result<PlayerResponse, Error>) -> Void) {
        let payload: [String: Any] = [
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true
        ]
        postInnertube(endpoint: "player", payload: payload, useMobile: true) { res in
            switch res {
            case .failure(let e):
                DispatchQueue.main.async { completion(.failure(e)) }
            case .success(let json):
                let parsed = autoreleasepool { Self.parsePlayerResponse(json, fallbackId: videoId) }
                DispatchQueue.main.async { completion(.success(parsed)) }
            }
        }
    }

    private static func parsePlayerResponse(_ json: [String: Any], fallbackId: String) -> PlayerResponse {
        let playability = json["playabilityStatus"] as? [String: Any]
        let status = playability?["status"] as? String ?? ""
        let errorReason: String? = (status != "OK") ? (playability?["reason"] as? String ?? "Video unavailable (\(status))") : nil

        let vd = json["videoDetails"] as? [String: Any] ?? [:]
        let sd = json["streamingData"] as? [String: Any] ?? [:]

        func parseFormat(_ d: [String: Any]) -> StreamFormat? {
            guard let itag = d["itag"] as? Int, let url = d["url"] as? String, !url.isEmpty else { return nil }
            let mimeFull = d["mimeType"] as? String ?? ""
            let mime = mimeFull.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces) ?? mimeFull
            var codecs = ""
            if let r = mimeFull.range(of: #"codecs="([^"]+)""#, options: .regularExpression) {
                codecs = String(mimeFull[r]).replacingOccurrences(of: "codecs=\"", with: "").replacingOccurrences(of: "\"", with: "")
            }
            let initR = parseRange(d["initRange"] as? [String: Any])
            let idxR = parseRange(d["indexRange"] as? [String: Any])
            let isV = mime.hasPrefix("video/")
            let isA = mime.hasPrefix("audio/")
            return StreamFormat(
                itag: itag,
                url: url,
                mimeType: mime,
                codecs: codecs,
                width: d["width"] as? Int ?? 0,
                height: d["height"] as? Int ?? 0,
                fps: d["fps"] as? Int ?? 0,
                bitrate: d["bitrate"] as? Int ?? 0,
                contentLength: Int64(d["contentLength"] as? String ?? "0") ?? 0,
                qualityLabel: d["qualityLabel"] as? String ?? (d["audioQuality"] as? String ?? ""),
                audioChannels: d["audioChannels"] as? Int ?? 2,
                audioSampleRate: Int(d["audioSampleRate"] as? String ?? "44100") ?? 44100,
                initRange: initR,
                indexRange: idxR,
                isVideo: isV,
                isAudio: isA
            )
        }

        func parseRange(_ d: [String: Any]?) -> ByteRange? {
            guard let d = d,
                  let s = Int64(d["start"] as? String ?? ""),
                  let e = Int64(d["end"] as? String ?? "") else { return nil }
            return ByteRange(start: s, end: e)
        }

        let progressive = (sd["formats"] as? [[String: Any]] ?? []).compactMap(parseFormat)
        let adaptive = (sd["adaptiveFormats"] as? [[String: Any]] ?? []).compactMap(parseFormat)
        let videos = adaptive.filter { $0.isVideo }.sorted {
            if $0.height != $1.height { return $0.height > $1.height }
            if $0.isH264 != $1.isH264 { return $0.isH264 } // Prefer hardware-decoded H.264
            return $0.bitrate > $1.bitrate
        }
        let audios = adaptive.filter { $0.isAudio }.sorted {
            if $0.isAAC != $1.isAAC { return $0.isAAC } // Prefer AAC MP4 for AVPlayer HLS
            return $0.bitrate > $1.bitrate
        }

        // Captions
        var captions: [CaptionTrack] = []
        if let capRoot = json["captions"] as? [String: Any],
           let renderer = capRoot["playerCaptionsTracklistRenderer"] as? [String: Any],
           let tracks = renderer["captionTracks"] as? [[String: Any]] {
            for t in tracks {
                guard let base = t["baseUrl"] as? String, let code = t["languageCode"] as? String else { continue }
                let name = extractText(t["name"])
                let kind = t["kind"] as? String ?? ""
                captions.append(CaptionTrack(
                    languageCode: code,
                    name: name.isEmpty ? code.uppercased() : name,
                    baseURL: base,
                    isAutoGenerated: kind == "asr"
                ))
            }
        }

        let sb = ((json["storyboards"] as? [String: Any])?["playerStoryboardSpecRenderer"] as? [String: Any])?["spec"] as? String

        return PlayerResponse(
            videoId: vd["videoId"] as? String ?? fallbackId,
            title: vd["title"] as? String ?? "",
            author: vd["author"] as? String ?? "",
            channelId: vd["channelId"] as? String ?? "",
            lengthSeconds: Double(vd["lengthSeconds"] as? String ?? "0") ?? 0,
            viewCount: vd["viewCount"] as? String ?? "",
            shortDescription: vd["shortDescription"] as? String ?? "",
            isLive: (vd["isLiveContent"] as? Bool ?? false) && (sd["hlsManifestUrl"] != nil),
            hlsManifestURL: sd["hlsManifestUrl"] as? String,
            videoFormats: videos,
            audioFormats: audios,
            progressiveFormats: progressive,
            captions: captions,
            storyboardSpec: sb,
            playabilityError: errorReason
        )
    }

    // MARK: - 2. Watch Page Metadata, Chapters, Related, Comment Token (`next`)

    func fetchWatchDetails(videoId: String, completion: @escaping (Result<WatchDetails, Error>) -> Void) {
        postInnertube(endpoint: "next", payload: ["videoId": videoId]) { res in
            switch res {
            case .failure(let e):
                DispatchQueue.main.async { completion(.failure(e)) }
            case .success(let json):
                let details = autoreleasepool { Self.parseWatchDetails(json, videoId: videoId) }
                DispatchQueue.main.async { completion(.success(details)) }
            }
        }
    }

    func fetchRelatedContinuation(token: String, completion: @escaping (Result<([VideoItem], String?), Error>) -> Void) {
        postInnertube(endpoint: "next", payload: ["continuation": token]) { res in
            switch res {
            case .failure(let e):
                DispatchQueue.main.async { completion(.failure(e)) }
            case .success(let json):
                let parsed = autoreleasepool { () -> ([VideoItem], String?) in
                    let items = Self.extractVideos(from: json)
                    let nextTok = Self.extractLastContinuationToken(from: json)
                    return (items, nextTok)
                }
                DispatchQueue.main.async { completion(.success(parsed)) }
            }
        }
    }

    private static func parseWatchDetails(_ json: [String: Any], videoId: String) -> WatchDetails {
        var title = ""
        var views = ""
        var dateText = ""
        var relDate = ""
        var likeText = ""
        var channelName = ""
        var channelId = ""
        var channelAvatar = ""
        var subCount = ""
        var isVerified = false
        var description = ""

        if let vpi = findFirstDict(in: json, key: "videoPrimaryInfoRenderer") {
            title = extractText(vpi["title"])
            if let vc = (vpi["viewCount"] as? [String: Any])?["videoViewCountRenderer"] as? [String: Any] {
                views = extractText(vc["viewCount"])
                if views.isEmpty { views = extractText(vc["shortViewCount"]) }
            }
            dateText = extractText(vpi["dateText"])
            relDate = extractText(vpi["relativeDateText"])
            if let lb = findFirstDict(in: vpi, key: "likeButtonViewModel"),
               let btn = findFirstDict(in: lb, key: "buttonViewModel") {
                likeText = btn["title"] as? String ?? ""
            }
        }

        if let vsi = findFirstDict(in: json, key: "videoSecondaryInfoRenderer") {
            if let owner = (vsi["owner"] as? [String: Any])?["videoOwnerRenderer"] as? [String: Any] {
                channelName = extractText(owner["title"])
                subCount = extractText(owner["subscriberCountText"])
                channelAvatar = bestThumbURL(owner["thumbnail"])
                if let nav = owner["navigationEndpoint"] as? [String: Any],
                   let be = nav["browseEndpoint"] as? [String: Any] {
                    channelId = be["browseId"] as? String ?? ""
                }
                if let badges = owner["badges"] as? [[String: Any]] {
                    isVerified = badges.contains { b in
                        let style = (b["metadataBadgeRenderer"] as? [String: Any])?["style"] as? String ?? ""
                        return style.contains("VERIFIED")
                    }
                }
            }
            if let attrDesc = vsi["attributedDescription"] as? [String: Any] {
                description = attrDesc["content"] as? String ?? ""
            }
            if description.isEmpty {
                description = extractText(vsi["description"])
            }
        }

        // Chapters from macroMarkersListItemRenderer
        var chapters: [VideoChapter] = []
        var seenStarts = Set<Int>()
        for m in findAllDicts(in: json, key: "macroMarkersListItemRenderer") {
            let ct = extractText(m["title"])
            let td = extractText(m["timeDescription"])
            var startSec: Double? = nil
            if let ep = (m["onTap"] as? [String: Any])?["watchEndpoint"] as? [String: Any],
               let st = ep["startTimeSeconds"] as? Double {
                startSec = st
            } else if let ep = (m["onTap"] as? [String: Any])?["watchEndpoint"] as? [String: Any],
                      let st = ep["startTimeSeconds"] as? Int {
                startSec = Double(st)
            } else {
                startSec = Formatters.parseTimestamp(td)
            }
            if let s = startSec, !ct.isEmpty, seenStarts.insert(Int(s)).inserted {
                chapters.append(VideoChapter(
                    title: ct,
                    startSeconds: s,
                    timeText: td.isEmpty ? Formatters.timeString(s) : td,
                    thumbnailURL: bestThumbURL(m["thumbnail"])
                ))
            }
        }
        chapters.sort { $0.startSeconds < $1.startSeconds }

        // Fallback: parse chapters from description timestamps if YouTube didn't send markers
        if chapters.isEmpty && !description.isEmpty {
            chapters = parseChaptersFromDescription(description)
        }

        // Related videos (secondaryResults)
        var related: [VideoItem] = []
        var relatedCont: String? = nil
        if let sec = findFirstDict(in: json, key: "secondaryResults") {
            related = extractVideos(from: sec)
            relatedCont = extractLastContinuationToken(from: sec)
        }

        // Comments continuation tokens (Top + Newest)
        var commentCont: String? = nil
        var commentNewestCont: String? = nil
        var commentCount = ""
        if let epList = json["engagementPanels"] as? [[String: Any]] {
            for panel in epList {
                guard let pr = panel["engagementPanelSectionListRenderer"] as? [String: Any] else { continue }
                let id = pr["panelIdentifier"] as? String ?? ""
                if id.contains("comment") {
                    if let hdr = (pr["header"] as? [String: Any])?["engagementPanelTitleHeaderRenderer"] as? [String: Any] {
                        commentCount = extractText(hdr["contextualInfo"])
                    }
                    // Sort menu tokens (Top comments vs Newest first)
                    let subItems = findAllDicts(in: pr, key: "sortFilterSubMenuRenderer")
                    if let items = subItems.first?["subMenuItems"] as? [[String: Any]] {
                        for it in items {
                            let lbl = (it["title"] as? String ?? "").lowercased()
                            if let tok = (findFirstDict(in: it, key: "continuationCommand"))?["token"] as? String {
                                if lbl.contains("newest") { commentNewestCont = tok }
                                else if commentCont == nil { commentCont = tok }
                            }
                        }
                    }
                    if commentCont == nil {
                        commentCont = extractFirstContinuationToken(from: pr)
                    }
                }
            }
        }
        if commentCont == nil {
            // Fallback: check primary results comment section
            if let primary = findFirstDict(in: json, key: "twoColumnWatchNextResults")?["results"] {
                for cc in findAllDicts(in: primary, key: "continuationCommand") {
                    if let tok = cc["token"] as? String, !tok.isEmpty {
                        commentCont = tok
                        break
                    }
                }
            }
        }

        return WatchDetails(
            videoId: videoId,
            title: title,
            viewCountText: views,
            dateText: dateText,
            relativeDateText: relDate,
            likeCountText: likeText,
            channelName: channelName,
            channelId: channelId,
            channelAvatarURL: channelAvatar,
            subscriberCountText: subCount,
            isVerified: isVerified,
            descriptionText: description,
            chapters: chapters,
            relatedVideos: related,
            relatedContinuation: relatedCont,
            commentsContinuation: commentCont,
            commentsNewestContinuation: commentNewestCont,
            commentCountText: commentCount
        )
    }

    private static func parseChaptersFromDescription(_ desc: String) -> [VideoChapter] {
        var result: [VideoChapter] = []
        let regex = try? NSRegularExpression(pattern: #"^(?:\s*)(\d{1,2}:\d{2}(?::\d{2})?)\s*[-–—|]?\s+(.+)$"#)
        for line in desc.components(separatedBy: .newlines) {
            let ns = line as NSString
            guard let m = regex?.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges == 3 else { continue }
            let ts = ns.substring(with: m.range(at: 1))
            let title = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            if let sec = Formatters.parseTimestamp(ts), !title.isEmpty {
                result.append(VideoChapter(title: title, startSeconds: sec, timeText: ts, thumbnailURL: nil))
            }
        }
        return result.count >= 2 ? result : []
    }

    // MARK: - 3. Comments & Replies

    func fetchComments(continuation: String, completion: @escaping (Result<([CommentItem], String?), Error>) -> Void) {
        postInnertube(endpoint: "next", payload: ["continuation": continuation]) { res in
            switch res {
            case .failure(let e):
                DispatchQueue.main.async { completion(.failure(e)) }
            case .success(let json):
                let parsed = autoreleasepool { Self.parseCommentsResponse(json) }
                DispatchQueue.main.async { completion(.success(parsed)) }
            }
        }
    }

    private static func parseCommentsResponse(_ json: [String: Any]) -> ([CommentItem], String?) {
        // Map commentKey -> replies continuation from commentThreadRenderer
        var replyContByKey: [String: String] = [:]
        var pinnedKeys = Set<String>()
        for thread in findAllDicts(in: json, key: "commentThreadRenderer") {
            let cvm = (thread["commentViewModel"] as? [String: Any])?["commentViewModel"] as? [String: Any]
            let key = cvm?["commentKey"] as? String ?? ""
            if cvm?["pinnedText"] != nil { pinnedKeys.insert(key) }
            if let replies = thread["replies"] as? [String: Any],
               let cc = findFirstDict(in: replies, key: "continuationCommand"),
               let tok = cc["token"] as? String {
                replyContByKey[key] = tok
            }
        }

        // Extract commentEntityPayload items (new YouTube frameworkUpdates format)
        var items: [CommentItem] = []
        var seenIds = Set<String>()
        for cep in findAllDicts(in: json, key: "commentEntityPayload") {
            let key = cep["key"] as? String ?? ""
            let props = cep["properties"] as? [String: Any] ?? [:]
            let author = cep["author"] as? [String: Any] ?? [:]
            let toolbar = cep["toolbar"] as? [String: Any] ?? [:]

            let cid = props["commentId"] as? String ?? UUID().uuidString
            guard seenIds.insert(cid).inserted else { continue }

            let text = (props["content"] as? [String: Any])?["content"] as? String ?? ""
            let pub = props["publishedTime"] as? String ?? ""
            let name = author["displayName"] as? String ?? "User"
            let chId = author["channelId"] as? String ?? ""
            let avatar = author["avatarThumbnailUrl"] as? String ?? ""
            let isOwner = author["isCreator"] as? Bool ?? false
            let likes = toolbar["likeCountNotliked"] as? String ?? ""
            let replyCount = toolbar["replyCount"] as? String ?? ""
            let hearted = !(toolbar["heartActiveTooltip"] as? String ?? "").isEmpty

            items.append(CommentItem(
                id: cid,
                authorName: name,
                authorChannelId: chId,
                authorAvatarURL: avatar,
                publishedTime: pub,
                text: text,
                likeCountText: likes.trimmingCharacters(in: .whitespaces),
                replyCountText: replyCount.trimmingCharacters(in: .whitespaces),
                isCreatorHearted: hearted,
                isPinned: pinnedKeys.contains(key),
                isAuthorChannelOwner: isOwner,
                repliesContinuation: replyContByKey[key]
            ))
        }

        // Next page continuation (last continuationItemRenderer outside replies)
        var nextCont: String? = nil
        if let endpoints = json["onResponseReceivedEndpoints"] as? [[String: Any]] {
            for ep in endpoints {
                let itemsArr: [[String: Any]] =
                    ((ep["reloadContinuationItemsCommand"] as? [String: Any])?["continuationItems"] as? [[String: Any]]) ??
                    ((ep["appendContinuationItemsAction"] as? [String: Any])?["continuationItems"] as? [[String: Any]]) ?? []
                if let last = itemsArr.last,
                   let cir = last["continuationItemRenderer"] as? [String: Any],
                   let cc = findFirstDict(in: cir, key: "continuationCommand"),
                   let tok = cc["token"] as? String {
                    nextCont = tok
                }
            }
        }
        return (items, nextCont)
    }

    // MARK: - 4. Home / Explore / Category Feed

    func fetchCategoryFeed(category: String, completion: @escaping (Result<([VideoItem], String?), Error>) -> Void) {
        if category == "All" {
            fetchBlendedHomeFeed(completion: completion)
            return
        }
        if let entry = Self.exploreCategories.first(where: { $0.name == category }) {
            if let bid = entry.browseId {
                postInnertube(endpoint: "browse", payload: ["browseId": bid]) { res in
                    switch res {
                    case .failure(let e): DispatchQueue.main.async { completion(.failure(e)) }
                    case .success(let json):
                        let out = autoreleasepool { (Self.extractVideos(from: json), Self.extractLastContinuationToken(from: json)) }
                        DispatchQueue.main.async { completion(.success(out)) }
                    }
                }
                return
            } else if let q = entry.searchQuery {
                search(query: q, filters: SearchFilters(sortBy: .relevance, uploadDate: .thisMonth, type: .video, duration: .any)) { res in
                    switch res {
                    case .failure(let e): completion(.failure(e))
                    case .success(let (items, cont)):
                        let vids = items.compactMap { if case .video(let v) = $0 { return v } else { return nil } }
                        completion(.success((vids, cont)))
                    }
                }
                return
            }
        }
        // Fallback topic search
        search(query: category, filters: SearchFilters(sortBy: .relevance, uploadDate: .thisMonth, type: .video, duration: .any)) { res in
            switch res {
            case .failure(let e): completion(.failure(e))
            case .success(let (items, cont)):
                let vids = items.compactMap { if case .video(let v) = $0 { return v } else { return nil } }
                completion(.success((vids, cont)))
            }
        }
    }

    /// Builds a rich YouTube Home feed: combines recommendations from recent watch history,
    /// subscribed channels, and live popular YouTube category feeds (Music, Gaming, Science, News).
    private func fetchBlendedHomeFeed(completion: @escaping (Result<([VideoItem], String?), Error>) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var buckets: [[VideoItem]] = []

        // 1. Seed recommendations from up to 2 recent history videos
        let recent = Array(LocalStore.shared.history.prefix(2))
        for h in recent {
            group.enter()
            postInnertube(endpoint: "next", payload: ["videoId": h.video.id]) { res in
                if case .success(let json) = res {
                    let vids = autoreleasepool {
                        if let sec = Self.findFirstDict(in: json, key: "secondaryResults") {
                            return Array(Self.extractVideos(from: sec).prefix(12))
                        }
                        return []
                    }
                    lock.lock(); buckets.append(vids); lock.unlock()
                }
                group.leave()
            }
        }

        // 2. Blend real YouTube browse feeds (Gaming, Music, News, Science)
        let browseSeeds = ["UCOpNcN46UbXVtpKMrmU4Abg", "UC-9-kyTW8ZkZNDHQJ6FgpwQ", "UCYfdidRxbB8Qhf0Nx7ioOYw"]
        for bid in browseSeeds {
            group.enter()
            postInnertube(endpoint: "browse", payload: ["browseId": bid]) { res in
                if case .success(let json) = res {
                    let vids = autoreleasepool { Array(Self.extractVideos(from: json).prefix(14)) }
                    lock.lock(); buckets.append(vids); lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            // Interleave buckets round-robin & deduplicate
            var out: [VideoItem] = []
            var seen = Set<String>()
            let maxLen = buckets.map(\.count).max() ?? 0
            for i in 0..<maxLen {
                for b in buckets where i < b.count {
                    let v = b[i]
                    if seen.insert(v.id).inserted {
                        out.append(v)
                    }
                }
            }
            completion(.success((out, nil)))
        }
    }

    func fetchBrowseContinuation(token: String, completion: @escaping (Result<([VideoItem], String?), Error>) -> Void) {
        postInnertube(endpoint: "browse", payload: ["continuation": token]) { res in
            switch res {
            case .failure(let e): DispatchQueue.main.async { completion(.failure(e)) }
            case .success(let json):
                let out = autoreleasepool { (Self.extractVideos(from: json), Self.extractLastContinuationToken(from: json)) }
                DispatchQueue.main.async { completion(.success(out)) }
            }
        }
    }

    // MARK: - 5. Search & Autocomplete

    func search(query: String, filters: SearchFilters = SearchFilters(), continuation: String? = nil, completion: @escaping (Result<([SearchResultItem], String?), Error>) -> Void) {
        var payload: [String: Any] = [:]
        if let cont = continuation {
            payload["continuation"] = cont
        } else {
            payload["query"] = query
            if let sp = filters.spParam { payload["params"] = sp }
        }
        postInnertube(endpoint: "search", payload: payload) { res in
            switch res {
            case .failure(let e): DispatchQueue.main.async { completion(.failure(e)) }
            case .success(let json):
                let parsed = autoreleasepool { Self.parseSearchResults(json) }
                DispatchQueue.main.async { completion(.success(parsed)) }
            }
        }
    }

    func fetchAutocomplete(query: String, completion: @escaping ([String]) -> Void) {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://suggestqueries-clients6.youtube.com/complete/search?client=youtube&ds=yt&q=\(encoded)") else {
            completion([])
            return
        }
        session.dataTask(with: url) { data, _, _ in
            guard let data = data, let text = String(data: data, encoding: .utf8) else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            // Response is JSONP: window.google.ac.h([query, [[suggestion, ...], ...]])
            var suggestions: [String] = []
            if let s = text.firstIndex(of: "("), let e = text.lastIndex(of: ")"), s < e {
                let inner = String(text[text.index(after: s)..<e])
                if let arr = try? JSONSerialization.jsonObject(with: Data(inner.utf8)) as? [Any],
                   arr.count >= 2,
                   let list = arr[1] as? [[Any]] {
                    suggestions = list.compactMap { $0.first as? String }
                }
            }
            DispatchQueue.main.async { completion(Array(suggestions.prefix(8))) }
        }.resume()
    }

    private static func parseSearchResults(_ json: [String: Any]) -> ([SearchResultItem], String?) {
        var items: [SearchResultItem] = []
        var seenVideoIds = Set<String>()
        var seenChanIds = Set<String>()
        var seenPlIds = Set<String>()

        func walk(_ obj: Any) {
            if let dict = obj as? [String: Any] {
                if let vr = dict["videoRenderer"] as? [String: Any], let v = parseVideoRenderer(vr) {
                    if seenVideoIds.insert(v.id).inserted { items.append(.video(v)) }
                    return
                }
                if let cr = dict["channelRenderer"] as? [String: Any], let c = parseChannelRenderer(cr) {
                    if seenChanIds.insert(c.id).inserted { items.append(.channel(c)) }
                    return
                }
                if let pr = dict["playlistRenderer"] as? [String: Any], let p = parsePlaylistRenderer(pr) {
                    if seenPlIds.insert(p.id).inserted { items.append(.playlist(p)) }
                    return
                }
                if let lk = dict["lockupViewModel"] as? [String: Any] {
                    let ctype = lk["contentType"] as? String ?? ""
                    if ctype.contains("PLAYLIST"), let p = parseLockupPlaylist(lk) {
                        if seenPlIds.insert(p.id).inserted { items.append(.playlist(p)) }
                        return
                    } else if let v = parseLockupVideo(lk) {
                        if seenVideoIds.insert(v.id).inserted { items.append(.video(v)) }
                        return
                    }
                }
                for val in dict.values { walk(val) }
            } else if let arr = obj as? [Any] {
                for el in arr { walk(el) }
            }
        }
        walk(json)
        return (items, extractLastContinuationToken(from: json))
    }

    // MARK: - 6. Channel Page & Tabs & Subscriptions Aggregation

    func fetchChannel(channelId: String, tabParams: String? = nil, completion: @escaping (Result<ChannelPageData, Error>) -> Void) {
        var payload: [String: Any] = ["browseId": channelId]
        if let p = tabParams, !p.isEmpty { payload["params"] = p }
        postInnertube(endpoint: "browse", payload: payload) { res in
            switch res {
            case .failure(let e): DispatchQueue.main.async { completion(.failure(e)) }
            case .success(let json):
                let parsed = autoreleasepool { Self.parseChannelPage(json, channelId: channelId) }
                DispatchQueue.main.async { completion(.success(parsed)) }
            }
        }
    }

    func fetchSubscriptionsFeed(channels: [SubscribedChannel], completion: @escaping ([VideoItem]) -> Void) {
        guard !channels.isEmpty else { completion([]); return }
        let group = DispatchGroup()
        let lock = NSLock()
        var buckets: [[VideoItem]] = []
        // Videos tab params
        let videosParams = "EgZ2aWRlb3PyBgQKAjoA"
        for ch in channels.prefix(12) {
            group.enter()
            postInnertube(endpoint: "browse", payload: ["browseId": ch.id, "params": videosParams]) { res in
                if case .success(let json) = res {
                    let vids = autoreleasepool {
                        Self.extractVideos(from: json, defaultChannelName: ch.name, defaultChannelId: ch.id, defaultAvatar: ch.avatarURL)
                            .prefix(6)
                    }
                    lock.lock(); buckets.append(Array(vids)); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            var out: [VideoItem] = []
            var seen = Set<String>()
            let maxLen = buckets.map(\.count).max() ?? 0
            for i in 0..<maxLen {
                for b in buckets where i < b.count {
                    let v = b[i]
                    if seen.insert(v.id).inserted { out.append(v) }
                }
            }
            completion(out)
        }
    }

    private static func parseChannelPage(_ json: [String: Any], channelId: String) -> ChannelPageData {
        var title = ""
        var handle = ""
        var subs = ""
        var vidCount = ""
        var desc = ""
        var avatar = ""
        var banner = ""
        var verified = false

        if let meta = (json["metadata"] as? [String: Any])?["channelMetadataRenderer"] as? [String: Any] {
            title = meta["title"] as? String ?? ""
            desc = meta["description"] as? String ?? ""
            avatar = bestThumbURL(meta["avatar"])
        }

        if let hdr = json["header"] as? [String: Any] {
            if let ph = hdr["pageHeaderRenderer"] as? [String: Any] {
                if title.isEmpty { title = ph["pageTitle"] as? String ?? "" }
                if let vm = (ph["content"] as? [String: Any])?["pageHeaderViewModel"] as? [String: Any] {
                    if let bannerSources = (((vm["banner"] as? [String: Any])?["imageBannerViewModel"] as? [String: Any])?["image"] as? [String: Any])?["sources"] as? [[String: Any]] {
                        banner = bannerSources.last?["url"] as? String ?? ""
                    }
                    if let avSources = findFirstDict(in: vm["image"] ?? [:], key: "image")?["sources"] as? [[String: Any]], let u = avSources.last?["url"] as? String {
                        avatar = u
                    }
                    // Extract handle / subs / video count from metadataRows
                    if let rows = ((vm["metadata"] as? [String: Any])?["contentMetadataViewModel"] as? [String: Any])?["metadataRows"] as? [[String: Any]] {
                        for row in rows {
                            for part in (row["metadataParts"] as? [[String: Any]] ?? []) {
                                let txt = (part["text"] as? [String: Any])?["content"] as? String ?? ""
                                if txt.hasPrefix("@") { handle = txt }
                                else if txt.lowercased().contains("subscriber") { subs = txt }
                                else if txt.lowercased().contains("video") { vidCount = txt }
                            }
                        }
                    }
                    let raw = (try? JSONSerialization.data(withJSONObject: vm)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    verified = raw.contains("CHECK_CIRCLE")
                }
            } else if let c4 = hdr["c4TabbedHeaderRenderer"] as? [String: Any] {
                if title.isEmpty { title = c4["title"] as? String ?? "" }
                subs = extractText(c4["subscriberCountText"])
                if avatar.isEmpty { avatar = bestThumbURL(c4["avatar"]) }
                banner = bestThumbURL(c4["banner"])
            }
        }

        var tabs: [ChannelTabInfo] = []
        if let tabArr = ((json["contents"] as? [String: Any])?["twoColumnBrowseResultsRenderer"] as? [String: Any])?["tabs"] as? [[String: Any]] {
            for t in tabArr {
                guard let tr = t["tabRenderer"] as? [String: Any],
                      let tTitle = tr["title"] as? String,
                      let ep = (tr["endpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any],
                      let params = ep["params"] as? String else { continue }
                if ["Home", "Videos", "Shorts", "Live", "Playlists"].contains(tTitle) {
                    tabs.append(ChannelTabInfo(title: tTitle, params: params))
                }
            }
        }

        let videos = extractVideos(from: json, defaultChannelName: title, defaultChannelId: channelId, defaultAvatar: avatar)
        let playlists = extractPlaylists(from: json, defaultChannelName: title, defaultChannelId: channelId)
        let cont = extractLastContinuationToken(from: json)

        return ChannelPageData(
            channelId: channelId,
            title: title,
            handle: handle,
            subscriberCountText: subs,
            videoCountText: vidCount,
            descriptionText: desc,
            avatarURL: avatar,
            bannerURL: banner,
            isVerified: verified,
            tabs: tabs,
            videos: videos,
            playlists: playlists,
            continuation: cont
        )
    }

    // MARK: - 7. Playlist Browse

    func fetchPlaylist(playlistId: String, completion: @escaping (Result<(title: String, videos: [VideoItem]), Error>) -> Void) {
        let bid = playlistId.hasPrefix("VL") ? playlistId : "VL\(playlistId)"
        postInnertube(endpoint: "browse", payload: ["browseId": bid]) { res in
            switch res {
            case .failure(let e): DispatchQueue.main.async { completion(.failure(e)) }
            case .success(let json):
                let parsed = autoreleasepool { () -> (String, [VideoItem]) in
                    var title = "Playlist"
                    if let meta = (json["metadata"] as? [String: Any])?["playlistMetadataRenderer"] as? [String: Any],
                       let t = meta["title"] as? String {
                        title = t
                    }
                    return (title, Self.extractVideos(from: json))
                }
                DispatchQueue.main.async { completion(.success(parsed)) }
            }
        }
    }

    // MARK: - 8. Shorts Feed

    func fetchShortsFeed(completion: @escaping ([VideoItem]) -> Void) {
        search(query: "#shorts", filters: SearchFilters(sortBy: .relevance, uploadDate: .thisWeek, type: .video, duration: .short)) { res in
            switch res {
            case .failure: completion([])
            case .success(let (items, _)):
                let vids = items.compactMap { item -> VideoItem? in
                    guard case .video(var v) = item else { return nil }
                    v.isShort = true
                    return v
                }
                completion(vids)
            }
        }
    }

    // MARK: - 9. Captions (WebVTT) & SponsorBlock & Storyboards

    func fetchCaptions(track: CaptionTrack, completion: @escaping ([CaptionCue]) -> Void) {
        let urlStr = track.baseURL.contains("fmt=") ? track.baseURL : (track.baseURL + "&fmt=vtt")
        guard let url = URL(string: urlStr) else { completion([]); return }
        session.dataTask(with: url) { data, _, _ in
            guard let data = data, let text = String(data: data, encoding: .utf8) else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let cues = Self.parseWebVTT(text)
            DispatchQueue.main.async { completion(cues) }
        }.resume()
    }

    func fetchSponsorSegments(videoId: String, completion: @escaping ([SponsorSegment]) -> Void) {
        let cats = #"["sponsor","selfpromo","interaction","intro","outro","preview","music_offtopic"]"#
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "https://sponsor.ajay.app/api/skipSegments?videoID=\(videoId)&categories=\(cats)") else {
            completion([])
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        session.dataTask(with: req) { data, resp, _ in
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let data = data,
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let segs: [SponsorSegment] = arr.compactMap { d in
                guard let seg = d["segment"] as? [Double], seg.count == 2,
                      let cat = d["category"] as? String else { return nil }
                let uuid = d["UUID"] as? String ?? UUID().uuidString
                return SponsorSegment(id: uuid, startTime: seg[0], endTime: seg[1], category: cat)
            }.sorted { $0.startTime < $1.startTime }
            DispatchQueue.main.async { completion(segs) }
        }.resume()
    }

    static func parseStoryboardSpec(_ spec: String?, videoDuration: Double) -> StoryboardLevel? {
        guard let spec = spec, !spec.isEmpty else { return nil }
        let parts = spec.components(separatedBy: "|")
        guard parts.count >= 2 else { return nil }
        let baseURL = parts[0]
        // Prefer level 2 (highest quality grid) or fallback to highest available
        let levelIndex = min(2, parts.count - 2)
        let lvlParts = parts[levelIndex + 1].components(separatedBy: "#")
        guard lvlParts.count >= 8,
              let w = Int(lvlParts[0]),
              let h = Int(lvlParts[1]),
              let count = Int(lvlParts[2]),
              let cols = Int(lvlParts[3]),
              let rows = Int(lvlParts[4]),
              cols > 0, rows > 0, count > 0 else { return nil }
        var interval = Double(lvlParts[5]) ?? 0
        if interval <= 0 && videoDuration > 0 {
            interval = (videoDuration * 1000.0) / Double(count)
        }
        let name = lvlParts[6]
        let sigh = lvlParts[7]
        let urlTemplate = baseURL
            .replacingOccurrences(of: "$L", with: "\(levelIndex)")
            .replacingOccurrences(of: "$N", with: name)
            + (baseURL.contains("?") ? "&" : "?") + "sigh=\(sigh)"
        return StoryboardLevel(
            urlTemplate: urlTemplate,
            thumbWidth: w,
            thumbHeight: h,
            thumbCount: count,
            cols: cols,
            rows: rows,
            intervalMs: max(interval, 500),
            name: name,
            sigh: sigh
        )
    }

    private static func parseWebVTT(_ vtt: String) -> [CaptionCue] {
        var cues: [CaptionCue] = []
        let lines = vtt.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0
        let tagRegex = try? NSRegularExpression(pattern: #"<[^>]+>"#)

        func parseTime(_ s: String) -> Double? {
            let clean = s.trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? s
            let parts = clean.split(separator: ":")
            if parts.count == 3 {
                guard let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2]) else { return nil }
                return h * 3600 + m * 60 + sec
            } else if parts.count == 2 {
                guard let m = Double(parts[0]), let sec = Double(parts[1]) else { return nil }
                return m * 60 + sec
            }
            return nil
        }

        while i < lines.count {
            let line = lines[i]
            if line.contains("-->") {
                let halves = line.components(separatedBy: "-->")
                if halves.count == 2,
                   let start = parseTime(halves[0]),
                   let end = parseTime(halves[1]) {
                    i += 1
                    var textLines: [String] = []
                    while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                        let raw = lines[i]
                        let cleaned = tagRegex?.stringByReplacingMatches(in: raw, range: NSRange(location: 0, length: (raw as NSString).length), withTemplate: "") ?? raw
                        let unescaped = decodeHTMLEntities(cleaned).trimmingCharacters(in: .whitespaces)
                        if !unescaped.isEmpty { textLines.append(unescaped) }
                        i += 1
                    }
                    let combined = textLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    // Deduplicate rolling auto-caption overlap
                    if !combined.isEmpty {
                        if let last = cues.last, last.text == combined {
                            // skip exact duplicate
                        } else if let last = cues.last, combined.hasPrefix(last.text), combined.count > last.text.count {
                            let suffix = String(combined.dropFirst(last.text.count)).trimmingCharacters(in: .whitespaces)
                            if !suffix.isEmpty {
                                cues.append(CaptionCue(startTime: start, endTime: end, text: suffix))
                            }
                        } else {
                            cues.append(CaptionCue(startTime: start, endTime: end, text: combined))
                        }
                    }
                    continue
                }
            }
            i += 1
        }
        return cues
    }

    private static func decodeHTMLEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
         .replacingOccurrences(of: "&lt;", with: "<")
         .replacingOccurrences(of: "&gt;", with: ">")
         .replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&#39;", with: "'")
         .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    // MARK: - Universal Innertube Video / Channel / Playlist Parsers

    private static func extractVideos(
        from root: Any,
        defaultChannelName: String = "",
        defaultChannelId: String = "",
        defaultAvatar: String? = nil
    ) -> [VideoItem] {
        var out: [VideoItem] = []
        var seen = Set<String>()

        func add(_ v: VideoItem?) {
            guard var v = v, !v.id.isEmpty, seen.insert(v.id).inserted else { return }
            if v.channelName.isEmpty { v.channelName = defaultChannelName }
            if v.channelId.isEmpty { v.channelId = defaultChannelId }
            if v.channelAvatarURL == nil || v.channelAvatarURL!.isEmpty { v.channelAvatarURL = defaultAvatar }
            out.append(v)
        }

        func walk(_ obj: Any) {
            if let dict = obj as? [String: Any] {
                if let vr = dict["videoRenderer"] as? [String: Any] {
                    add(parseVideoRenderer(vr)); return
                }
                if let gv = dict["gridVideoRenderer"] as? [String: Any] {
                    add(parseVideoRenderer(gv)); return
                }
                if let cv = dict["compactVideoRenderer"] as? [String: Any] {
                    add(parseVideoRenderer(cv)); return
                }
                if let pv = dict["playlistVideoRenderer"] as? [String: Any] {
                    add(parseVideoRenderer(pv)); return
                }
                if let lk = dict["lockupViewModel"] as? [String: Any] {
                    let ct = lk["contentType"] as? String ?? ""
                    if !ct.contains("PLAYLIST") {
                        add(parseLockupVideo(lk))
                    }
                    return
                }
                if let sl = dict["shortsLockupViewModel"] as? [String: Any] {
                    add(parseShortsLockup(sl)); return
                }
                for v in dict.values { walk(v) }
            } else if let arr = obj as? [Any] {
                for el in arr { walk(el) }
            }
        }
        walk(root)
        return out
    }

    private static func extractPlaylists(from root: Any, defaultChannelName: String = "", defaultChannelId: String = "") -> [PlaylistCard] {
        var out: [PlaylistCard] = []
        var seen = Set<String>()
        for lk in findAllDicts(in: root, key: "lockupViewModel") {
            if let ct = lk["contentType"] as? String, ct.contains("PLAYLIST"), var p = parseLockupPlaylist(lk) {
                if p.channelName.isEmpty { p.channelName = defaultChannelName }
                if p.channelId.isEmpty { p.channelId = defaultChannelId }
                if seen.insert(p.id).inserted { out.append(p) }
            }
        }
        for pr in findAllDicts(in: root, key: "playlistRenderer") {
            if var p = parsePlaylistRenderer(pr) {
                if p.channelName.isEmpty { p.channelName = defaultChannelName }
                if p.channelId.isEmpty { p.channelId = defaultChannelId }
                if seen.insert(p.id).inserted { out.append(p) }
            }
        }
        return out
    }

    private static func parseVideoRenderer(_ d: [String: Any]) -> VideoItem? {
        guard let vid = d["videoId"] as? String, vid.count == 11 else { return nil }
        let title = extractText(d["title"])
        guard !title.isEmpty else { return nil }

        var channelName = extractText(d["ownerText"])
        if channelName.isEmpty { channelName = extractText(d["shortBylineText"]) }
        if channelName.isEmpty { channelName = extractText(d["longBylineText"]) }

        var channelId = ""
        for field in ["ownerText", "shortBylineText", "longBylineText"] {
            if let runs = (d[field] as? [String: Any])?["runs"] as? [[String: Any]],
               let first = runs.first,
               let bid = ((first["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any])?["browseId"] as? String {
                channelId = bid
                break
            }
        }

        var avatar: String? = nil
        if let ctr = (d["channelThumbnailSupportedRenderers"] as? [String: Any])?["channelThumbnailWithLinkRenderer"] as? [String: Any] {
            avatar = bestThumbURL(ctr["thumbnail"])
        } else if let ct = d["channelThumbnail"] {
            avatar = bestThumbURL(ct)
        }

        let thumb = bestThumbURL(d["thumbnail"])
        let dur = extractText(d["lengthText"])
        var views = extractText(d["shortViewCountText"])
        if views.isEmpty { views = extractText(d["viewCountText"]) }
        let pub = extractText(d["publishedTimeText"])

        let badges = d["badges"] as? [[String: Any]] ?? []
        let isLive = dur.isEmpty && (views.lowercased().contains("watching") || badges.contains {
            (($0["metadataBadgeRenderer"] as? [String: Any])?["style"] as? String ?? "").contains("LIVE")
        })
        let ownerBadges = d["ownerBadges"] as? [[String: Any]] ?? []
        let isVerified = ownerBadges.contains {
            (($0["metadataBadgeRenderer"] as? [String: Any])?["style"] as? String ?? "").contains("VERIFIED")
        }

        var snippet = ""
        if let snips = d["detailedMetadataSnippets"] as? [[String: Any]], let first = snips.first {
            snippet = extractText(first["snippetText"])
        } else {
            snippet = extractText(d["descriptionSnippet"])
        }

        return VideoItem(
            id: vid,
            title: title,
            channelName: channelName,
            channelId: channelId,
            channelAvatarURL: avatar,
            thumbnailURL: thumb,
            durationText: isLive ? "LIVE" : dur,
            viewsText: views,
            publishedText: pub,
            isLive: isLive,
            isShort: false,
            isVerified: isVerified,
            descriptionSnippet: snippet
        )
    }

    private static func parseLockupVideo(_ lk: [String: Any]) -> VideoItem? {
        guard let vid = lk["contentId"] as? String, vid.count == 11 else { return nil }
        guard let meta = (lk["metadata"] as? [String: Any])?["lockupMetadataViewModel"] as? [String: Any] else { return nil }
        let title = (meta["title"] as? [String: Any])?["content"] as? String ?? ""
        guard !title.isEmpty else { return nil }

        // Thumbnail & duration badge
        var thumb = ""
        var dur = ""
        if let ci = lk["contentImage"] as? [String: Any],
           let tvm = ci["thumbnailViewModel"] as? [String: Any] {
            if let sources = (tvm["image"] as? [String: Any])?["sources"] as? [[String: Any]] {
                thumb = (sources.first(where: { ($0["width"] as? Int ?? 0) >= 320 }) ?? sources.last)?["url"] as? String ?? ""
            }
            if let badge = findFirstDict(in: tvm, key: "thumbnailBadgeViewModel") {
                dur = badge["text"] as? String ?? ""
            }
        }

        // Avatar & channelId
        var avatar: String? = nil
        var channelId = ""
        if let img = meta["image"] as? [String: Any] {
            if let av = findFirstDict(in: img, key: "avatarViewModel"),
               let sources = (av["image"] as? [String: Any])?["sources"] as? [[String: Any]] {
                avatar = sources.last?["url"] as? String
            }
            if let be = findFirstDict(in: img, key: "browseEndpoint"),
               let bid = be["browseId"] as? String {
                channelId = bid
            }
        }

        // Metadata rows: [channelName], [views, publishedTime]
        var channelName = ""
        var views = ""
        var pub = ""
        if let rows = ((meta["metadata"] as? [String: Any])?["contentMetadataViewModel"] as? [String: Any])?["metadataRows"] as? [[String: Any]] {
            var allParts: [String] = []
            for row in rows {
                for p in (row["metadataParts"] as? [[String: Any]] ?? []) {
                    if let txt = (p["text"] as? [String: Any])?["content"] as? String, !txt.isEmpty {
                        allParts.append(txt)
                    }
                }
            }
            for part in allParts {
                let low = part.lowercased()
                if low.contains("view") || low.contains("watching") {
                    views = part
                } else if low.contains("ago") || low.contains("streamed") || low.contains("premiered") {
                    pub = part
                } else if channelName.isEmpty {
                    channelName = part
                }
            }
        }

        let isLive = dur.uppercased() == "LIVE" || views.lowercased().contains("watching")
        return VideoItem(
            id: vid,
            title: title,
            channelName: channelName,
            channelId: channelId,
            channelAvatarURL: avatar,
            thumbnailURL: thumb,
            durationText: isLive ? "LIVE" : dur,
            viewsText: views,
            publishedText: pub,
            isLive: isLive
        )
    }

    private static func parseShortsLockup(_ sl: [String: Any]) -> VideoItem? {
        guard let rwe = findFirstDict(in: sl, key: "reelWatchEndpoint"),
              let vid = rwe["videoId"] as? String, vid.count == 11 else { return nil }
        var title = ""
        var views = ""
        if let ov = sl["overlayMetadata"] as? [String: Any] {
            title = (ov["primaryText"] as? [String: Any])?["content"] as? String ?? ""
            views = (ov["secondaryText"] as? [String: Any])?["content"] as? String ?? ""
        }
        if title.isEmpty {
            title = (sl["accessibilityText"] as? String ?? "Short").components(separatedBy: ",").first ?? "Short"
        }
        var thumb = ""
        if let sources = (sl["thumbnail"] as? [String: Any])?["sources"] as? [[String: Any]] {
            thumb = sources.last?["url"] as? String ?? ""
        }
        return VideoItem(
            id: vid,
            title: title,
            channelName: "",
            channelId: "",
            channelAvatarURL: nil,
            thumbnailURL: thumb,
            durationText: "SHORT",
            viewsText: views,
            publishedText: "",
            isLive: false,
            isShort: true
        )
    }

    private static func parseChannelRenderer(_ d: [String: Any]) -> ChannelCard? {
        guard let cid = d["channelId"] as? String, !cid.isEmpty else { return nil }
        let name = extractText(d["title"])
        let avatar = bestThumbURL(d["thumbnail"])
        let subText = extractText(d["videoCountText"]) // YouTube swaps handle/subCount here sometimes
        let handleOrSub = extractText(d["subscriberCountText"])
        let handle = handleOrSub.hasPrefix("@") ? handleOrSub : (subText.hasPrefix("@") ? subText : "")
        let subs = handleOrSub.lowercased().contains("subscriber") ? handleOrSub : (subText.lowercased().contains("subscriber") ? subText : handleOrSub)
        let desc = extractText(d["descriptionSnippet"])
        let ownerBadges = d["ownerBadges"] as? [[String: Any]] ?? []
        let verified = ownerBadges.contains { (($0["metadataBadgeRenderer"] as? [String: Any])?["style"] as? String ?? "").contains("VERIFIED") }
        return ChannelCard(id: cid, name: name, handle: handle, avatarURL: avatar, subscriberCountText: subs, videoCountText: "", descriptionSnippet: desc, isVerified: verified)
    }

    private static func parsePlaylistRenderer(_ d: [String: Any]) -> PlaylistCard? {
        guard let pid = d["playlistId"] as? String, !pid.isEmpty else { return nil }
        let title = extractText(d["title"])
        let ch = extractText(d["shortBylineText"])
        let count = d["videoCount"] as? String ?? extractText(d["videoCountText"])
        let thumb = bestThumbURL((d["thumbnails"] as? [[String: Any]])?.first)
        return PlaylistCard(id: pid, title: title, channelName: ch, channelId: "", thumbnailURL: thumb, videoCountText: "\(count) videos")
    }

    private static func parseLockupPlaylist(_ lk: [String: Any]) -> PlaylistCard? {
        var pid = lk["contentId"] as? String ?? ""
        if let we = findFirstDict(in: lk, key: "watchEndpoint"), let fullId = we["playlistId"] as? String, !fullId.isEmpty {
            pid = fullId
        } else if let be = findFirstDict(in: lk, key: "browseEndpoint"), let bid = be["browseId"] as? String, bid.hasPrefix("VL") {
            pid = String(bid.dropFirst(2))
        }
        guard !pid.isEmpty else { return nil }
        let meta = (lk["metadata"] as? [String: Any])?["lockupMetadataViewModel"] as? [String: Any]
        let title = (meta?["title"] as? [String: Any])?["content"] as? String ?? "Playlist"
        var thumb = ""
        var countText = "Playlist"
        if let ci = lk["contentImage"] as? [String: Any] {
            if let tvm = findFirstDict(in: ci, key: "thumbnailViewModel"),
               let sources = (tvm["image"] as? [String: Any])?["sources"] as? [[String: Any]] {
                thumb = sources.last?["url"] as? String ?? ""
            }
            if let badge = findFirstDict(in: ci, key: "thumbnailBadgeViewModel"), let txt = badge["text"] as? String {
                countText = txt
            }
        }
        return PlaylistCard(id: pid, title: title, channelName: "", channelId: "", thumbnailURL: thumb, videoCountText: countText)
    }

    // MARK: - JSON Traversal Helpers

    private static func extractText(_ obj: Any?) -> String {
        guard let dict = obj as? [String: Any] else { return "" }
        if let simple = dict["simpleText"] as? String { return simple }
        if let content = dict["content"] as? String { return content }
        if let runs = dict["runs"] as? [[String: Any]] {
            return runs.compactMap { $0["text"] as? String }.joined()
        }
        return ""
    }

    private static func bestThumbURL(_ obj: Any?) -> String {
        guard let dict = obj as? [String: Any],
              let arr = dict["thumbnails"] as? [[String: Any]], !arr.isEmpty else { return "" }
        // Pick medium-sized thumbnail (~320-480px) to save bandwidth & decode memory
        let preferred = arr.first(where: { ($0["width"] as? Int ?? 0) >= 300 }) ?? arr.last
        var url = preferred?["url"] as? String ?? ""
        if url.hasPrefix("//") { url = "https:" + url }
        return url
    }

    private static func findFirstDict(in obj: Any, key: String) -> [String: Any]? {
        if let dict = obj as? [String: Any] {
            if let hit = dict[key] as? [String: Any] { return hit }
            for v in dict.values {
                if let found = findFirstDict(in: v, key: key) { return found }
            }
        } else if let arr = obj as? [Any] {
            for el in arr {
                if let found = findFirstDict(in: el, key: key) { return found }
            }
        }
        return nil
    }

    private static func findAllDicts(in obj: Any, key: String) -> [[String: Any]] {
        var out: [[String: Any]] = []
        func walk(_ cur: Any) {
            if let dict = cur as? [String: Any] {
                if let hit = dict[key] as? [String: Any] { out.append(hit) }
                for v in dict.values { walk(v) }
            } else if let arr = cur as? [Any] {
                for el in arr { walk(el) }
            }
        }
        walk(obj)
        return out
    }

    private static func extractFirstContinuationToken(from obj: Any) -> String? {
        findFirstDict(in: obj, key: "continuationCommand")?["token"] as? String
    }

    private static func extractLastContinuationToken(from obj: Any) -> String? {
        findAllDicts(in: obj, key: "continuationCommand").last?["token"] as? String
    }
}

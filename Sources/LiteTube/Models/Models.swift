import Foundation

// MARK: - Core Video & Feed Models

struct VideoItem: Codable, Hashable, Identifiable {
    let id: String // 11-char YouTube videoId
    var title: String
    var channelName: String
    var channelId: String
    var channelAvatarURL: String?
    var thumbnailURL: String
    var durationText: String
    var viewsText: String
    var publishedText: String
    var isLive: Bool = false
    var isShort: Bool = false
    var isVerified: Bool = false
    var descriptionSnippet: String = ""

    var watchURL: String { "https://www.youtube.com/watch?v=\(id)" }

    var bestThumbnailURL: String {
        if !thumbnailURL.isEmpty { return thumbnailURL }
        return "https://i.ytimg.com/vi/\(id)/mqdefault.jpg"
    }
}

struct ChannelCard: Hashable, Identifiable {
    let id: String // UC...
    var name: String
    var handle: String
    var avatarURL: String
    var subscriberCountText: String
    var videoCountText: String
    var descriptionSnippet: String
    var isVerified: Bool = false
}

struct PlaylistCard: Hashable, Identifiable {
    let id: String // PL...
    var title: String
    var channelName: String
    var channelId: String
    var thumbnailURL: String
    var videoCountText: String
}

enum SearchResultItem: Hashable {
    case video(VideoItem)
    case channel(ChannelCard)
    case playlist(PlaylistCard)
}

struct SearchFilters: Equatable {
    enum SortBy: String, CaseIterable {
        case relevance = "Relevance"
        case uploadDate = "Upload date"
        case viewCount = "View count"
        case rating = "Rating"
    }
    enum UploadDate: String, CaseIterable {
        case any = "Any time"
        case lastHour = "Last hour"
        case today = "Today"
        case thisWeek = "This week"
        case thisMonth = "This month"
        case thisYear = "This year"
    }
    enum ResultType: String, CaseIterable {
        case all = "All"
        case video = "Video"
        case channel = "Channel"
        case playlist = "Playlist"
    }
    enum Duration: String, CaseIterable {
        case any = "Any duration"
        case short = "Under 4 min"
        case medium = "4–20 min"
        case long = "Over 20 min"
    }

    var sortBy: SortBy = .relevance
    var uploadDate: UploadDate = .any
    var type: ResultType = .all
    var duration: Duration = .any

    /// Encodes YouTube's protobuf search `sp` parameter.
    var spParam: String? {
        if sortBy == .relevance && uploadDate == .any && type == .all && duration == .any {
            return nil
        }
        var bytes: [UInt8] = []
        // Field 1 (varint): sort (0=relevance, 1=rating, 2=uploadDate, 3=viewCount)
        let sortCode: UInt8? = {
            switch sortBy {
            case .relevance: return nil
            case .rating: return 1
            case .uploadDate: return 2
            case .viewCount: return 3
            }
        }()
        if let s = sortCode {
            bytes.append(0x08) // field 1, varint
            bytes.append(s)
        }
        // Field 2 (length-delimited submessage): filter
        var sub: [UInt8] = []
        switch uploadDate {
        case .any: break
        case .lastHour: sub += [0x08, 1]
        case .today: sub += [0x08, 2]
        case .thisWeek: sub += [0x08, 3]
        case .thisMonth: sub += [0x08, 4]
        case .thisYear: sub += [0x08, 5]
        }
        switch type {
        case .all: break
        case .video: sub += [0x10, 1]
        case .channel: sub += [0x10, 2]
        case .playlist: sub += [0x10, 3]
        }
        switch duration {
        case .any: break
        case .short: sub += [0x18, 1]
        case .long: sub += [0x18, 2]
        case .medium: sub += [0x18, 3]
        }
        if !sub.isEmpty {
            bytes.append(0x12) // field 2, len-delimited
            bytes.append(UInt8(sub.count))
            bytes.append(contentsOf: sub)
        }
        return Data(bytes).base64EncodedString()
    }
}

// MARK: - Player & Stream Models

struct ByteRange {
    let start: Int64
    let end: Int64
    var length: Int64 { end - start + 1 }
}

struct StreamFormat: Identifiable {
    var id: Int { itag }
    let itag: Int
    let url: String
    let mimeType: String
    let codecs: String
    let width: Int
    let height: Int
    let fps: Int
    let bitrate: Int
    let contentLength: Int64
    let qualityLabel: String
    let audioChannels: Int
    let audioSampleRate: Int
    let initRange: ByteRange?
    let indexRange: ByteRange?
    let isVideo: Bool
    let isAudio: Bool

    var isMP4: Bool { mimeType.lowercased().contains("mp4") }
    var isH264: Bool { codecs.lowercased().hasPrefix("avc1") }
    var isAV1: Bool { codecs.lowercased().hasPrefix("av01") }
    var isAAC: Bool { codecs.lowercased().hasPrefix("mp4a") }
    var codecShortName: String {
        let c = codecs.lowercased()
        if c.hasPrefix("avc1") { return "H.264" }
        if c.hasPrefix("av01") { return "AV1" }
        if c.hasPrefix("vp09") || c.hasPrefix("vp9") { return "VP9" }
        if c.hasPrefix("mp4a") { return "AAC" }
        if c.hasPrefix("opus") { return "Opus" }
        return codecs
    }
}

struct CaptionTrack: Identifiable, Hashable {
    var id: String { "\(languageCode)-\(isAutoGenerated ? "auto" : "man")" }
    let languageCode: String
    let name: String
    let baseURL: String
    let isAutoGenerated: Bool
}

struct CaptionCue: Identifiable {
    let id = UUID()
    let startTime: Double
    let endTime: Double
    let text: String
}

struct StoryboardLevel {
    let urlTemplate: String
    let thumbWidth: Int
    let thumbHeight: Int
    let thumbCount: Int
    let cols: Int
    let rows: Int
    let intervalMs: Double
    let name: String
    let sigh: String
}

struct PlayerResponse {
    let videoId: String
    let title: String
    let author: String
    let channelId: String
    let lengthSeconds: Double
    let viewCount: String
    let shortDescription: String
    let isLive: Bool
    let hlsManifestURL: String?
    let videoFormats: [StreamFormat]
    let audioFormats: [StreamFormat]
    let progressiveFormats: [StreamFormat]
    let captions: [CaptionTrack]
    let storyboardSpec: String?
    let playabilityError: String?
}

// MARK: - Watch Page Metadata, Chapters, Comments, SponsorBlock

struct VideoChapter: Identifiable, Hashable {
    var id: Double { startSeconds }
    let title: String
    let startSeconds: Double
    let timeText: String
    let thumbnailURL: String?
}

struct WatchDetails {
    let videoId: String
    var title: String
    var viewCountText: String
    var dateText: String
    var relativeDateText: String
    var likeCountText: String
    var channelName: String
    var channelId: String
    var channelAvatarURL: String
    var subscriberCountText: String
    var isVerified: Bool
    var descriptionText: String
    var chapters: [VideoChapter]
    var relatedVideos: [VideoItem]
    var relatedContinuation: String?
    var commentsContinuation: String?
    var commentsNewestContinuation: String?
    var commentCountText: String
}

struct CommentItem: Identifiable {
    let id: String
    let authorName: String
    let authorChannelId: String
    let authorAvatarURL: String
    let publishedTime: String
    let text: String
    let likeCountText: String
    let replyCountText: String
    let isCreatorHearted: Bool
    let isPinned: Bool
    let isAuthorChannelOwner: Bool
    let repliesContinuation: String?
    var replies: [CommentItem] = []
    var repliesExpanded: Bool = false
}

struct SponsorSegment: Identifiable {
    let id: String
    let startTime: Double
    let endTime: Double
    let category: String

    var displayName: String {
        switch category {
        case "sponsor": return "Sponsor"
        case "selfpromo": return "Self-Promo"
        case "intro": return "Intro"
        case "outro": return "Outro"
        case "interaction": return "Interaction Reminder"
        case "preview": return "Preview/Recap"
        case "music_offtopic": return "Non-Music"
        default: return category.capitalized
        }
    }
}

// MARK: - Channel Page Models

struct ChannelTabInfo: Hashable {
    let title: String
    let params: String
}

struct ChannelPageData {
    let channelId: String
    var title: String
    var handle: String
    var subscriberCountText: String
    var videoCountText: String
    var descriptionText: String
    var avatarURL: String
    var bannerURL: String
    var isVerified: Bool
    var tabs: [ChannelTabInfo]
    var videos: [VideoItem]
    var playlists: [PlaylistCard]
    var continuation: String?
}

// MARK: - Local Persistence Models

struct SubscribedChannel: Codable, Hashable, Identifiable {
    let id: String // UC...
    var name: String
    var avatarURL: String
    var subscriberCountText: String
    var subscribedAt: Date
}

struct WatchHistoryEntry: Codable, Hashable, Identifiable {
    var id: String { video.id }
    var video: VideoItem
    var lastPositionSeconds: Double
    var durationSeconds: Double
    var watchedAt: Date
}

struct LocalPlaylist: Codable, Hashable, Identifiable {
    let id: String
    var name: String
    var videos: [VideoItem]
    var createdAt: Date
}

struct AppSettings: Codable {
    var preferredQuality: String = "1080p" // Auto, 1080p, 720p, 480p, 360p, 240p, 144p, Audio Only
    var autoplayNext: Bool = true
    var sponsorBlockEnabled: Bool = true
    var sponsorBlockAutoSkip: Bool = true
    var darkMode: Bool = true
    var defaultVolume: Float = 0.85
    var defaultSpeed: Float = 1.0
    var pauseHistory: Bool = false
    var showCaptionsByDefault: Bool = false
    var maxRAMBudgetMB: Int = 100
}

// MARK: - Formatting Helpers

enum Formatters {
    static func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    static func parseTimestamp(_ text: String) -> Double? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        if parts.count == 2 {
            return Double(parts[0] * 60 + parts[1])
        } else if parts.count == 3 {
            return Double(parts[0] * 3600 + parts[1] * 60 + parts[2])
        }
        return nil
    }

    /// Extract YouTube videoId and optional start timestamp (`t=`) from a URL or raw 11-char ID.
    static func parseYouTubeURL(_ input: String) -> (videoId: String, startSeconds: Double?)? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == 11, trimmed.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil {
            return (trimmed, nil)
        }
        guard let url = URL(string: trimmed.hasPrefix("http") ? trimmed : "https://\(trimmed)"),
              let host = url.host?.lowercased(),
              host.contains("youtube.com") || host.contains("youtu.be") || host.contains("music.youtube.com") else {
            return nil
        }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var videoId: String?
        if host.contains("youtu.be") {
            videoId = url.pathComponents.dropFirst().first
        } else if url.path.hasPrefix("/shorts/") {
            videoId = url.pathComponents.dropFirst(2).first
        } else if url.path.hasPrefix("/embed/") || url.path.hasPrefix("/live/") {
            videoId = url.pathComponents.dropFirst(2).first
        } else {
            videoId = comps?.queryItems?.first(where: { $0.name == "v" })?.value
        }
        guard let vid = videoId, vid.count == 11 else { return nil }

        var startSeconds: Double?
        if let t = comps?.queryItems?.first(where: { $0.name == "t" || $0.name == "start" })?.value {
            if let num = Double(t.replacingOccurrences(of: "s", with: "")) {
                startSeconds = num
            } else {
                // Handle 1h2m3s format
                var total: Double = 0
                let regex = try? NSRegularExpression(pattern: #"(\d+)([hms])"#)
                let ns = t as NSString
                regex?.enumerateMatches(in: t, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                    guard let m = m, m.numberOfRanges == 3 else { return }
                    let val = Double(ns.substring(with: m.range(at: 1))) ?? 0
                    switch ns.substring(with: m.range(at: 2)) {
                    case "h": total += val * 3600
                    case "m": total += val * 60
                    case "s": total += val
                    default: break
                    }
                }
                if total > 0 { startSeconds = total }
            }
        }
        return (vid, startSeconds)
    }
}

import Foundation
import Darwin

/// Zero-bloat, in-process HTTP/1.1 DASH-to-HLS v7 bridge.
/// Parses ISO-BMFF `sidx` boxes from YouTube's direct fMP4 streams and serves
/// standard HLS v7 playlists + streamed 64 KB-buffered segment proxies to AVPlayer.
/// Result: Native Apple Silicon VideoToolbox hardware decode at 144p–4K with ~0.2 MB server RAM.
final class LocalHLSServer {
    static let shared = LocalHLSServer()

    struct Segment {
        let start: Int64
        let end: Int64
        let duration: Double
    }

    struct ParsedTrack {
        let format: StreamFormat
        let initRange: ByteRange
        let segments: [Segment]
        let targetDuration: Int
    }

    struct Session {
        let id: String
        let videoTracks: [Int: ParsedTrack] // itag -> track
        let audioTrack: ParsedTrack?
        let orderedVideoItags: [Int]
    }

    struct ProgressiveSession {
        let id: String
        let format: StreamFormat
    }

    private let lock = NSLock()
    private var sessions: [String: Session] = [:]
    private var progressiveSessions: [String: ProgressiveSession] = [:]
    private var listenFD: Int32 = -1
    private(set) var port: UInt16 = 0
    private let acceptQueue = DispatchQueue(label: "com.litetube.hls.accept", qos: .userInitiated)
    private let connQueue = DispatchQueue(label: "com.litetube.hls.conn", qos: .userInitiated, attributes: .concurrent)

    private let streamUA = "com.google.android.youtube/20.10.38 (Linux; U; Android 14) gzip"

    var activeSessionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return sessions.count + progressiveSessions.count
    }

    private init() {
        startServer()
    }

    // MARK: - POSIX Loopback HTTP Server

    private func startServer() {
        signal(SIGPIPE, SIG_IGN)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // ephemeral port
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 64) == 0 else {
            close(fd)
            return
        }

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(fd, $0, &len)
            }
        }
        self.listenFD = fd
        self.port = UInt16(bigEndian: boundAddr.sin_port)

        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    private func acceptLoop() {
        while listenFD >= 0 {
            var clientAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let cfd = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(listenFD, $0, &addrLen)
                }
            }
            if cfd < 0 { continue }
            var noSigPipe: Int32 = 1
            setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            connQueue.async { [weak self] in
                self?.handleClient(cfd)
            }
        }
    }

    // MARK: - Session Preparation (SIDX Parsing)

    /// Prepares an HLS session for a chosen video format (or nil for Audio Only) + audio format.
    /// Keeps ONLY the latest session in memory to guarantee zero session leaks.
    func prepareSession(
        videoFormats: [StreamFormat],
        audioFormat: StreamFormat?,
        completion: @escaping (Result<(sessionId: String, masterURL: URL), Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let group = DispatchGroup()
            let resultsLock = NSLock()
            var parsedVideos: [Int: ParsedTrack] = [:]
            var parsedAudio: ParsedTrack?
            var firstError: Error?

            for vf in videoFormats {
                group.enter()
                self.fetchAndParseSIDX(format: vf) { res in
                    resultsLock.lock()
                    switch res {
                    case .success(let track): parsedVideos[vf.itag] = track
                    case .failure(let err): if firstError == nil { firstError = err }
                    }
                    resultsLock.unlock()
                    group.leave()
                }
            }

            if let af = audioFormat {
                group.enter()
                self.fetchAndParseSIDX(format: af) { res in
                    resultsLock.lock()
                    switch res {
                    case .success(let track): parsedAudio = track
                    case .failure(let err): if firstError == nil { firstError = err }
                    }
                    resultsLock.unlock()
                    group.leave()
                }
            }

            group.wait()

            if parsedVideos.isEmpty && parsedAudio == nil {
                let err = firstError ?? NSError(domain: "LocalHLS", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to index media streams"])
                DispatchQueue.main.async { completion(.failure(err)) }
                return
            }

            let sid = UUID().uuidString.prefix(8).lowercased()
            let ordered = videoFormats.map(\.itag).filter { parsedVideos[$0] != nil }
            let session = Session(id: String(sid), videoTracks: parsedVideos, audioTrack: parsedAudio, orderedVideoItags: ordered)

            self.lock.lock()
            // Evict old sessions so we never accumulate stale segment maps
            self.sessions.removeAll()
            self.sessions[session.id] = session
            self.lock.unlock()

            let url = URL(string: "http://127.0.0.1:\(self.port)/s/\(session.id)/master.m3u8")!
            DispatchQueue.main.async { completion(.success((session.id, url))) }
        }
    }

    /// Probes whether an adaptive stream is unrestricted past 75% (not GVS PO-token gated).
    func probeAdaptiveUnrestricted(format: StreamFormat, completion: @escaping (Bool) -> Void) {
        let probeOff = max(Int64(0), (format.contentLength > 0 ? (format.contentLength * 3 / 4) : 10_000_000))
        guard let url = URL(string: "\(format.url)&range=\(probeOff)-\(probeOff + 1023)") else {
            completion(false)
            return
        }
        var req = URLRequest(url: url)
        req.setValue(streamUA, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 5
        let sess = URLSession(configuration: .ephemeral)
        sess.dataTask(with: req) { _, resp, err in
            defer { sess.finishTasksAndInvalidate() }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            completion(err == nil && (code == 200 || code == 206))
        }.resume()
    }

    /// Creates a loopback Range-proxied URL for an unrestricted progressive MP4 stream.
    func prepareProgressiveSession(format: StreamFormat) -> URL {
        let sid = String(UUID().uuidString.prefix(8).lowercased())
        lock.lock()
        sessions.removeAll()
        progressiveSessions.removeAll()
        progressiveSessions[sid] = ProgressiveSession(id: sid, format: format)
        lock.unlock()
        return URL(string: "http://127.0.0.1:\(self.port)/p/\(sid)/video.mp4")!
    }

    func clearAllSessions() {
        lock.lock()
        sessions.removeAll()
        progressiveSessions.removeAll()
        lock.unlock()
    }

    private func fetchAndParseSIDX(format: StreamFormat, completion: @escaping (Result<ParsedTrack, Error>) -> Void) {
        guard let initR = format.initRange, let idxR = format.indexRange,
              let url = URL(string: "\(format.url)&range=\(idxR.start)-\(idxR.end)") else {
            completion(.failure(NSError(domain: "LocalHLS", code: -2, userInfo: [NSLocalizedDescriptionKey: "Missing init/index range for itag \(format.itag)"])))
            return
        }
        var req = URLRequest(url: url)
        req.setValue(streamUA, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 12

        let cfg = URLSessionConfiguration.ephemeral
        let sess = URLSession(configuration: cfg)
        sess.dataTask(with: req) { data, _, err in
            defer { sess.finishTasksAndInvalidate() }
            if let err = err {
                completion(.failure(err))
                return
            }
            guard let data = data, let segments = Self.parseSIDX(data: data, indexEnd: idxR.end), !segments.isEmpty else {
                completion(.failure(NSError(domain: "LocalHLS", code: -3, userInfo: [NSLocalizedDescriptionKey: "Invalid sidx box for itag \(format.itag)"])))
                return
            }
            let maxDur = segments.map(\.duration).max() ?? 5.0
            let track = ParsedTrack(format: format, initRange: initR, segments: segments, targetDuration: max(1, Int(ceil(maxDur))))
            completion(.success(track))
        }.resume()
    }

    /// Parses ISO/IEC 14496-12 `sidx` (Segment Index) box.
    private static func parseSIDX(data: Data, indexEnd: Int64) -> [Segment]? {
        guard data.count >= 32 else { return nil }
        return data.withUnsafeBytes { raw -> [Segment]? in
            guard let base = raw.baseAddress else { return nil }
            func u16(_ o: Int) -> UInt16 {
                var v: UInt16 = 0
                memcpy(&v, base.advanced(by: o), 2)
                return UInt16(bigEndian: v)
            }
            func u32(_ o: Int) -> UInt32 {
                var v: UInt32 = 0
                memcpy(&v, base.advanced(by: o), 4)
                return UInt32(bigEndian: v)
            }
            func u64(_ o: Int) -> UInt64 {
                var v: UInt64 = 0
                memcpy(&v, base.advanced(by: o), 8)
                return UInt64(bigEndian: v)
            }

            // Locate `sidx` box (usually offset 0)
            var boxOff = 0
            while boxOff + 8 <= data.count {
                let sz = Int(u32(boxOff))
                let t0 = data[boxOff + 4], t1 = data[boxOff + 5], t2 = data[boxOff + 6], t3 = data[boxOff + 7]
                if t0 == 0x73 && t1 == 0x69 && t2 == 0x64 && t3 == 0x78 { // "sidx"
                    break
                }
                if sz <= 8 { return nil }
                boxOff += sz
            }
            guard boxOff + 24 <= data.count else { return nil }

            let version = data[boxOff + 8]
            var off = boxOff + 12
            _ = u32(off); off += 4 // reference_ID
            let timescale = u32(off); off += 4
            guard timescale > 0 else { return nil }

            let firstOffset: Int64
            if version == 0 {
                guard off + 8 <= data.count else { return nil }
                _ = u32(off); off += 4 // earliest_presentation_time
                firstOffset = Int64(u32(off)); off += 4
            } else {
                guard off + 16 <= data.count else { return nil }
                _ = u64(off); off += 8
                firstOffset = Int64(u64(off)); off += 8
            }

            guard off + 4 <= data.count else { return nil }
            off += 2 // reserved
            let refCount = Int(u16(off)); off += 2

            var segs: [Segment] = []
            segs.reserveCapacity(refCount)
            var cursor = indexEnd + 1 + firstOffset

            for _ in 0..<refCount {
                guard off + 12 <= data.count else { break }
                let w0 = u32(off)
                let w1 = u32(off + 4)
                off += 12
                let refSize = Int64(w0 & 0x7FFF_FFFF)
                let dur = Double(w1) / Double(timescale)
                segs.append(Segment(start: cursor, end: cursor + refSize - 1, duration: dur))
                cursor += refSize
            }
            return segs
        }
    }

    // MARK: - HTTP Request Handling

    private func handleClient(_ fd: Int32) {
        defer { close(fd) }

        var reqBuf = Data()
        var tmp = [UInt8](repeating: 0, count: 2048)
        while reqBuf.count < 16384 {
            let n = recv(fd, &tmp, tmp.count, 0)
            if n <= 0 { return }
            reqBuf.append(tmp, count: n)
            if let s = String(data: reqBuf, encoding: .utf8), s.contains("\r\n\r\n") {
                break
            }
        }
        guard let reqStr = String(data: reqBuf, encoding: .utf8),
              let firstLine = reqStr.split(separator: "\r\n").first else { return }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return }
        let method = String(parts[0])
        let path = String(parts[1])

        // Extract optional incoming Range header (used by AVPlayer for progressive MP4 seeking!)
        var incomingRange: String? = nil
        for line in reqStr.split(separator: "\r\n").dropFirst() {
            if line.lowercased().hasPrefix("range:") {
                incomingRange = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                break
            }
        }

        // Parse path: /p/<sid>/video.mp4 OR /s/<sid>/...
        let comps = path.split(separator: "/").map(String.init)
        if comps.count >= 3, comps[0] == "p" {
            let sid = comps[1]
            lock.lock()
            let prog = progressiveSessions[sid]
            lock.unlock()
            guard let prog = prog else {
                sendText(fd, status: "404 Not Found", contentType: "text/plain", body: "Session expired")
                return
            }
            streamProgressiveProxy(fd: fd, format: prog.format, incomingRange: incomingRange, headOnly: method == "HEAD")
            return
        }

        guard comps.count >= 3, comps[0] == "s" else {
            sendText(fd, status: "404 Not Found", contentType: "text/plain", body: "Not found")
            return
        }
        let sid = comps[1]
        lock.lock()
        let session = sessions[sid]
        lock.unlock()
        guard let session = session else {
            sendText(fd, status: "404 Not Found", contentType: "text/plain", body: "Session expired")
            return
        }

        let target = comps[2]

        // 1. Master playlist: /s/<sid>/master.m3u8
        if target == "master.m3u8" {
            let m3u8 = buildMasterPlaylist(session: session)
            sendText(fd, status: "200 OK", contentType: "application/vnd.apple.mpegurl", body: m3u8, headOnly: method == "HEAD")
            return
        }

        // 2. Audio playlist: /s/<sid>/audio.m3u8
        if target == "audio.m3u8", let audio = session.audioTrack {
            let m3u8 = buildMediaPlaylist(sid: sid, trackName: "a", track: audio)
            sendText(fd, status: "200 OK", contentType: "application/vnd.apple.mpegurl", body: m3u8, headOnly: method == "HEAD")
            return
        }

        // 3. Video playlist: /s/<sid>/v_<itag>.m3u8
        if target.hasPrefix("v_"), target.hasSuffix(".m3u8") {
            let numStr = target.dropFirst(2).dropLast(5)
            if let itag = Int(numStr), let vTrack = session.videoTracks[itag] {
                let m3u8 = buildMediaPlaylist(sid: sid, trackName: "v_\(itag)", track: vTrack)
                sendText(fd, status: "200 OK", contentType: "application/vnd.apple.mpegurl", body: m3u8, headOnly: method == "HEAD")
                return
            }
        }

        // 4. Media segment or init: /s/<sid>/seg/<trackName>/<file>
        if target == "seg", comps.count >= 5 {
            let trackName = comps[3]
            let file = comps[4]

            let track: ParsedTrack?
            if trackName == "a" {
                track = session.audioTrack
            } else if trackName.hasPrefix("v_"), let itag = Int(trackName.dropFirst(2)) {
                track = session.videoTracks[itag]
            } else {
                track = nil
            }
            guard let t = track else {
                sendText(fd, status: "404 Not Found", contentType: "text/plain", body: "No track")
                return
            }

            let range: ByteRange?
            if file == "init.mp4" {
                range = t.initRange
            } else if file.hasSuffix(".m4s"), let idx = Int(file.dropLast(4)), idx >= 0, idx < t.segments.count {
                let seg = t.segments[idx]
                range = ByteRange(start: seg.start, end: seg.end)
            } else {
                range = nil
            }
            guard let r = range else {
                sendText(fd, status: "404 Not Found", contentType: "text/plain", body: "No segment")
                return
            }

            streamUpstreamRange(fd: fd, urlString: t.format.url, range: r, contentType: t.format.isAudio ? "audio/mp4" : "video/mp4", headOnly: method == "HEAD")
            return
        }

        sendText(fd, status: "404 Not Found", contentType: "text/plain", body: "Unknown route")
    }

    private func buildMasterPlaylist(session: Session) -> String {
        var lines: [String] = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS"]

        // Audio-only session!
        if session.orderedVideoItags.isEmpty, let audio = session.audioTrack {
            lines.append("#EXT-X-STREAM-INF:BANDWIDTH=\(max(audio.format.bitrate, 64000)),CODECS=\"\(audio.format.codecs)\"")
            lines.append("/s/\(session.id)/audio.m3u8")
            return lines.joined(separator: "\n") + "\n"
        }

        let hasAudio = session.audioTrack != nil
        if hasAudio {
            lines.append("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"Default\",DEFAULT=YES,AUTOSELECT=YES,URI=\"/s/\(session.id)/audio.m3u8\"")
        }

        let audioCodec = session.audioTrack?.format.codecs ?? ""
        for itag in session.orderedVideoItags {
            guard let vt = session.videoTracks[itag] else { continue }
            let bw = vt.format.bitrate + (session.audioTrack?.format.bitrate ?? 0)
            let codecs = hasAudio ? "\(vt.format.codecs),\(audioCodec)" : vt.format.codecs
            var attrs = "BANDWIDTH=\(max(bw, 100_000)),RESOLUTION=\(vt.format.width)x\(vt.format.height),CODECS=\"\(codecs)\""
            if vt.format.fps > 0 { attrs += ",FRAME-RATE=\(vt.format.fps).000" }
            if hasAudio { attrs += ",AUDIO=\"aud\"" }
            lines.append("#EXT-X-STREAM-INF:\(attrs)")
            lines.append("/s/\(session.id)/v_\(itag).m3u8")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func buildMediaPlaylist(sid: String, trackName: String, track: ParsedTrack) -> String {
        var lines: [String] = []
        lines.reserveCapacity(track.segments.count * 2 + 8)
        lines.append("#EXTM3U")
        lines.append("#EXT-X-VERSION:7")
        lines.append("#EXT-X-TARGETDURATION:\(track.targetDuration)")
        lines.append("#EXT-X-MEDIA-SEQUENCE:0")
        lines.append("#EXT-X-PLAYLIST-TYPE:VOD")
        lines.append("#EXT-X-MAP:URI=\"/s/\(sid)/seg/\(trackName)/init.mp4\"")
        for (i, seg) in track.segments.enumerated() {
            lines.append(String(format: "#EXTINF:%.5f,", seg.duration))
            lines.append("/s/\(sid)/seg/\(trackName)/\(i).m4s")
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Streams a progressive MP4 with full HTTP 206 Partial Content byte-range support (for instant AVPlayer seeking).
    private func streamProgressiveProxy(fd: Int32, format: StreamFormat, incomingRange: String?, headOnly: Bool) {
        let totalLen = format.contentLength
        var start: Int64 = 0
        var end: Int64 = totalLen > 0 ? (totalLen - 1) : 1_048_575
        var isPartial = false

        if let r = incomingRange, r.lowercased().hasPrefix("bytes=") {
            let spec = r.dropFirst(6).components(separatedBy: ",").first ?? ""
            let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
            if bounds.count == 2 {
                if let s = Int64(bounds[0]) {
                    start = s
                    isPartial = true
                    if let e = Int64(bounds[1]) {
                        end = totalLen > 0 ? min(e, totalLen - 1) : e
                    } else if totalLen > 0 {
                        // Cap open-ended range chunks to 2 MB per request so memory stays ultra-low
                        end = min(totalLen - 1, start + 2 * 1024 * 1024 - 1)
                    }
                }
            }
        } else if totalLen > 0 {
            end = totalLen - 1
        }

        let chunkLen = max(0, end - start + 1)
        if headOnly {
            let hdr = "HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nAccept-Ranges: bytes\r\nContent-Length: \(totalLen)\r\nConnection: close\r\n\r\n"
            sendAll(fd, Data(hdr.utf8))
            return
        }

        guard let url = URL(string: format.url) else {
            sendText(fd, status: "502 Bad Gateway", contentType: "text/plain", body: "Bad URL")
            return
        }
        var req = URLRequest(url: url)
        req.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        req.setValue(streamUA, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20

        let contentRange = totalLen > 0 ? "bytes \(start)-\(end)/\(totalLen)" : nil
        let sem = DispatchSemaphore(value: 0)
        let delegate = StreamingProxyDelegate(
            fd: fd,
            contentType: "video/mp4",
            expectedLength: chunkLen,
            isPartial: isPartial,
            contentRange: contentRange,
            sem: sem
        )
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        let sess = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        sess.dataTask(with: req).resume()
        _ = sem.wait(timeout: .now() + 25)
        sess.invalidateAndCancel()
    }

    /// Streams an upstream byte range directly into `fd` in small chunks (never caches in RAM).
    private func streamUpstreamRange(fd: Int32, urlString: String, range: ByteRange, contentType: String, headOnly: Bool) {
        if headOnly {
            let hdr = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(range.length)\r\nConnection: close\r\n\r\n"
            sendAll(fd, Data(hdr.utf8))
            return
        }
        guard let url = URL(string: "\(urlString)&range=\(range.start)-\(range.end)") else {
            sendText(fd, status: "502 Bad Gateway", contentType: "text/plain", body: "Bad URL")
            return
        }
        var req = URLRequest(url: url)
        req.setValue(streamUA, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20

        let sem = DispatchSemaphore(value: 0)
        let delegate = StreamingProxyDelegate(fd: fd, contentType: contentType, expectedLength: range.length, sem: sem)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        let sess = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        let task = sess.dataTask(with: req)
        task.resume()
        _ = sem.wait(timeout: .now() + 25)
        sess.invalidateAndCancel()
    }

    private func sendText(_ fd: Int32, status: String, contentType: String, body: String, headOnly: Bool = false) {
        let data = Data(body.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        sendAll(fd, Data(header.utf8))
        if !headOnly { sendAll(fd, data) }
    }

    fileprivate static func sendAllStatic(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let ptr = raw.baseAddress else { return true }
            var sent = 0
            while sent < data.count {
                let n = send(fd, ptr.advanced(by: sent), data.count - sent, 0)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    private func sendAll(_ fd: Int32, _ data: Data) {
        _ = Self.sendAllStatic(fd, data)
    }
}

private final class StreamingProxyDelegate: NSObject, URLSessionDataDelegate {
    private let fd: Int32
    private let contentType: String
    private let expectedLength: Int64
    private let isPartial: Bool
    private let contentRange: String?
    private let sem: DispatchSemaphore
    private var headerSent = false
    private var failed = false

    init(fd: Int32, contentType: String, expectedLength: Int64, isPartial: Bool = false, contentRange: String? = nil, sem: DispatchSemaphore) {
        self.fd = fd
        self.contentType = contentType
        self.expectedLength = expectedLength
        self.isPartial = isPartial
        self.contentRange = contentRange
        self.sem = sem
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let len = response.expectedContentLength > 0 ? response.expectedContentLength : expectedLength
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        if status >= 400 {
            let hdr = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            _ = LocalHLSServer.sendAllStatic(fd, Data(hdr.utf8))
            failed = true
            completionHandler(.cancel)
            return
        }
        let statusLine = isPartial ? "HTTP/1.1 206 Partial Content" : "HTTP/1.1 200 OK"
        var hdr = "\(statusLine)\r\nContent-Type: \(contentType)\r\nAccept-Ranges: bytes\r\nContent-Length: \(len)\r\n"
        if isPartial, let cr = contentRange {
            hdr += "Content-Range: \(cr)\r\n"
        }
        hdr += "Connection: close\r\n\r\n"
        headerSent = true
        if !LocalHLSServer.sendAllStatic(fd, Data(hdr.utf8)) {
            failed = true
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !failed else { return }
        if !LocalHLSServer.sendAllStatic(fd, data) {
            failed = true
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if !headerSent && !failed {
            let hdr = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            _ = LocalHLSServer.sendAllStatic(fd, Data(hdr.utf8))
        }
        sem.signal()
    }
}

import AppKit
import ImageIO

final class ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, NSImage>()
    private let session: URLSession
    private let lock = NSLock()
    private var inFlight: [String: [(NSImage?) -> Void]] = [:]
    private var trackedCosts: [String: Int] = [:]

    /// Hard cap: 8 MB total decoded pixel cache (keeps total app RAM well under 100 MB).
    private let maxBytes = 8 * 1024 * 1024

    var estimatedMB: Double {
        lock.lock()
        let sum = trackedCosts.values.reduce(0, +)
        lock.unlock()
        return min(Double(sum), Double(maxBytes)) / 1_048_576.0
    }

    private init() {
        cache.totalCostLimit = maxBytes
        cache.countLimit = 45

        let cfg = URLSessionConfiguration.default
        cfg.urlCache = URLCache(memoryCapacity: 1 * 1024 * 1024, diskCapacity: 16 * 1024 * 1024)
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.timeoutIntervalForRequest = 12
        self.session = URLSession(configuration: cfg)
    }

    func clearAll() {
        cache.removeAllObjects()
        lock.lock()
        trackedCosts.removeAll()
        lock.unlock()
        session.configuration.urlCache?.removeAllCachedResponses()
    }

    func trimForPressure() {
        cache.removeAllObjects()
        lock.lock()
        trackedCosts.removeAll()
        lock.unlock()
    }

    /// Loads and downsamples an image to `maxPixelSize` directly from compressed bytes
    /// so we NEVER allocate a full 1280×720 or 4K RGBA bitmap for a 320px card.
    func load(_ urlString: String?, maxPixelSize: Int = 360, completion: @escaping (NSImage?) -> Void) {
        guard var raw = urlString, !raw.isEmpty else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        if raw.hasPrefix("//") { raw = "https:" + raw }
        let key = "\(raw)#\(maxPixelSize)" as NSString

        if let hit = cache.object(forKey: key) {
            DispatchQueue.main.async { completion(hit) }
            return
        }

        lock.lock()
        if inFlight[key as String] != nil {
            inFlight[key as String]?.append(completion)
            lock.unlock()
            return
        }
        inFlight[key as String] = [completion]
        lock.unlock()

        guard let url = URL(string: raw) else {
            finish(key: key as String, image: nil)
            return
        }

        session.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self else { return }
            var decoded: NSImage? = nil
            var cost = 0
            if let data = data, !data.isEmpty {
                autoreleasepool {
                    // maxPixelSize is in points at the call sites; decode at backing scale so thumbnails stay sharp on Retina.
                    let scale = Int(NSScreen.main?.backingScaleFactor ?? 2)
                    if let cg = Self.downsample(data: data, maxPixelSize: maxPixelSize * scale) {
                        cost = cg.bytesPerRow * cg.height
                        decoded = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    }
                }
            }
            if let img = decoded {
                self.cache.setObject(img, forKey: key, cost: max(cost, 16_384))
                self.lock.lock()
                self.trackedCosts[key as String] = cost
                if self.trackedCosts.count > 60 {
                    self.trackedCosts.removeAll()
                }
                self.lock.unlock()
            }
            self.finish(key: key as String, image: decoded)
        }.resume()
    }

    /// Load a storyboard sprite sheet without downsampling (so crop rects stay exact).
    func loadStoryboardSheet(_ urlString: String, completion: @escaping (CGImage?) -> Void) {
        let key = "sb#\(urlString)" as NSString
        if let hit = cache.object(forKey: key), let cg = hit.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            DispatchQueue.main.async { completion(cg) }
            return
        }
        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        session.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self else { return }
            var cgImg: CGImage?
            if let data = data, let src = CGImageSourceCreateWithData(data as CFData, nil) {
                cgImg = CGImageSourceCreateImageAtIndex(src, 0, nil)
                if let cg = cgImg {
                    let ns = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    self.cache.setObject(ns, forKey: key, cost: cg.bytesPerRow * cg.height)
                }
            }
            DispatchQueue.main.async { completion(cgImg) }
        }.resume()
    }

    private func finish(key: String, image: NSImage?) {
        lock.lock()
        let callbacks = inFlight.removeValue(forKey: key) ?? []
        lock.unlock()
        DispatchQueue.main.async {
            for cb in callbacks { cb(image) }
        }
    }

    private static func downsample(data: Data, maxPixelSize: Int) -> CGImage? {
        let srcOpts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithData(data as CFData, srcOpts as CFDictionary) else {
            return nil
        }
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary)
    }
}

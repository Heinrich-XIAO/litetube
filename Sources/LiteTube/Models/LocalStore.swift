import Foundation

extension Notification.Name {
    static let liteTubeStoreDidChange = Notification.Name("LiteTubeStoreDidChange")
    static let liteTubeHistoryDidChange = Notification.Name("LiteTubeHistoryDidChange")
    static let liteTubeQueueDidChange = Notification.Name("LiteTubeQueueDidChange")
    static let liteTubeThemeDidChange = Notification.Name("LiteTubeThemeDidChange")
}

final class LocalStore {
    static let shared = LocalStore()

    private struct DiskPayload: Codable {
        var subscriptions: [SubscribedChannel] = []
        var history: [WatchHistoryEntry] = []
        var watchLater: [VideoItem] = []
        var likedVideos: [VideoItem] = []
        var playlists: [LocalPlaylist] = []
        var searchHistory: [String] = []
        var settings: AppSettings = AppSettings()
    }

    private let fileURL: URL
    private var data = DiskPayload()
    private let ioQueue = DispatchQueue(label: "com.litetube.store", qos: .utility)

    // In-memory playback queue
    private(set) var queue: [VideoItem] = []
    private(set) var queueIndex: Int = -1

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("LiteTube", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("state.json")
        load()
    }

    private func load() {
        guard let raw = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(DiskPayload.self, from: raw) else {
            return
        }
        self.data = decoded
    }

    private func save(postStoreNotification: Bool = true) {
        let snapshot = self.data
        let url = self.fileURL
        ioQueue.async {
            if let encoded = try? JSONEncoder().encode(snapshot) {
                try? encoded.write(to: url, options: .atomic)
            }
        }
        DispatchQueue.main.async {
            if postStoreNotification {
                NotificationCenter.default.post(name: .liteTubeStoreDidChange, object: nil)
            } else {
                NotificationCenter.default.post(name: .liteTubeHistoryDidChange, object: nil)
            }
        }
    }

    // MARK: - Settings
    var settings: AppSettings {
        get { data.settings }
        set {
            let themeChanged = data.settings.darkMode != newValue.darkMode
            data.settings = newValue
            save()
            if themeChanged {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .liteTubeThemeDidChange, object: nil)
                }
            }
        }
    }

    // MARK: - Subscriptions
    var subscriptions: [SubscribedChannel] { data.subscriptions }

    func isSubscribed(channelId: String) -> Bool {
        data.subscriptions.contains { $0.id == channelId }
    }

    func toggleSubscription(channelId: String, name: String, avatarURL: String, subscriberCountText: String = "") -> Bool {
        if let idx = data.subscriptions.firstIndex(where: { $0.id == channelId }) {
            data.subscriptions.remove(at: idx)
            save()
            return false
        } else {
            let sub = SubscribedChannel(
                id: channelId,
                name: name,
                avatarURL: avatarURL,
                subscriberCountText: subscriberCountText,
                subscribedAt: Date()
            )
            data.subscriptions.insert(sub, at: 0)
            save()
            return true
        }
    }

    // MARK: - Watch History
    var history: [WatchHistoryEntry] { data.history }

    func recordWatch(video: VideoItem, position: Double, duration: Double) {
        guard !data.settings.pauseHistory else { return }
        data.history.removeAll { $0.video.id == video.id }
        let entry = WatchHistoryEntry(
            video: video,
            lastPositionSeconds: position,
            durationSeconds: duration,
            watchedAt: Date()
        )
        data.history.insert(entry, at: 0)
        if data.history.count > 250 {
            data.history.removeLast(data.history.count - 250)
        }
        save(postStoreNotification: false)
    }

    func savedPosition(for videoId: String) -> Double? {
        guard let entry = data.history.first(where: { $0.video.id == videoId }) else { return nil }
        if entry.durationSeconds > 30 && entry.lastPositionSeconds > 5 && entry.lastPositionSeconds < entry.durationSeconds - 15 {
            return entry.lastPositionSeconds
        }
        return nil
    }

    func removeFromHistory(videoId: String) {
        data.history.removeAll { $0.video.id == videoId }
        save()
    }

    func clearHistory() {
        data.history.removeAll()
        save()
    }

    // MARK: - Watch Later
    var watchLater: [VideoItem] { data.watchLater }

    func isInWatchLater(_ videoId: String) -> Bool {
        data.watchLater.contains { $0.id == videoId }
    }

    @discardableResult
    func toggleWatchLater(_ video: VideoItem) -> Bool {
        if let idx = data.watchLater.firstIndex(where: { $0.id == video.id }) {
            data.watchLater.remove(at: idx)
            save()
            return false
        } else {
            data.watchLater.insert(video, at: 0)
            save()
            return true
        }
    }

    // MARK: - Liked Videos
    var likedVideos: [VideoItem] { data.likedVideos }

    func isLiked(_ videoId: String) -> Bool {
        data.likedVideos.contains { $0.id == videoId }
    }

    @discardableResult
    func toggleLike(_ video: VideoItem) -> Bool {
        if let idx = data.likedVideos.firstIndex(where: { $0.id == video.id }) {
            data.likedVideos.remove(at: idx)
            save()
            return false
        } else {
            data.likedVideos.insert(video, at: 0)
            save()
            return true
        }
    }

    // MARK: - Custom Playlists
    var playlists: [LocalPlaylist] { data.playlists }

    @discardableResult
    func createPlaylist(name: String) -> LocalPlaylist {
        let pl = LocalPlaylist(id: UUID().uuidString, name: name, videos: [], createdAt: Date())
        data.playlists.insert(pl, at: 0)
        save()
        return pl
    }

    func deletePlaylist(id: String) {
        data.playlists.removeAll { $0.id == id }
        save()
    }

    func add(_ video: VideoItem, toPlaylist id: String) {
        guard let idx = data.playlists.firstIndex(where: { $0.id == id }) else { return }
        if !data.playlists[idx].videos.contains(where: { $0.id == video.id }) {
            data.playlists[idx].videos.append(video)
            save()
        }
    }

    func remove(videoId: String, fromPlaylist id: String) {
        guard let idx = data.playlists.firstIndex(where: { $0.id == id }) else { return }
        data.playlists[idx].videos.removeAll { $0.id == videoId }
        save()
    }

    // MARK: - Search History
    var searchHistory: [String] { data.searchHistory }

    func recordSearch(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        data.searchHistory.removeAll { $0.caseInsensitiveCompare(q) == .orderedSame }
        data.searchHistory.insert(q, at: 0)
        if data.searchHistory.count > 25 {
            data.searchHistory.removeLast(data.searchHistory.count - 25)
        }
        save()
    }

    // MARK: - Playback Queue
    func addToQueue(_ video: VideoItem) {
        if !queue.contains(where: { $0.id == video.id }) {
            queue.append(video)
            NotificationCenter.default.post(name: .liteTubeQueueDidChange, object: nil)
        }
    }

    func setQueue(_ videos: [VideoItem], startAt index: Int = 0) {
        queue = videos
        queueIndex = videos.isEmpty ? -1 : max(0, min(index, videos.count - 1))
        NotificationCenter.default.post(name: .liteTubeQueueDidChange, object: nil)
    }

    func removeFromQueue(at index: Int) {
        guard index >= 0 && index < queue.count else { return }
        queue.remove(at: index)
        if queueIndex >= queue.count { queueIndex = queue.count - 1 }
        NotificationCenter.default.post(name: .liteTubeQueueDidChange, object: nil)
    }

    func clearQueue() {
        queue.removeAll()
        queueIndex = -1
        NotificationCenter.default.post(name: .liteTubeQueueDidChange, object: nil)
    }

    func nextInQueue(after currentId: String) -> VideoItem? {
        if let idx = queue.firstIndex(where: { $0.id == currentId }), idx + 1 < queue.count {
            queueIndex = idx + 1
            return queue[queueIndex]
        }
        if !queue.isEmpty && queueIndex < 0 {
            queueIndex = 0
            return queue[0]
        }
        return nil
    }

    func previousInQueue(before currentId: String) -> VideoItem? {
        if let idx = queue.firstIndex(where: { $0.id == currentId }), idx > 0 {
            queueIndex = idx - 1
            return queue[queueIndex]
        }
        return nil
    }
}

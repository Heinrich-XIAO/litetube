import AppKit

/// Loads the next page before the reader reaches the end of a list.
///
/// It watches a scroll view and calls `loadNext` once the remaining content is closer than `threshold`
/// points (about a screen and a half). It runs again after every scroll and after the owner's content
/// changes, so a short first page fills the view too. After a failed automatic load it pauses instead
/// of retrying on every scroll; the owner shows a "Try again" control and calls `resume()` when pressed.
final class NearEndLoader {
    private weak var scrollView: NSScrollView?
    private let threshold: CGFloat
    private let hasMore: () -> Bool
    private let loadNext: () -> Void
    private(set) var paused = false

    init(scrollView: NSScrollView, threshold: CGFloat = 900, hasMore: @escaping () -> Bool, loadNext: @escaping () -> Void) {
        self.scrollView = scrollView
        self.threshold = threshold
        self.hasMore = hasMore
        self.loadNext = loadNext
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func boundsChanged() { check() }

    /// Load the next page if the reader is close to the end and there is one.
    func check() {
        guard !paused, hasMore(), let sv = scrollView, let doc = sv.documentView else { return }
        let visible = sv.contentView.documentVisibleRect
        // Distance from the visible region to the far end of the content, for flipped and unflipped documents alike.
        let remaining = doc.isFlipped ? doc.bounds.maxY - visible.maxY : visible.minY - doc.bounds.minY
        if remaining < threshold { loadNext() }
    }

    /// Stop automatic loading after a failure, until the owner resumes it.
    func pause() { paused = true }

    func resume() { paused = false }
}

extension NearEndLoader {
    /// Headless checks of the trigger, run by SelfTest. Returns one message per failed check.
    /// The owners' hasMore is false while a request is in flight, and the test models that the same way.
    static func selfChecks() -> [String] {
        var fails: [String] = []
        func expect(_ ok: Bool, _ what: String) { if !ok { fails.append("near-end: \(what)") } }

        final class FlippedDoc: NSView { override var isFlipped: Bool { true } }
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let doc = FlippedDoc(frame: NSRect(x: 0, y: 0, width: 400, height: 3000))
        sv.documentView = doc
        var calls = 0
        var more = true
        var inFlight = false
        let loader = NearEndLoader(scrollView: sv, threshold: 900,
                                   hasMore: { more && !inFlight },
                                   loadNext: { calls += 1; inFlight = true })

        func scroll(to y: CGFloat) {
            sv.contentView.scroll(to: NSPoint(x: 0, y: y))
            sv.reflectScrolledClipView(sv.contentView)
        }

        // Top of a long list: 2700pt still to go, so nothing loads.
        scroll(to: 0)
        loader.check()
        expect(calls == 0, "loads when the reader is far from the end")

        // 1200pt to go: still outside the threshold.
        scroll(to: 1500)
        expect(calls == 0, "loads 1200pt early, outside the 900pt threshold")

        // 600pt to go: inside the threshold, so the next page loads before the reader reaches the end.
        scroll(to: 2100)
        expect(calls == 1, "does not load once inside the threshold, or loads more than once")
        inFlight = false   // the page arrived

        // A failed automatic load pauses: scrolling does not retry until the owner resumes.
        loader.pause()
        scroll(to: 2200)
        expect(calls == 1, "retries while paused")
        loader.resume()
        loader.check()
        expect(calls == 2, "does not load after resume")
        inFlight = false

        // No more pages: never loads.
        more = false
        scroll(to: 2250)
        loader.check()
        expect(calls == 2, "loads with no next page")
        more = true

        // A short first page fills the view: content shorter than the viewport loads at once.
        inFlight = false
        doc.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        scroll(to: 0)
        loader.check()
        expect(calls == 3, "does not fill a short first page, or loads it more than once")
        return fails
    }
}

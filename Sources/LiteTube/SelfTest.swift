import AppKit

/// Headless layout check, run with LITETUBE_SELFTEST=1. The window is never shown.
/// It lays out the main window at several sizes and on each route, reports any
/// view with ambiguous layout, checks sidebar widths, and exits 0 only when every check passes.
/// The log goes to $LITETUBE_SELFTEST_LOG, or a temp file if that is unset.
enum SelfTest {
    static let logPath: String = ProcessInfo.processInfo.environment["LITETUBE_SELFTEST_LOG"]
        ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("litetube-selftest.log")

    static func log(_ line: String) {
        print(line)
        let data = (line + "\n").data(using: .utf8) ?? Data()
        if !FileManager.default.fileExists(atPath: logPath) { FileManager.default.createFile(atPath: logPath, contents: nil) }
        if let h = FileHandle(forWritingAtPath: logPath) { h.seekToEndOfFile(); h.write(data); h.closeFile() }
    }

    static func run(_ wc: MainWindowController) {
        try? FileManager.default.removeItem(atPath: logPath)
        log("SELFTEST start")
        var failures: [String] = []
        guard let window = wc.window, let content = window.contentView else {
            log("SELFTEST FAIL: no window or content view"); exit(1)
        }
        LiteTubeWindow.allowsProgrammaticResize = true
        let sizes: [NSSize] = [NSSize(width: 1280, height: 800), NSSize(width: 900, height: 600)]
        for size in sizes {
            window.setContentSize(size)
            content.setFrameSize(size)
            content.layoutSubtreeIfNeeded()
            log("SELFTEST size \(Int(size.width))x\(Int(size.height))")
            failures += ambiguousViews(in: content, label: "home \(Int(size.width))")
            if let sb = allSubviews(content).first(where: { $0.identifier?.rawValue == "sidebarScroll" }) {
                log("  sidebar width=\(Int(sb.frame.width))")
                if abs(sb.frame.width - 224) > 1 && abs(sb.frame.width - 72) > 1 {
                    failures.append("sidebar width \(sb.frame.width) is neither 224 nor 72")
                }
            }
        }

        wc.showShorts()
        content.layoutSubtreeIfNeeded()
        log("SELFTEST route shorts, canToggleSidebar=\(wc.canToggleSidebar)")
        failures += ambiguousViews(in: content, label: "shorts")
        if wc.canToggleSidebar { failures.append("sidebar toggle should be disabled on Shorts") }

        wc.showHome()
        content.layoutSubtreeIfNeeded()
        log("SELFTEST route home, canToggleSidebar=\(wc.canToggleSidebar)")
        if !wc.canToggleSidebar { failures.append("sidebar toggle should be enabled on Home") }

        // Watch page with a fixture video. The network fails offline; the layout must still be unambiguous.
        let fixture = VideoItem(id: "dQw4w9WgXcQ", title: "Fixture", channelName: "Fixture Channel", channelId: "", channelAvatarURL: nil,
                                thumbnailURL: "", durationText: "3:00", viewsText: "1 view", publishedText: "now")
        wc.openVideo(fixture, startSeconds: nil)
        content.layoutSubtreeIfNeeded()
        log("SELFTEST route watch")
        failures += ambiguousViews(in: content, label: "watch")

        if failures.isEmpty {
            log("SELFTEST PASS")
            exit(0)
        }
        for f in failures { log("SELFTEST FAIL: \(f)") }
        exit(1)
    }

    private static func ambiguousViews(in root: NSView, label: String) -> [String] {
        allSubviews(root).filter { $0.hasAmbiguousLayout }.map {
            let parent = $0.superview.map { "\(type(of: $0)) frame=\($0.frame)" } ?? "none"
            return "ambiguous layout (\(label)): \(type(of: $0)) frame=\($0.frame) in [\(parent)] text=\(($0 as? NSTextField)?.stringValue ?? "")"
        }
    }

    private static func allSubviews(_ v: NSView) -> [NSView] {
        [v] + v.subviews.flatMap { allSubviews($0) }
    }
}

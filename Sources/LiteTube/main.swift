import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    var initialURL: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep shared URLCache tiny globally
        URLCache.shared = URLCache(memoryCapacity: 2 * 1024 * 1024, diskCapacity: 16 * 1024 * 1024)

        // Warm up local loopback HLS bridge
        _ = LocalHLSServer.shared

        setupMenuBar()

        let wc = MainWindowController()
        self.windowController = wc
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        if let raw = initialURL, !raw.isEmpty {
            wc.openURLString(raw)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let first = urls.first else { return }
        let str = first.absoluteString.replacingOccurrences(of: "litetube://", with: "https://")
        windowController?.openURLString(str)
    }

    private func setupMenuBar() {
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About LiteTube", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide LiteTube", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit LiteTube", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // File menu
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let openItem = NSMenuItem(title: "Open YouTube URL...", action: #selector(openURLAction), keyEquivalent: "o")
        openItem.target = self
        fileMenu.addItem(openItem)
        let searchItem = NSMenuItem(title: "Focus Search", action: #selector(focusSearchAction), keyEquivalent: "l")
        searchItem.target = self
        fileMenu.addItem(searchItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        // Edit menu (essential for Cmd+C / Cmd+V / Cmd+A in Search bar!)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        // View menu
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let homeItem = NSMenuItem(title: "Home", action: #selector(goHomeAction), keyEquivalent: "1")
        homeItem.target = self
        viewMenu.addItem(homeItem)
        let themeItem = NSMenuItem(title: "Toggle Dark / Light Mode", action: #selector(toggleThemeAction), keyEquivalent: "D")
        themeItem.target = self
        viewMenu.addItem(themeItem)
        let trimItem = NSMenuItem(title: "Trim Memory Caches", action: #selector(trimMemoryAction), keyEquivalent: "M")
        trimItem.target = self
        viewMenu.addItem(trimItem)
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func openURLAction() { windowController?.promptOpenURL() }
    @objc private func focusSearchAction() { windowController?.focusSearchBar() }
    @objc private func goHomeAction() { windowController?.showHome() }
    @objc private func toggleThemeAction() { windowController?.toggleDarkMode() }
    @objc private func trimMemoryAction() { windowController?.trimMemoryNow() }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
if CommandLine.arguments.count > 1 {
    delegate.initialURL = CommandLine.arguments[1]
}
app.delegate = delegate
app.run()

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var windowController: MainWindowController?
    var initialURL: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep shared URLCache tiny globally
        URLCache.shared = URLCache(memoryCapacity: 2 * 1024 * 1024, diskCapacity: 16 * 1024 * 1024)

        // Warm up local loopback HLS bridge
        _ = LocalHLSServer.shared

        NSApp.appearance = YTTheme.appearance
        setupMenuBar()

        let wc = MainWindowController()
        self.windowController = wc
        if ProcessInfo.processInfo.environment["LITETUBE_SELFTEST"] == "1" {
            SelfTest.run(wc)
        }
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
        // ⌘, belongs to the single "All Settings..." item in the Window menu so the shortcut is not bound twice.
        let prefsItem = NSMenuItem(title: "Settings...", action: #selector(openSettingsAction), keyEquivalent: "")
        prefsItem.target = self
        appMenu.addItem(prefsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide LiteTube", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
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
        let backItem = NSMenuItem(title: "Back", action: #selector(goBackAction), keyEquivalent: "[")
        backItem.target = self
        viewMenu.addItem(backItem)
        let fwdItem = NSMenuItem(title: "Forward", action: #selector(goForwardAction), keyEquivalent: "]")
        fwdItem.target = self
        viewMenu.addItem(fwdItem)
        let sidebarItem = NSMenuItem(title: "Toggle Sidebar", action: #selector(toggleSidebarAction), keyEquivalent: "s")
        sidebarItem.keyEquivalentModifierMask = [.command, .control]
        sidebarItem.target = self
        viewMenu.addItem(sidebarItem)
        viewMenu.addItem(.separator())
        let themeItem = NSMenuItem(title: "Toggle Dark / Light Mode", action: #selector(toggleThemeAction), keyEquivalent: "D")
        themeItem.target = self
        viewMenu.addItem(themeItem)
        let trimItem = NSMenuItem(title: "Trim Caches", action: #selector(trimMemoryAction), keyEquivalent: "k")
        trimItem.keyEquivalentModifierMask = [.command, .shift]
        trimItem.target = self
        viewMenu.addItem(trimItem)
        viewMenu.addItem(.separator())
        let fsItem = NSMenuItem(title: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fsItem.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fsItem)
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        // Playback menu
        let playbackItem = NSMenuItem()
        let playbackMenu = NSMenu(title: "Playback")
        let ppItem = NSMenuItem(title: "Play / Pause", action: #selector(playPauseAction), keyEquivalent: "p")
        ppItem.target = self
        playbackMenu.addItem(ppItem)
        let nextItem = NSMenuItem(title: "Next Video", action: #selector(nextTrackAction), keyEquivalent: "")
        nextItem.target = self
        playbackMenu.addItem(nextItem)
        let prevItem = NSMenuItem(title: "Previous Video", action: #selector(prevTrackAction), keyEquivalent: "")
        prevItem.target = self
        playbackMenu.addItem(prevItem)
        playbackMenu.addItem(.separator())
        let muteItem = NSMenuItem(title: "Mute / Unmute", action: #selector(muteAction), keyEquivalent: "m")
        muteItem.keyEquivalentModifierMask = [.command, .option]
        muteItem.target = self
        playbackMenu.addItem(muteItem)
        let ccItem = NSMenuItem(title: "Toggle Captions", action: #selector(captionsAction), keyEquivalent: "c")
        ccItem.keyEquivalentModifierMask = [.command, .option]
        ccItem.target = self
        playbackMenu.addItem(ccItem)
        let miniItem = NSMenuItem(title: "Toggle Miniplayer", action: #selector(miniplayerAction), keyEquivalent: "i")
        miniItem.target = self
        playbackMenu.addItem(miniItem)
        let theaterItem = NSMenuItem(title: "Toggle Theater Mode", action: #selector(theaterAction), keyEquivalent: "t")
        theaterItem.target = self
        playbackMenu.addItem(theaterItem)
        playbackItem.submenu = playbackMenu
        mainMenu.addItem(playbackItem)

        // Window menu
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func openURLAction() { windowController?.promptOpenURL() }
    @objc private func focusSearchAction() { windowController?.focusSearchBar() }
    @objc private func goHomeAction() { windowController?.showHome() }
    @objc private func goBackAction() { windowController?.navigateBack() }
    @objc private func goForwardAction() { windowController?.navigateForward() }
    @objc private func toggleSidebarAction() { windowController?.toggleSidebar() }
    @objc private func openSettingsAction() { windowController?.showSettingsWindow() }
    @objc private func toggleThemeAction() { windowController?.toggleDarkMode() }
    @objc private func trimMemoryAction() { windowController?.trimMemoryNow() }
    @objc private func playPauseAction() { windowController?.togglePlaybackFromMenu() }
    @objc private func nextTrackAction() { windowController?.nextTrackFromMenu() }
    @objc private func prevTrackAction() { windowController?.prevTrackFromMenu() }
    @objc private func muteAction() { windowController?.mutePlaybackFromMenu() }
    @objc private func captionsAction() { windowController?.toggleCaptionsFromMenu() }
    @objc private func miniplayerAction() { windowController?.toggleMiniplayerFromMenu() }
    @objc private func theaterAction() { windowController?.toggleTheaterFromMenu() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(goBackAction) {
            return windowController?.canNavigateBack ?? false
        }
        if menuItem.action == #selector(goForwardAction) {
            return windowController?.canNavigateForward ?? false
        }
        if menuItem.action == #selector(playPauseAction) ||
            menuItem.action == #selector(nextTrackAction) ||
            menuItem.action == #selector(prevTrackAction) ||
            menuItem.action == #selector(muteAction) ||
            menuItem.action == #selector(captionsAction) {
            return windowController?.canControlPlayback ?? false
        }
        if menuItem.action == #selector(miniplayerAction) {
            return (windowController?.isWatchPageActive ?? false) || (windowController?.isMiniplayerActive ?? false)
        }
        if menuItem.action == #selector(toggleSidebarAction) {
            return windowController?.canToggleSidebar ?? true
        }
        if menuItem.action == #selector(theaterAction) {
            return windowController?.canToggleTheater ?? false
        }
        return true
    }
}

let app = NSApplication.shared
if ProcessInfo.processInfo.environment["LITETUBE_SELFTEST"] == "1" {
    // Run the layout check without entering the event loop, so no app-status notifications are processed.
    let wc = MainWindowController()
    SelfTest.run(wc)
}
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
if CommandLine.arguments.count > 1 {
    delegate.initialURL = CommandLine.arguments[1]
}
app.delegate = delegate
app.run()

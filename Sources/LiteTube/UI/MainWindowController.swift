import AppKit

final class MainWindowController: NSWindowController,
                                  FeedNavigationDelegate,
                                  WatchNavigationDelegate,
                                  SearchNavigationDelegate,
                                  NSTextFieldDelegate,
                                  NSTableViewDataSource,
                                  NSTableViewDelegate {

    // Top Masthead
    private let masthead = NSView()
    private let mastheadDivider = NSView()
    private let menuBtn = makeSymbolButton("line.3.horizontal", size: IconScale.chrome, tooltip: "Toggle sidebar", hoverBg: YTTheme.surface)
    private let backBtn = makeSymbolButton("chevron.left", size: IconScale.chrome, tooltip: "Back (Cmd+[)", hoverBg: YTTheme.surface)
    private let forwardBtn = makeSymbolButton("chevron.right", size: IconScale.chrome, tooltip: "Forward (Cmd+])", hoverBg: YTTheme.surface)
    private let logoContainer = ClickableView()
    private let logoBadge = YouTubeLogoView()
    private let logoText = makeLabel("LiteTube", size: 16, weight: .bold)
    private let searchBox = ClickableView()
    private let searchField = FocusAwareTextField()
    private var searchTrailingToClear: NSLayoutConstraint!
    private var searchTrailingToGo: NSLayoutConstraint!
    private var isSearchFocused = false
    private let searchClearBtn = makeSymbolButton("xmark.circle.fill", size: IconScale.small, color: YTTheme.textSecondary, tooltip: "Clear search")
    private let searchGoBtn = makeSymbolButton("magnifyingglass", size: IconScale.chrome, tooltip: "Search", hoverBg: YTTheme.surface)
    private let ramPillBtn = PillButton()
    private let themeBtn = makeSymbolButton("moon.fill", size: IconScale.chrome, tooltip: "Toggle Dark / Light Mode", hoverBg: YTTheme.surface)
    private let settingsBtn = makeSymbolButton("slider.horizontal.3", size: IconScale.chrome, tooltip: "All Settings", hoverBg: YTTheme.surface)

    // Autocomplete Dropdown
    private let suggestBox = NSView()
    private let suggestTable = NSTableView()
    private var suggestHeightValue: CGFloat = 0 { didSet { requestRegionLayout() } }
    private var suggestions: [String] = []
    private var suggestWork: DispatchWorkItem?
    private var suggestGeneration = 0
    private var settingsWindow: NSWindow?

    // Sidebar + Main Content
    private let sidebarScroll = NSScrollView()
    private let sidebarStack = NSStackView()
    private let sidebarDoc = FlippedView()
    /// Width of the sidebar region; applied by layoutRegions().
    private var sidebarWidthValue: CGFloat = 224 { didSet { requestRegionLayout() } }
    private var isSidebarCollapsed = false
    private var sidebarRail: Bool { isSidebarCollapsed || activeSidebarRoute == .shorts }
    private var sidebarTargetWidth: CGFloat { sidebarRail ? 72 : 224 }
    private let contentHost = NSView()

    private enum SidebarRoute: Equatable {
        case home, shorts, subscriptions, history, watchLater, liked, queue
        case playlist(String)
        case explore(String)
        case channel(String)
        case none
    }
    private enum NavRoute: Equatable {
        case home(String)
        case feed(FeedMode)
        case shorts
        case search(String)
        case channel(String, String)
        case watch(VideoItem, Double?)
    }
    private var activeSidebarRoute: SidebarRoute = .home
    private var navHistory: [NavRoute] = []
    private var navHistoryIndex: Int = -1
    private var navScrollY: [Int: CGFloat] = [:]
    private var lastNonWatchRoute: NavRoute = .home("All")
    private var isApplyingHistoryNav = false

    // Child View Controllers
    private let homeVC = HomeViewController()
    private let searchVC = SearchViewController()
    private let watchVC = WatchViewController()
    private let channelVC = ChannelViewController()
    private let shortsVC = ShortsViewController()
    private var activeVC: NSViewController?

    // Floating Miniplayer
    private let miniShadowHost = NSView()
    private let miniContainer = NSView()
    private let miniVideoSlot = NSView()
    private let miniDivider = NSView()
    private let miniTitleLabel = makeLabel("", size: 12, weight: .semibold, maxLines: 1)
    private let miniChannelLabel = makeLabel("", size: 11, color: YTTheme.textSecondary, maxLines: 1)
    private let miniPlayPauseBtn = makeSymbolButton("pause.fill", size: 14, tooltip: "Play / Pause", hoverBg: YTTheme.surface)
    private let miniExpandBtn = makeSymbolButton("arrow.up.left.and.arrow.down.right", size: 14, tooltip: "Expand player", hoverBg: YTTheme.surface)
    private let miniCloseBtn = makeSymbolButton("xmark", size: 14, tooltip: "Close miniplayer", hoverBg: YTTheme.surface)
    private var miniVideo: VideoItem?

    // Toast notification
    private let toastBanner = NSView()
    private let toastText = makeLabel("", size: 14, weight: .medium, color: .white, maxLines: 2)
    /// Offset of the toast's right edge from the window's right edge; -400 hides it behind the mini player.
    private var toastTrailingValue: CGFloat = -24 { didSet { requestRegionLayout() } }
    private var menuLeadingConstraint: NSLayoutConstraint!
    private var toastWork: DispatchWorkItem?
    private var toastToken = UUID()

    // RAM Monitor Timer
    private var ramTimer: Timer?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?

    convenience init() {
        // Start at the requested size, clamped to the screen, so the window is not created larger than it can be shown.
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1380, height: 860)
        let size = NSSize(width: min(1380, visible.width), height: min(860, visible.height))
        let win = LiteTubeWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.contentView = WindowContentView(frame: win.contentRect(forFrameRect: win.frame))
        (win.contentView as? WindowContentView)?.hostWindow = win
        win.title = "LiteTube"
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.minSize = NSSize(width: 900, height: 600)
        win.center()
        self.init(window: win)
        setupRootUI()
        applyTheme()
        showHome()
        startRAMMonitor()
        installKeyboardMonitor()
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(onThemeChanged), name: .liteTubeThemeDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onStoreChanged), name: .liteTubeStoreDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onWillEnterFullScreen), name: NSWindow.willEnterFullScreenNotification, object: win)
        NotificationCenter.default.addObserver(self, selector: #selector(onWillExitFullScreen), name: NSWindow.willExitFullScreenNotification, object: win)
    }

    @objc private func onWillEnterFullScreen() {
        menuLeadingConstraint?.constant = 16
    }

    @objc private func onWillExitFullScreen() {
        menuLeadingConstraint?.constant = 82
    }

    deinit {
        ramTimer?.invalidate()
        if let km = keyMonitor { NSEvent.removeMonitor(km) }
        if let mm = mouseMonitor { NSEvent.removeMonitor(mm) }
        NotificationCenter.default.removeObserver(self)
    }

    private weak var rootView: NSView?

    private func requestRegionLayout() {
        rootView?.needsLayout = true
    }

    /// Places the top-level regions by frame. Auto Layout still lays out everything inside each region.
    private func layoutRegions() {
        guard let root = rootView else { return }
        let w = root.bounds.width
        let h = root.bounds.height
        let mastheadH: CGFloat = 48
        let dividerH: CGFloat = 1
        masthead.frame = NSRect(x: 0, y: h - mastheadH, width: w, height: mastheadH)
        mastheadDivider.frame = NSRect(x: 0, y: h - mastheadH - dividerH, width: w, height: dividerH)
        let regionTop = max(0, h - mastheadH - dividerH)
        masthead.layoutSubtreeIfNeeded()

        let sidebarW = min(max(0, sidebarWidthValue), w)
        sidebarScroll.frame = NSRect(x: 0, y: 0, width: sidebarW, height: regionTop)
        contentHost.frame = NSRect(x: sidebarW, y: 0, width: max(0, w - sidebarW), height: regionTop)

        miniShadowHost.frame = NSRect(x: w - 20 - 360, y: 20, width: 360, height: 253)

        // Suggestions hang under the search pill.
        let search = searchBox.convert(searchBox.bounds, to: root)
        suggestBox.frame = NSRect(x: search.minX, y: search.minY - 4 - suggestHeightValue, width: search.width, height: suggestHeightValue)

        // Toast: bottom-left, width fits its text but stops at the toast's right edge.
        toastText.layoutSubtreeIfNeeded()
        let fit = toastText.fittingSize
        let toastH = fit.height + 18
        let maxRight = w + toastTrailingValue
        let toastW = max(0, min(fit.width + 28, maxRight - 24))
        toastBanner.frame = NSRect(x: 24, y: 24, width: toastW, height: toastH)
    }

    private func setupRootUI() {
        guard let root = window?.contentView else { return }
        root.wantsLayer = true
        rootView = root
        (root as? WindowContentView)?.onLayout = { [weak self] in self?.layoutRegions() }
        homeVC.navDelegate = self
        homeVC.onCategorySelected = { [weak self] cat in
            self?.recordRoute(.home(cat))
        }
        searchVC.navDelegate = self
        watchVC.navDelegate = self
        channelVC.navDelegate = self
        channelVC.onOpenPlaylist = { [weak self] id, name in self?.openPlaylist(id: id, name: name) }
        shortsVC.navDelegate = self

        // Masthead
        masthead.wantsLayer = true
        masthead.translatesAutoresizingMaskIntoConstraints = true
        root.addSubview(masthead)

        mastheadDivider.wantsLayer = true
        mastheadDivider.translatesAutoresizingMaskIntoConstraints = true
        root.addSubview(mastheadDivider)

        menuBtn.target = self; menuBtn.action = #selector(toggleSidebar)
        masthead.addSubview(menuBtn)

        backBtn.target = self; backBtn.action = #selector(navigateBack)
        backBtn.isEnabled = false
        forwardBtn.target = self; forwardBtn.action = #selector(navigateForward)
        forwardBtn.isEnabled = false
        masthead.addSubview(backBtn)
        masthead.addSubview(forwardBtn)

        logoContainer.translatesAutoresizingMaskIntoConstraints = false
        logoContainer.accessibilityTitle = "LiteTube Home"
        logoContainer.toolTip = "Go to Home"
        logoContainer.allowsKeyboardFocus = true
        logoContainer.onClick = { [weak self] in self?.showHome() }
        masthead.addSubview(logoContainer)
        logoBadge.translatesAutoresizingMaskIntoConstraints = false
        logoContainer.addSubview(logoBadge)
        logoContainer.addSubview(logoText)

        // Centered YouTube Search Pill
        searchBox.wantsLayer = true
        searchBox.layer?.cornerRadius = 18
        searchBox.layer?.borderWidth = 1
        searchBox.actsAsAccessibilityElement = false
        searchBox.onClick = { [weak self] in self?.focusSearchBar() }
        searchBox.translatesAutoresizingMaskIntoConstraints = false
        masthead.addSubview(searchBox)

        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 14)
        searchField.placeholderString = "Search YouTube or paste a YouTube URL..."
        searchField.setAccessibilityLabel("Search YouTube or paste a YouTube URL")
        searchField.onFocusChanged = { [weak self] focused in
            self?.isSearchFocused = focused
            self?.searchBox.layer?.borderColor = (focused ? YTTheme.linkBlue : YTTheme.border).cgColor
        }
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchBox.addSubview(searchField)

        searchClearBtn.isHidden = true
        searchClearBtn.target = self; searchClearBtn.action = #selector(clearSearchField)
        searchBox.addSubview(searchClearBtn)

        searchGoBtn.target = self; searchGoBtn.action = #selector(submitSearch)
        searchBox.addSubview(searchGoBtn)

        // Right masthead controls: RAM Pill, Theme Toggle, Settings
        ramPillBtn.useDynamicThemeColors = false
        ramPillBtn.title = "RAM: -- MB"
        ramPillBtn.toolTip = "Physical memory footprint — click for breakdown"
        ramPillBtn.setAccessibilityLabel("Memory use. Opens a breakdown.")
        ramPillBtn.cornerRadiusValue = 14
        ramPillBtn.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        ramPillBtn.horizontalPadding = 10
        ramPillBtn.target = self; ramPillBtn.action = #selector(showRAMInspector)
        ramPillBtn.translatesAutoresizingMaskIntoConstraints = false

        themeBtn.target = self; themeBtn.action = #selector(toggleDarkMode)
        settingsBtn.target = self; settingsBtn.action = #selector(showSettingsPopover)

        let rightCluster = NSStackView(views: [ramPillBtn, themeBtn, settingsBtn])
        rightCluster.orientation = .horizontal
        rightCluster.spacing = 12
        rightCluster.alignment = .centerY
        rightCluster.translatesAutoresizingMaskIntoConstraints = false
        masthead.addSubview(rightCluster)

        // Sidebar
        sidebarScroll.identifier = NSUserInterfaceItemIdentifier("sidebarScroll")
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.scrollerStyle = .overlay
        sidebarScroll.autohidesScrollers = true
        sidebarScroll.drawsBackground = false
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = true
        root.addSubview(sidebarScroll)

        // sidebarDoc is a stored property (see above)
        sidebarDoc.translatesAutoresizingMaskIntoConstraints = false
        sidebarScroll.documentView = sidebarDoc

        sidebarStack.orientation = .vertical
        sidebarStack.alignment = .leading
        sidebarStack.spacing = 2
        sidebarStack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 20, right: 10)
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false
        sidebarDoc.addSubview(sidebarStack)

        // Main Content Host
        contentHost.wantsLayer = true
        contentHost.translatesAutoresizingMaskIntoConstraints = true
        root.addSubview(contentHost)

        // Floating Miniplayer
        miniShadowHost.wantsLayer = true
        miniShadowHost.layer?.shadowColor = NSColor.black.cgColor
        miniShadowHost.layer?.shadowOpacity = 0.45
        miniShadowHost.layer?.shadowRadius = 14
        miniShadowHost.layer?.shadowOffset = CGSize(width: 0, height: -4)
        miniShadowHost.isHidden = true
        miniShadowHost.translatesAutoresizingMaskIntoConstraints = true
        root.addSubview(miniShadowHost)

        miniContainer.wantsLayer = true
        miniContainer.layer?.cornerRadius = 12
        miniContainer.layer?.masksToBounds = true
        miniContainer.layer?.borderWidth = 1
        miniContainer.translatesAutoresizingMaskIntoConstraints = false
        miniShadowHost.addSubview(miniContainer)

        miniVideoSlot.wantsLayer = true
        miniVideoSlot.layer?.backgroundColor = NSColor.black.cgColor
        miniVideoSlot.translatesAutoresizingMaskIntoConstraints = false
        miniContainer.addSubview(miniVideoSlot)

        miniDivider.wantsLayer = true
        miniDivider.translatesAutoresizingMaskIntoConstraints = false
        miniContainer.addSubview(miniDivider)

        let miniFooter = ClickableView()
        miniFooter.translatesAutoresizingMaskIntoConstraints = false
        miniFooter.actsAsAccessibilityElement = false
        miniFooter.onClick = { [weak self] in self?.expandMiniplayer() }
        miniContainer.addSubview(miniFooter)
        miniPlayPauseBtn.target = self; miniPlayPauseBtn.action = #selector(toggleMiniPlayPause)
        miniExpandBtn.target = self; miniExpandBtn.action = #selector(expandMiniplayer)
        miniCloseBtn.target = self; miniCloseBtn.action = #selector(closeMiniplayer)
        watchVC.playerView.onMiniDoubleClick = { [weak self] in self?.expandMiniplayer() }
        watchVC.playerView.onPlayStateChanged = { [weak self] playing in
            self?.syncMiniPlayPauseButton(playing: playing)
        }
        miniFooter.addSubview(miniTitleLabel)
        miniFooter.addSubview(miniChannelLabel)
        miniFooter.addSubview(miniPlayPauseBtn)
        miniFooter.addSubview(miniExpandBtn)
        miniFooter.addSubview(miniCloseBtn)

        // Autocomplete Dropdown (floats above content)
        suggestBox.wantsLayer = true
        suggestBox.layer?.cornerRadius = 12
        suggestBox.layer?.borderWidth = 1
        suggestBox.isHidden = true
        suggestBox.translatesAutoresizingMaskIntoConstraints = true
        root.addSubview(suggestBox)

        let scol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sug"))
        scol.resizingMask = .autoresizingMask
        suggestTable.addTableColumn(scol)
        suggestTable.headerView = nil
        suggestTable.backgroundColor = .clear
        suggestTable.rowHeight = 32
        suggestTable.dataSource = self
        suggestTable.delegate = self
        suggestTable.action = #selector(suggestionClicked)
        suggestTable.target = self

        let sScroll = NSScrollView()
        sScroll.documentView = suggestTable
        sScroll.drawsBackground = false
        sScroll.translatesAutoresizingMaskIntoConstraints = false
        suggestBox.addSubview(sScroll)

        // Toast Banner
        toastBanner.wantsLayer = true
        toastBanner.layer?.backgroundColor = YTTheme.mainToastBg.cgColor
        toastBanner.layer?.cornerRadius = 8
        toastBanner.isHidden = true
        toastBanner.translatesAutoresizingMaskIntoConstraints = true
        root.addSubview(toastBanner)
        toastBanner.addSubview(toastText)

        menuLeadingConstraint = menuBtn.leadingAnchor.constraint(equalTo: masthead.leadingAnchor, constant: 82)
        toastText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let preferredSearchWidth = searchBox.widthAnchor.constraint(equalToConstant: 540)
        preferredSearchWidth.priority = .defaultHigh
        let centerSearchX = searchBox.centerXAnchor.constraint(equalTo: masthead.centerXAnchor)
        centerSearchX.priority = .defaultLow

        searchTrailingToClear = searchField.trailingAnchor.constraint(equalTo: searchClearBtn.leadingAnchor, constant: -4)
        searchTrailingToGo = searchField.trailingAnchor.constraint(equalTo: searchGoBtn.leadingAnchor, constant: -4)

        NSLayoutConstraint.activate([
            // Masthead (leave 78px on left for macOS traffic light buttons!)


            menuLeadingConstraint,
            menuBtn.centerYAnchor.constraint(equalTo: masthead.centerYAnchor),
            menuBtn.widthAnchor.constraint(equalToConstant: 32),
            menuBtn.heightAnchor.constraint(equalToConstant: 32),

            backBtn.leadingAnchor.constraint(equalTo: menuBtn.trailingAnchor, constant: 4),
            backBtn.centerYAnchor.constraint(equalTo: masthead.centerYAnchor),
            backBtn.widthAnchor.constraint(equalToConstant: 28),
            backBtn.heightAnchor.constraint(equalToConstant: 28),

            forwardBtn.leadingAnchor.constraint(equalTo: backBtn.trailingAnchor, constant: 2),
            forwardBtn.centerYAnchor.constraint(equalTo: masthead.centerYAnchor),
            forwardBtn.widthAnchor.constraint(equalToConstant: 28),
            forwardBtn.heightAnchor.constraint(equalToConstant: 28),

            logoContainer.leadingAnchor.constraint(equalTo: forwardBtn.trailingAnchor, constant: 8),
            logoContainer.centerYAnchor.constraint(equalTo: masthead.centerYAnchor),
            logoContainer.heightAnchor.constraint(equalToConstant: 32),
            logoBadge.leadingAnchor.constraint(equalTo: logoContainer.leadingAnchor),
            logoBadge.centerYAnchor.constraint(equalTo: logoContainer.centerYAnchor),
            logoBadge.widthAnchor.constraint(equalToConstant: 30),
            logoBadge.heightAnchor.constraint(equalToConstant: 24),
            logoText.leadingAnchor.constraint(equalTo: logoBadge.trailingAnchor, constant: 6),
            logoText.trailingAnchor.constraint(equalTo: logoContainer.trailingAnchor),
            logoText.centerYAnchor.constraint(equalTo: logoContainer.centerYAnchor),

            centerSearchX,
            searchBox.centerYAnchor.constraint(equalTo: masthead.centerYAnchor),
            preferredSearchWidth,
            searchBox.widthAnchor.constraint(lessThanOrEqualToConstant: 540),
            searchBox.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            searchBox.leadingAnchor.constraint(greaterThanOrEqualTo: logoContainer.trailingAnchor, constant: 16),
            searchBox.trailingAnchor.constraint(lessThanOrEqualTo: rightCluster.leadingAnchor, constant: -16),
            searchBox.heightAnchor.constraint(equalToConstant: 36),

            searchField.leadingAnchor.constraint(equalTo: searchBox.leadingAnchor, constant: 16),
            searchTrailingToGo,
            searchField.centerYAnchor.constraint(equalTo: searchBox.centerYAnchor),

            searchClearBtn.trailingAnchor.constraint(equalTo: searchGoBtn.leadingAnchor, constant: -2),
            searchClearBtn.centerYAnchor.constraint(equalTo: searchBox.centerYAnchor),
            searchClearBtn.widthAnchor.constraint(equalToConstant: 24),
            searchClearBtn.heightAnchor.constraint(equalToConstant: 24),

            searchGoBtn.trailingAnchor.constraint(equalTo: searchBox.trailingAnchor, constant: -10),
            searchGoBtn.centerYAnchor.constraint(equalTo: searchBox.centerYAnchor),
            searchGoBtn.widthAnchor.constraint(equalToConstant: 30),
            searchGoBtn.heightAnchor.constraint(equalToConstant: 30),

            rightCluster.trailingAnchor.constraint(equalTo: masthead.trailingAnchor, constant: -16),
            rightCluster.centerYAnchor.constraint(equalTo: masthead.centerYAnchor),
            themeBtn.widthAnchor.constraint(equalToConstant: 28),
            themeBtn.heightAnchor.constraint(equalToConstant: 28),
            settingsBtn.widthAnchor.constraint(equalToConstant: 28),
            settingsBtn.heightAnchor.constraint(equalToConstant: 28),

            // Sidebar & Content

            sidebarDoc.topAnchor.constraint(equalTo: sidebarScroll.contentView.topAnchor),
            sidebarDoc.leadingAnchor.constraint(equalTo: sidebarScroll.contentView.leadingAnchor),
            sidebarDoc.widthAnchor.constraint(equalTo: sidebarScroll.contentView.widthAnchor),
            sidebarStack.topAnchor.constraint(equalTo: sidebarDoc.topAnchor),
            sidebarStack.leadingAnchor.constraint(equalTo: sidebarDoc.leadingAnchor),
            sidebarStack.trailingAnchor.constraint(equalTo: sidebarDoc.trailingAnchor),
            sidebarStack.bottomAnchor.constraint(equalTo: sidebarDoc.bottomAnchor),


            // Autocomplete box
            sScroll.topAnchor.constraint(equalTo: suggestBox.topAnchor, constant: 4),
            sScroll.bottomAnchor.constraint(equalTo: suggestBox.bottomAnchor, constant: -4),
            sScroll.leadingAnchor.constraint(equalTo: suggestBox.leadingAnchor),
            sScroll.trailingAnchor.constraint(equalTo: suggestBox.trailingAnchor),

            // Floating Miniplayer

            miniContainer.topAnchor.constraint(equalTo: miniShadowHost.topAnchor),
            miniContainer.leadingAnchor.constraint(equalTo: miniShadowHost.leadingAnchor),
            miniContainer.trailingAnchor.constraint(equalTo: miniShadowHost.trailingAnchor),
            miniContainer.bottomAnchor.constraint(equalTo: miniShadowHost.bottomAnchor),

            miniVideoSlot.topAnchor.constraint(equalTo: miniContainer.topAnchor),
            miniVideoSlot.leadingAnchor.constraint(equalTo: miniContainer.leadingAnchor),
            miniVideoSlot.trailingAnchor.constraint(equalTo: miniContainer.trailingAnchor),
            miniVideoSlot.heightAnchor.constraint(equalToConstant: 202),

            miniDivider.topAnchor.constraint(equalTo: miniVideoSlot.bottomAnchor),
            miniDivider.leadingAnchor.constraint(equalTo: miniContainer.leadingAnchor),
            miniDivider.trailingAnchor.constraint(equalTo: miniContainer.trailingAnchor),
            miniDivider.heightAnchor.constraint(equalToConstant: 1),

            miniFooter.topAnchor.constraint(equalTo: miniDivider.bottomAnchor),
            miniFooter.leadingAnchor.constraint(equalTo: miniContainer.leadingAnchor),
            miniFooter.trailingAnchor.constraint(equalTo: miniContainer.trailingAnchor),
            miniFooter.bottomAnchor.constraint(equalTo: miniContainer.bottomAnchor),

            miniTitleLabel.topAnchor.constraint(equalTo: miniFooter.topAnchor, constant: 8),
            miniTitleLabel.leadingAnchor.constraint(equalTo: miniFooter.leadingAnchor, constant: 10),
            miniTitleLabel.trailingAnchor.constraint(equalTo: miniPlayPauseBtn.leadingAnchor, constant: -6),
            miniChannelLabel.topAnchor.constraint(equalTo: miniTitleLabel.bottomAnchor, constant: 2),
            miniChannelLabel.leadingAnchor.constraint(equalTo: miniTitleLabel.leadingAnchor),
            miniChannelLabel.trailingAnchor.constraint(equalTo: miniTitleLabel.trailingAnchor),

            miniCloseBtn.trailingAnchor.constraint(equalTo: miniFooter.trailingAnchor, constant: -8),
            miniCloseBtn.centerYAnchor.constraint(equalTo: miniFooter.centerYAnchor),
            miniCloseBtn.widthAnchor.constraint(equalToConstant: 26),
            miniCloseBtn.heightAnchor.constraint(equalToConstant: 26),

            miniExpandBtn.trailingAnchor.constraint(equalTo: miniCloseBtn.leadingAnchor, constant: -4),
            miniExpandBtn.centerYAnchor.constraint(equalTo: miniFooter.centerYAnchor),
            miniExpandBtn.widthAnchor.constraint(equalToConstant: 26),
            miniExpandBtn.heightAnchor.constraint(equalToConstant: 26),

            miniPlayPauseBtn.trailingAnchor.constraint(equalTo: miniExpandBtn.leadingAnchor, constant: -4),
            miniPlayPauseBtn.centerYAnchor.constraint(equalTo: miniFooter.centerYAnchor),
            miniPlayPauseBtn.widthAnchor.constraint(equalToConstant: 26),
            miniPlayPauseBtn.heightAnchor.constraint(equalToConstant: 26),

            // Toast
            toastText.topAnchor.constraint(equalTo: toastBanner.topAnchor, constant: 9),
            toastText.bottomAnchor.constraint(equalTo: toastBanner.bottomAnchor, constant: -9),
            toastText.leadingAnchor.constraint(equalTo: toastBanner.leadingAnchor, constant: 14),
            toastText.trailingAnchor.constraint(equalTo: toastBanner.trailingAnchor, constant: -14)
        ])

        rebuildSidebar()
    }

    // MARK: - Sidebar Navigation

    private func rebuildSidebar() {
        menuBtn.isEnabled = canToggleSidebar
        menuBtn.alphaValue = canToggleSidebar ? 1 : 0.35
        var focusedTitle: String?
        if let fr = window?.firstResponder as? ClickableView,
           sidebarStack.arrangedSubviews.contains(where: { $0 === fr }) {
            focusedTitle = fr.accessibilityTitle
        }
        sidebarStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        addSidebarItem(icon: "house.fill", title: "Home", isActive: activeSidebarRoute == .home) { [weak self] in self?.showHome() }
        addSidebarItem(icon: "bolt.fill", title: "Shorts", isActive: activeSidebarRoute == .shorts) { [weak self] in self?.showShorts() }
        addSidebarItem(icon: "rectangle.stack.person.crop", title: "Subscriptions", isActive: activeSidebarRoute == .subscriptions) { [weak self] in self?.showFeed(.subscriptions) }

        addSidebarDivider()
        if !sidebarRail { addSidebarSectionHeader("You") }
        addSidebarItem(icon: "clock.arrow.circlepath", title: "History", isActive: activeSidebarRoute == .history) { [weak self] in self?.showFeed(.history) }
        addSidebarItem(icon: "clock", title: "Watch Later", isActive: activeSidebarRoute == .watchLater) { [weak self] in self?.showFeed(.watchLater) }
        addSidebarItem(icon: "hand.thumbsup", title: "Liked Videos", isActive: activeSidebarRoute == .liked) { [weak self] in self?.showFeed(.liked) }
        addSidebarItem(icon: "list.bullet", title: "Queue", isActive: activeSidebarRoute == .queue) { [weak self] in self?.showFeed(.queue) }

        if !sidebarRail {
            for pl in LocalStore.shared.playlists {
                addSidebarItem(icon: "music.note.list", title: pl.name, isActive: activeSidebarRoute == .playlist(pl.id)) { [weak self] in
                    self?.showFeed(.playlist(id: pl.id, name: pl.name))
                }
            }
        }

        addSidebarDivider()
        if !sidebarRail { addSidebarSectionHeader("Explore") }
        let explores: [(String, String)] = [
            ("music.note", "Music"),
            ("gamecontroller.fill", "Gaming"),
            ("dot.radiowaves.left.and.right", "Live"),
            ("newspaper.fill", "News"),
            ("sportscourt.fill", "Sports"),
            ("atom", "Science"),
            ("cpu", "Technology"),
            ("mic.fill", "Podcasts")
        ]
        for (ic, name) in explores {
            addSidebarItem(icon: ic, title: name, isActive: activeSidebarRoute == .explore(name)) { [weak self] in self?.showFeed(.explore(name)) }
        }

        if !sidebarRail && !LocalStore.shared.subscriptions.isEmpty {
            addSidebarDivider()
            addSidebarSectionHeader("Subscribed Channels")
            for sub in LocalStore.shared.subscriptions.prefix(15) {
                addSidebarItem(icon: "person.crop.circle", title: sub.name, isActive: activeSidebarRoute == .channel(sub.id)) { [weak self] in
                    self?.openChannel(channelId: sub.id, name: sub.name)
                }
            }
        }
        if let ft = focusedTitle,
           let match = sidebarStack.arrangedSubviews.compactMap({ $0 as? ClickableView }).first(where: { $0.accessibilityTitle == ft }) {
            window?.makeFirstResponder(match)
        }
    }

    private func addSidebarItem(icon: String, title: String, isActive: Bool = false, action: @escaping () -> Void) {
        let row = ClickableView()
        row.layer?.cornerRadius = 8
        row.hoverBgColor = isActive ? YTTheme.surfaceHover : YTTheme.surface
        row.normalBgColor = isActive ? YTTheme.surface : .clear
        row.accessibilityTitle = title
        row.setAccessibilityRole(.button)
        // ClickableView reports selection from accessibilitySelectedState.
        row.accessibilitySelectedState = isActive
        // Button-role rows read their value aloud, so the current item is announced as "Selected".
        row.setAccessibilityValue(isActive ? "Selected" : nil)
        row.allowsKeyboardFocus = true
        row.onClick = action
        row.translatesAutoresizingMaskIntoConstraints = false

        let iv = NSImageView()
        let cfg = NSImage.SymbolConfiguration(pointSize: IconScale.chrome, weight: .medium)
        iv.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)?.withSymbolConfiguration(cfg)
        iv.contentTintColor = YTTheme.textPrimary
        iv.translatesAutoresizingMaskIntoConstraints = false
        // The row is the one accessible control; its icon and label are not announced separately.
        iv.setAccessibilityElement(false)
        row.addSubview(iv)

        // Add to the stack before activating constraints that reference sidebarDoc (same view hierarchy required).
        sidebarStack.addArrangedSubview(row)
        if !sidebarRail {
            let lbl = makeLabel(title, size: 14, weight: .semibold, color: YTTheme.textPrimary)
            lbl.setAccessibilityElement(false)
            row.addSubview(lbl)
            if isActive {
                // Accent bar: selection is shown by more than a faint fill.
                let bar = NSView()
                bar.wantsLayer = true
                bar.layer?.backgroundColor = YTTheme.linkBlue.cgColor
                bar.layer?.cornerRadius = 1.5
                bar.translatesAutoresizingMaskIntoConstraints = false
                bar.setAccessibilityElement(false)
                row.addSubview(bar)
                NSLayoutConstraint.activate([
                    bar.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 2),
                    bar.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                    bar.widthAnchor.constraint(equalToConstant: 3),
                    bar.heightAnchor.constraint(equalToConstant: 18)
                ])
            }
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
                iv.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 20),
                lbl.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 14),
                lbl.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
                lbl.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                row.heightAnchor.constraint(equalToConstant: 36),
                row.widthAnchor.constraint(equalTo: sidebarDoc.widthAnchor, constant: -20)
            ])
        } else {
            row.toolTip = title
            if isActive {
                // Same accent bar as the expanded rail so selection reads the same in both modes.
                let bar = NSView()
                bar.wantsLayer = true
                bar.layer?.backgroundColor = YTTheme.linkBlue.cgColor
                bar.layer?.cornerRadius = 1.5
                bar.translatesAutoresizingMaskIntoConstraints = false
                bar.setAccessibilityElement(false)
                row.addSubview(bar)
                NSLayoutConstraint.activate([
                    bar.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 2),
                    bar.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                    bar.widthAnchor.constraint(equalToConstant: 3),
                    bar.heightAnchor.constraint(equalToConstant: 18)
                ])
            }
            NSLayoutConstraint.activate([
                iv.centerXAnchor.constraint(equalTo: row.centerXAnchor),
                iv.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                row.heightAnchor.constraint(equalToConstant: 36),
                row.widthAnchor.constraint(equalTo: sidebarDoc.widthAnchor, constant: -20)
            ])
        }
    }

    private func addSidebarSectionHeader(_ title: String) {
        let lbl = sectionHeadingLabel(title)
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(lbl)
        sidebarStack.addArrangedSubview(box)
        NSLayoutConstraint.activate([
            lbl.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            lbl.topAnchor.constraint(equalTo: box.topAnchor, constant: 6),
            lbl.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -4),
            box.widthAnchor.constraint(equalTo: sidebarDoc.widthAnchor, constant: -20)
        ])
    }

    private func addSidebarDivider() {
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = YTTheme.divider.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(line)
        sidebarStack.addArrangedSubview(wrap)
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 6),
            line.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -6),
            line.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 10),
            line.heightAnchor.constraint(equalToConstant: 1),
            wrap.widthAnchor.constraint(equalTo: sidebarDoc.widthAnchor, constant: -20),
            line.widthAnchor.constraint(equalTo: wrap.widthAnchor, constant: -20)
        ])
    }

    /// Shorts pins the sidebar to its rail, so the toggle has no effect there and is disabled.
    var canToggleSidebar: Bool { activeSidebarRoute != .shorts }

    @objc func toggleSidebar() {
        // Shorts always shows the rail, so toggling there would only flip a state the user can't see.
        guard canToggleSidebar else { return }
        if activeVC === watchVC {
            if sidebarWidthValue == 0 {
                // Reveal at the user's own preferred width; don't overwrite their saved rail/full choice.
                sidebarWidthValue = sidebarTargetWidth
            } else {
                sidebarWidthValue = 0
            }
            rebuildSidebar()
            return
        }
        isSidebarCollapsed.toggle()
        sidebarWidthValue = sidebarTargetWidth
        rebuildSidebar()
    }

    // MARK: - Content Router & Navigation History

    private func saveCurrentScrollPosition() {
        guard navHistoryIndex >= 0 else { return }
        if activeVC === homeVC { navScrollY[navHistoryIndex] = homeVC.currentScrollY }
        else if activeVC === searchVC { navScrollY[navHistoryIndex] = searchVC.currentScrollY }
        else if activeVC === channelVC { navScrollY[navHistoryIndex] = channelVC.currentScrollY }
    }

    private func recordRoute(_ route: NavRoute) {
        if case .home = route { lastNonWatchRoute = route }
        else if case .feed = route { lastNonWatchRoute = route }
        else if case .search = route { lastNonWatchRoute = route }
        else if case .channel = route { lastNonWatchRoute = route }

        guard !isApplyingHistoryNav else { return }
        saveCurrentScrollPosition()
        if navHistoryIndex >= 0 && navHistoryIndex < navHistory.count && navHistory[navHistoryIndex] == route {
            updateHistoryButtons()
            return
        }
        if navHistoryIndex + 1 < navHistory.count {
            for idx in (navHistoryIndex + 1)..<navHistory.count { navScrollY.removeValue(forKey: idx) }
            navHistory.removeSubrange((navHistoryIndex + 1)..<navHistory.count)
        }
        navHistory.append(route)
        if navHistory.count > 50 {
            navHistory.removeFirst()
            var shifted: [Int: CGFloat] = [:]
            for (k, v) in navScrollY where k > 0 { shifted[k - 1] = v }
            navScrollY = shifted
        }
        navHistoryIndex = navHistory.count - 1
        updateHistoryButtons()
    }

    var canNavigateBack: Bool { navHistoryIndex > 0 }
    var canNavigateForward: Bool { navHistoryIndex >= 0 && navHistoryIndex + 1 < navHistory.count }

    private func updateHistoryButtons() {
        let canBack = canNavigateBack
        let canFwd = canNavigateForward
        backBtn.isEnabled = canBack
        forwardBtn.isEnabled = canFwd
        backBtn.alphaValue = canBack ? 1.0 : 0.35
        forwardBtn.alphaValue = canFwd ? 1.0 : 0.35
    }

    @objc func navigateBack() {
        guard navHistoryIndex > 0 else { return }
        saveCurrentScrollPosition()
        navHistoryIndex -= 1
        applyRoute(navHistory[navHistoryIndex], scrollY: navScrollY[navHistoryIndex])
    }

    @objc func navigateForward() {
        guard navHistoryIndex + 1 < navHistory.count else { return }
        saveCurrentScrollPosition()
        navHistoryIndex += 1
        applyRoute(navHistory[navHistoryIndex], scrollY: navScrollY[navHistoryIndex])
    }

    private func applyRoute(_ route: NavRoute, scrollY: CGFloat? = nil) {
        isApplyingHistoryNav = true
        defer {
            isApplyingHistoryNav = false
            updateHistoryButtons()
        }
        switch route {
        case .home(let cat):
            if homeVC.canReuseLoadedFeed(mode: .home, category: cat) {
                activeSidebarRoute = .home
                sidebarWidthValue = sidebarTargetWidth
                rebuildSidebar()
                setContent(homeVC)
                if let y = scrollY { homeVC.restoreScrollY(y) }
            } else {
                showHome(category: cat)
            }
        case .feed(let mode):
            if homeVC.canReuseLoadedFeed(mode: mode, category: nil) {
                activeSidebarRoute = sidebarRoute(for: mode)
                sidebarWidthValue = sidebarTargetWidth
                rebuildSidebar()
                setContent(homeVC)
                if let y = scrollY { homeVC.restoreScrollY(y) }
            } else {
                showFeed(mode)
            }
        case .shorts: showShorts()
        case .search(let q):
            searchField.stringValue = q
            updateSearchClearVisible(!q.isEmpty)
            if searchVC.query == q && !searchVC.lastSearchFailed {
                activeSidebarRoute = .none
                sidebarWidthValue = sidebarTargetWidth
                rebuildSidebar()
                setContent(searchVC)
                if let y = scrollY { searchVC.restoreScrollY(y) }
            } else {
                executeSearch(q)
            }
        case .channel(let id, let name):
            if channelVC.canReuseLoadedChannel(id: id) {
                activeSidebarRoute = .channel(id)
                sidebarWidthValue = sidebarTargetWidth
                rebuildSidebar()
                setContent(channelVC)
                if let y = scrollY { channelVC.restoreScrollY(y) }
            } else {
                openChannel(channelId: id, name: name)
            }
        case .watch(let v, let t):
            if !miniShadowHost.isHidden, miniVideo?.id == v.id {
                expandMiniplayer()
            } else {
                openVideo(v, startSeconds: t)
            }
        }
    }

    private func sidebarRoute(for mode: FeedMode) -> SidebarRoute {
        switch mode {
        case .home: return .home
        case .subscriptions: return .subscriptions
        case .history: return .history
        case .watchLater: return .watchLater
        case .liked: return .liked
        case .queue: return .queue
        case .playlist(let id, _): return .playlist(id)
        case .explore(let name): return .explore(name)
        }
    }

    private func setContent(_ vc: NSViewController) {
        if activeVC === shortsVC && vc !== shortsVC {
            shortsVC.deactivate()
        }
        if activeVC === watchVC && vc !== watchVC && miniShadowHost.isHidden {
            watchVC.recordExactHistoryPosition()
            watchVC.playerView.stopAndReleaseMemory()
        }
        if vc !== searchVC {
            searchField.stringValue = ""
            updateSearchClearVisible(false)
        }
        suggestGeneration += 1
        suggestWork?.cancel()
        suggestions = []
        activeVC?.view.removeFromSuperview()
        activeVC = vc
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.topAnchor.constraint(equalTo: contentHost.topAnchor),
            vc.view.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            vc.view.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor)
        ])
        suggestBox.isHidden = true
    }

    func showHome() {
        showHome(category: "All")
    }

    func showHome(category: String) {
        activeSidebarRoute = .home
        recordRoute(.home(category))
        sidebarWidthValue = sidebarTargetWidth
        rebuildSidebar()
        setContent(homeVC)
        homeVC.load(mode: .home, category: category)
    }

    func showFeed(_ mode: FeedMode) {
        activeSidebarRoute = sidebarRoute(for: mode)
        recordRoute(.feed(mode))
        sidebarWidthValue = sidebarTargetWidth
        rebuildSidebar()
        setContent(homeVC)
        homeVC.load(mode: mode)
    }

    func showShorts() {
        if !miniShadowHost.isHidden { closeMiniplayer() }
        activeSidebarRoute = .shorts
        recordRoute(.shorts)
        sidebarWidthValue = sidebarTargetWidth
        rebuildSidebar()
        setContent(shortsVC)
        shortsVC.activate()
    }

    func openVideo(_ video: VideoItem, startSeconds: Double?) {
        miniShadowHost.isHidden = true
        toastTrailingValue = -24
        miniVideo = nil
        activeSidebarRoute = .none
        recordRoute(.watch(video, startSeconds))
        // Auto-collapse sidebar on Watch page just like YouTube!
        sidebarWidthValue = 0
        rebuildSidebar()
        setContent(watchVC)
        watchVC.loadVideo(video, startSeconds: startSeconds)
    }

    func openURLString(_ raw: String) {
        if let parsed = Formatters.parseYouTubeURL(raw) {
            let v = VideoItem(id: parsed.videoId, title: "Loading...", channelName: "", channelId: "", channelAvatarURL: nil, thumbnailURL: "", durationText: "", viewsText: "", publishedText: "")
            openVideo(v, startSeconds: parsed.startSeconds)
        } else {
            searchField.stringValue = raw
            updateSearchClearVisible(!raw.isEmpty)
            submitSearch()
        }
    }

    func openChannel(channelId: String, name: String) {
        activeSidebarRoute = .channel(channelId)
        recordRoute(.channel(channelId, name))
        sidebarWidthValue = sidebarTargetWidth
        rebuildSidebar()
        setContent(channelVC)
        channelVC.loadChannel(channelId: channelId, initialName: name)
    }

    func openPlaylist(id: String, name: String) {
        showFeed(.playlist(id: id, name: name))
    }

    // MARK: - Miniplayer

    func enterMiniplayer(with playerView: PlayerView, video: VideoItem) {
        miniVideo = video
        miniTitleLabel.stringValue = video.title
        miniChannelLabel.stringValue = video.channelName
        playerView.removeFromSuperview()
        playerView.setMiniMode(true)
        playerView.translatesAutoresizingMaskIntoConstraints = false
        miniVideoSlot.addSubview(playerView)
        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: miniVideoSlot.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: miniVideoSlot.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: miniVideoSlot.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: miniVideoSlot.bottomAnchor)
        ])
        miniShadowHost.isHidden = false
        toastTrailingValue = -400
        syncMiniPlayPauseButton(playing: playerView.isPlaying)
        applyRoute(lastNonWatchRoute)
    }

    func updateCurrentVideoMetadata(video: VideoItem) {
        if miniVideo?.id == video.id {
            miniVideo = video
            if !video.title.isEmpty && video.title != "Loading..." {
                miniTitleLabel.stringValue = video.title
            }
            if !video.channelName.isEmpty {
                miniChannelLabel.stringValue = video.channelName
            }
        }
    }

    private func syncMiniPlayPauseButton(playing: Bool) {
        let sym = playing ? "pause.fill" : "play.fill"
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        miniPlayPauseBtn.image = NSImage(systemSymbolName: sym, accessibilityDescription: playing ? "Pause" : "Play")?.withSymbolConfiguration(cfg)
        miniPlayPauseBtn.setAccessibilityLabel(playing ? "Pause" : "Play")
    }

    @objc private func toggleMiniPlayPause() {
        watchVC.playerView.togglePlayPause()
    }

    @objc private func expandMiniplayer() {
        miniShadowHost.isHidden = true
        toastTrailingValue = -24
        sidebarWidthValue = 0
        activeSidebarRoute = .none
        if let mv = miniVideo {
            if !(navHistoryIndex >= 0 && navHistoryIndex < navHistory.count && {
                if case .watch(let existing, _) = navHistory[navHistoryIndex] { return existing.id == mv.id }
                return false
            }()) {
                recordRoute(.watch(mv, nil))
            }
        }
        rebuildSidebar()
        watchVC.attachPlayerView()
        setContent(watchVC)
    }

    @objc private func closeMiniplayer() {
        miniShadowHost.isHidden = true
        toastTrailingValue = -24
        miniVideo = nil
        watchVC.playerView.stopAndReleaseMemory()
    }

    // MARK: - Search & Autocomplete

    private func updateSearchClearVisible(_ visible: Bool) {
        searchClearBtn.isHidden = !visible
        NSLayoutConstraint.deactivate([searchTrailingToClear, searchTrailingToGo])
        if visible {
            searchTrailingToClear.isActive = true
        } else {
            searchTrailingToGo.isActive = true
        }
    }

    @objc func focusSearchBar() {
        window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    @objc private func clearSearchField() {
        suggestGeneration += 1
        suggestWork?.cancel()
        searchField.stringValue = ""
        updateSearchClearVisible(false)
        suggestions = []
        suggestBox.isHidden = true
        window?.makeFirstResponder(searchField)
    }

    @objc private func submitSearch() {
        let q = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        suggestGeneration += 1
        suggestWork?.cancel()
        suggestBox.isHidden = true
        window?.makeFirstResponder(nil)

        // Direct YouTube URL / Video ID detection!
        if let parsed = Formatters.parseYouTubeURL(q) {
            let v = VideoItem(id: parsed.videoId, title: "Loading...", channelName: "", channelId: "", channelAvatarURL: nil, thumbnailURL: "", durationText: "", viewsText: "", publishedText: "")
            openVideo(v, startSeconds: parsed.startSeconds)
            return
        }

        executeSearch(q)
    }

    private func executeSearch(_ q: String) {
        LocalStore.shared.recordSearch(q)
        activeSidebarRoute = .none
        recordRoute(.search(q))
        sidebarWidthValue = sidebarTargetWidth
        rebuildSidebar()
        setContent(searchVC)
        searchVC.performSearch(q)
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        isSearchFocused = true
        searchBox.layer?.borderColor = YTTheme.linkBlue.cgColor
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        isSearchFocused = false
        searchBox.layer?.borderColor = YTTheme.border.cgColor
    }

    func controlTextDidChange(_ obj: Notification) {
        let raw = searchField.stringValue
        updateSearchClearVisible(!raw.isEmpty)
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        suggestGeneration += 1
        let gen = suggestGeneration
        suggestWork?.cancel()
        if q.isEmpty || Formatters.parseYouTubeURL(q) != nil {
            suggestions = []
            suggestBox.isHidden = true
            return
        }
        let work = DispatchWorkItem { [weak self] in
            YouTubeAPI.shared.fetchAutocomplete(query: q) { items in
                guard let self = self, self.suggestGeneration == gen else { return }
                self.suggestions = items
                self.suggestTable.reloadData()
                self.suggestTable.deselectAll(nil)
                self.suggestHeightValue = CGFloat(min(items.count, 8)) * 32 + 8
                self.suggestBox.isHidden = items.isEmpty
            }
        }
        suggestWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveDown(_:)), !suggestBox.isHidden, !suggestions.isEmpty {
            let next = min(suggestions.count - 1, suggestTable.selectedRow + 1)
            suggestTable.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
            suggestTable.scrollRowToVisible(next)
            searchField.stringValue = suggestions[next]
            updateSearchClearVisible(true)
            return true
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)), !suggestBox.isHidden, !suggestions.isEmpty {
            let prev = suggestTable.selectedRow <= 0 ? 0 : suggestTable.selectedRow - 1
            suggestTable.selectRowIndexes(IndexSet(integer: prev), byExtendingSelection: false)
            suggestTable.scrollRowToVisible(prev)
            searchField.stringValue = suggestions[prev]
            updateSearchClearVisible(true)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if !suggestBox.isHidden && suggestTable.selectedRow >= 0 && suggestTable.selectedRow < suggestions.count {
                searchField.stringValue = suggestions[suggestTable.selectedRow]
            }
            submitSearch()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            suggestBox.isHidden = true
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { suggestions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSView()
        let icon = NSImageView()
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        icon.contentTintColor = YTTheme.textSecondary
        icon.translatesAutoresizingMaskIntoConstraints = false

        let lbl = makeLabel(suggestions[row], size: 14, color: YTTheme.textPrimary)
        cell.addSubview(icon)
        cell.addSubview(lbl)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            lbl.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            lbl.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -14),
            lbl.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    @objc private func suggestionClicked() {
        let r = suggestTable.clickedRow
        guard r >= 0 && r < suggestions.count else { return }
        searchField.stringValue = suggestions[r]
        submitSearch()
    }

    // MARK: - Live RAM Monitor & Memory Guard (< 100 MB Budget)

    private func startRAMMonitor() {
        updateRAMBadge()
        ramTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.updateRAMBadge()
        }
    }

    private func updateRAMBadge() {
        let fp = MemoryMonitor.currentFootprintMB()
        let budget = Double(LocalStore.shared.settings.maxRAMBudgetMB)
        ramPillBtn.title = String(format: "RAM: %.0f MB", fp)
        // Colour alone does not carry the warning, so the spoken value names the level too.
        let level: String
        if fp <= budget * 0.80 { level = "normal" } else if fp <= budget { level = "approaching budget" } else { level = "over budget" }
        ramPillBtn.setAccessibilityValue(String(format: "%.0f megabytes, %@, budget %.0f megabytes", fp, level, budget))
        if fp <= budget * 0.80 {
            ramPillBtn.normalBg = YTTheme.ramGreenBg
            ramPillBtn.normalFg = YTTheme.ramGreenFg
        } else if fp <= budget {
            ramPillBtn.normalBg = YTTheme.ramAmberBg
            ramPillBtn.normalFg = YTTheme.ramAmberFg
        } else {
            ramPillBtn.normalBg = YTTheme.ramRedBg
            ramPillBtn.normalFg = YTTheme.ramRedFg
            // Automatic soft memory trim when approaching/exceeding budget!
            ImageCache.shared.trimForPressure()
            watchVC.playerView.player.currentItem?.preferredForwardBufferDuration = 2.5
        }
        ramPillBtn.updateStyle()
    }

    @objc private func showRAMInspector() {
        let stats = MemoryMonitor.detailedStats()
        let menu = NSMenu()
        let lines = [
            String(format: "Physical Footprint: %.1f MB (budget: %d MB)", stats.footprintMB, LocalStore.shared.settings.maxRAMBudgetMB),
            String(format: "Resident Size: %.1f MB  |  Compressed: %.1f MB", stats.residentMB, stats.compressedMB),
            String(format: "Downsampled Image Cache: %.1f MB / 8.0 MB max", stats.imageCacheMB),
            "Active Local HLS Sessions: \(stats.hlsSessionsCount) (0 MB transcode)"
        ]
        for l in lines {
            let mi = NSMenuItem(title: l, action: nil, keyEquivalent: "")
            mi.isEnabled = false
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        let trim = NSMenuItem(title: "Trim Caches", action: #selector(trimMemoryNow), keyEquivalent: "")
        trim.target = self
        menu.addItem(trim)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: ramPillBtn)
    }

    @objc func trimMemoryNow() {
        ImageCache.shared.clearAll()
        URLCache.shared.removeAllCachedResponses()
        watchVC.playerView.player.currentItem?.preferredForwardBufferDuration = 3.0
        updateRAMBadge()
        showToastMessage("Trimmed image & URL caches")
    }

    @objc func showSettingsPopover() {
        let s = LocalStore.shared.settings
        let menu = NSMenu()

        let qHead = NSMenuItem(title: "Default Quality: \(s.preferredQuality)", action: nil, keyEquivalent: "")
        let qSub = NSMenu()
        for q in ["Auto", "1080p", "720p", "480p", "360p", "240p", "144p", "Audio Only"] {
            let mi = NSMenuItem(title: q, action: #selector(setDefaultQuality(_:)), keyEquivalent: "")
            mi.target = self; mi.representedObject = q
            mi.state = (s.preferredQuality == q) ? .on : .off
            qSub.addItem(mi)
        }
        qHead.submenu = qSub
        menu.addItem(qHead)

        let ap = NSMenuItem(title: "Autoplay Next Video", action: #selector(toggleAutoplaySetting), keyEquivalent: "")
        ap.target = self; ap.state = s.autoplayNext ? .on : .off
        menu.addItem(ap)

        let sb = NSMenuItem(title: "SponsorBlock Auto-Skip", action: #selector(toggleSBSetting), keyEquivalent: "")
        sb.target = self; sb.state = s.sponsorBlockAutoSkip ? .on : .off
        menu.addItem(sb)

        let cc = NSMenuItem(title: "Captions On By Default", action: #selector(toggleCCDefault), keyEquivalent: "")
        cc.target = self; cc.state = s.showCaptionsByDefault ? .on : .off
        menu.addItem(cc)

        menu.addItem(.separator())
        let openURL = NSMenuItem(title: "Open YouTube URL...", action: #selector(promptOpenURL), keyEquivalent: "o")
        openURL.target = self
        menu.addItem(openURL)

        let trim = NSMenuItem(title: "Trim Caches", action: #selector(trimMemoryNow), keyEquivalent: "")
        trim.target = self
        menu.addItem(trim)

        let prefs = NSMenuItem(title: "All Settings...", action: #selector(showSettingsWindow), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: settingsBtn)
    }

    @objc func showSettingsWindow() {
        if let win = settingsWindow {
            win.appearance = YTTheme.appearance
            win.makeKeyAndOrderFront(nil)
            return
        }
        let vc = SettingsViewController(onTrimMemory: { [weak self] in self?.trimMemoryNow() })
        let win = NSWindow(contentViewController: vc)
        win.title = "All Settings"
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        win.appearance = YTTheme.appearance
        // Size to the content so no control is clipped, including when text grows.
        vc.view.layoutSubtreeIfNeeded()
        win.setContentSize(NSSize(width: 440, height: max(390, vc.view.fittingSize.height)))
        if let mainFrame = window?.frame {
            win.setFrameOrigin(NSPoint(x: mainFrame.midX - win.frame.width / 2, y: mainFrame.midY - win.frame.height / 2))
        } else {
            win.center()
        }
        settingsWindow = win
        win.makeKeyAndOrderFront(nil)
    }

    @objc private func setDefaultQuality(_ sender: NSMenuItem) {
        guard let q = sender.representedObject as? String else { return }
        var s = LocalStore.shared.settings; s.preferredQuality = q; LocalStore.shared.settings = s
        showToastMessage("Default quality set to \(q)")
    }
    @objc private func toggleAutoplaySetting() {
        var s = LocalStore.shared.settings; s.autoplayNext.toggle(); LocalStore.shared.settings = s
    }
    @objc private func toggleSBSetting() {
        var s = LocalStore.shared.settings; s.sponsorBlockAutoSkip.toggle(); LocalStore.shared.settings = s
    }
    @objc private func toggleCCDefault() {
        var s = LocalStore.shared.settings; s.showCaptionsByDefault.toggle(); LocalStore.shared.settings = s
    }

    @objc func promptOpenURL() {
        let alert = NSAlert()
        alert.messageText = "Open YouTube Video"
        alert.informativeText = "Paste a YouTube video URL or 11-character video ID (timestamps like &t=1535s are preserved):"
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        tf.placeholderString = "https://www.youtube.com/watch?v=..."
        tf.setAccessibilityLabel("YouTube video URL or ID")
        if let clip = NSPasteboard.general.string(forType: .string), Formatters.parseYouTubeURL(clip) != nil {
            tf.stringValue = clip
        }
        alert.accessoryView = tf
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.layout()
        alert.window.initialFirstResponder = tf
        if let win = window {
            alert.beginSheetModal(for: win) { [weak self] resp in
                if resp == .alertFirstButtonReturn {
                    self?.openURLString(tf.stringValue)
                }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            openURLString(tf.stringValue)
        }
    }

    // MARK: - Keyboard Shortcuts

    private func installKeyboardMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self,
                  event.window === self.window,
                  self.window?.attachedSheet == nil else { return event }
            let fr = self.window?.firstResponder
            let isEditingText = ((fr as? NSTextView)?.isEditable == true) || ((fr as? NSTextField)?.isEditable == true)
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if mods == [.command] && !isEditingText {
                if event.charactersIgnoringModifiers == "[", self.canNavigateBack {
                    self.navigateBack()
                    return nil
                }
                if event.charactersIgnoringModifiers == "]", self.canNavigateForward {
                    self.navigateForward()
                    return nil
                }
            }
            // Do not hijack typing inside editable text fields
            // Reading text (selectable description/comments) keeps every key, so arrows scroll and letters don't seek or fullscreen
            if isEditingText || fr is NSTextView {
                return event
            }
            // Let focused controls/cards/activating tables keep Space and directional navigation
            if event.keyCode == 49 {
                let isInteractiveControl = (fr is NSButton) || (fr is NSSlider) || (fr is ClickableView) || (String(describing: type(of: fr)).contains("AccessibleThumbView")) || ((fr as? ActivatingTableView)?.activatesOnSpace == true)
                if isInteractiveControl {
                    return event
                }
            }
            if (event.keyCode == 125 || event.keyCode == 126), (fr is NSTableView || fr is NSSlider) {
                return event
            }
            if (event.keyCode == 123 || event.keyCode == 124), fr is NSSlider {
                return event
            }
            if event.charactersIgnoringModifiers == "/" {
                self.focusSearchBar()
                return nil
            }
            if self.activeVC === self.shortsVC {
                if self.shortsVC.handleKeyEvent(event) {
                    return nil
                }
            }
            if self.activeVC === self.watchVC {
                if self.watchVC.playerView.handleKeyEvent(event) {
                    return nil
                }
            } else if !self.miniShadowHost.isHidden {
                let keyChar = (event.charactersIgnoringModifiers ?? "").lowercased()
                if keyChar == "i" && mods.isEmpty {
                    self.expandMiniplayer()
                    return nil
                }
                if ["k", "j", "l", "m"].contains(keyChar) && mods.isEmpty {
                    if self.watchVC.playerView.handleKeyEvent(event) {
                        return nil
                    }
                }
            }
            return event
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self = self, event.window === self.window else { return event }
            if !self.suggestBox.isHidden {
                let ptInRoot = self.window?.contentView?.convert(event.locationInWindow, from: nil) ?? .zero
                if !self.suggestBox.frame.contains(ptInRoot) && !self.searchBox.frame.contains(ptInRoot) {
                    self.suggestBox.isHidden = true
                    if self.isSearchFocused || self.window?.firstResponder === self.searchField {
                        self.window?.makeFirstResponder(nil)
                    }
                }
            }
            return event
        }
    }

    // MARK: - Playback Menu Actions

    var canControlPlayback: Bool {
        activeVC === watchVC || activeVC === shortsVC || !miniShadowHost.isHidden
    }
    var isWatchPageActive: Bool { activeVC === watchVC }
    /// Theater mode only has a visible effect on the watch page when the layout is not stacked.
    var canToggleTheater: Bool { isWatchPageActive && watchVC.playerView.theaterSupported }
    var isMiniplayerActive: Bool { !miniShadowHost.isHidden }

    private var activePlayerView: PlayerView? {
        if activeVC === shortsVC { return shortsVC.playerView }
        if activeVC === watchVC || !miniShadowHost.isHidden { return watchVC.playerView }
        return nil
    }

    func togglePlaybackFromMenu() { activePlayerView?.togglePlayPause() }
    func mutePlaybackFromMenu() { activePlayerView?.toggleMute() }
    func toggleCaptionsFromMenu() { activePlayerView?.toggleCaptions() }
    func nextTrackFromMenu() {
        if activeVC === shortsVC { shortsVC.nextShort() }
        else { watchVC.playerDidRequestNext(watchVC.playerView) }
    }
    func prevTrackFromMenu() {
        if activeVC === shortsVC { shortsVC.prevShort() }
        else { watchVC.playerDidRequestPrevious(watchVC.playerView) }
    }
    func toggleMiniplayerFromMenu() {
        if !miniShadowHost.isHidden { expandMiniplayer() }
        else if activeVC === watchVC { watchVC.playerDidToggleMiniplayer(watchVC.playerView) }
    }
    func toggleTheaterFromMenu() {
        if activeVC === watchVC { watchVC.playerDidToggleTheater(watchVC.playerView) }
    }

    // MARK: - Theme & Toast

    @objc func toggleDarkMode() {
        var s = LocalStore.shared.settings
        s.darkMode.toggle()
        LocalStore.shared.settings = s
    }

    @objc private func onThemeChanged() { applyTheme() }
    @objc private func onStoreChanged() { rebuildSidebar() }

    private func applyTheme() {
        NSApp.appearance = YTTheme.appearance
        window?.appearance = YTTheme.appearance
        settingsWindow?.appearance = YTTheme.appearance
        window?.contentView?.layer?.backgroundColor = YTTheme.bg.cgColor
        masthead.layer?.backgroundColor = YTTheme.bg.cgColor
        mastheadDivider.layer?.backgroundColor = YTTheme.divider.cgColor
        menuBtn.contentTintColor = YTTheme.textPrimary
        menuBtn.hoverBgColor = YTTheme.surface
        backBtn.contentTintColor = YTTheme.textPrimary
        backBtn.hoverBgColor = YTTheme.surface
        forwardBtn.contentTintColor = YTTheme.textPrimary
        forwardBtn.hoverBgColor = YTTheme.surface
        logoText.textColor = YTTheme.textPrimary
        searchBox.layer?.backgroundColor = YTTheme.searchBg.cgColor
        searchBox.layer?.borderColor = (isSearchFocused ? YTTheme.linkBlue : YTTheme.border).cgColor
        searchField.textColor = YTTheme.textPrimary
        searchClearBtn.contentTintColor = YTTheme.textSecondary
        searchGoBtn.contentTintColor = YTTheme.textPrimary
        searchGoBtn.hoverBgColor = YTTheme.surface
        let themeCfg = NSImage.SymbolConfiguration(pointSize: IconScale.chrome, weight: .medium)
        // The label names the mode the button switches to, so VoiceOver says what pressing it does.
        let themeLabel = YTTheme.isDark ? "Switch to light mode" : "Switch to dark mode"
        themeBtn.image = NSImage(systemSymbolName: YTTheme.isDark ? "sun.max.fill" : "moon.fill", accessibilityDescription: themeLabel)?.withSymbolConfiguration(themeCfg)
        themeBtn.setAccessibilityLabel(themeLabel)
        themeBtn.contentTintColor = YTTheme.textPrimary
        themeBtn.hoverBgColor = YTTheme.surface
        settingsBtn.contentTintColor = YTTheme.textPrimary
        settingsBtn.hoverBgColor = YTTheme.surface
        suggestBox.layer?.backgroundColor = YTTheme.bgElevated.cgColor
        suggestBox.layer?.borderColor = YTTheme.border.cgColor
        suggestTable.reloadData()
        miniContainer.layer?.backgroundColor = YTTheme.bgElevated.cgColor
        miniContainer.layer?.borderColor = YTTheme.border.cgColor
        miniDivider.layer?.backgroundColor = YTTheme.divider.cgColor
        miniTitleLabel.textColor = YTTheme.textPrimary
        miniChannelLabel.textColor = YTTheme.textSecondary
        miniPlayPauseBtn.contentTintColor = YTTheme.textPrimary
        miniPlayPauseBtn.hoverBgColor = YTTheme.surface
        miniExpandBtn.contentTintColor = YTTheme.textPrimary
        miniExpandBtn.hoverBgColor = YTTheme.surface
        miniCloseBtn.contentTintColor = YTTheme.textPrimary
        miniCloseBtn.hoverBgColor = YTTheme.surface
        updateRAMBadge()
        rebuildSidebar()
    }

    func showToastMessage(_ message: String) {
        let token = UUID()
        toastToken = token
        toastText.stringValue = message
        toastBanner.isHidden = false
        toastBanner.alphaValue = 1
        postAccessibilityAnnouncement(message)
        toastWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = motionDuration(0.25)
                self?.toastBanner.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self = self, self.toastToken == token, self.toastBanner.alphaValue <= 0.01 else { return }
                self.toastBanner.isHidden = true
            })
        }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: w)
    }
}

private final class SettingsViewController: NSViewController {
    private let onTrimMemory: () -> Void
    private let qualityPopup = NSPopUpButton()
    private let speedPopup = NSPopUpButton()
    private let volumeSlider = NSSlider(value: 1.0, minValue: 0.0, maxValue: 1.0, target: nil, action: nil)
    private let volumeValueLabel = makeLabel("100%", size: 12, color: YTTheme.textSecondary)
    private let ramPopup = NSPopUpButton()
    private let autoplayCheck = NSButton(checkboxWithTitle: "Autoplay next video", target: nil, action: nil)
    private let sbEnabledCheck = NSButton(checkboxWithTitle: "Enable SponsorBlock segments", target: nil, action: nil)
    private let sbAutoSkipCheck = NSButton(checkboxWithTitle: "Auto-skip SponsorBlock segments", target: nil, action: nil)
    private let ccCheck = NSButton(checkboxWithTitle: "Show captions by default", target: nil, action: nil)
    private let pauseHistoryCheck = NSButton(checkboxWithTitle: "Pause watch & search history", target: nil, action: nil)

    private let qualities = ["Auto", "1080p", "720p", "480p", "360p", "240p", "144p", "Audio Only"]
    private var speeds: [Float] { PlayerView.playbackSpeeds }
    private let ramBudgets = [100, 150, 200, 300, 500]
    private var rowLabels: [NSTextField] = []

    init(onTrimMemory: @escaping () -> Void) {
        self.onTrimMemory = onTrimMemory
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        qualityPopup.addItems(withTitles: qualities)
        speedPopup.addItems(withTitles: speeds.map { String(format: "%g×", $0) })
        ramPopup.addItems(withTitles: ramBudgets.map { "\($0) MB" })
        // One width for the popups, so their right edges line up in the settings column.
        for popup in [qualityPopup, speedPopup, ramPopup] {
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.widthAnchor.constraint(equalToConstant: 120).isActive = true
        }

        qualityPopup.target = self; qualityPopup.action = #selector(saveSettings)
        speedPopup.target = self; speedPopup.action = #selector(saveSettings)
        // Save on mouse-up, not on every tick, so the store and sidebar aren't rebuilt while dragging.
        volumeSlider.isContinuous = true
        volumeSlider.target = self; volumeSlider.action = #selector(volumeSliderMoved)
        ramPopup.target = self; ramPopup.action = #selector(saveSettings)
        autoplayCheck.target = self; autoplayCheck.action = #selector(saveSettings)
        sbEnabledCheck.target = self; sbEnabledCheck.action = #selector(saveSettings)
        sbAutoSkipCheck.target = self; sbAutoSkipCheck.action = #selector(saveSettings)
        ccCheck.target = self; ccCheck.action = #selector(saveSettings)
        pauseHistoryCheck.target = self; pauseHistoryCheck.action = #selector(saveSettings)

        func row(_ title: String, _ control: NSView, accessibleControl: NSView? = nil) -> NSStackView {
            let lbl = makeLabel(title, size: 12, weight: .medium, color: YTTheme.textSecondary)
            lbl.alignment = .right
            lbl.widthAnchor.constraint(equalToConstant: 145).isActive = true
            rowLabels.append(lbl)
            let a11yTarget = accessibleControl ?? control
            a11yTarget.setAccessibilityLabel(title.trimmingCharacters(in: CharacterSet(charactersIn: ":")))
            a11yTarget.setAccessibilityTitleUIElement(lbl)
            let r = NSStackView(views: [lbl, control])
            r.orientation = .horizontal
            r.alignment = .centerY
            r.spacing = 10
            return r
        }

        volumeSlider.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let volWrap = NSStackView(views: [volumeSlider, volumeValueLabel])
        volWrap.orientation = .horizontal
        volWrap.alignment = .centerY
        volWrap.spacing = 8

        let trimBtn = PillButton()
        trimBtn.title = "Trim Caches"
        trimBtn.target = self
        trimBtn.action = #selector(trimClicked(_:))

        // Grouped under headings so related controls read as one section.
        func heading(_ title: String) -> NSTextField {
            let h = sectionHeadingLabel(title)
            h.setAccessibilityRole(.staticText)
            return h
        }
        stack.addArrangedSubview(heading("Playback"))
        // Extra space before each later section so the groups read as units.
        stack.addArrangedSubview(row("Preferred Quality:", qualityPopup))
        stack.addArrangedSubview(row("Default Speed:", speedPopup))
        stack.addArrangedSubview(row("Default Volume:", volWrap, accessibleControl: volumeSlider))
        // Checkboxes and the trim button share the controls column, so every control lines up with the popups and sliders.
        func controlColumn(_ v: NSView) -> NSStackView {
            let r = NSStackView(views: [NSView(), v])
            r.orientation = .horizontal
            r.spacing = 10
            r.setHuggingPriority(.defaultLow, for: .horizontal)
            r.arrangedSubviews.first?.widthAnchor.constraint(equalToConstant: 145).isActive = true
            return r
        }
        stack.addArrangedSubview(controlColumn(autoplayCheck))
        stack.setCustomSpacing(22, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(heading("SponsorBlock"))
        stack.addArrangedSubview(controlColumn(sbEnabledCheck))
        // Indented under its parent toggle, which it depends on: same column, one step further in.
        let autoSkipRow = controlColumn(sbAutoSkipCheck)
        autoSkipRow.arrangedSubviews.first?.widthAnchor.constraint(equalToConstant: 165).isActive = true
        stack.addArrangedSubview(autoSkipRow)
        stack.setCustomSpacing(22, after: autoSkipRow)
        stack.addArrangedSubview(heading("Privacy & Storage"))
        stack.addArrangedSubview(row("Memory Budget:", ramPopup))
        stack.addArrangedSubview(controlColumn(ccCheck))
        stack.addArrangedSubview(controlColumn(pauseHistoryCheck))
        stack.addArrangedSubview(controlColumn(trimBtn))
        let trimHelp = makeLabel("Clears cached thumbnails and network responses. Playback is not affected.", size: 12, color: YTTheme.textSecondary, maxLines: 2)
        stack.addArrangedSubview(controlColumn(trimHelp))

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20)
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(syncFromStore), name: .liteTubeStoreDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(syncFromStore), name: .liteTubeThemeDidChange, object: nil)
        syncFromStore()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func syncFromStore() {
        view.layer?.backgroundColor = YTTheme.bg.cgColor
        for lbl in rowLabels { lbl.textColor = YTTheme.textSecondary }
        volumeValueLabel.textColor = YTTheme.textSecondary
        let s = LocalStore.shared.settings
        if let qi = qualities.firstIndex(of: s.preferredQuality) { qualityPopup.selectItem(at: qi) }
        if let si = speeds.enumerated().min(by: { abs($0.element - s.defaultSpeed) < abs($1.element - s.defaultSpeed) })?.offset {
            speedPopup.selectItem(at: si)
        }
        volumeSlider.doubleValue = Double(s.defaultVolume)
        volumeValueLabel.stringValue = "\(Int(round(s.defaultVolume * 100)))%"
        // VoiceOver reads the percentage, not the raw 0–1 slider value.
        volumeSlider.setAccessibilityValue("\(Int(round(s.defaultVolume * 100))) percent")
        if let ri = ramBudgets.enumerated().min(by: { abs($0.element - s.maxRAMBudgetMB) < abs($1.element - s.maxRAMBudgetMB) })?.offset {
            ramPopup.selectItem(at: ri)
        }
        autoplayCheck.state = s.autoplayNext ? .on : .off
        sbEnabledCheck.state = s.sponsorBlockEnabled ? .on : .off
        sbAutoSkipCheck.state = s.sponsorBlockAutoSkip ? .on : .off
        sbAutoSkipCheck.isEnabled = s.sponsorBlockEnabled
        ccCheck.state = s.showCaptionsByDefault ? .on : .off
        pauseHistoryCheck.state = s.pauseHistory ? .on : .off
    }

    /// Keeps the percentage label in step with the slider while it is dragged; the setting is saved by saveSettings.
    @objc private func volumeSliderMoved() {
        let percent = Int(round(volumeSlider.doubleValue * 100))
        volumeValueLabel.stringValue = "\(percent)%"
        // Keep VoiceOver's value in step with the drag, not only with the value at load.
        volumeSlider.setAccessibilityValue("\(percent) percent")
        saveSettings()
    }

    @objc private func saveSettings() {
        var s = LocalStore.shared.settings
        let qi = qualityPopup.indexOfSelectedItem
        if qi >= 0 && qi < qualities.count { s.preferredQuality = qualities[qi] }
        let si = speedPopup.indexOfSelectedItem
        if si >= 0 && si < speeds.count { s.defaultSpeed = speeds[si] }
        s.defaultVolume = Float(volumeSlider.doubleValue)
        let ri = ramPopup.indexOfSelectedItem
        if ri >= 0 && ri < ramBudgets.count { s.maxRAMBudgetMB = ramBudgets[ri] }
        s.autoplayNext = (autoplayCheck.state == .on)
        s.sponsorBlockEnabled = (sbEnabledCheck.state == .on)
        s.sponsorBlockAutoSkip = (sbAutoSkipCheck.state == .on)
        s.showCaptionsByDefault = (ccCheck.state == .on)
        s.pauseHistory = (pauseHistoryCheck.state == .on)
        LocalStore.shared.settings = s
    }

    private var trimRevertWork: DispatchWorkItem?

    @objc private func trimClicked(_ sender: PillButton) {
        onTrimMemory()
        // The result toast appears on the main window, which can be behind this one, so confirm here too.
        sender.title = "Trimmed image & URL caches"
        // Announced here as well, since the main window's announcement may not be the window the user is in.
        postAccessibilityAnnouncement("Trimmed image and URL caches")
        // Cancel any earlier revert, so the confirmation always lasts two seconds after the latest click.
        trimRevertWork?.cancel()
        let revert = DispatchWorkItem { sender.title = "Trim Caches" }
        trimRevertWork = revert
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: revert)
    }
}

/// Main window that keeps its size when AppKit tries to fit it to the content.
///
/// The window's content uses Auto Layout with no fixed size, so AppKit resizes the window to the
/// content's constraint-derived size when the window is shown and after layout passes. That size
/// is much smaller than the window (for example 540×142), and it snaps the window back after the user
/// or code sets a larger frame. This override ignores those size-only changes. User live-resizes and
/// explicit resizes that set `allowsProgrammaticResize` still go through.
final class LiteTubeWindow: NSWindow {
    static var allowsProgrammaticResize = false

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        if Self.allowsProgrammaticResize || inLiveResize || frameRect.size == frame.size {
            super.setFrame(frameRect, display: flag)
            return
        }
        var kept = frameRect
        kept.size = frame.size
        super.setFrame(kept, display: flag)
    }

    override func setContentSize(_ size: NSSize) {
        if Self.allowsProgrammaticResize || inLiveResize {
            super.setContentSize(size)
            return
        }
        super.setContentSize(contentRect(forFrameRect: frame).size)
    }
}


/// Root content view that always matches its window's content size.
///
/// AppKit can set a content view's frame directly during Auto Layout passes, bypassing the window's
/// own frame changes. This keeps the content view at the window's content size.
final class WindowContentView: NSView {
    weak var hostWindow: NSWindow?

    override func setFrameSize(_ newSize: NSSize) {
        guard let w = hostWindow else {
            super.setFrameSize(newSize)
            return
        }
        let target = w.contentRect(forFrameRect: w.frame).size
        if frame.size != target {
            super.setFrameSize(target)
            // Constraints depend on this view's size, so they must be solved again for the new size.
            needsUpdateConstraints = true
            needsLayout = true
        }
    }

    /// Places the app's regions once this view has its final size.
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        // Re-apply the window's content size after each layout pass, since AppKit can resize this view directly.
        guard let w = hostWindow else { return }
        let target = w.contentRect(forFrameRect: w.frame).size
        if frame.size != target {
            setFrameSize(target)
        }
        onLayout?()
    }
}

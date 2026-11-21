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
    private let menuBtn = makeSymbolButton("line.3.horizontal", size: 17, tooltip: "Toggle sidebar")
    private let logoContainer = ClickableView()
    private let logoBadge = YouTubeLogoView()
    private let logoText = makeLabel("LiteTube", size: 17, weight: .bold)
    private let searchBox = NSView()
    private let searchField = NSTextField()
    private let searchGoBtn = makeSymbolButton("magnifyingglass", size: 15, tooltip: "Search")
    private let ramPillBtn = PillButton()
    private let themeBtn = makeSymbolButton("moon.fill", size: 15, tooltip: "Toggle Dark / Light Mode")
    private let settingsBtn = makeSymbolButton("slider.horizontal.3", size: 15, tooltip: "Settings & Memory Controls")

    // Autocomplete Dropdown
    private let suggestBox = NSView()
    private let suggestTable = NSTableView()
    private var suggestions: [String] = []
    private var suggestWork: DispatchWorkItem?

    // Sidebar + Main Content
    private let sidebarScroll = NSScrollView()
    private let sidebarStack = NSStackView()
    private var sidebarWidthConstraint: NSLayoutConstraint!
    private var isSidebarCollapsed = false
    private let contentHost = NSView()

    // Child View Controllers
    private let homeVC = HomeViewController()
    private let searchVC = SearchViewController()
    private let watchVC = WatchViewController()
    private let channelVC = ChannelViewController()
    private let shortsVC = ShortsViewController()
    private var activeVC: NSViewController?

    // Floating Miniplayer
    private let miniContainer = NSView()
    private let miniVideoSlot = NSView()
    private let miniTitleLabel = makeLabel("", size: 12, weight: .semibold, maxLines: 1)
    private let miniChannelLabel = makeLabel("", size: 11, color: YTTheme.textSecondary, maxLines: 1)
    private let miniExpandBtn = makeSymbolButton("arrow.up.left.and.arrow.down.right", size: 13, tooltip: "Expand player")
    private let miniCloseBtn = makeSymbolButton("xmark", size: 13, tooltip: "Close miniplayer")
    private var miniVideo: VideoItem?

    // Toast notification
    private let toastBanner = NSView()
    private let toastText = makeLabel("", size: 13, weight: .medium, color: .white)
    private var toastWork: DispatchWorkItem?

    // RAM Monitor Timer
    private var ramTimer: Timer?
    private var keyMonitor: Any?

    convenience init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1380, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
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
        NotificationCenter.default.addObserver(self, selector: #selector(onThemeChanged), name: .liteTubeThemeDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onStoreChanged), name: .liteTubeStoreDidChange, object: nil)
    }

    deinit {
        ramTimer?.invalidate()
        if let km = keyMonitor { NSEvent.removeMonitor(km) }
        NotificationCenter.default.removeObserver(self)
    }

    private func setupRootUI() {
        guard let root = window?.contentView else { return }
        root.wantsLayer = true

        homeVC.navDelegate = self
        searchVC.navDelegate = self
        watchVC.navDelegate = self
        channelVC.navDelegate = self
        channelVC.onOpenPlaylist = { [weak self] id, name in self?.openPlaylist(id: id, name: name) }
        shortsVC.navDelegate = self

        // Masthead
        masthead.wantsLayer = true
        masthead.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(masthead)

        mastheadDivider.wantsLayer = true
        mastheadDivider.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(mastheadDivider)

        menuBtn.target = self; menuBtn.action = #selector(toggleSidebar)
        masthead.addSubview(menuBtn)

        logoContainer.translatesAutoresizingMaskIntoConstraints = false
        logoContainer.onClick = { [weak self] in self?.showHome() }
        masthead.addSubview(logoContainer)
        logoBadge.translatesAutoresizingMaskIntoConstraints = false
        logoContainer.addSubview(logoBadge)
        logoContainer.addSubview(logoText)

        // Centered YouTube Search Pill
        searchBox.wantsLayer = true
        searchBox.layer?.cornerRadius = 19
        searchBox.layer?.borderWidth = 1
        searchBox.translatesAutoresizingMaskIntoConstraints = false
        masthead.addSubview(searchBox)

        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 14)
        searchField.placeholderString = "Search YouTube or paste a YouTube URL..."
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchBox.addSubview(searchField)

        searchGoBtn.target = self; searchGoBtn.action = #selector(submitSearch)
        searchBox.addSubview(searchGoBtn)

        // Right masthead controls: RAM Pill, Theme Toggle, Settings
        ramPillBtn.title = "RAM: -- MB"
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
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.drawsBackground = false
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebarScroll)

        let sidebarDoc = FlippedView()
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
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentHost)

        // Floating Miniplayer
        miniContainer.wantsLayer = true
        miniContainer.layer?.cornerRadius = 12
        miniContainer.layer?.masksToBounds = true
        miniContainer.layer?.borderWidth = 1
        miniContainer.isHidden = true
        miniContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(miniContainer)

        miniVideoSlot.wantsLayer = true
        miniVideoSlot.layer?.backgroundColor = NSColor.black.cgColor
        miniVideoSlot.translatesAutoresizingMaskIntoConstraints = false
        miniContainer.addSubview(miniVideoSlot)

        let miniFooter = NSView()
        miniFooter.translatesAutoresizingMaskIntoConstraints = false
        miniContainer.addSubview(miniFooter)
        miniExpandBtn.target = self; miniExpandBtn.action = #selector(expandMiniplayer)
        miniCloseBtn.target = self; miniCloseBtn.action = #selector(closeMiniplayer)
        miniFooter.addSubview(miniTitleLabel)
        miniFooter.addSubview(miniChannelLabel)
        miniFooter.addSubview(miniExpandBtn)
        miniFooter.addSubview(miniCloseBtn)

        // Autocomplete Dropdown (floats above content)
        suggestBox.wantsLayer = true
        suggestBox.layer?.cornerRadius = 12
        suggestBox.layer?.borderWidth = 1
        suggestBox.isHidden = true
        suggestBox.translatesAutoresizingMaskIntoConstraints = false
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
        toastBanner.layer?.backgroundColor = NSColor(hex: 0x222222, alpha: 0.94).cgColor
        toastBanner.layer?.cornerRadius = 8
        toastBanner.isHidden = true
        toastBanner.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toastBanner)
        toastBanner.addSubview(toastText)

        sidebarWidthConstraint = sidebarScroll.widthAnchor.constraint(equalToConstant: 224)

        NSLayoutConstraint.activate([
            // Masthead (leave 78px on left for macOS traffic light buttons!)
            masthead.topAnchor.constraint(equalTo: root.topAnchor),
            masthead.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            masthead.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            masthead.heightAnchor.constraint(equalToConstant: 56),

            mastheadDivider.topAnchor.constraint(equalTo: masthead.bottomAnchor),
            mastheadDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            mastheadDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            mastheadDivider.heightAnchor.constraint(equalToConstant: 1),

            menuBtn.leadingAnchor.constraint(equalTo: masthead.leadingAnchor, constant: 82),
            menuBtn.centerYAnchor.constraint(equalTo: masthead.centerYAnchor),
            menuBtn.widthAnchor.constraint(equalToConstant: 32),
            menuBtn.heightAnchor.constraint(equalToConstant: 32),

            logoContainer.leadingAnchor.constraint(equalTo: menuBtn.trailingAnchor, constant: 10),
            logoContainer.centerYAnchor.constraint(equalTo: masthead.centerYAnchor),
            logoContainer.heightAnchor.constraint(equalToConstant: 32),
            logoBadge.leadingAnchor.constraint(equalTo: logoContainer.leadingAnchor),
            logoBadge.centerYAnchor.constraint(equalTo: logoContainer.centerYAnchor),
            logoBadge.widthAnchor.constraint(equalToConstant: 30),
            logoBadge.heightAnchor.constraint(equalToConstant: 24),
            logoText.leadingAnchor.constraint(equalTo: logoBadge.trailingAnchor, constant: 6),
            logoText.trailingAnchor.constraint(equalTo: logoContainer.trailingAnchor),
            logoText.centerYAnchor.constraint(equalTo: logoContainer.centerYAnchor),

            searchBox.centerXAnchor.constraint(equalTo: masthead.centerXAnchor),
            searchBox.centerYAnchor.constraint(equalTo: masthead.centerYAnchor),
            searchBox.widthAnchor.constraint(lessThanOrEqualToConstant: 540),
            searchBox.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            searchBox.leadingAnchor.constraint(greaterThanOrEqualTo: logoContainer.trailingAnchor, constant: 20),
            searchBox.trailingAnchor.constraint(lessThanOrEqualTo: rightCluster.leadingAnchor, constant: -20),
            searchBox.heightAnchor.constraint(equalToConstant: 38),

            searchField.leadingAnchor.constraint(equalTo: searchBox.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: searchGoBtn.leadingAnchor, constant: -8),
            searchField.centerYAnchor.constraint(equalTo: searchBox.centerYAnchor),

            searchGoBtn.trailingAnchor.constraint(equalTo: searchBox.trailingAnchor, constant: -10),
            searchGoBtn.centerYAnchor.constraint(equalTo: searchBox.centerYAnchor),
            searchGoBtn.widthAnchor.constraint(equalToConstant: 30),
            searchGoBtn.heightAnchor.constraint(equalToConstant: 30),

            rightCluster.trailingAnchor.constraint(equalTo: masthead.trailingAnchor, constant: -16),
            rightCluster.centerYAnchor.constraint(equalTo: masthead.centerYAnchor),

            // Sidebar & Content
            sidebarScroll.topAnchor.constraint(equalTo: mastheadDivider.bottomAnchor),
            sidebarScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebarScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarWidthConstraint,

            sidebarDoc.topAnchor.constraint(equalTo: sidebarScroll.contentView.topAnchor),
            sidebarDoc.leadingAnchor.constraint(equalTo: sidebarScroll.contentView.leadingAnchor),
            sidebarDoc.widthAnchor.constraint(equalTo: sidebarScroll.contentView.widthAnchor),
            sidebarStack.topAnchor.constraint(equalTo: sidebarDoc.topAnchor),
            sidebarStack.leadingAnchor.constraint(equalTo: sidebarDoc.leadingAnchor),
            sidebarStack.trailingAnchor.constraint(equalTo: sidebarDoc.trailingAnchor),
            sidebarStack.bottomAnchor.constraint(equalTo: sidebarDoc.bottomAnchor),

            contentHost.topAnchor.constraint(equalTo: mastheadDivider.bottomAnchor),
            contentHost.leadingAnchor.constraint(equalTo: sidebarScroll.trailingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            // Autocomplete box
            suggestBox.topAnchor.constraint(equalTo: searchBox.bottomAnchor, constant: 4),
            suggestBox.leadingAnchor.constraint(equalTo: searchBox.leadingAnchor),
            suggestBox.trailingAnchor.constraint(equalTo: searchBox.trailingAnchor),
            suggestBox.heightAnchor.constraint(equalToConstant: 264),
            sScroll.topAnchor.constraint(equalTo: suggestBox.topAnchor, constant: 4),
            sScroll.bottomAnchor.constraint(equalTo: suggestBox.bottomAnchor, constant: -4),
            sScroll.leadingAnchor.constraint(equalTo: suggestBox.leadingAnchor),
            sScroll.trailingAnchor.constraint(equalTo: suggestBox.trailingAnchor),

            // Floating Miniplayer
            miniContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            miniContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            miniContainer.widthAnchor.constraint(equalToConstant: 360),
            miniContainer.heightAnchor.constraint(equalToConstant: 252),

            miniVideoSlot.topAnchor.constraint(equalTo: miniContainer.topAnchor),
            miniVideoSlot.leadingAnchor.constraint(equalTo: miniContainer.leadingAnchor),
            miniVideoSlot.trailingAnchor.constraint(equalTo: miniContainer.trailingAnchor),
            miniVideoSlot.heightAnchor.constraint(equalToConstant: 202),

            miniFooter.topAnchor.constraint(equalTo: miniVideoSlot.bottomAnchor),
            miniFooter.leadingAnchor.constraint(equalTo: miniContainer.leadingAnchor),
            miniFooter.trailingAnchor.constraint(equalTo: miniContainer.trailingAnchor),
            miniFooter.bottomAnchor.constraint(equalTo: miniContainer.bottomAnchor),

            miniTitleLabel.topAnchor.constraint(equalTo: miniFooter.topAnchor, constant: 8),
            miniTitleLabel.leadingAnchor.constraint(equalTo: miniFooter.leadingAnchor, constant: 10),
            miniTitleLabel.trailingAnchor.constraint(equalTo: miniExpandBtn.leadingAnchor, constant: -8),
            miniChannelLabel.topAnchor.constraint(equalTo: miniTitleLabel.bottomAnchor, constant: 2),
            miniChannelLabel.leadingAnchor.constraint(equalTo: miniTitleLabel.leadingAnchor),
            miniChannelLabel.trailingAnchor.constraint(equalTo: miniTitleLabel.trailingAnchor),

            miniCloseBtn.trailingAnchor.constraint(equalTo: miniFooter.trailingAnchor, constant: -10),
            miniCloseBtn.centerYAnchor.constraint(equalTo: miniFooter.centerYAnchor),
            miniExpandBtn.trailingAnchor.constraint(equalTo: miniCloseBtn.leadingAnchor, constant: -10),
            miniExpandBtn.centerYAnchor.constraint(equalTo: miniFooter.centerYAnchor),

            // Toast
            toastBanner.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            toastBanner.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
            toastText.topAnchor.constraint(equalTo: toastBanner.topAnchor, constant: 9),
            toastText.bottomAnchor.constraint(equalTo: toastBanner.bottomAnchor, constant: -9),
            toastText.leadingAnchor.constraint(equalTo: toastBanner.leadingAnchor, constant: 14),
            toastText.trailingAnchor.constraint(equalTo: toastBanner.trailingAnchor, constant: -14)
        ])

        rebuildSidebar()
    }

    // MARK: - Sidebar Navigation

    private func rebuildSidebar() {
        sidebarStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        addSidebarItem(icon: "house.fill", title: "Home") { [weak self] in self?.showHome() }
        addSidebarItem(icon: "bolt.fill", title: "Shorts") { [weak self] in self?.showShorts() }
        addSidebarItem(icon: "rectangle.stack.person.crop", title: "Subscriptions") { [weak self] in self?.showFeed(.subscriptions) }

        addSidebarDivider()
        if !isSidebarCollapsed { addSidebarSectionHeader("You") }
        addSidebarItem(icon: "clock.arrow.circlepath", title: "History") { [weak self] in self?.showFeed(.history) }
        addSidebarItem(icon: "clock", title: "Watch Later") { [weak self] in self?.showFeed(.watchLater) }
        addSidebarItem(icon: "hand.thumbsup", title: "Liked Videos") { [weak self] in self?.showFeed(.liked) }
        addSidebarItem(icon: "list.bullet", title: "Queue") { [weak self] in self?.showFeed(.queue) }

        if !isSidebarCollapsed {
            for pl in LocalStore.shared.playlists {
                addSidebarItem(icon: "music.note.list", title: pl.name) { [weak self] in
                    self?.showFeed(.playlist(id: pl.id, name: pl.name))
                }
            }
        }

        addSidebarDivider()
        if !isSidebarCollapsed { addSidebarSectionHeader("Explore") }
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
            addSidebarItem(icon: ic, title: name) { [weak self] in self?.showFeed(.explore(name)) }
        }

        if !isSidebarCollapsed && !LocalStore.shared.subscriptions.isEmpty {
            addSidebarDivider()
            addSidebarSectionHeader("Subscribed Channels")
            for sub in LocalStore.shared.subscriptions.prefix(15) {
                addSidebarItem(icon: "person.crop.circle", title: sub.name) { [weak self] in
                    self?.openChannel(channelId: sub.id, name: sub.name)
                }
            }
        }
    }

    private func addSidebarItem(icon: String, title: String, action: @escaping () -> Void) {
        let row = ClickableView()
        row.layer?.cornerRadius = 8
        row.hoverBgColor = YTTheme.surface
        row.normalBgColor = .clear
        row.onClick = action
        row.translatesAutoresizingMaskIntoConstraints = false

        let iv = NSImageView()
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        iv.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)?.withSymbolConfiguration(cfg)
        iv.contentTintColor = YTTheme.textPrimary
        iv.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(iv)

        if !isSidebarCollapsed {
            let lbl = makeLabel(title, size: 13, weight: .medium, color: YTTheme.textPrimary)
            row.addSubview(lbl)
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
                iv.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 20),
                lbl.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 14),
                lbl.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
                lbl.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                row.heightAnchor.constraint(equalToConstant: 36),
                row.widthAnchor.constraint(equalToConstant: 204)
            ])
        } else {
            row.toolTip = title
            NSLayoutConstraint.activate([
                iv.centerXAnchor.constraint(equalTo: row.centerXAnchor),
                iv.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                row.heightAnchor.constraint(equalToConstant: 40),
                row.widthAnchor.constraint(equalToConstant: 52)
            ])
        }
        sidebarStack.addArrangedSubview(row)
    }

    private func addSidebarSectionHeader(_ title: String) {
        let lbl = makeLabel(title, size: 12, weight: .bold, color: YTTheme.textSecondary)
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(lbl)
        NSLayoutConstraint.activate([
            lbl.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            lbl.topAnchor.constraint(equalTo: box.topAnchor, constant: 6),
            lbl.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -4),
            box.widthAnchor.constraint(equalToConstant: 204)
        ])
        sidebarStack.addArrangedSubview(box)
    }

    private func addSidebarDivider() {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = YTTheme.divider.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            line.heightAnchor.constraint(equalToConstant: 1),
            line.widthAnchor.constraint(equalToConstant: isSidebarCollapsed ? 48 : 196)
        ])
        sidebarStack.addArrangedSubview(line)
    }

    @objc private func toggleSidebar() {
        isSidebarCollapsed.toggle()
        sidebarWidthConstraint.constant = isSidebarCollapsed ? 72 : 224
        rebuildSidebar()
    }

    // MARK: - Content Router

    private func setContent(_ vc: NSViewController) {
        if activeVC === shortsVC && vc !== shortsVC {
            shortsVC.deactivate()
        }
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
        sidebarWidthConstraint.constant = isSidebarCollapsed ? 72 : 224
        setContent(homeVC)
        homeVC.load(mode: .home)
    }

    func showFeed(_ mode: FeedMode) {
        sidebarWidthConstraint.constant = isSidebarCollapsed ? 72 : 224
        setContent(homeVC)
        homeVC.load(mode: mode)
    }

    func showShorts() {
        sidebarWidthConstraint.constant = 72
        setContent(shortsVC)
        shortsVC.activate()
    }

    func openVideo(_ video: VideoItem, startSeconds: Double?) {
        miniContainer.isHidden = true
        miniVideo = nil
        // Auto-collapse sidebar on Watch page just like YouTube!
        sidebarWidthConstraint.constant = 0
        setContent(watchVC)
        watchVC.loadVideo(video, startSeconds: startSeconds)
    }

    func openURLString(_ raw: String) {
        if let parsed = Formatters.parseYouTubeURL(raw) {
            let v = VideoItem(id: parsed.videoId, title: "Loading...", channelName: "", channelId: "", channelAvatarURL: nil, thumbnailURL: "", durationText: "", viewsText: "", publishedText: "")
            openVideo(v, startSeconds: parsed.startSeconds)
        } else {
            searchField.stringValue = raw
            submitSearch()
        }
    }

    func openChannel(channelId: String, name: String) {
        sidebarWidthConstraint.constant = isSidebarCollapsed ? 72 : 224
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
        miniContainer.isHidden = false
        showHome()
    }

    @objc private func expandMiniplayer() {
        miniContainer.isHidden = true
        sidebarWidthConstraint.constant = 0
        watchVC.attachPlayerView()
        setContent(watchVC)
    }

    @objc private func closeMiniplayer() {
        miniContainer.isHidden = true
        miniVideo = nil
        watchVC.playerView.stopAndReleaseMemory()
    }

    // MARK: - Search & Autocomplete

    @objc func focusSearchBar() {
        window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    @objc private func submitSearch() {
        let q = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        suggestBox.isHidden = true
        window?.makeFirstResponder(nil)

        // Direct YouTube URL / Video ID detection!
        if let parsed = Formatters.parseYouTubeURL(q) {
            let v = VideoItem(id: parsed.videoId, title: "Loading...", channelName: "", channelId: "", channelAvatarURL: nil, thumbnailURL: "", durationText: "", viewsText: "", publishedText: "")
            openVideo(v, startSeconds: parsed.startSeconds)
            return
        }

        LocalStore.shared.recordSearch(q)
        sidebarWidthConstraint.constant = isSidebarCollapsed ? 72 : 224
        setContent(searchVC)
        searchVC.performSearch(q)
    }

    func controlTextDidChange(_ obj: Notification) {
        let q = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        suggestWork?.cancel()
        if q.isEmpty || Formatters.parseYouTubeURL(q) != nil {
            suggestBox.isHidden = true
            return
        }
        let work = DispatchWorkItem { [weak self] in
            YouTubeAPI.shared.fetchAutocomplete(query: q) { items in
                guard let self = self else { return }
                self.suggestions = items
                self.suggestTable.reloadData()
                self.suggestBox.isHidden = items.isEmpty
            }
        }
        suggestWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
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
        let lbl = makeLabel("🔍  \(suggestions[row])", size: 13, color: YTTheme.textPrimary)
        cell.addSubview(lbl)
        NSLayoutConstraint.activate([
            lbl.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 14),
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
        ramPillBtn.title = String(format: "%.0f MB", fp)
        if fp <= budget * 0.80 {
            ramPillBtn.normalBg = YTTheme.greenGood.withAlphaComponent(0.18)
            ramPillBtn.normalFg = YTTheme.greenGood
        } else if fp <= budget {
            ramPillBtn.normalBg = YTTheme.amberWarn.withAlphaComponent(0.22)
            ramPillBtn.normalFg = YTTheme.amberWarn
        } else {
            ramPillBtn.normalBg = YTTheme.red.withAlphaComponent(0.22)
            ramPillBtn.normalFg = YTTheme.red
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
        let trim = NSMenuItem(title: "Trim Caches Now", action: #selector(trimMemoryNow), keyEquivalent: "")
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

    @objc private func showSettingsPopover() {
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

        let trim = NSMenuItem(title: "Trim Memory Caches", action: #selector(trimMemoryNow), keyEquivalent: "")
        trim.target = self
        menu.addItem(trim)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: settingsBtn)
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
        if let clip = NSPasteboard.general.string(forType: .string), Formatters.parseYouTubeURL(clip) != nil {
            tf.stringValue = clip
        }
        alert.accessoryView = tf
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            openURLString(tf.stringValue)
        }
    }

    // MARK: - Keyboard Shortcuts

    private func installKeyboardMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            // Do not hijack typing inside text fields
            if let fr = self.window?.firstResponder, fr is NSTextView || fr is NSTextField {
                return event
            }
            if event.charactersIgnoringModifiers == "/" {
                self.focusSearchBar()
                return nil
            }
            if self.activeVC === self.shortsVC {
                if event.keyCode == 126 { self.shortsVC.prevShort(); return nil }
                if event.keyCode == 125 { self.shortsVC.nextShort(); return nil }
            }
            if self.activeVC === self.watchVC || !self.miniContainer.isHidden {
                if self.watchVC.playerView.handleKeyEvent(event) {
                    return nil
                }
            }
            return event
        }
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
        window?.appearance = YTTheme.appearance
        window?.contentView?.layer?.backgroundColor = YTTheme.bg.cgColor
        masthead.layer?.backgroundColor = YTTheme.bg.cgColor
        mastheadDivider.layer?.backgroundColor = YTTheme.divider.cgColor
        menuBtn.contentTintColor = YTTheme.textPrimary
        logoText.textColor = YTTheme.textPrimary
        searchBox.layer?.backgroundColor = YTTheme.searchBg.cgColor
        searchBox.layer?.borderColor = YTTheme.border.cgColor
        searchField.textColor = YTTheme.textPrimary
        searchGoBtn.contentTintColor = YTTheme.textPrimary
        themeBtn.image = NSImage(systemSymbolName: YTTheme.isDark ? "sun.max.fill" : "moon.fill", accessibilityDescription: nil)
        themeBtn.contentTintColor = YTTheme.textPrimary
        settingsBtn.contentTintColor = YTTheme.textPrimary
        suggestBox.layer?.backgroundColor = YTTheme.bgElevated.cgColor
        suggestBox.layer?.borderColor = YTTheme.border.cgColor
        miniContainer.layer?.backgroundColor = YTTheme.bgElevated.cgColor
        miniContainer.layer?.borderColor = YTTheme.border.cgColor
        miniTitleLabel.textColor = YTTheme.textPrimary
        miniChannelLabel.textColor = YTTheme.textSecondary
        miniExpandBtn.contentTintColor = YTTheme.textPrimary
        miniCloseBtn.contentTintColor = YTTheme.textPrimary
        rebuildSidebar()
    }

    func showToastMessage(_ message: String) {
        toastText.stringValue = message
        toastBanner.isHidden = false
        toastBanner.alphaValue = 1
        toastWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                self?.toastBanner.animator().alphaValue = 0
            } completionHandler: {
                self?.toastBanner.isHidden = true
            }
        }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: w)
    }
}

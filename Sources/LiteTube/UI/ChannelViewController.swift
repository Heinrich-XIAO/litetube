import AppKit

final class ChannelHeaderView: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("ChannelHeaderView")

    let bannerLayerHost = NSView()
    let avatarView = NSImageView()
    let titleLabel = makeLabel("", size: 24, weight: .bold)
    let metaLabel = makeLabel("", size: 14, color: YTTheme.textSecondary)
    let descLabel = makeLabel("", size: 12, color: YTTheme.textSecondary, maxLines: 2)
    let subscribeBtn = PillButton()
    let tabScroll = NSScrollView()
    let tabStack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        bannerLayerHost.wantsLayer = true
        bannerLayerHost.layer?.cornerRadius = 12
        bannerLayerHost.layer?.masksToBounds = true
        bannerLayerHost.layer?.backgroundColor = YTTheme.surface.cgColor
        bannerLayerHost.layer?.contentsGravity = .resizeAspectFill
        bannerLayerHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bannerLayerHost)

        avatarView.wantsLayer = true
        avatarView.layer?.cornerRadius = 42
        avatarView.layer?.masksToBounds = true
        avatarView.layer?.backgroundColor = YTTheme.surface.cgColor
        avatarView.imageScaling = .scaleProportionallyUpOrDown
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.setAccessibilityLabel("Channel avatar")
        addSubview(avatarView)

        subscribeBtn.title = "Subscribe"
        subscribeBtn.cornerRadiusValue = 18
        subscribeBtn.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        metaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        descLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let infoStack = NSStackView(views: [titleLabel, metaLabel, descLabel, subscribeBtn])
        infoStack.orientation = .vertical
        infoStack.alignment = .leading
        infoStack.spacing = 4
        infoStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(infoStack)

        tabScroll.hasHorizontalScroller = false
        tabScroll.hasVerticalScroller = false
        tabScroll.drawsBackground = false
        tabScroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabScroll)

        tabStack.orientation = .horizontal
        tabStack.spacing = 8
        tabStack.translatesAutoresizingMaskIntoConstraints = false
        tabScroll.documentView = tabStack

        let tabPreferredTop = tabScroll.topAnchor.constraint(equalTo: infoStack.bottomAnchor, constant: 12)
        tabPreferredTop.priority = .defaultHigh

        NSLayoutConstraint.activate([
            bannerLayerHost.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            bannerLayerHost.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            bannerLayerHost.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            bannerLayerHost.heightAnchor.constraint(equalToConstant: 132),

            avatarView.topAnchor.constraint(equalTo: bannerLayerHost.bottomAnchor, constant: 14),
            avatarView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            avatarView.widthAnchor.constraint(equalToConstant: 84),
            avatarView.heightAnchor.constraint(equalToConstant: 84),

            infoStack.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 16),
            infoStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            infoStack.topAnchor.constraint(equalTo: bannerLayerHost.bottomAnchor, constant: 12),

            tabPreferredTop,
            tabScroll.topAnchor.constraint(greaterThanOrEqualTo: avatarView.bottomAnchor, constant: 12),
            tabScroll.topAnchor.constraint(greaterThanOrEqualTo: infoStack.bottomAnchor, constant: 12),
            tabScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            tabScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            tabScroll.heightAnchor.constraint(equalToConstant: 36),

            tabStack.topAnchor.constraint(equalTo: tabScroll.contentView.topAnchor),
            tabStack.bottomAnchor.constraint(equalTo: tabScroll.contentView.bottomAnchor),
            tabStack.leadingAnchor.constraint(equalTo: tabScroll.contentView.leadingAnchor)
        ])
    }

    func setBannerImage(_ image: NSImage?) {
        guard let image = image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            bannerLayerHost.layer?.contents = nil
            return
        }
        bannerLayerHost.layer?.contents = cg
    }

    func applyTheme() {
        bannerLayerHost.layer?.backgroundColor = YTTheme.surface.cgColor
        avatarView.layer?.backgroundColor = YTTheme.surface.cgColor
        titleLabel.textColor = YTTheme.textPrimary
        metaLabel.textColor = YTTheme.textSecondary
        descLabel.textColor = YTTheme.textSecondary
        subscribeBtn.normalBg = YTTheme.surface
        subscribeBtn.activeBg = YTTheme.chipActiveBg
        subscribeBtn.normalFg = YTTheme.textPrimary
        subscribeBtn.activeFg = YTTheme.chipActiveText
        subscribeBtn.updateStyle()
        for case let btn as PillButton in tabStack.arrangedSubviews {
            btn.normalBg = YTTheme.surface
            btn.activeBg = YTTheme.chipActiveBg
            btn.normalFg = YTTheme.textPrimary
            btn.activeFg = YTTheme.chipActiveText
            btn.updateStyle()
        }
    }
}

final class ChannelViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    weak var navDelegate: FeedNavigationDelegate?
    var onOpenPlaylist: ((String, String) -> Void)?

    private var channelId = ""
    private var initialName = ""
    private var channelData: ChannelPageData?
    private var bannerImage: NSImage?
    private var avatarImage: NSImage?
    private var selectedTabTitle = "Videos"
    private var videos: [VideoItem] = []
    private var playlists: [PlaylistCard] = []
    private var showingPlaylists = false
    private var continuationToken: String?
    private var isLoadingMore = false
    private var loadGeneration = 0

    private weak var headerViewRef: ChannelHeaderView?
    private let scrollView = NSScrollView()
    private let collectionView = NSCollectionView()
    private let spinner: NSProgressIndicator = {
        let s = NSProgressIndicator()
        s.setAccessibilityLabel("Loading channel")
        return s
    }()
    private let emptyLabel = makeLabel("", size: 16, weight: .medium, color: YTTheme.textSecondary, maxLines: 3)
    private let retryBtn = PillButton()

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        self.view = root
        setupUI()
        applyTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(onThemeChanged), name: .liteTubeThemeDidChange, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func setupUI() {
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 16
        layout.minimumLineSpacing = 24
        layout.sectionInset = NSEdgeInsets(top: 12, left: 24, bottom: 28, right: 24)

        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = false
        collectionView.backgroundColors = [.clear]
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(VideoCardItem.self, forItemWithIdentifier: VideoCardItem.identifier)
        collectionView.register(ChannelHeaderView.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader, withIdentifier: ChannelHeaderView.identifier)
        collectionView.register(CollectionLoadMoreFooter.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionFooter, withIdentifier: CollectionLoadMoreFooter.identifier)

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        spinner.style = .spinning
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        view.addSubview(emptyLabel)
        retryBtn.title = "Try Again"
        retryBtn.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Try again")
        retryBtn.cornerRadiusValue = 16
        retryBtn.horizontalPadding = 14
        retryBtn.target = self; retryBtn.action = #selector(retryChannel)
        retryBtn.isHidden = true
        retryBtn.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(retryBtn)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 120),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 120),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            retryBtn.topAnchor.constraint(equalTo: emptyLabel.bottomAnchor, constant: 14),
            retryBtn.centerXAnchor.constraint(equalTo: emptyLabel.centerXAnchor)
        ])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        collectionView.collectionViewLayout?.invalidateLayout()
    }

    func canReuseLoadedChannel(id: String) -> Bool {
        channelId == id && channelData != nil
    }

    var currentScrollY: CGFloat { scrollView.contentView.bounds.origin.y }

    func restoreScrollY(_ y: CGFloat) {
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @objc private func retryChannel() {
        loadChannel(channelId: channelId, initialName: "")
    }

    func loadChannel(channelId: String, initialName: String = "") {
        retryBtn.isHidden = true
        loadGeneration += 1
        let gen = loadGeneration
        self.channelId = channelId
        self.initialName = initialName
        self.channelData = nil
        self.bannerImage = nil
        self.avatarImage = nil
        self.selectedTabTitle = "Videos"
        self.videos = []
        self.playlists = []
        self.showingPlaylists = false
        self.continuationToken = nil
        self.isLoadingMore = false
        self.emptyLabel.isHidden = true
        collectionView.reloadData()
        spinner.startAnimation(nil)

        // Default to Videos tab directly so user immediately sees all uploads!
        YouTubeAPI.shared.fetchChannel(channelId: channelId, tabParams: "EgZ2aWRlb3PyBgQKAjoA") { [weak self] res in
            guard let self = self, self.loadGeneration == gen, self.channelId == channelId else { return }
            self.spinner.stopAnimation(nil)
            switch res {
            case .failure:
                showRetryableError(message: "Could not load this channel. Check your connection.", label: self.emptyLabel, retryButton: self.retryBtn)
            case .success(let data):
                self.channelData = data
                if !data.bannerURL.isEmpty {
                    ImageCache.shared.load(data.bannerURL, maxPixelSize: 1200) { [weak self] img in
                        guard let self = self, self.channelId == channelId else { return }
                        self.bannerImage = img
                        self.headerViewRef?.setBannerImage(img)
                    }
                }
                if !data.avatarURL.isEmpty {
                    ImageCache.shared.load(data.avatarURL, maxPixelSize: 168) { [weak self] img in
                        guard let self = self, self.channelId == channelId else { return }
                        self.avatarImage = img
                        self.headerViewRef?.avatarView.image = img
                    }
                }

                self.videos = data.videos
                self.playlists = data.playlists
                self.continuationToken = data.continuation
                let count = self.showingPlaylists ? self.playlists.count : self.videos.count
                self.emptyLabel.stringValue = "No items in this tab. Try another tab above."
                self.emptyLabel.isHidden = count > 0
                self.collectionView.reloadData()
            }
        }
    }

    private func populateHeader(_ header: ChannelHeaderView) {
        headerViewRef = header
        if let data = channelData {
            header.titleLabel.stringValue = data.isVerified ? "\(data.title) ✓" : data.title
            header.metaLabel.stringValue = [data.handle, data.subscriberCountText, data.videoCountText].filter { !$0.isEmpty }.joined(separator: " • ")
            header.descLabel.stringValue = data.descriptionText
        } else {
            header.titleLabel.stringValue = initialName.isEmpty ? "Loading channel…" : initialName
            header.metaLabel.stringValue = ""
            header.descLabel.stringValue = ""
        }
        header.setBannerImage(bannerImage)
        header.avatarView.image = avatarImage

        let isSub = LocalStore.shared.isSubscribed(channelId: channelId)
        header.subscribeBtn.title = isSub ? "Subscribed ✓" : "Subscribe"
        header.subscribeBtn.isSelectedPill = !isSub
        header.subscribeBtn.stateValue = isSub ? "Subscribed" : "Not subscribed"
        header.subscribeBtn.target = self
        header.subscribeBtn.action = #selector(toggleSubscribe)

        header.tabStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for tab in channelData?.tabs ?? [] {
            let b = PillButton()
            b.title = tab.title
            b.cornerRadiusValue = IconScale.tabChipRadius
            b.isSelectedPill = (tab.title == selectedTabTitle)
            b.identifier = NSUserInterfaceItemIdentifier(tab.params)
            b.target = self; b.action = #selector(tabClicked(_:))
            header.tabStack.addArrangedSubview(b)
        }
        header.applyTheme()
    }

    @objc private func tabClicked(_ sender: PillButton) {
        loadGeneration += 1
        let gen = loadGeneration
        selectedTabTitle = sender.title
        let params = sender.identifier?.rawValue
        showingPlaylists = (sender.title == "Playlists")
        videos = []
        playlists = []
        continuationToken = nil
        isLoadingMore = false
        emptyLabel.isHidden = true
        collectionView.reloadData()
        spinner.startAnimation(nil)
        YouTubeAPI.shared.fetchChannel(channelId: channelId, tabParams: params) { [weak self] res in
            guard let self = self, self.loadGeneration == gen else { return }
            self.spinner.stopAnimation(nil)
            switch res {
            case .failure:
                showRetryableError(message: "Could not load this tab. Check your connection.", label: self.emptyLabel, retryButton: self.retryBtn)
            case .success(let data):
                self.videos = data.videos
                self.playlists = data.playlists
                self.continuationToken = data.continuation
                let count = self.showingPlaylists ? self.playlists.count : self.videos.count
                self.emptyLabel.stringValue = "No items in this tab. Try another tab above."
                self.emptyLabel.isHidden = count > 0
                self.collectionView.reloadData()
            }
        }
    }

    @objc private func loadMore() {
        guard let tok = continuationToken, !isLoadingMore else { return }
        let gen = loadGeneration
        isLoadingMore = true
        collectionView.reloadData()
        YouTubeAPI.shared.fetchBrowseContinuation(token: tok) { [weak self] res in
            guard let self = self, self.loadGeneration == gen else { return }
            self.isLoadingMore = false
            switch res {
            case .failure:
                self.navDelegate?.showToastMessage("Could not load more videos. Check your connection.")
            case .success(let (more, next)):
                let existing = Set(self.videos.map(\.id))
                self.videos.append(contentsOf: more.filter { !existing.contains($0.id) })
                self.continuationToken = next
            }
            self.collectionView.reloadData()
        }
    }

    @objc private func toggleSubscribe() {
        guard let d = channelData else { return }
        let now = LocalStore.shared.toggleSubscription(channelId: d.channelId, name: d.title, avatarURL: d.avatarURL, subscriberCountText: d.subscriberCountText)
        if let h = headerViewRef {
            h.subscribeBtn.title = now ? "Subscribed ✓" : "Subscribe"
            h.subscribeBtn.isSelectedPill = !now
            h.subscribeBtn.stateValue = now ? "Subscribed" : "Not subscribed"
        }
        navDelegate?.showToastMessage(now ? "Subscribed to \(d.title)" : "Unsubscribed")
    }

    // MARK: - CollectionView

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        showingPlaylists ? playlists.count : videos.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: VideoCardItem.identifier, for: indexPath) as! VideoCardItem
        if showingPlaylists {
            let p = playlists[indexPath.item]
            let fakeVideo = VideoItem(id: p.id, title: "Playlist · \(p.title)", channelName: p.channelName, channelId: p.channelId, channelAvatarURL: channelData?.avatarURL, thumbnailURL: p.thumbnailURL, durationText: p.videoCountText, viewsText: "Playlist", publishedText: "")
            item.configure(with: fakeVideo)
            item.onSelectVideo = { [weak self] _ in self?.onOpenPlaylist?(p.id, p.title) }
            item.onSelectChannel = nil
            item.onShowContextMenu = nil
        } else {
            let v = videos[indexPath.item]
            item.configure(with: v)
            item.onSelectVideo = { [weak self] vid in self?.navDelegate?.openVideo(vid, startSeconds: nil) }
            item.onSelectChannel = nil
            item.onShowContextMenu = { [weak self] vid, anchor in
                self?.presentContextMenu(for: vid, from: anchor)
            }
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> NSSize {
        let availW = max(320, scrollView.contentSize.width - 48)
        let cardW = GridLayoutHelper.cardWidth(forAvailableWidth: availW)
        return NSSize(width: cardW, height: VideoCardItem.preferredHeight(forCardWidth: cardW))
    }

    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> NSSize {
        let w = max(320, scrollView.contentSize.width)
        let hasDesc = !(channelData?.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasTabs = !(channelData?.tabs.isEmpty ?? true)
        var h: CGFloat = 144 // top 12 + banner 132
        let infoHeight: CGFloat = 30 + 4 + 17 + 4 + (hasDesc ? 34 : 0) + 4 + 34
        let contentBottom = max(14 + 84, 12 + infoHeight)
        h += contentBottom + (hasTabs ? (12 + 36 + 8) : 12)
        return NSSize(width: w, height: h)
    }

    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, referenceSizeForFooterInSection section: Int) -> NSSize {
        continuationToken != nil ? NSSize(width: max(320, scrollView.contentSize.width), height: 64) : .zero
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind, at indexPath: IndexPath) -> NSView {
        if kind == NSCollectionView.elementKindSectionHeader {
            let header = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: ChannelHeaderView.identifier, for: indexPath) as! ChannelHeaderView
            populateHeader(header)
            return header
        }
        let footer = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: CollectionLoadMoreFooter.identifier, for: indexPath) as! CollectionLoadMoreFooter
        footer.button.title = isLoadingMore ? "Loading…" : "Load more"
        footer.button.isEnabled = !isLoadingMore
        footer.button.target = self
        footer.button.action = #selector(loadMore)
        return footer
    }

    private func presentContextMenu(for video: VideoItem, from anchor: NSView) {
        let menu = NSMenu()
        let q = NSMenuItem(title: "Add to Queue", action: #selector(ctxAddQueue(_:)), keyEquivalent: "")
        q.target = self; q.representedObject = video
        menu.addItem(q)

        let wlTitle = LocalStore.shared.isInWatchLater(video.id) ? "Remove from Watch Later" : "Save to Watch Later"
        let wl = NSMenuItem(title: wlTitle, action: #selector(ctxWatchLater(_:)), keyEquivalent: "")
        wl.target = self; wl.representedObject = video
        menu.addItem(wl)

        let cp = NSMenuItem(title: "Copy Video URL", action: #selector(ctxCopyURL(_:)), keyEquivalent: "")
        cp.target = self; cp.representedObject = video
        menu.addItem(cp)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: anchor)
    }

    @objc private func ctxAddQueue(_ s: NSMenuItem) {
        if let v = s.representedObject as? VideoItem {
            LocalStore.shared.addToQueue(v)
            navDelegate?.showToastMessage("Added to Queue")
        }
    }
    @objc private func ctxWatchLater(_ s: NSMenuItem) {
        if let v = s.representedObject as? VideoItem {
            let added = LocalStore.shared.toggleWatchLater(v)
            navDelegate?.showToastMessage(added ? "Saved to Watch Later" : "Removed from Watch Later")
        }
    }
    @objc private func ctxCopyURL(_ s: NSMenuItem) {
        if let v = s.representedObject as? VideoItem {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(v.watchURL, forType: .string)
            navDelegate?.showToastMessage("Copied URL")
        }
    }

    @objc private func onThemeChanged() { applyTheme() }

    func applyTheme() {
        view.layer?.backgroundColor = YTTheme.bg.cgColor
        emptyLabel.textColor = YTTheme.textSecondary
        headerViewRef?.applyTheme()
        collectionView.reloadData()
    }
}

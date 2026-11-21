import AppKit

final class ChannelViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    weak var navDelegate: FeedNavigationDelegate?
    var onOpenPlaylist: ((String, String) -> Void)?

    private var channelId = ""
    private var channelData: ChannelPageData?
    private var videos: [VideoItem] = []
    private var playlists: [PlaylistCard] = []
    private var showingPlaylists = false
    private var continuationToken: String?

    private let bannerView = NSImageView()
    private let avatarView = NSImageView()
    private let titleLabel = makeLabel("", size: 24, weight: .bold)
    private let metaLabel = makeLabel("", size: 13, color: YTTheme.textSecondary)
    private let descLabel = makeLabel("", size: 12, color: YTTheme.textSecondary, maxLines: 2)
    private let subscribeBtn = PillButton()
    private let tabStack = NSStackView()
    private var tabButtons: [PillButton] = []

    private let scrollView = NSScrollView()
    private let collectionView = NSCollectionView()
    private let spinner = NSProgressIndicator()
    private let loadMoreBtn = PillButton()

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
        bannerView.wantsLayer = true
        bannerView.layer?.cornerRadius = 12
        bannerView.layer?.masksToBounds = true
        bannerView.layer?.backgroundColor = YTTheme.surface.cgColor
        bannerView.imageScaling = .scaleAxesIndependently
        bannerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bannerView)

        avatarView.wantsLayer = true
        avatarView.layer?.cornerRadius = 42
        avatarView.layer?.masksToBounds = true
        avatarView.layer?.backgroundColor = YTTheme.surface.cgColor
        avatarView.imageScaling = .scaleProportionallyUpOrDown
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(avatarView)

        subscribeBtn.title = "Subscribe"
        subscribeBtn.cornerRadiusValue = 18
        subscribeBtn.target = self; subscribeBtn.action = #selector(toggleSubscribe)
        subscribeBtn.translatesAutoresizingMaskIntoConstraints = false

        let infoStack = NSStackView(views: [titleLabel, metaLabel, descLabel, subscribeBtn])
        infoStack.orientation = .vertical
        infoStack.alignment = .leading
        infoStack.spacing = 4
        infoStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(infoStack)

        tabStack.orientation = .horizontal
        tabStack.spacing = 8
        tabStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tabStack)

        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 16
        layout.minimumLineSpacing = 24
        layout.sectionInset = NSEdgeInsets(top: 12, left: 24, bottom: 56, right: 24)

        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = false
        collectionView.backgroundColors = [.clear]
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(VideoCardItem.self, forItemWithIdentifier: VideoCardItem.identifier)

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        spinner.style = .spinning
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        loadMoreBtn.title = "Load more"
        loadMoreBtn.cornerRadiusValue = 16
        loadMoreBtn.isHidden = true
        loadMoreBtn.target = self; loadMoreBtn.action = #selector(loadMore)
        loadMoreBtn.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(loadMoreBtn)

        NSLayoutConstraint.activate([
            bannerView.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            bannerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            bannerView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            bannerView.heightAnchor.constraint(equalToConstant: 132),

            avatarView.topAnchor.constraint(equalTo: bannerView.bottomAnchor, constant: 14),
            avatarView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            avatarView.widthAnchor.constraint(equalToConstant: 84),
            avatarView.heightAnchor.constraint(equalToConstant: 84),

            infoStack.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 16),
            infoStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            infoStack.topAnchor.constraint(equalTo: bannerView.bottomAnchor, constant: 12),

            tabStack.topAnchor.constraint(equalTo: infoStack.bottomAnchor, constant: 12),
            tabStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),

            scrollView.topAnchor.constraint(equalTo: tabStack.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            spinner.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            loadMoreBtn.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            loadMoreBtn.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        collectionView.collectionViewLayout?.invalidateLayout()
    }

    func loadChannel(channelId: String, initialName: String = "") {
        self.channelId = channelId
        self.channelData = nil
        self.videos = []
        self.playlists = []
        self.showingPlaylists = false
        self.continuationToken = nil
        titleLabel.stringValue = initialName.isEmpty ? "Loading channel..." : initialName
        metaLabel.stringValue = ""
        descLabel.stringValue = ""
        bannerView.image = nil
        avatarView.image = nil
        collectionView.reloadData()
        spinner.startAnimation(nil)

        // Default to Videos tab directly so user immediately sees all uploads!
        YouTubeAPI.shared.fetchChannel(channelId: channelId, tabParams: "EgZ2aWRlb3PyBgQKAjoA") { [weak self] res in
            guard let self = self, self.channelId == channelId else { return }
            self.spinner.stopAnimation(nil)
            switch res {
            case .failure(let e):
                self.metaLabel.stringValue = "Failed to load channel: \(e.localizedDescription)"
            case .success(let data):
                self.channelData = data
                self.titleLabel.stringValue = data.isVerified ? "\(data.title) ✓" : data.title
                self.metaLabel.stringValue = [data.handle, data.subscriberCountText, data.videoCountText].filter { !$0.isEmpty }.joined(separator: " • ")
                self.descLabel.stringValue = data.descriptionText
                self.updateSubscribeButton()

                if !data.bannerURL.isEmpty {
                    ImageCache.shared.load(data.bannerURL, maxPixelSize: 1200) { [weak self] img in self?.bannerView.image = img }
                }
                if !data.avatarURL.isEmpty {
                    ImageCache.shared.load(data.avatarURL, maxPixelSize: 168) { [weak self] img in self?.avatarView.image = img }
                }

                self.rebuildTabs(data.tabs, selectedTitle: "Videos")
                self.videos = data.videos
                self.playlists = data.playlists
                self.continuationToken = data.continuation
                self.loadMoreBtn.isHidden = (data.continuation == nil)
                self.collectionView.reloadData()
            }
        }
    }

    private func rebuildTabs(_ tabs: [ChannelTabInfo], selectedTitle: String) {
        tabStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        tabButtons.removeAll()
        for tab in tabs {
            let b = PillButton()
            b.title = tab.title
            b.cornerRadiusValue = 8
            b.isSelectedPill = (tab.title == selectedTitle)
            b.identifier = NSUserInterfaceItemIdentifier(tab.params)
            b.target = self; b.action = #selector(tabClicked(_:))
            tabButtons.append(b)
            tabStack.addArrangedSubview(b)
        }
    }

    @objc private func tabClicked(_ sender: PillButton) {
        for b in tabButtons { b.isSelectedPill = (b === sender) }
        let params = sender.identifier?.rawValue
        showingPlaylists = (sender.title == "Playlists")
        videos = []
        playlists = []
        collectionView.reloadData()
        spinner.startAnimation(nil)
        YouTubeAPI.shared.fetchChannel(channelId: channelId, tabParams: params) { [weak self] res in
            guard let self = self else { return }
            self.spinner.stopAnimation(nil)
            if case .success(let data) = res {
                self.videos = data.videos
                self.playlists = data.playlists
                self.continuationToken = data.continuation
                self.loadMoreBtn.isHidden = (data.continuation == nil)
                self.collectionView.reloadData()
            }
        }
    }

    @objc private func loadMore() {
        guard let tok = continuationToken else { return }
        continuationToken = nil
        YouTubeAPI.shared.fetchBrowseContinuation(token: tok) { [weak self] res in
            guard let self = self else { return }
            if case .success(let (more, next)) = res {
                let existing = Set(self.videos.map(\.id))
                self.videos.append(contentsOf: more.filter { !existing.contains($0.id) })
                self.continuationToken = next
                self.loadMoreBtn.isHidden = (next == nil)
                self.collectionView.reloadData()
            }
        }
    }

    private func updateSubscribeButton() {
        let isSub = LocalStore.shared.isSubscribed(channelId: channelId)
        subscribeBtn.title = isSub ? "Subscribed ✓" : "Subscribe"
        subscribeBtn.isSelectedPill = !isSub
    }

    @objc private func toggleSubscribe() {
        guard let d = channelData else { return }
        let now = LocalStore.shared.toggleSubscription(channelId: d.channelId, name: d.title, avatarURL: d.avatarURL, subscriberCountText: d.subscriberCountText)
        updateSubscribeButton()
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
            let fakeVideo = VideoItem(id: p.id, title: "📑 \(p.title)", channelName: p.channelName, channelId: p.channelId, channelAvatarURL: channelData?.avatarURL, thumbnailURL: p.thumbnailURL, durationText: p.videoCountText, viewsText: "Playlist", publishedText: "")
            item.configure(with: fakeVideo)
            item.onSelectVideo = { [weak self] _ in self?.onOpenPlaylist?(p.id, p.title) }
        } else {
            let v = videos[indexPath.item]
            item.configure(with: v)
            item.onSelectVideo = { [weak self] vid in self?.navDelegate?.openVideo(vid, startSeconds: nil) }
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> NSSize {
        let availW = max(320, scrollView.contentSize.width - 48)
        let cols = availW >= 1200 ? 4 : (availW >= 820 ? 3 : 2)
        let cardW = floor((availW - CGFloat(cols - 1) * 16) / CGFloat(cols))
        return NSSize(width: cardW, height: floor(cardW * 9.0 / 16.0) + 90)
    }

    @objc private func onThemeChanged() { applyTheme() }

    func applyTheme() {
        view.layer?.backgroundColor = YTTheme.bg.cgColor
        titleLabel.textColor = YTTheme.textPrimary
        metaLabel.textColor = YTTheme.textSecondary
        descLabel.textColor = YTTheme.textSecondary
        for b in tabButtons + [subscribeBtn, loadMoreBtn] {
            b.normalBg = YTTheme.surface
            b.activeBg = YTTheme.chipActiveBg
            b.normalFg = YTTheme.textPrimary
            b.activeFg = YTTheme.chipActiveText
            b.updateStyle()
        }
        collectionView.reloadData()
    }
}

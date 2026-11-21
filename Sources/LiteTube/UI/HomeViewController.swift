import AppKit

protocol FeedNavigationDelegate: AnyObject {
    func openVideo(_ video: VideoItem, startSeconds: Double?)
    func openChannel(channelId: String, name: String)
    func showToastMessage(_ message: String)
}

// MARK: - Recycled YouTube Video Grid Card (NSCollectionViewItem)

final class VideoCardItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("VideoCardItem")

    private let cardBg = NSView()
    private let thumbView = NSImageView()
    private let durationBadge = makeLabel("", size: 11, weight: .bold, color: .white)
    private let progressTrack = NSView()
    private let progressFill = NSView()
    private var progressWidthConstraint: NSLayoutConstraint!
    private let avatarView = NSImageView()
    private let titleLabel = makeLabel("", size: 14, weight: .semibold, maxLines: 2)
    private let channelLabel = makeLabel("", size: 12, color: YTTheme.textSecondary)
    private let metaLabel = makeLabel("", size: 12, color: YTTheme.textSecondary)
    private let moreBtn = makeSymbolButton("ellipsis", size: 14, color: YTTheme.textSecondary, tooltip: "More options")

    private var video: VideoItem?
    var onSelectVideo: ((VideoItem) -> Void)?
    var onSelectChannel: ((String, String) -> Void)?
    var onShowContextMenu: ((VideoItem, NSView) -> Void)?
    private var tracking: NSTrackingArea?

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        self.view = root

        cardBg.wantsLayer = true
        cardBg.layer?.cornerRadius = 12
        cardBg.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(cardBg)

        thumbView.wantsLayer = true
        thumbView.layer?.cornerRadius = 12
        thumbView.layer?.masksToBounds = true
        thumbView.layer?.backgroundColor = YTTheme.surface.cgColor
        thumbView.imageScaling = .scaleProportionallyUpOrDown
        thumbView.translatesAutoresizingMaskIntoConstraints = false
        cardBg.addSubview(thumbView)

        durationBadge.wantsLayer = true
        durationBadge.layer?.cornerRadius = 4
        durationBadge.alignment = .center
        cardBg.addSubview(durationBadge)

        progressTrack.wantsLayer = true
        progressTrack.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.3).cgColor
        progressTrack.isHidden = true
        progressTrack.translatesAutoresizingMaskIntoConstraints = false
        thumbView.addSubview(progressTrack)

        progressFill.wantsLayer = true
        progressFill.layer?.backgroundColor = YTTheme.red.cgColor
        progressFill.translatesAutoresizingMaskIntoConstraints = false
        progressTrack.addSubview(progressFill)
        progressWidthConstraint = progressFill.widthAnchor.constraint(equalToConstant: 0)

        avatarView.wantsLayer = true
        avatarView.layer?.cornerRadius = 18
        avatarView.layer?.masksToBounds = true
        avatarView.layer?.backgroundColor = YTTheme.surface.cgColor
        avatarView.imageScaling = .scaleProportionallyUpOrDown
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        cardBg.addSubview(avatarView)

        let avClick = NSClickGestureRecognizer(target: self, action: #selector(channelClicked))
        avatarView.addGestureRecognizer(avClick)
        let chClick = NSClickGestureRecognizer(target: self, action: #selector(channelClicked))
        channelLabel.addGestureRecognizer(chClick)

        moreBtn.target = self; moreBtn.action = #selector(moreClicked)
        cardBg.addSubview(titleLabel)
        cardBg.addSubview(channelLabel)
        cardBg.addSubview(metaLabel)
        cardBg.addSubview(moreBtn)

        let cardClick = NSClickGestureRecognizer(target: self, action: #selector(cardClicked))
        thumbView.addGestureRecognizer(cardClick)
        let titleClick = NSClickGestureRecognizer(target: self, action: #selector(cardClicked))
        titleLabel.addGestureRecognizer(titleClick)

        NSLayoutConstraint.activate([
            cardBg.topAnchor.constraint(equalTo: root.topAnchor, constant: 2),
            cardBg.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 2),
            cardBg.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -2),
            cardBg.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -2),

            thumbView.topAnchor.constraint(equalTo: cardBg.topAnchor),
            thumbView.leadingAnchor.constraint(equalTo: cardBg.leadingAnchor),
            thumbView.trailingAnchor.constraint(equalTo: cardBg.trailingAnchor),
            thumbView.heightAnchor.constraint(equalTo: thumbView.widthAnchor, multiplier: 9.0 / 16.0),

            durationBadge.trailingAnchor.constraint(equalTo: thumbView.trailingAnchor, constant: -6),
            durationBadge.bottomAnchor.constraint(equalTo: thumbView.bottomAnchor, constant: -6),

            progressTrack.leadingAnchor.constraint(equalTo: thumbView.leadingAnchor),
            progressTrack.trailingAnchor.constraint(equalTo: thumbView.trailingAnchor),
            progressTrack.bottomAnchor.constraint(equalTo: thumbView.bottomAnchor),
            progressTrack.heightAnchor.constraint(equalToConstant: 3.5),
            progressFill.leadingAnchor.constraint(equalTo: progressTrack.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progressTrack.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressTrack.bottomAnchor),
            progressWidthConstraint,

            avatarView.topAnchor.constraint(equalTo: thumbView.bottomAnchor, constant: 10),
            avatarView.leadingAnchor.constraint(equalTo: cardBg.leadingAnchor, constant: 2),
            avatarView.widthAnchor.constraint(equalToConstant: 36),
            avatarView.heightAnchor.constraint(equalToConstant: 36),

            moreBtn.topAnchor.constraint(equalTo: thumbView.bottomAnchor, constant: 10),
            moreBtn.trailingAnchor.constraint(equalTo: cardBg.trailingAnchor, constant: -2),
            moreBtn.widthAnchor.constraint(equalToConstant: 24),
            moreBtn.heightAnchor.constraint(equalToConstant: 24),

            titleLabel.topAnchor.constraint(equalTo: thumbView.bottomAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: moreBtn.leadingAnchor, constant: -4),

            channelLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            channelLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            channelLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            metaLabel.topAnchor.constraint(equalTo: channelLabel.bottomAnchor, constant: 2),
            metaLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            metaLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor)
        ])
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        video = nil
        thumbView.image = nil
        avatarView.image = nil
        progressTrack.isHidden = true
    }

    func configure(with video: VideoItem, watchProgress: Double? = nil) {
        self.video = video
        let vid = video.id
        titleLabel.stringValue = video.title
        titleLabel.textColor = YTTheme.textPrimary
        channelLabel.stringValue = video.isVerified ? "\(video.channelName) ✓" : video.channelName
        channelLabel.textColor = YTTheme.textSecondary
        metaLabel.stringValue = [video.viewsText, video.publishedText].filter { !$0.isEmpty }.joined(separator: " • ")
        metaLabel.textColor = YTTheme.textSecondary
        thumbView.layer?.backgroundColor = YTTheme.surface.cgColor
        avatarView.layer?.backgroundColor = YTTheme.surface.cgColor

        if video.durationText.isEmpty {
            durationBadge.isHidden = true
        } else {
            durationBadge.isHidden = false
            durationBadge.stringValue = " \(video.durationText) "
            durationBadge.layer?.backgroundColor = (video.isLive ? YTTheme.red : NSColor.black.withAlphaComponent(0.84)).cgColor
        }

        if let p = watchProgress, p > 0.02 {
            progressTrack.isHidden = false
            let w = max(thumbView.bounds.width, 280)
            progressWidthConstraint.constant = w * CGFloat(min(1, p))
        } else {
            progressTrack.isHidden = true
        }

        ImageCache.shared.load(video.bestThumbnailURL, maxPixelSize: 380) { [weak self] img in
            guard let self = self, self.video?.id == vid else { return }
            self.thumbView.image = img
        }
        if let av = video.channelAvatarURL, !av.isEmpty {
            ImageCache.shared.load(av, maxPixelSize: 72) { [weak self] img in
                guard let self = self, self.video?.id == vid else { return }
                self.avatarView.image = img
            }
        }
    }

    @objc private func cardClicked() {
        if let v = video { onSelectVideo?(v) }
    }

    @objc private func channelClicked() {
        if let v = video, !v.channelId.isEmpty { onSelectChannel?(v.channelId, v.channelName) }
    }

    @objc private func moreClicked() {
        if let v = video { onShowContextMenu?(v, moreBtn) }
    }
}

// MARK: - Home / Explore / Subscriptions / History / Library Grid Controller

enum FeedMode: Equatable {
    case home
    case explore(String)
    case subscriptions
    case history
    case watchLater
    case liked
    case queue
    case playlist(id: String, name: String)
}

final class HomeViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    weak var navDelegate: FeedNavigationDelegate?

    private(set) var mode: FeedMode = .home
    private var activeCategory: String = "All"
    private var videos: [VideoItem] = []
    private var historyMap: [String: WatchHistoryEntry] = [:]
    private var continuationToken: String?
    private var isLoading = false

    // Header / Category Chips
    private let headerContainer = NSView()
    private let headerTitle = makeLabel("Home", size: 22, weight: .bold)
    private let headerActionStack = NSStackView()
    private let chipsScroll = NSScrollView()
    private let chipsStack = NSStackView()
    private var chipButtons: [String: PillButton] = [:]

    // Collection View
    private let scrollView = NSScrollView()
    private let collectionView = NSCollectionView()
    private let spinner = NSProgressIndicator()
    private let emptyLabel = makeLabel("", size: 15, weight: .medium, color: YTTheme.textSecondary, maxLines: 3)
    private let loadMoreBtn = PillButton()

    private var headerHeightConstraint: NSLayoutConstraint!
    private var chipsHeightConstraint: NSLayoutConstraint!

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        self.view = root
        setupUI()
        applyTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(onThemeChanged), name: .liteTubeThemeDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onStoreChanged), name: .liteTubeStoreDidChange, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func setupUI() {
        headerContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerContainer)

        headerActionStack.orientation = .horizontal
        headerActionStack.spacing = 8
        headerActionStack.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.addSubview(headerTitle)
        headerContainer.addSubview(headerActionStack)

        // Category chips bar (YouTube Home)
        chipsScroll.hasHorizontalScroller = false
        chipsScroll.hasVerticalScroller = false
        chipsScroll.drawsBackground = false
        chipsScroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(chipsScroll)

        chipsStack.orientation = .horizontal
        chipsStack.spacing = 10
        chipsStack.edgeInsets = NSEdgeInsets(top: 6, left: 20, bottom: 6, right: 20)
        chipsStack.translatesAutoresizingMaskIntoConstraints = false
        chipsScroll.documentView = chipsStack

        for cat in YouTubeAPI.exploreCategories {
            let btn = PillButton()
            btn.title = cat.name
            btn.cornerRadiusValue = 8
            btn.horizontalPadding = 12
            btn.isSelectedPill = (cat.name == "All")
            btn.target = self; btn.action = #selector(categoryChipClicked(_:))
            chipButtons[cat.name] = btn
            chipsStack.addArrangedSubview(btn)
        }

        // CollectionView with responsive FlowLayout
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 16
        layout.minimumLineSpacing = 26
        layout.sectionInset = NSEdgeInsets(top: 14, left: 20, bottom: 64, right: 20)

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

        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        view.addSubview(emptyLabel)

        loadMoreBtn.title = "Load more videos"
        loadMoreBtn.cornerRadiusValue = 16
        loadMoreBtn.isHidden = true
        loadMoreBtn.target = self; loadMoreBtn.action = #selector(loadMoreClicked)
        loadMoreBtn.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(loadMoreBtn)

        headerHeightConstraint = headerContainer.heightAnchor.constraint(equalToConstant: 0)
        chipsHeightConstraint = chipsScroll.heightAnchor.constraint(equalToConstant: 46)

        NSLayoutConstraint.activate([
            headerContainer.topAnchor.constraint(equalTo: view.topAnchor),
            headerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerHeightConstraint,

            headerTitle.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 20),
            headerTitle.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),
            headerActionStack.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor, constant: -20),
            headerActionStack.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),

            chipsScroll.topAnchor.constraint(equalTo: headerContainer.bottomAnchor),
            chipsScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chipsScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chipsHeightConstraint,

            scrollView.topAnchor.constraint(equalTo: chipsScroll.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            spinner.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),

            loadMoreBtn.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),
            loadMoreBtn.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        collectionView.collectionViewLayout?.invalidateLayout()
    }

    // MARK: - Mode Loading

    func load(mode: FeedMode) {
        self.mode = mode
        continuationToken = nil
        loadMoreBtn.isHidden = true
        emptyLabel.isHidden = true
        headerActionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        historyMap.removeAll()

        switch mode {
        case .home:
            headerHeightConstraint.constant = 0
            chipsHeightConstraint.constant = 46
            headerContainer.isHidden = true
            chipsScroll.isHidden = false
            loadCategory(activeCategory)

        case .explore(let cat):
            headerHeightConstraint.constant = 50
            chipsHeightConstraint.constant = 0
            headerContainer.isHidden = false
            chipsScroll.isHidden = true
            headerTitle.stringValue = cat
            loadCategory(cat)

        case .subscriptions:
            headerHeightConstraint.constant = 52
            chipsHeightConstraint.constant = 0
            headerContainer.isHidden = false
            chipsScroll.isHidden = true
            headerTitle.stringValue = "Subscriptions"
            let subs = LocalStore.shared.subscriptions
            if subs.isEmpty {
                videos = []
                collectionView.reloadData()
                emptyLabel.stringValue = "No subscriptions yet.\nOpen any video or channel and click Subscribe to build your feed."
                emptyLabel.isHidden = false
                return
            }
            let refreshBtn = makeActionPill("Refresh", symbol: "arrow.clockwise", action: #selector(reloadCurrentMode))
            headerActionStack.addArrangedSubview(refreshBtn)
            spinner.startAnimation(nil)
            YouTubeAPI.shared.fetchSubscriptionsFeed(channels: subs) { [weak self] vids in
                guard let self = self, self.mode == .subscriptions else { return }
                self.spinner.stopAnimation(nil)
                self.videos = vids
                self.emptyLabel.isHidden = !vids.isEmpty
                if vids.isEmpty { self.emptyLabel.stringValue = "No recent uploads found from subscribed channels." }
                self.collectionView.reloadData()
            }

        case .history:
            headerHeightConstraint.constant = 52
            chipsHeightConstraint.constant = 0
            headerContainer.isHidden = false
            chipsScroll.isHidden = true
            headerTitle.stringValue = "Watch History"
            let pauseBtn = makeActionPill(LocalStore.shared.settings.pauseHistory ? "Resume History" : "Pause History", symbol: "pause.circle", action: #selector(togglePauseHistory))
            let clearBtn = makeActionPill("Clear History", symbol: "trash", action: #selector(clearHistoryClicked))
            headerActionStack.addArrangedSubview(pauseBtn)
            headerActionStack.addArrangedSubview(clearBtn)
            let entries = LocalStore.shared.history
            for e in entries { historyMap[e.video.id] = e }
            videos = entries.map(\.video)
            emptyLabel.stringValue = "Your watch history is empty."
            emptyLabel.isHidden = !videos.isEmpty
            collectionView.reloadData()

        case .watchLater:
            configureLocalList(title: "Watch Later", items: LocalStore.shared.watchLater, empty: "Save videos to Watch Later from any card or watch page.")

        case .liked:
            configureLocalList(title: "Liked Videos", items: LocalStore.shared.likedVideos, empty: "Videos you like appear here.")

        case .queue:
            configureLocalList(title: "Playback Queue", items: LocalStore.shared.queue, empty: "Your queue is empty. Right-click any video to add it to Queue.")
            if !LocalStore.shared.queue.isEmpty {
                headerActionStack.addArrangedSubview(makeActionPill("Clear Queue", symbol: "trash", action: #selector(clearQueueClicked)))
            }

        case .playlist(let id, let name):
            if let localPl = LocalStore.shared.playlists.first(where: { $0.id == id }) {
                configureLocalList(title: localPl.name, items: localPl.videos, empty: "This playlist is empty.")
                headerActionStack.addArrangedSubview(makeActionPill("Delete", symbol: "trash", action: #selector(deleteCurrentPlaylist)))
            } else {
                // Remote YouTube playlist
                headerHeightConstraint.constant = 52
                chipsHeightConstraint.constant = 0
                headerContainer.isHidden = false
                chipsScroll.isHidden = true
                headerTitle.stringValue = name
                spinner.startAnimation(nil)
                YouTubeAPI.shared.fetchPlaylist(playlistId: id) { [weak self] res in
                    guard let self = self else { return }
                    self.spinner.stopAnimation(nil)
                    if case .success(let (t, vids)) = res {
                        self.headerTitle.stringValue = t
                        self.videos = vids
                        if !vids.isEmpty {
                            self.headerActionStack.addArrangedSubview(self.makeActionPill("Play All", symbol: "play.fill", action: #selector(self.playAllClicked)))
                        }
                        self.collectionView.reloadData()
                    }
                }
            }
        }
    }

    private func configureLocalList(title: String, items: [VideoItem], empty: String) {
        headerHeightConstraint.constant = 52
        chipsHeightConstraint.constant = 0
        headerContainer.isHidden = false
        chipsScroll.isHidden = true
        headerTitle.stringValue = "\(title) (\(items.count))"
        videos = items
        if !items.isEmpty {
            headerActionStack.addArrangedSubview(makeActionPill("Play All", symbol: "play.fill", action: #selector(playAllClicked)))
        }
        emptyLabel.stringValue = empty
        emptyLabel.isHidden = !items.isEmpty
        collectionView.reloadData()
    }

    private func loadCategory(_ cat: String) {
        activeCategory = cat
        for (name, btn) in chipButtons { btn.isSelectedPill = (name == cat) }
        spinner.startAnimation(nil)
        videos = []
        collectionView.reloadData()
        YouTubeAPI.shared.fetchCategoryFeed(category: cat) { [weak self] res in
            guard let self = self else { return }
            self.spinner.stopAnimation(nil)
            switch res {
            case .failure(let err):
                self.emptyLabel.stringValue = "Could not load feed: \(err.localizedDescription)"
                self.emptyLabel.isHidden = false
            case .success(let (vids, cont)):
                self.videos = vids
                self.continuationToken = cont
                self.loadMoreBtn.isHidden = (cont == nil)
                self.emptyLabel.isHidden = !vids.isEmpty
                self.collectionView.reloadData()
            }
        }
    }

    @objc private func categoryChipClicked(_ sender: PillButton) {
        loadCategory(sender.title)
    }

    @objc private func reloadCurrentMode() { load(mode: mode) }

    @objc private func playAllClicked() {
        guard let first = videos.first else { return }
        LocalStore.shared.setQueue(videos, startAt: 0)
        navDelegate?.openVideo(first, startSeconds: nil)
    }

    @objc private func togglePauseHistory() {
        var s = LocalStore.shared.settings
        s.pauseHistory.toggle()
        LocalStore.shared.settings = s
        load(mode: .history)
    }

    @objc private func clearHistoryClicked() {
        LocalStore.shared.clearHistory()
        load(mode: .history)
    }

    @objc private func clearQueueClicked() {
        LocalStore.shared.clearQueue()
        load(mode: .queue)
    }

    @objc private func deleteCurrentPlaylist() {
        if case .playlist(let id, _) = mode {
            LocalStore.shared.deletePlaylist(id: id)
            load(mode: .home)
        }
    }

    @objc private func loadMoreClicked() {
        guard let tok = continuationToken, !isLoading else { return }
        isLoading = true
        YouTubeAPI.shared.fetchBrowseContinuation(token: tok) { [weak self] res in
            guard let self = self else { return }
            self.isLoading = false
            if case .success(let (more, next)) = res {
                let existing = Set(self.videos.map(\.id))
                self.videos.append(contentsOf: more.filter { !existing.contains($0.id) })
                self.continuationToken = next
                self.loadMoreBtn.isHidden = (next == nil)
                self.collectionView.reloadData()
            }
        }
    }

    @objc private func onStoreChanged() {
        switch mode {
        case .history, .watchLater, .liked, .queue, .playlist:
            load(mode: mode)
        default: break
        }
    }

    private func makeActionPill(_ title: String, symbol: String, action: Selector) -> PillButton {
        let b = PillButton()
        b.title = title
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        b.cornerRadiusValue = 16
        b.target = self; b.action = action
        return b
    }

    // MARK: - CollectionView DataSource & Responsive Grid

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        videos.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: VideoCardItem.identifier, for: indexPath) as! VideoCardItem
        let v = videos[indexPath.item]
        var prog: Double? = nil
        if let h = historyMap[v.id], h.durationSeconds > 0 {
            prog = h.lastPositionSeconds / h.durationSeconds
        }
        item.configure(with: v, watchProgress: prog)
        item.onSelectVideo = { [weak self] vid in
            self?.navDelegate?.openVideo(vid, startSeconds: nil)
        }
        item.onSelectChannel = { [weak self] cid, name in
            self?.navDelegate?.openChannel(channelId: cid, name: name)
        }
        item.onShowContextMenu = { [weak self] vid, anchor in
            self?.presentContextMenu(for: vid, from: anchor)
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> NSSize {
        let availW = max(320, scrollView.contentSize.width - 40)
        let cols: Int
        if availW >= 1320 { cols = 4 }
        else if availW >= 920 { cols = 3 }
        else if availW >= 580 { cols = 2 }
        else { cols = 1 }
        let spacing = CGFloat(cols - 1) * 16
        let cardW = floor((availW - spacing) / CGFloat(cols))
        let thumbH = floor(cardW * 9.0 / 16.0)
        return NSSize(width: cardW, height: thumbH + 92)
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

        if !video.channelId.isEmpty {
            let ch = NSMenuItem(title: "Go to Channel (\(video.channelName))", action: #selector(ctxOpenChannel(_:)), keyEquivalent: "")
            ch.target = self; ch.representedObject = video
            menu.addItem(ch)
        }
        let cp = NSMenuItem(title: "Copy Video URL", action: #selector(ctxCopyURL(_:)), keyEquivalent: "")
        cp.target = self; cp.representedObject = video
        menu.addItem(cp)

        if mode == .history {
            menu.addItem(.separator())
            let rm = NSMenuItem(title: "Remove from History", action: #selector(ctxRemoveHistory(_:)), keyEquivalent: "")
            rm.target = self; rm.representedObject = video
            menu.addItem(rm)
        }

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
    @objc private func ctxOpenChannel(_ s: NSMenuItem) {
        if let v = s.representedObject as? VideoItem { navDelegate?.openChannel(channelId: v.channelId, name: v.channelName) }
    }
    @objc private func ctxCopyURL(_ s: NSMenuItem) {
        if let v = s.representedObject as? VideoItem {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(v.watchURL, forType: .string)
            navDelegate?.showToastMessage("Copied URL")
        }
    }
    @objc private func ctxRemoveHistory(_ s: NSMenuItem) {
        if let v = s.representedObject as? VideoItem { LocalStore.shared.removeFromHistory(videoId: v.id) }
    }

    @objc private func onThemeChanged() { applyTheme() }

    func applyTheme() {
        view.layer?.backgroundColor = YTTheme.bg.cgColor
        headerTitle.textColor = YTTheme.textPrimary
        for btn in chipButtons.values {
            btn.normalBg = YTTheme.surface
            btn.activeBg = YTTheme.chipActiveBg
            btn.normalFg = YTTheme.textPrimary
            btn.activeFg = YTTheme.chipActiveText
            btn.updateStyle()
        }
        loadMoreBtn.normalBg = YTTheme.surface
        loadMoreBtn.normalFg = YTTheme.textPrimary
        loadMoreBtn.updateStyle()
        collectionView.reloadData()
    }
}

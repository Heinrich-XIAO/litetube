import AppKit

protocol FeedNavigationDelegate: AnyObject {
    func showHome()
    func openVideo(_ video: VideoItem, startSeconds: Double?)
    func openChannel(channelId: String, name: String)
    func showToastMessage(_ message: String)
}

final class CollectionLoadMoreFooter: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("CollectionLoadMoreFooter")
    let button = PillButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        button.title = "Load more"
        button.cornerRadiusValue = 16
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

private final class CardInteractiveView: NSView {
    var cursorViews: [NSView] = []
    var onContextMenu: ((NSView) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Hover tint so the grid responds to the pointer like search rows and sidebar items do.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = YTTheme.surface.withAlphaComponent(0.55).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func resetCursorRects() {
        for v in cursorViews where !v.isHidden {
            let rect = convert(v.bounds, from: v)
            addCursorRect(rect, cursor: .pointingHand)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onContextMenu?(self)
    }
}

private final class AccessibleThumbView: NSImageView {
    var onPress: (() -> Void)?
    var onOpenChannel: (() -> Void)?
    var onFocusChanged: ((Bool) -> Void)?
    var accessibilityTitleText: String?

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChanged?(true) }
        return ok
    }
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        onFocusChanged?(false)
        return ok
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 || event.keyCode == 76 {
            onPress?()
            return
        }
        super.keyDown(with: event)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { accessibilityTitleText }
    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard onOpenChannel != nil else { return nil }
        return [
            NSAccessibilityCustomAction(name: "Open channel") { [weak self] in
                self?.onOpenChannel?()
                return true
            }
        ]
    }
}

// MARK: - Recycled YouTube Video Grid Card (NSCollectionViewItem)

final class VideoCardItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("VideoCardItem")

    static func preferredHeight(forCardWidth cardW: CGFloat) -> CGFloat {
        floor(cardW * 9.0 / 16.0) + 86
    }

    private let cardBg = CardInteractiveView()
    private let thumbView = AccessibleThumbView()
    private let focusOverlay = NSView()
    private let durationBadge = DurationBadgeView()
    private let progressTrack = NSView()
    private let progressFill = NSView()
    private var progressWidthConstraint: NSLayoutConstraint!
    private let avatarView = NSImageView()
    private let titleLabel = makeLabel("", size: 14, weight: .semibold, maxLines: 2)
    private let channelLabel = makeLabel("", size: 12, color: YTTheme.textSecondary)
    private let metaLabel = makeLabel("", size: 12, color: YTTheme.textSecondary)
    private let moreBtn = makeSymbolButton("ellipsis", size: 14, color: YTTheme.textSecondary, tooltip: "More options", hoverBg: YTTheme.surface)

    private var titleLeadingToAvatar: NSLayoutConstraint!
    private var titleLeadingToEdge: NSLayoutConstraint!
    private var metaTopToChannel: NSLayoutConstraint!
    private var metaTopToTitle: NSLayoutConstraint!

    private var video: VideoItem?
    var onSelectVideo: ((VideoItem) -> Void)?
    var onSelectChannel: ((String, String) -> Void)? {
        didSet { updateInteractiveCursors() }
    }
    var onShowContextMenu: ((VideoItem, NSView) -> Void)? {
        didSet { moreBtn.isHidden = (onShowContextMenu == nil) }
    }
    private var tracking: NSTrackingArea?

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        self.view = root

        cardBg.wantsLayer = true
        cardBg.layer?.cornerRadius = 12
        cardBg.translatesAutoresizingMaskIntoConstraints = false
        cardBg.onContextMenu = { [weak self] anchor in
            if let v = self?.video { self?.onShowContextMenu?(v, anchor) }
        }
        root.addSubview(cardBg)

        thumbView.wantsLayer = true
        thumbView.layer?.cornerRadius = 12
        thumbView.layer?.masksToBounds = true
        thumbView.layer?.backgroundColor = YTTheme.surface.cgColor
        thumbView.imageScaling = .scaleProportionallyUpOrDown
        thumbView.onPress = { [weak self] in self?.cardClicked() }
        thumbView.onFocusChanged = { [weak self] focused in
            self?.focusOverlay.isHidden = !focused
            self?.focusOverlay.layer?.borderColor = YTTheme.linkBlue.cgColor
        }
        thumbView.translatesAutoresizingMaskIntoConstraints = false
        cardBg.addSubview(thumbView)

        focusOverlay.wantsLayer = true
        focusOverlay.layer?.cornerRadius = 12
        focusOverlay.layer?.borderWidth = 2
        focusOverlay.isHidden = true
        focusOverlay.translatesAutoresizingMaskIntoConstraints = false
        cardBg.addSubview(focusOverlay)

        cardBg.addSubview(durationBadge)

        progressTrack.wantsLayer = true
        progressTrack.layer?.backgroundColor = YTTheme.progressTrackBg.cgColor
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
        avatarView.setAccessibilityElement(false)
        titleLabel.setAccessibilityElement(false)
        channelLabel.setAccessibilityElement(false)
        metaLabel.setAccessibilityElement(false)
        durationBadge.setAccessibilityElement(false)
        cardBg.addSubview(titleLabel)
        cardBg.addSubview(channelLabel)
        cardBg.addSubview(metaLabel)
        cardBg.addSubview(moreBtn)

        let cardClick = NSClickGestureRecognizer(target: self, action: #selector(cardClicked))
        thumbView.addGestureRecognizer(cardClick)
        let titleClick = NSClickGestureRecognizer(target: self, action: #selector(cardClicked))
        titleLabel.addGestureRecognizer(titleClick)

        titleLeadingToAvatar = titleLabel.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 10)
        titleLeadingToEdge = titleLabel.leadingAnchor.constraint(equalTo: cardBg.leadingAnchor, constant: 2)
        metaTopToChannel = metaLabel.topAnchor.constraint(equalTo: channelLabel.bottomAnchor, constant: 2)
        metaTopToTitle = metaLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4)

        NSLayoutConstraint.activate([
            cardBg.topAnchor.constraint(equalTo: root.topAnchor, constant: 2),
            cardBg.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 2),
            cardBg.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -2),
            cardBg.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -2),

            thumbView.topAnchor.constraint(equalTo: cardBg.topAnchor),
            thumbView.leadingAnchor.constraint(equalTo: cardBg.leadingAnchor),
            thumbView.trailingAnchor.constraint(equalTo: cardBg.trailingAnchor),
            thumbView.heightAnchor.constraint(equalTo: thumbView.widthAnchor, multiplier: 9.0 / 16.0),

            focusOverlay.topAnchor.constraint(equalTo: cardBg.topAnchor),
            focusOverlay.leadingAnchor.constraint(equalTo: cardBg.leadingAnchor),
            focusOverlay.trailingAnchor.constraint(equalTo: cardBg.trailingAnchor),
            focusOverlay.bottomAnchor.constraint(equalTo: cardBg.bottomAnchor),

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
            moreBtn.widthAnchor.constraint(equalToConstant: IconScale.moreTarget),
            moreBtn.heightAnchor.constraint(equalToConstant: IconScale.moreTarget),

            titleLabel.topAnchor.constraint(equalTo: thumbView.bottomAnchor, constant: 10),
            titleLeadingToAvatar,
            titleLabel.trailingAnchor.constraint(equalTo: moreBtn.leadingAnchor, constant: -4),

            channelLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            channelLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            channelLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            metaTopToChannel,
            metaLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            metaLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor)
        ])
        updateInteractiveCursors()
    }

    private func updateInteractiveCursors() {
        // Placeholder cards are not links, so they get no pointer cursor.
        if video?.id.hasPrefix("placeholder-") == true {
            cardBg.cursorViews = []
            view.window?.invalidateCursorRects(for: cardBg)
            return
        }
        var views: [NSView] = [thumbView, titleLabel]
        if onSelectChannel != nil && !avatarView.isHidden {
            views.append(contentsOf: [avatarView, channelLabel])
        }
        cardBg.cursorViews = views
        view.window?.invalidateCursorRects(for: cardBg)
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

        let hasChannelText = !video.channelName.isEmpty
        // The avatar only appears with a channel name; a blank circle reads as broken.
        let showAvatar = hasChannelText
        avatarView.isHidden = !showAvatar
        channelLabel.isHidden = false
        NSLayoutConstraint.deactivate([titleLeadingToAvatar, titleLeadingToEdge, metaTopToChannel, metaTopToTitle])
        // Titles sit against the avatar only when there is one; a hidden avatar leaves no empty gutter.
        titleLeadingToAvatar.isActive = showAvatar
        titleLeadingToEdge.isActive = !showAvatar
        // The channel line always keeps its height, so titles and metadata line up across a row.
        metaTopToChannel.isActive = true
        metaTopToTitle.isActive = false

        // Without a channel name, the views move up into the channel line instead of leaving an empty row.
        if hasChannelText {
            channelLabel.stringValue = video.isVerified ? "\(video.channelName) ✓" : video.channelName
            metaLabel.stringValue = [video.viewsText, video.publishedText].filter { !$0.isEmpty }.joined(separator: " • ")
        } else {
            channelLabel.stringValue = video.viewsText
            metaLabel.stringValue = video.publishedText
        }
        channelLabel.textColor = YTTheme.textSecondary
        metaLabel.textColor = YTTheme.textSecondary
        thumbView.layer?.backgroundColor = YTTheme.surface.cgColor
        avatarView.layer?.backgroundColor = YTTheme.surface.cgColor
        moreBtn.contentTintColor = YTTheme.textSecondary
        moreBtn.setAccessibilityLabel("More options for \(video.title)")
        moreBtn.hoverBgColor = YTTheme.surface
        moreBtn.isHidden = (onShowContextMenu == nil)

        durationBadge.configure(text: video.durationText, isLive: video.isLive)

        if let p = watchProgress, p > 0.02 {
            progressTrack.isHidden = false
            progressWidthConstraint.isActive = false
            progressWidthConstraint = progressFill.widthAnchor.constraint(equalTo: progressTrack.widthAnchor, multiplier: CGFloat(min(1.0, max(0.01, p))))
            progressWidthConstraint.isActive = true
        } else {
            progressTrack.isHidden = true
        }
        let accLabel = [video.title, video.channelName, video.viewsText, video.publishedText, video.durationText].filter { !$0.isEmpty }.joined(separator: ", ")
        // A placeholder is announced as loading, not as an unnamed button.
        thumbView.accessibilityTitleText = video.id.hasPrefix("placeholder-") ? "Loading video" : accLabel
        thumbView.onOpenChannel = (onSelectChannel != nil && !video.channelId.isEmpty) ? { [weak self] in self?.channelClicked() } : nil
        updateInteractiveCursors()

        if showAvatar {
            let cfg = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
            avatarView.image = NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
            avatarView.contentTintColor = YTTheme.textSecondary
        }

        ImageCache.shared.load(video.bestThumbnailURL, maxPixelSize: 380) { [weak self] img in
            guard let self = self, self.video?.id == vid else { return }
            self.thumbView.image = img
        }
        if let av = video.channelAvatarURL, !av.isEmpty {
            ImageCache.shared.load(av, maxPixelSize: 72) { [weak self] img in
                guard let self = self, self.video?.id == vid else { return }
                if let img = img {
                    self.avatarView.contentTintColor = nil
                    self.avatarView.image = img
                }
            }
        }
    }

    @objc private func cardClicked() {
        // Placeholder cards are not videos, so they cannot be opened.
        if let v = video, !v.id.hasPrefix("placeholder-") { onSelectVideo?(v) }
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
    var onCategorySelected: ((String) -> Void)?

    private(set) var mode: FeedMode = .home
    private(set) var activeCategory: String = "All"
    private var videos: [VideoItem] = []
    private var historyMap: [String: WatchHistoryEntry] = [:]
    private var lastSubscriptionIds: [String] = []
    private var continuationToken: String?
    private var isLoading = false
    private var loadGeneration = 0

    // Header / Category Chips
    private let headerContainer = NSView()
    private let headerTitle = makeLabel("Home", size: 20, weight: .bold)
    private let headerActionStack = NSStackView()
    private let chipsBar = NSView()
    private let chipsScroll = NSScrollView()
    private let chipsStack = NSStackView()
    private let chipsLeftBtn = makeSymbolButton("chevron.left", size: 14, color: YTTheme.textPrimary, tooltip: "Scroll categories left", hoverBg: YTTheme.surface)
    private let chipsRightBtn = makeSymbolButton("chevron.right", size: 14, color: YTTheme.textPrimary, tooltip: "Scroll categories right", hoverBg: YTTheme.surface)
    private var chipButtons: [String: PillButton] = [:]

    // Collection View
    private let scrollView = NSScrollView()
    private let collectionView = NSCollectionView()
    private let spinner: NSProgressIndicator = {
        let s = NSProgressIndicator()
        s.setAccessibilityLabel("Loading videos")
        return s
    }()
    private let emptyLabel = makeLabel("", size: 16, weight: .medium, color: YTTheme.textSecondary, maxLines: 3)
    private let retryBtn = PillButton()

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
        NotificationCenter.default.addObserver(self, selector: #selector(onStoreChanged), name: .liteTubeQueueDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateChipScrollButtons), name: NSView.boundsDidChangeNotification, object: chipsScroll.contentView)
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
        chipsBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(chipsBar)

        chipsScroll.hasHorizontalScroller = false
        chipsScroll.hasVerticalScroller = false
        chipsScroll.drawsBackground = false
        chipsScroll.contentView.postsBoundsChangedNotifications = true
        chipsScroll.translatesAutoresizingMaskIntoConstraints = false
        chipsBar.addSubview(chipsScroll)

        chipsLeftBtn.target = self; chipsLeftBtn.action = #selector(scrollChipsLeft)
        chipsLeftBtn.layer?.cornerRadius = 14
        chipsLeftBtn.layer?.borderWidth = 1
        chipsLeftBtn.isHidden = true
        chipsRightBtn.target = self; chipsRightBtn.action = #selector(scrollChipsRight)
        chipsRightBtn.layer?.cornerRadius = 14
        chipsRightBtn.layer?.borderWidth = 1
        chipsBar.addSubview(chipsLeftBtn)
        chipsBar.addSubview(chipsRightBtn)

        chipsStack.orientation = .horizontal
        chipsStack.spacing = 10
        chipsStack.edgeInsets = NSEdgeInsets(top: 6, left: 20, bottom: 6, right: 42)
        chipsStack.translatesAutoresizingMaskIntoConstraints = false
        chipsScroll.documentView = chipsStack
        // Pin the document's origin and height to the clip view; its width comes from the chips' intrinsic size.
        NSLayoutConstraint.activate([
            chipsStack.leadingAnchor.constraint(equalTo: chipsScroll.contentView.leadingAnchor),
            chipsStack.topAnchor.constraint(equalTo: chipsScroll.contentView.topAnchor),
            chipsStack.bottomAnchor.constraint(equalTo: chipsScroll.contentView.bottomAnchor)
        ])

        for cat in YouTubeAPI.exploreCategories {
            let btn = PillButton()
            btn.title = cat.name
            btn.cornerRadiusValue = IconScale.tabChipRadius
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
        layout.sectionInset = NSEdgeInsets(top: 14, left: 20, bottom: 28, right: 20)

        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = false
        collectionView.backgroundColors = [.clear]
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(VideoCardItem.self, forItemWithIdentifier: VideoCardItem.identifier)
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
        retryBtn.target = self; retryBtn.action = #selector(retryLoad)
        retryBtn.isHidden = true
        view.addSubview(retryBtn)

        headerHeightConstraint = headerContainer.heightAnchor.constraint(equalToConstant: 0)
        chipsHeightConstraint = chipsBar.heightAnchor.constraint(equalToConstant: 46)

        NSLayoutConstraint.activate([
            headerContainer.topAnchor.constraint(equalTo: view.topAnchor),
            headerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerHeightConstraint,

            headerTitle.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 20),
            headerTitle.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),
            headerActionStack.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor, constant: -20),
            headerActionStack.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),

            chipsBar.topAnchor.constraint(equalTo: headerContainer.bottomAnchor),
            chipsBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chipsBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chipsHeightConstraint,

            chipsLeftBtn.leadingAnchor.constraint(equalTo: chipsBar.leadingAnchor, constant: 8),
            chipsLeftBtn.centerYAnchor.constraint(equalTo: chipsBar.centerYAnchor),
            chipsLeftBtn.widthAnchor.constraint(equalToConstant: 28),
            chipsLeftBtn.heightAnchor.constraint(equalToConstant: 28),

            chipsRightBtn.trailingAnchor.constraint(equalTo: chipsBar.trailingAnchor, constant: -8),
            chipsRightBtn.centerYAnchor.constraint(equalTo: chipsBar.centerYAnchor),
            chipsRightBtn.widthAnchor.constraint(equalToConstant: 28),
            chipsRightBtn.heightAnchor.constraint(equalToConstant: 28),

            chipsScroll.topAnchor.constraint(equalTo: chipsBar.topAnchor),
            chipsScroll.bottomAnchor.constraint(equalTo: chipsBar.bottomAnchor),
            chipsScroll.leadingAnchor.constraint(equalTo: chipsBar.leadingAnchor),
            chipsScroll.trailingAnchor.constraint(equalTo: chipsBar.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: chipsBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            spinner.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            retryBtn.topAnchor.constraint(equalTo: emptyLabel.bottomAnchor, constant: 14),
            retryBtn.centerXAnchor.constraint(equalTo: emptyLabel.centerXAnchor)
        ])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        collectionView.collectionViewLayout?.invalidateLayout()
        updateChipScrollButtons()
    }

    @objc private func scrollChipsLeft() {
        let curX = chipsScroll.contentView.bounds.origin.x
        let nextX = max(0, curX - 240)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = motionDuration(0.2)
            chipsScroll.contentView.animator().setBoundsOrigin(NSPoint(x: nextX, y: 0))
        }
    }

    @objc private func scrollChipsRight() {
        let docW = chipsStack.fittingSize.width
        let visW = chipsScroll.contentView.bounds.width
        let maxX = max(0, docW - visW)
        let nextX = min(maxX, chipsScroll.contentView.bounds.origin.x + 240)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = motionDuration(0.2)
            chipsScroll.contentView.animator().setBoundsOrigin(NSPoint(x: nextX, y: 0))
        }
    }

    @objc private func updateChipScrollButtons() {
        let docW = chipsStack.fittingSize.width
        let visW = chipsScroll.contentView.bounds.width
        let curX = chipsScroll.contentView.bounds.origin.x
        let hideLeft = curX <= 2
        let hideRight = (docW <= visW + 2) || (curX >= docW - visW - 2)
        chipsLeftBtn.isHidden = hideLeft
        chipsRightBtn.isHidden = hideRight
    }

    // MARK: - Mode Loading

    func canReuseLoadedFeed(mode: FeedMode, category: String?) -> Bool {
        guard self.mode == mode, !videos.isEmpty else { return false }
        if case .home = mode, let cat = category {
            return activeCategory == cat
        }
        return true
    }

    var currentScrollY: CGFloat { scrollView.contentView.bounds.origin.y }

    func restoreScrollY(_ y: CGFloat) {
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func load(mode: FeedMode, category: String? = nil) {
        loadGeneration += 1
        retryBtn.title = "Try Again"
        retryBtn.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Try again")
        retryBtn.action = #selector(retryLoad)
        let gen = loadGeneration
        self.mode = mode
        if let cat = category {
            self.activeCategory = cat
        }
        continuationToken = nil
        isLoading = false
        spinner.stopAnimation(nil)
        emptyLabel.isHidden = true
        retryBtn.isHidden = true
        headerActionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        historyMap.removeAll()
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        switch mode {
        case .home:
            headerHeightConstraint.constant = 0
            chipsHeightConstraint.constant = 46
            headerContainer.isHidden = true
            chipsBar.isHidden = false
            loadCategory(activeCategory)

        case .explore(let cat):
            headerHeightConstraint.constant = 52
            chipsHeightConstraint.constant = 0
            headerContainer.isHidden = false
            chipsBar.isHidden = true
            headerTitle.stringValue = cat
            loadCategory(cat)

        case .subscriptions:
            headerHeightConstraint.constant = 52
            chipsHeightConstraint.constant = 0
            headerContainer.isHidden = false
            chipsBar.isHidden = true
            headerTitle.stringValue = "Subscriptions"
            let subs = LocalStore.shared.subscriptions
            lastSubscriptionIds = subs.map(\.id)
            if subs.isEmpty {
                videos = []
                collectionView.reloadData()
                emptyLabel.stringValue = "No subscriptions yet.\nOpen any video or channel and click Subscribe to build your feed."
                emptyLabel.isHidden = false
                // Nothing to retry here; the one useful action is to go somewhere that has videos.
                retryBtn.title = "Browse Home"
                retryBtn.image = NSImage(systemSymbolName: "house", accessibilityDescription: "Browse Home")
                retryBtn.action = #selector(browseHomeAction)
                retryBtn.isHidden = false
                return
            }
            let refreshBtn = makeActionPill("Refresh", symbol: "arrow.clockwise", action: #selector(reloadCurrentMode))
            headerActionStack.addArrangedSubview(refreshBtn)
            // Clear the previous feed so a spinner never sits over stale cards.
            videos = []
            collectionView.reloadData()
            spinner.startAnimation(nil)
            YouTubeAPI.shared.fetchSubscriptionsFeed(channels: subs) { [weak self] vids, failedChannels in
                guard let self = self, self.loadGeneration == gen, self.mode == .subscriptions else { return }
                self.spinner.stopAnimation(nil)
                self.videos = vids
                self.emptyLabel.isHidden = !vids.isEmpty
                self.retryBtn.isHidden = true
                let allFailed = vids.isEmpty && failedChannels > 0
                if allFailed {
                    showRetryableError(message: "Could not load your subscriptions. Check your connection.", label: self.emptyLabel, retryButton: self.retryBtn)
                } else if vids.isEmpty {
                    self.emptyLabel.stringValue = "No recent uploads from your subscriptions. Check back later or subscribe to more channels."
                    // Reloading is the one recovery action, so it is offered here too.
                    self.retryBtn.isHidden = false
                    postAccessibilityAnnouncement(self.emptyLabel.stringValue)
                } else if failedChannels > 0 {
                    // Some channels loaded; say so rather than presenting a partial feed as complete.
                    // Visible note so a partial feed is not presented as complete.
                    self.navDelegate?.showToastMessage("Some subscribed channels could not be loaded.")
                }
                self.collectionView.reloadData()
            }

        case .history:
            headerHeightConstraint.constant = 52
            chipsHeightConstraint.constant = 0
            headerContainer.isHidden = false
            chipsBar.isHidden = true
            headerTitle.stringValue = "Watch History"
            let pauseBtn = makeActionPill(LocalStore.shared.settings.pauseHistory ? "Resume History" : "Pause History", symbol: "pause.circle", action: #selector(togglePauseHistory))
            let clearBtn = makeActionPill("Clear History", symbol: "trash", action: #selector(clearHistoryClicked))
            headerActionStack.addArrangedSubview(pauseBtn)
            headerActionStack.addArrangedSubview(clearBtn)
            let entries = LocalStore.shared.history
            for e in entries { historyMap[e.video.id] = e }
            videos = entries.map(\.video)
            emptyLabel.stringValue = "Your watch history is empty. Videos you watch appear here."
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
                chipsBar.isHidden = true
                headerTitle.stringValue = name
                // Clear the previous feed so a spinner never sits over stale cards.
                videos = []
                collectionView.reloadData()
                spinner.startAnimation(nil)
                YouTubeAPI.shared.fetchPlaylist(playlistId: id) { [weak self] res in
                    guard let self = self, self.loadGeneration == gen else { return }
                    self.spinner.stopAnimation(nil)
                    switch res {
                    case .failure:
                        showRetryableError(message: "Could not load this playlist. Check your connection.", label: self.emptyLabel, retryButton: self.retryBtn)
                    case .success(let (t, vids)):
                        self.headerTitle.stringValue = t
                        self.videos = vids
                        self.headerActionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
                        if !vids.isEmpty {
                            self.headerActionStack.addArrangedSubview(self.makeActionPill("Play All", symbol: "play.fill", action: #selector(self.playAllClicked)))
                        }
                        self.emptyLabel.isHidden = !vids.isEmpty
                        if vids.isEmpty { self.emptyLabel.stringValue = "This playlist is empty." }
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
        chipsBar.isHidden = true
        headerTitle.stringValue = "\(title) (\(items.count))"
        videos = items
        if !items.isEmpty {
            headerActionStack.addArrangedSubview(makeActionPill("Play All", symbol: "play.fill", action: #selector(playAllClicked)))
        }
        emptyLabel.stringValue = empty
        emptyLabel.isHidden = !items.isEmpty
        collectionView.reloadData()
    }

    static func placeholderVideos() -> [VideoItem] {
        (0..<9).map { i in
            VideoItem(id: "placeholder-\(i)", title: "", channelName: "", channelId: "", channelAvatarURL: nil,
                      thumbnailURL: "", durationText: "", viewsText: "", publishedText: "")
        }
    }

    private func loadCategory(_ cat: String) {
        retryBtn.isHidden = true
        loadGeneration += 1
        let gen = loadGeneration
        activeCategory = cat
        continuationToken = nil
        isLoading = false
        emptyLabel.isHidden = true
        for (name, btn) in chipButtons { btn.isSelectedPill = (name == cat) }
        spinner.startAnimation(nil)
        // Placeholder cards hold the grid's shape while the feed loads, so the results do not jump into place.
        videos = Self.placeholderVideos()
        collectionView.reloadData()
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        YouTubeAPI.shared.fetchCategoryFeed(category: cat) { [weak self] res in
            guard let self = self, self.loadGeneration == gen else { return }
            self.spinner.stopAnimation(nil)
            switch res {
            case .failure:
                self.videos = []
                self.collectionView.reloadData()
                showRetryableError(message: "Could not load this feed. Check your connection.", label: self.emptyLabel, retryButton: self.retryBtn)
            case .success(let (vids, cont)):
                self.videos = vids
                self.continuationToken = cont
                self.emptyLabel.stringValue = "No videos found in this category. Try another category above."
                self.emptyLabel.isHidden = !vids.isEmpty
                self.collectionView.reloadData()
            }
        }
    }

    @objc private func categoryChipClicked(_ sender: PillButton) {
        loadCategory(sender.title)
        onCategorySelected?(sender.title)
    }

    @objc private func reloadCurrentMode() { load(mode: mode) }

    @objc private func playAllClicked() {
        guard let first = videos.first else { return }
        if !LocalStore.shared.queue.isEmpty,
           !confirmDestructive("Replace your queue?", detail: "Play All replaces the \(LocalStore.shared.queue.count) videos currently in your queue.", confirmTitle: "Replace Queue") {
            return
        }
        LocalStore.shared.setQueue(videos, startAt: 0)
        navDelegate?.openVideo(first, startSeconds: nil)
    }

    @objc private func togglePauseHistory() {
        var s = LocalStore.shared.settings
        s.pauseHistory.toggle()
        LocalStore.shared.settings = s
        load(mode: .history)
    }

    @objc private func browseHomeAction() {
        navDelegate?.showHome()
    }

    @objc private func retryLoad() {
        load(mode: mode, category: activeCategory)
    }

    @objc private func clearHistoryClicked() {
        guard confirmDestructive("Clear watch history?", detail: "This removes every video from your watch history. It can't be undone.", confirmTitle: "Clear History") else { return }
        LocalStore.shared.clearHistory()
        load(mode: .history)
    }

    @objc private func clearQueueClicked() {
        guard confirmDestructive("Clear the playback queue?", detail: "All videos in your queue will be removed. It can't be undone.", confirmTitle: "Clear Queue") else { return }
        LocalStore.shared.clearQueue()
        load(mode: .queue)
    }

    @objc private func deleteCurrentPlaylist() {
        if case .playlist(let id, let name) = mode {
            guard confirmDestructive("Delete \"\(name)\"?", detail: "This playlist and its videos will be removed. It can't be undone.", confirmTitle: "Delete Playlist") else { return }
            LocalStore.shared.deletePlaylist(id: id)
            navDelegate?.showHome()
        }
    }

    @objc private func loadMoreClicked() {
        guard let tok = continuationToken, !isLoading else { return }
        let gen = loadGeneration
        isLoading = true
        collectionView.reloadData()
        YouTubeAPI.shared.fetchBrowseContinuation(token: tok) { [weak self] res in
            guard let self = self, self.loadGeneration == gen else { return }
            self.isLoading = false
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

    @objc private func onStoreChanged() {
        switch mode {
        case .history:
            if let pauseBtn = headerActionStack.arrangedSubviews.first as? PillButton {
                let want = LocalStore.shared.settings.pauseHistory ? "Resume History" : "Pause History"
                if pauseBtn.title != want { pauseBtn.title = want }
            }
            let entries = LocalStore.shared.history
            historyMap.removeAll()
            for e in entries { historyMap[e.video.id] = e }
            let newVideos = entries.map(\.video)
            if newVideos.map(\.id) != videos.map(\.id) {
                videos = newVideos
                emptyLabel.isHidden = !videos.isEmpty
            }
            collectionView.reloadData()
        case .subscriptions:
            let curIds = LocalStore.shared.subscriptions.map(\.id)
            if curIds != lastSubscriptionIds {
                load(mode: .subscriptions)
            }
        case .watchLater:
            let items = LocalStore.shared.watchLater
            if items.map(\.id) != videos.map(\.id) {
                headerTitle.stringValue = "Watch Later (\(items.count))"
                videos = items
                emptyLabel.isHidden = !items.isEmpty
                collectionView.reloadData()
            }
        case .liked:
            let items = LocalStore.shared.likedVideos
            if items.map(\.id) != videos.map(\.id) {
                headerTitle.stringValue = "Liked Videos (\(items.count))"
                videos = items
                emptyLabel.isHidden = !items.isEmpty
                collectionView.reloadData()
            }
        case .queue:
            let items = LocalStore.shared.queue
            if items.map(\.id) != videos.map(\.id) {
                headerTitle.stringValue = "Queue · \(items.count) video\(items.count == 1 ? "" : "s")"
                videos = items
                emptyLabel.isHidden = !items.isEmpty
                collectionView.reloadData()
            }
        case .playlist(let id, _):
            if let localPl = LocalStore.shared.playlists.first(where: { $0.id == id }) {
                if localPl.videos.map(\.id) != videos.map(\.id) {
                    headerTitle.stringValue = "\(localPl.name) (\(localPl.videos.count))"
                    videos = localPl.videos
                    emptyLabel.isHidden = !localPl.videos.isEmpty
                    collectionView.reloadData()
                }
            }
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
        let cardW = GridLayoutHelper.cardWidth(forAvailableWidth: availW)
        return NSSize(width: cardW, height: VideoCardItem.preferredHeight(forCardWidth: cardW))
    }

    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, referenceSizeForFooterInSection section: Int) -> NSSize {
        continuationToken != nil ? NSSize(width: collectionView.bounds.width, height: 64) : .zero
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind, at indexPath: IndexPath) -> NSView {
        let footer = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: CollectionLoadMoreFooter.identifier, for: indexPath) as! CollectionLoadMoreFooter
        footer.button.title = isLoading ? "Loading…" : "Load more"
        footer.button.isEnabled = !isLoading
        footer.button.target = self
        footer.button.action = #selector(loadMoreClicked)
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
        if mode == .queue {
            menu.addItem(.separator())
            let rq = NSMenuItem(title: "Remove from Queue", action: #selector(ctxRemoveQueue(_:)), keyEquivalent: "")
            rq.target = self; rq.representedObject = video
            menu.addItem(rq)
        }

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: anchor)
    }

    @objc private func ctxRemoveQueue(_ s: NSMenuItem) {
        guard let v = s.representedObject as? VideoItem,
              let index = LocalStore.shared.queue.firstIndex(where: { $0.id == v.id }) else { return }
        LocalStore.shared.removeFromQueue(at: index)
        load(mode: .queue)
        navDelegate?.showToastMessage("Removed from Queue")
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
        emptyLabel.textColor = YTTheme.textSecondary
        chipsLeftBtn.contentTintColor = YTTheme.textPrimary
        chipsLeftBtn.normalBgColor = YTTheme.bgElevated
        chipsLeftBtn.hoverBgColor = YTTheme.surface
        chipsLeftBtn.layer?.backgroundColor = YTTheme.bgElevated.cgColor
        chipsLeftBtn.layer?.borderColor = YTTheme.border.cgColor
        chipsRightBtn.contentTintColor = YTTheme.textPrimary
        chipsRightBtn.normalBgColor = YTTheme.bgElevated
        chipsRightBtn.hoverBgColor = YTTheme.surface
        chipsRightBtn.layer?.backgroundColor = YTTheme.bgElevated.cgColor
        chipsRightBtn.layer?.borderColor = YTTheme.border.cgColor
        for btn in chipButtons.values {
            btn.normalBg = YTTheme.surface
            btn.activeBg = YTTheme.chipActiveBg
            btn.normalFg = YTTheme.textPrimary
            btn.activeFg = YTTheme.chipActiveText
            btn.updateStyle()
        }
        for case let btn as PillButton in headerActionStack.arrangedSubviews {
            btn.normalBg = YTTheme.surface
            btn.activeBg = YTTheme.chipActiveBg
            btn.normalFg = YTTheme.textPrimary
            btn.activeFg = YTTheme.chipActiveText
            btn.updateStyle()
        }
        collectionView.reloadData()
    }
}

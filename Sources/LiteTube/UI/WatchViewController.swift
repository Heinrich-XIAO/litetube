import AppKit

protocol WatchNavigationDelegate: AnyObject {
    func openVideo(_ video: VideoItem, startSeconds: Double?)
    func openChannel(channelId: String, name: String)
    func enterMiniplayer(with playerView: PlayerView, video: VideoItem)
    func updateCurrentVideoMetadata(video: VideoItem)
    func showToastMessage(_ message: String)
}

final class WatchViewController: NSViewController, PlayerViewDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    weak var navDelegate: WatchNavigationDelegate?

    let playerView = PlayerView()
    private var currentVideo: VideoItem?
    private var details: WatchDetails?
    private var isTheaterMode = false
    private var isDescriptionExpanded = false
    private var isAdjustingLayout = false
    private var loadGeneration = 0
    private var commentsGeneration = 0
    private var loadingReplyIndices: Set<Int> = []
    private var lastDescLayoutWidth: CGFloat = 0
    private var needsDescLayout = true

    // Main scroll layout
    private let scrollView = NSScrollView()
    private let docView = FlippedView()
    private let playerSlot = NSView()
    private var playerHeightConstraint: NSLayoutConstraint!
    private var wideNormalConstraints: [NSLayoutConstraint] = []
    private var wideTheaterConstraints: [NSLayoutConstraint] = []
    private var narrowStackedConstraints: [NSLayoutConstraint] = []
    private enum WatchLayoutMode { case wideNormal, wideTheater, narrowStacked }
    private var currentLayoutMode: WatchLayoutMode = .wideNormal

    // Main metadata & comments
    private let mainColumn = NSView()
    private let titleLabel = makeLabel("", size: 20, weight: .bold, maxLines: 2)
    private let avatarView = NSImageView()
    private let channelBtn = NSButton()
    private let subCountLabel = makeLabel("", size: 12, color: YTTheme.textSecondary)
    /// Channel name plus optional subscriber line. Plain constraints, not a stack, so every frame is determined.
    private let channelInfoBox = NSView()
    private var subCountTopConstraint: NSLayoutConstraint?
    private var channelBoxBottomConstraint: NSLayoutConstraint?
    private var subCountBottomConstraint: NSLayoutConstraint?
    private let subscribeBtn = PillButton()
    private let likeBtn = PillButton()
    private let shareBtn = PillButton()
    private let saveBtn = PillButton()
    private let queueBtn = PillButton()
    private let browserBtn = PillButton()
    private let metaBar = NSView()
    private let actionsStack = WrappingFlowView()
    private var metaWideConstraints: [NSLayoutConstraint] = []
    private var metaNarrowConstraints: [NSLayoutConstraint] = []

    private let descBox = NSView()
    private let descMetaLabel = makeLabel("", size: 14, weight: .semibold)
    private let descTextView = NSTextView()
    private var descTextHeightConstraint: NSLayoutConstraint!
    private let descToggleBtn = NSButton()
    private var descToggleTopConstraint: NSLayoutConstraint!
    private var descToggleHeightConstraint: NSLayoutConstraint!

    // Comments
    private let commentsHeaderLabel = makeLabel("Comments", size: 16, weight: .bold)
    private let sortTopBtn = PillButton()
    private let sortNewestBtn = PillButton()
    private let commentsStack = NSStackView()
    private let loadMoreCommentsBtn = PillButton()
    private var commentsBottomConstraint: NSLayoutConstraint!
    private var loadMoreCommentsBottomConstraint: NSLayoutConstraint!
    private var comments: [CommentItem] = []
    private var commentsContinuation: String?
    private var isLoadingComments = false

    // Right Sidebar: Up Next / Chapters / Transcript
    private let sidebarColumn = NSView()
    private let tabUpNextBtn = PillButton()
    private let tabChaptersBtn = PillButton()
    private let tabTranscriptBtn = PillButton()
    private let transcriptSearch = NSSearchField()
    private let queueHeaderView = NSView()
    private let queueCountLabel = makeLabel("", size: 12, weight: .semibold)
    private let clearQueueBtn = NSButton()
    private let sideTableScroll = PassThroughScrollView()
    private let sideTable = ActivatingTableView()
    private let sideEmptyLabel = makeLabel("", size: 14, color: YTTheme.textSecondary, maxLines: 2)
    private let loadMoreRelatedBtn = PillButton()

    private var sideTableTopNormal: NSLayoutConstraint!
    private var sideTableTopWithAux: NSLayoutConstraint!
    private var sideTableHeightConstraint: NSLayoutConstraint!
    private var sideTableBottomToSidebar: NSLayoutConstraint!
    private var loadMoreRelatedTopConstraint: NSLayoutConstraint!
    private var loadMoreRelatedBottomConstraint: NSLayoutConstraint!
    private enum SidebarTab { case upNext, chapters, transcript }
    private var activeSideTab: SidebarTab = .upNext
    private var relatedVideos: [VideoItem] = []
    private var relatedContinuation: String?
    private var filteredCues: [CaptionCue] = []
    private var lastRecordedHistorySec: Double = -99

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        self.view = root
        setupLayout()
        applyTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(onThemeChanged), name: .liteTubeThemeDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onQueueChanged), name: .liteTubeQueueDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onStoreChanged), name: .liteTubeStoreDidChange, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupLayout() {
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.addSubview(scrollView)

        docView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = docView

        // Player container
        playerSlot.wantsLayer = true
        playerSlot.layer?.cornerRadius = 12
        playerSlot.layer?.masksToBounds = true
        playerSlot.layer?.backgroundColor = NSColor.black.cgColor
        playerSlot.translatesAutoresizingMaskIntoConstraints = false
        docView.addSubview(playerSlot)

        playerView.delegate = self
        playerView.translatesAutoresizingMaskIntoConstraints = false
        attachPlayerView()

        // Main left column (metadata + description + comments)
        mainColumn.translatesAutoresizingMaskIntoConstraints = false
        docView.addSubview(mainColumn)

        avatarView.wantsLayer = true
        avatarView.layer?.cornerRadius = 20
        avatarView.layer?.masksToBounds = true
        avatarView.layer?.backgroundColor = YTTheme.surface.cgColor
        avatarView.imageScaling = .scaleProportionallyUpOrDown
        avatarView.setAccessibilityElement(false)
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        let avClick = NSClickGestureRecognizer(target: self, action: #selector(openCurrentChannel))
        avatarView.addGestureRecognizer(avClick)

        channelBtn.isBordered = false
        channelBtn.font = .systemFont(ofSize: 16, weight: .semibold)
        channelBtn.target = self; channelBtn.action = #selector(openCurrentChannel)
        channelBtn.translatesAutoresizingMaskIntoConstraints = false
        channelBtn.setContentHuggingPriority(.required, for: .horizontal)
        channelBtn.setContentHuggingPriority(.required, for: .vertical)
        // One line: the channel name is never squeezed into a wrap or an ellipsis by its neighbours.
        channelBtn.cell?.wraps = false
        channelBtn.setContentCompressionResistancePriority(.required, for: .horizontal)

        subscribeBtn.useDynamicThemeColors = true
        subscribeBtn.title = "Subscribe"
        subscribeBtn.cornerRadiusValue = 17
        subscribeBtn.setAccessibilityLabel("Subscribe")
        subscribeBtn.setContentCompressionResistancePriority(.required, for: .horizontal)
        subscribeBtn.target = self; subscribeBtn.action = #selector(toggleSubscribe)
        subscribeBtn.translatesAutoresizingMaskIntoConstraints = false

        // Every action pill shares one radius, at least half the 32pt pill height, so all are fully rounded.
        likeBtn.title = "Like"
        likeBtn.image = NSImage(systemSymbolName: "hand.thumbsup", accessibilityDescription: "Like")
        likeBtn.setAccessibilityLabel("Like")
        likeBtn.cornerRadiusValue = 17
        likeBtn.target = self; likeBtn.action = #selector(toggleLike)

        shareBtn.title = "Share"
        shareBtn.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share")
        shareBtn.cornerRadiusValue = 17
        shareBtn.target = self; shareBtn.action = #selector(shareClicked)

        saveBtn.title = "Save"
        saveBtn.image = NSImage(systemSymbolName: "bookmark", accessibilityDescription: "Save")
        saveBtn.cornerRadiusValue = 17
        saveBtn.target = self; saveBtn.action = #selector(saveClicked)

        queueBtn.title = "Queue"
        queueBtn.image = NSImage(systemSymbolName: "text.badge.plus", accessibilityDescription: "Add to Queue")
        queueBtn.setAccessibilityLabel("Add to Queue")
        queueBtn.toolTip = "Add this video to the queue"
        queueBtn.cornerRadiusValue = 17
        queueBtn.target = self; queueBtn.action = #selector(addCurrentToQueue)

        // Icon-only: a square pill with the standard "open externally" glyph. The compass read as "explore".
        browserBtn.title = ""
        browserBtn.image = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: "Open in default browser")
        browserBtn.toolTip = "Open in default browser"
        browserBtn.setAccessibilityLabel("Open in default browser")
        browserBtn.cornerRadiusValue = 17
        browserBtn.target = self; browserBtn.action = #selector(openInBrowser)

        subCountLabel.setContentHuggingPriority(.required, for: .horizontal)
        subCountLabel.setContentHuggingPriority(.required, for: .vertical)
        channelInfoBox.translatesAutoresizingMaskIntoConstraints = false
        channelInfoBox.addSubview(channelBtn)
        NSLayoutConstraint.activate([
            channelBtn.topAnchor.constraint(equalTo: channelInfoBox.topAnchor),
            channelBtn.leadingAnchor.constraint(equalTo: channelInfoBox.leadingAnchor),
            channelInfoBox.widthAnchor.constraint(equalTo: channelBtn.widthAnchor),
        ])
        channelBoxBottomConstraint = channelInfoBox.bottomAnchor.constraint(equalTo: channelBtn.bottomAnchor)
        channelBoxBottomConstraint?.isActive = true

        let leftMeta = NSStackView(views: [avatarView, channelInfoBox, subscribeBtn])
        leftMeta.orientation = .horizontal
        leftMeta.spacing = 10
        leftMeta.alignment = .centerY
        leftMeta.translatesAutoresizingMaskIntoConstraints = false

        actionsStack.horizontalSpacing = 8
        actionsStack.verticalSpacing = 8
        actionsStack.alignRight = true
        for pill in [likeBtn, shareBtn, saveBtn, queueBtn, browserBtn] {
            actionsStack.addSubview(pill)
        }
        actionsStack.translatesAutoresizingMaskIntoConstraints = false

        metaBar.translatesAutoresizingMaskIntoConstraints = false
        metaBar.addSubview(leftMeta)
        metaBar.addSubview(actionsStack)

        // The bar is as tall as the actions stack (high priority) but never shorter than the left block.
        // Without the equality, the bar's height is under-determined and the layout is ambiguous.
        let metaBarFollowsActions = metaBar.bottomAnchor.constraint(equalTo: actionsStack.bottomAnchor)
        metaBarFollowsActions.priority = .defaultHigh
        metaWideConstraints = [
            leftMeta.topAnchor.constraint(equalTo: metaBar.topAnchor),
            leftMeta.leadingAnchor.constraint(equalTo: metaBar.leadingAnchor),
            metaBar.bottomAnchor.constraint(greaterThanOrEqualTo: leftMeta.bottomAnchor),
            actionsStack.topAnchor.constraint(equalTo: metaBar.topAnchor),
            actionsStack.trailingAnchor.constraint(equalTo: metaBar.trailingAnchor),
            actionsStack.leadingAnchor.constraint(equalTo: leftMeta.trailingAnchor, constant: 12).withPriority(.defaultHigh),
            metaBarFollowsActions
        ]
        metaNarrowConstraints = [
            leftMeta.topAnchor.constraint(equalTo: metaBar.topAnchor),
            leftMeta.leadingAnchor.constraint(equalTo: metaBar.leadingAnchor),
            leftMeta.trailingAnchor.constraint(lessThanOrEqualTo: metaBar.trailingAnchor),
            actionsStack.topAnchor.constraint(equalTo: leftMeta.bottomAnchor, constant: 10),
            actionsStack.leadingAnchor.constraint(equalTo: metaBar.leadingAnchor),
            actionsStack.trailingAnchor.constraint(equalTo: metaBar.trailingAnchor),
            actionsStack.bottomAnchor.constraint(equalTo: metaBar.bottomAnchor)
        ]
        NSLayoutConstraint.activate(metaWideConstraints)

        // Description box
        descBox.wantsLayer = true
        descBox.layer?.cornerRadius = 12
        descBox.translatesAutoresizingMaskIntoConstraints = false

        descTextView.isEditable = false
        descTextView.isSelectable = true
        descTextView.isVerticallyResizable = false
        descTextView.wantsLayer = true
        descTextView.layer?.masksToBounds = true
        descTextView.drawsBackground = false
        descTextView.textContainerInset = .zero
        descTextView.textContainer?.lineFragmentPadding = 0
        descTextView.textContainer?.widthTracksTextView = true
        descTextView.delegate = self
        descTextView.translatesAutoresizingMaskIntoConstraints = false

        descToggleBtn.isBordered = false
        setDescToggleTitle("…more")
        descToggleBtn.font = .systemFont(ofSize: 14, weight: .semibold)
        descToggleBtn.target = self; descToggleBtn.action = #selector(toggleDescription)
        descToggleBtn.translatesAutoresizingMaskIntoConstraints = false

        descBox.addSubview(descMetaLabel)
        descBox.addSubview(descTextView)
        descBox.addSubview(descToggleBtn)

        // Comments header + sort
        sortTopBtn.title = "Top"
        sortTopBtn.setAccessibilityLabel("Sort comments by top")
        sortTopBtn.isSelectedPill = true
        sortTopBtn.cornerRadiusValue = 14
        sortTopBtn.target = self; sortTopBtn.action = #selector(sortCommentsTop)

        sortNewestBtn.title = "Newest"
        sortNewestBtn.setAccessibilityLabel("Sort comments by newest")
        sortNewestBtn.cornerRadiusValue = 14
        sortNewestBtn.target = self; sortNewestBtn.action = #selector(sortCommentsNewest)

        let cHeaderStack = NSStackView(views: [commentsHeaderLabel, sortTopBtn, sortNewestBtn])
        cHeaderStack.orientation = .horizontal
        cHeaderStack.spacing = 10
        cHeaderStack.alignment = .centerY
        cHeaderStack.translatesAutoresizingMaskIntoConstraints = false

        commentsStack.orientation = .vertical
        commentsStack.alignment = .leading
        commentsStack.spacing = 14
        commentsStack.translatesAutoresizingMaskIntoConstraints = false

        loadMoreCommentsBtn.title = "Load more comments"
        loadMoreCommentsBtn.cornerRadiusValue = 16
        loadMoreCommentsBtn.target = self; loadMoreCommentsBtn.action = #selector(loadMoreComments)
        loadMoreCommentsBtn.isHidden = true
        loadMoreCommentsBtn.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        descMetaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        mainColumn.addSubview(titleLabel)
        mainColumn.addSubview(metaBar)
        mainColumn.addSubview(descBox)
        mainColumn.addSubview(cHeaderStack)
        mainColumn.addSubview(commentsStack)
        mainColumn.addSubview(loadMoreCommentsBtn)

        // Right Sidebar (Up Next / Chapters / Transcript)
        sidebarColumn.translatesAutoresizingMaskIntoConstraints = false
        docView.addSubview(sidebarColumn)

        tabUpNextBtn.title = "Up Next"
        tabUpNextBtn.isSelectedPill = true
        tabUpNextBtn.cornerRadiusValue = 14
        tabUpNextBtn.target = self; tabUpNextBtn.action = #selector(selectUpNextTab)

        tabChaptersBtn.title = "Chapters"
        tabChaptersBtn.cornerRadiusValue = 14
        tabChaptersBtn.target = self; tabChaptersBtn.action = #selector(selectChaptersTab)

        tabTranscriptBtn.title = "Transcript"
        tabTranscriptBtn.cornerRadiusValue = 14
        tabTranscriptBtn.target = self; tabTranscriptBtn.action = #selector(selectTranscriptTab)

        let tabStack = NSStackView(views: [tabUpNextBtn, tabChaptersBtn, tabTranscriptBtn])
        tabStack.orientation = .horizontal
        tabStack.spacing = 8
        tabStack.translatesAutoresizingMaskIntoConstraints = false
        sidebarColumn.addSubview(tabStack)

        transcriptSearch.placeholderString = "Search transcript..."
        transcriptSearch.setAccessibilityLabel("Search transcript")
        transcriptSearch.delegate = self
        transcriptSearch.isHidden = true
        transcriptSearch.translatesAutoresizingMaskIntoConstraints = false
        sidebarColumn.addSubview(transcriptSearch)

        queueHeaderView.wantsLayer = true
        queueHeaderView.layer?.cornerRadius = 8
        queueHeaderView.isHidden = true
        queueHeaderView.translatesAutoresizingMaskIntoConstraints = false
        clearQueueBtn.title = "Clear"
        clearQueueBtn.setAccessibilityLabel("Clear queue")
        clearQueueBtn.toolTip = "Clear queue"
        clearQueueBtn.isBordered = false
        clearQueueBtn.font = .systemFont(ofSize: 12, weight: .semibold)
        clearQueueBtn.target = self; clearQueueBtn.action = #selector(clearQueueClicked)
        clearQueueBtn.translatesAutoresizingMaskIntoConstraints = false
        queueHeaderView.addSubview(queueCountLabel)
        queueHeaderView.addSubview(clearQueueBtn)
        sidebarColumn.addSubview(queueHeaderView)

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("side"))
        col.resizingMask = .autoresizingMask
        sideTable.addTableColumn(col)
        sideTable.headerView = nil
        sideTable.backgroundColor = .clear
        sideTable.selectionHighlightStyle = .regular
        sideTable.intercellSpacing = NSSize(width: 0, height: 8)
        sideTable.dataSource = self
        sideTable.delegate = self
        sideTable.action = #selector(sideTableClicked)
        sideTable.target = self
        sideTable.onActivateRow = { [weak self] row in
            self?.activateSideTableRow(row)
        }
        sideTable.activatesOnSpace = false

        sideTableScroll.documentView = sideTable
        sideTableScroll.hasVerticalScroller = true
        sideTableScroll.scrollerStyle = .overlay
        sideTableScroll.drawsBackground = false
        sideTableScroll.translatesAutoresizingMaskIntoConstraints = false
        sidebarColumn.addSubview(sideTableScroll)

        sideEmptyLabel.alignment = .center
        sideEmptyLabel.isHidden = true
        sidebarColumn.addSubview(sideEmptyLabel)

        loadMoreRelatedBtn.title = "Show more related"
        loadMoreRelatedBtn.cornerRadiusValue = 14
        loadMoreRelatedBtn.target = self; loadMoreRelatedBtn.action = #selector(loadMoreRelated)
        loadMoreRelatedBtn.isHidden = true
        loadMoreRelatedBtn.translatesAutoresizingMaskIntoConstraints = false
        sidebarColumn.addSubview(loadMoreRelatedBtn)

        playerHeightConstraint = playerSlot.heightAnchor.constraint(equalToConstant: 460)
        descTextHeightConstraint = descTextView.heightAnchor.constraint(equalToConstant: 54)
        descToggleTopConstraint = descToggleBtn.topAnchor.constraint(equalTo: descTextView.bottomAnchor, constant: 6)
        descToggleHeightConstraint = descToggleBtn.heightAnchor.constraint(equalToConstant: 18)
        sideTableHeightConstraint = sideTableScroll.heightAnchor.constraint(equalToConstant: 420)

        let playerTrailingSidebar = playerSlot.trailingAnchor.constraint(equalTo: sidebarColumn.leadingAnchor, constant: -20)
        let playerTrailingFull = playerSlot.trailingAnchor.constraint(equalTo: docView.trailingAnchor, constant: -20)
        let mainTrailingSidebar = mainColumn.trailingAnchor.constraint(equalTo: sidebarColumn.leadingAnchor, constant: -20)
        let mainTrailingFull = mainColumn.trailingAnchor.constraint(equalTo: docView.trailingAnchor, constant: -20)
        let sidebarWidth = sidebarColumn.widthAnchor.constraint(equalToConstant: 375)

        wideNormalConstraints = [
            playerTrailingSidebar,
            mainTrailingSidebar,
            mainColumn.bottomAnchor.constraint(lessThanOrEqualTo: docView.bottomAnchor, constant: -32),
            sidebarColumn.topAnchor.constraint(equalTo: docView.topAnchor, constant: 16),
            sidebarWidth,
            sidebarColumn.bottomAnchor.constraint(lessThanOrEqualTo: docView.bottomAnchor, constant: -32)
        ]
        wideTheaterConstraints = [
            playerTrailingFull,
            mainTrailingSidebar,
            mainColumn.bottomAnchor.constraint(lessThanOrEqualTo: docView.bottomAnchor, constant: -32),
            sidebarColumn.topAnchor.constraint(equalTo: playerSlot.bottomAnchor, constant: 16),
            sidebarWidth,
            sidebarColumn.bottomAnchor.constraint(lessThanOrEqualTo: docView.bottomAnchor, constant: -32)
        ]
        narrowStackedConstraints = [
            playerTrailingFull,
            mainTrailingFull,
            sidebarColumn.topAnchor.constraint(equalTo: mainColumn.bottomAnchor, constant: 20),
            sidebarColumn.leadingAnchor.constraint(equalTo: docView.leadingAnchor, constant: 20),
            sidebarColumn.bottomAnchor.constraint(lessThanOrEqualTo: docView.bottomAnchor, constant: -32)
        ]

        sideTableTopNormal = sideTableScroll.topAnchor.constraint(equalTo: tabStack.bottomAnchor, constant: 12)
        sideTableTopWithAux = sideTableScroll.topAnchor.constraint(equalTo: tabStack.bottomAnchor, constant: 48)
        sideTableBottomToSidebar = sideTableScroll.bottomAnchor.constraint(equalTo: sidebarColumn.bottomAnchor)
        loadMoreRelatedTopConstraint = loadMoreRelatedBtn.topAnchor.constraint(equalTo: sideTableScroll.bottomAnchor, constant: 10)
        commentsBottomConstraint = commentsStack.bottomAnchor.constraint(equalTo: mainColumn.bottomAnchor, constant: -16)
        loadMoreCommentsBottomConstraint = loadMoreCommentsBtn.bottomAnchor.constraint(equalTo: mainColumn.bottomAnchor, constant: -16)
        loadMoreRelatedBottomConstraint = loadMoreRelatedBtn.bottomAnchor.constraint(equalTo: sidebarColumn.bottomAnchor)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            docView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            docView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            docView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            // Pin the document height so it isn't ambiguous: follow the main column, but never cut off the sidebar.
            docView.bottomAnchor.constraint(equalTo: mainColumn.bottomAnchor, constant: 32).withPriority(.defaultHigh),
            docView.bottomAnchor.constraint(greaterThanOrEqualTo: sidebarColumn.bottomAnchor, constant: 32),

            // Player slot
            playerSlot.topAnchor.constraint(equalTo: docView.topAnchor, constant: 16),
            playerSlot.leadingAnchor.constraint(equalTo: docView.leadingAnchor, constant: 20),
            playerHeightConstraint,

            // Main column below player
            mainColumn.topAnchor.constraint(equalTo: playerSlot.bottomAnchor, constant: 14),
            mainColumn.leadingAnchor.constraint(equalTo: docView.leadingAnchor, constant: 20),

            avatarView.widthAnchor.constraint(equalToConstant: 40),
            avatarView.heightAnchor.constraint(equalToConstant: 40),

            titleLabel.topAnchor.constraint(equalTo: mainColumn.topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: mainColumn.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: mainColumn.trailingAnchor),

            metaBar.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            metaBar.leadingAnchor.constraint(equalTo: mainColumn.leadingAnchor),
            metaBar.trailingAnchor.constraint(equalTo: mainColumn.trailingAnchor),

            descBox.topAnchor.constraint(equalTo: metaBar.bottomAnchor, constant: 14),
            descBox.leadingAnchor.constraint(equalTo: mainColumn.leadingAnchor),
            descBox.trailingAnchor.constraint(equalTo: mainColumn.trailingAnchor),

            descMetaLabel.topAnchor.constraint(equalTo: descBox.topAnchor, constant: 12),
            descMetaLabel.leadingAnchor.constraint(equalTo: descBox.leadingAnchor, constant: 14),
            descMetaLabel.trailingAnchor.constraint(equalTo: descBox.trailingAnchor, constant: -14),

            descTextView.topAnchor.constraint(equalTo: descMetaLabel.bottomAnchor, constant: 6),
            descTextView.leadingAnchor.constraint(equalTo: descBox.leadingAnchor, constant: 14),
            descTextView.trailingAnchor.constraint(equalTo: descBox.trailingAnchor, constant: -14),
            descTextHeightConstraint,

            descToggleTopConstraint,
            descToggleHeightConstraint,
            descToggleBtn.leadingAnchor.constraint(equalTo: descBox.leadingAnchor, constant: 14),
            descToggleBtn.bottomAnchor.constraint(equalTo: descBox.bottomAnchor, constant: -10),

            cHeaderStack.topAnchor.constraint(equalTo: descBox.bottomAnchor, constant: 22),
            cHeaderStack.leadingAnchor.constraint(equalTo: mainColumn.leadingAnchor),

            commentsStack.topAnchor.constraint(equalTo: cHeaderStack.bottomAnchor, constant: 14),
            commentsStack.leadingAnchor.constraint(equalTo: mainColumn.leadingAnchor),
            commentsStack.trailingAnchor.constraint(equalTo: mainColumn.trailingAnchor),

            loadMoreCommentsBtn.topAnchor.constraint(equalTo: commentsStack.bottomAnchor, constant: 14),
            loadMoreCommentsBtn.centerXAnchor.constraint(equalTo: mainColumn.centerXAnchor),
            commentsBottomConstraint,

            // Sidebar column
            sidebarColumn.trailingAnchor.constraint(equalTo: docView.trailingAnchor, constant: -20),

            tabStack.topAnchor.constraint(equalTo: sidebarColumn.topAnchor),
            tabStack.leadingAnchor.constraint(equalTo: sidebarColumn.leadingAnchor),

            transcriptSearch.topAnchor.constraint(equalTo: tabStack.bottomAnchor, constant: 10),
            transcriptSearch.leadingAnchor.constraint(equalTo: sidebarColumn.leadingAnchor),
            transcriptSearch.trailingAnchor.constraint(equalTo: sidebarColumn.trailingAnchor),

            queueHeaderView.topAnchor.constraint(equalTo: tabStack.bottomAnchor, constant: 10),
            queueHeaderView.leadingAnchor.constraint(equalTo: sidebarColumn.leadingAnchor),
            queueHeaderView.trailingAnchor.constraint(equalTo: sidebarColumn.trailingAnchor),
            queueHeaderView.heightAnchor.constraint(equalToConstant: 32),
            queueCountLabel.leadingAnchor.constraint(equalTo: queueHeaderView.leadingAnchor, constant: 10),
            queueCountLabel.centerYAnchor.constraint(equalTo: queueHeaderView.centerYAnchor),
            clearQueueBtn.trailingAnchor.constraint(equalTo: queueHeaderView.trailingAnchor, constant: -10),
            clearQueueBtn.centerYAnchor.constraint(equalTo: queueHeaderView.centerYAnchor),

            sideTableTopNormal,
            sideTableScroll.leadingAnchor.constraint(equalTo: sidebarColumn.leadingAnchor),
            sideTableScroll.trailingAnchor.constraint(equalTo: sidebarColumn.trailingAnchor),
            sideTableHeightConstraint,
            sideTableBottomToSidebar,

            sideEmptyLabel.centerXAnchor.constraint(equalTo: sideTableScroll.centerXAnchor),
            sideEmptyLabel.centerYAnchor.constraint(equalTo: sideTableScroll.centerYAnchor),
            sideEmptyLabel.widthAnchor.constraint(lessThanOrEqualTo: sideTableScroll.widthAnchor, constant: -24),

            loadMoreRelatedBtn.centerXAnchor.constraint(equalTo: sidebarColumn.centerXAnchor)
        ])
        NSLayoutConstraint.activate(wideNormalConstraints)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !isAdjustingLayout else { return }
        updateResponsiveLayoutMode()
        updatePlayerAspectHeight()
        let isNarrowMeta = mainColumn.bounds.width > 0 && mainColumn.bounds.width < 680
        if isNarrowMeta && metaWideConstraints.first?.isActive == true {
            actionsStack.alignRight = false
            actionsStack.needsLayout = true
            NSLayoutConstraint.deactivate(metaWideConstraints)
            NSLayoutConstraint.activate(metaNarrowConstraints)
            isAdjustingLayout = true
            mainColumn.layoutSubtreeIfNeeded()
            isAdjustingLayout = false
        } else if !isNarrowMeta && metaNarrowConstraints.first?.isActive == true {
            actionsStack.alignRight = true
            actionsStack.needsLayout = true
            NSLayoutConstraint.deactivate(metaNarrowConstraints)
            NSLayoutConstraint.activate(metaWideConstraints)
            isAdjustingLayout = true
            mainColumn.layoutSubtreeIfNeeded()
            isAdjustingLayout = false
        }
        updateDescriptionHeight()
    }

    private func updateResponsiveLayoutMode() {
        let w = view.bounds.width
        let targetMode: WatchLayoutMode
        if w > 0 && w < 1040 {
            targetMode = .narrowStacked
        } else if isTheaterMode {
            targetMode = .wideTheater
        } else {
            targetMode = .wideNormal
        }
        playerView.theaterSupported = (targetMode != .narrowStacked)
        guard targetMode != currentLayoutMode else { return }
        currentLayoutMode = targetMode
        NSLayoutConstraint.deactivate(wideNormalConstraints + wideTheaterConstraints + narrowStackedConstraints)
        switch targetMode {
        case .wideNormal: NSLayoutConstraint.activate(wideNormalConstraints)
        case .wideTheater: NSLayoutConstraint.activate(wideTheaterConstraints)
        case .narrowStacked: NSLayoutConstraint.activate(narrowStackedConstraints)
        }
        isAdjustingLayout = true
        docView.layoutSubtreeIfNeeded()
        isAdjustingLayout = false
    }

    private func updatePlayerAspectHeight() {
        let w = playerSlot.bounds.width
        guard w > 100 else { return }
        let ideal = w * 9.0 / 16.0
        let maxH = isTheaterMode ? max(520, view.bounds.height * 0.78) : max(420, view.bounds.height * 0.68)
        playerHeightConstraint.constant = min(ideal, maxH)
    }

    func attachPlayerView() {
        playerView.removeFromSuperview()
        playerView.setMiniMode(false)
        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerSlot.addSubview(playerView)
        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: playerSlot.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: playerSlot.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: playerSlot.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: playerSlot.bottomAnchor)
        ])
    }

    private func setChannelButtonTitle(_ text: String) {
        channelBtn.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .foregroundColor: YTTheme.textPrimary,
                .font: NSFont.systemFont(ofSize: 16, weight: .semibold)
            ]
        )
    }

    // MARK: - Open Video

    func loadVideo(_ video: VideoItem, startSeconds: Double? = nil) {
        loadGeneration += 1
        commentsGeneration += 1
        let gen = loadGeneration
        currentVideo = video
        details = nil
        comments = []
        commentsContinuation = nil
        commentsGeneration += 1
        loadingReplyIndices.removeAll()
        isLoadingComments = false
        relatedVideos = []
        relatedContinuation = nil
        filteredCues = []
        transcriptSearch.stringValue = ""
        isDescriptionExpanded = false
        lastRecordedHistorySec = -99
        sortTopBtn.isSelectedPill = true
        sortNewestBtn.isSelectedPill = false
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        attachPlayerView()
        titleLabel.stringValue = video.title.isEmpty ? "Loading..." : video.title
        // The title is capped at two lines, so the full text is offered as a tooltip.
        titleLabel.toolTip = video.title
        avatarView.image = nil
        setChannelButtonTitle(video.channelName)
        setSubscriberCount("")
        likeBtn.title = "Like"
        tabChaptersBtn.title = "Chapters"
        setLoadMoreRelatedVisible(false)
        setLoadMoreCommentsVisible(false)
        descMetaLabel.stringValue = [video.viewsText, video.publishedText].filter { !$0.isEmpty }.joined(separator: "  •  ")
        setDescriptionText(video.descriptionSnippet)
        commentsHeaderLabel.stringValue = "Comments"
        rebuildCommentsStack()
        updateActionButtons()
        reloadSideTable()

        // 1. Start native HLS stream immediately
        playerView.loadVideo(video, startSeconds: startSeconds)

        // 2. Fetch full Watch page metadata, chapters, related videos, and comments token
        YouTubeAPI.shared.fetchWatchDetails(videoId: video.id) { [weak self] res in
            guard let self = self, self.loadGeneration == gen, self.currentVideo?.id == video.id else { return }
            switch res {
            case .failure: self.navDelegate?.showToastMessage("Could not load video details.")
            case .success(let d):
                self.details = d
                if !d.title.isEmpty {
                    self.titleLabel.stringValue = d.title
                    self.currentVideo?.title = d.title
                }
                if !d.channelName.isEmpty {
                    self.setChannelButtonTitle(d.isVerified ? "\(d.channelName) ✓" : d.channelName)
                    self.currentVideo?.channelName = d.channelName
                }
                if !d.channelId.isEmpty { self.currentVideo?.channelId = d.channelId }
                if !d.channelAvatarURL.isEmpty {
                    self.currentVideo?.channelAvatarURL = d.channelAvatarURL
                    ImageCache.shared.load(d.channelAvatarURL, maxPixelSize: 80) { [weak self] img in
                        guard let self = self, self.loadGeneration == gen, self.currentVideo?.id == video.id else { return }
                        self.avatarView.image = img
                    }
                }
                self.setSubscriberCount(d.subscriberCountText)
                self.likeBtn.title = d.likeCountText.isEmpty ? "Like" : d.likeCountText
                // The visible title is a bare number, so the tooltip says what it counts.
                self.likeBtn.toolTip = d.likeCountText.isEmpty ? "Like" : "\(d.likeCountText) likes"
                // The count is part of the spoken state, since the visible title is a number.
                let liked = LocalStore.shared.isLiked(video.id)
                self.likeBtn.stateValue = [liked ? "Liked" : "Not liked", d.likeCountText.isEmpty ? nil : "\(d.likeCountText) likes"].compactMap { $0 }.joined(separator: ", ")
                self.descMetaLabel.stringValue = [d.viewCountText, d.dateText.isEmpty ? d.relativeDateText : d.dateText]
                    .filter { !$0.isEmpty }.joined(separator: "  •  ")
                self.setDescriptionText(d.descriptionText)
                self.commentsHeaderLabel.stringValue = d.commentCountText.isEmpty ? "Comments" : "\(d.commentCountText) Comments"

                self.playerView.updateChapters(d.chapters)
                self.tabChaptersBtn.title = d.chapters.isEmpty ? "Chapters" : "Chapters (\(d.chapters.count))"

                self.relatedVideos = d.relatedVideos
                self.relatedContinuation = d.relatedContinuation
                self.setLoadMoreRelatedVisible(d.relatedContinuation != nil && self.activeSideTab == .upNext)
                self.reloadSideTable()
                self.updateActionButtons()
                if let resolved = self.currentVideo {
                    self.navDelegate?.updateCurrentVideoMetadata(video: resolved)
                }

                if let tok = d.commentsContinuation {
                    self.loadComments(token: tok, replace: true)
                }
            }
        }
    }

    // MARK: - Description with Clickable Timestamps

    private func setDescriptionText(_ raw: String) {
        let attr = NSMutableAttributedString(
            string: raw,
            attributes: [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: YTTheme.textPrimary
            ]
        )
        // Highlight timestamps like 1:23 or 25:58 as clickable litetube-seek:// links
        let ns = raw as NSString
        if let tsRegex = try? NSRegularExpression(pattern: #"\b(\d{1,2}:\d{2}(?::\d{2})?)\b"#) {
            tsRegex.enumerateMatches(in: raw, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m = m else { return }
                let ts = ns.substring(with: m.range(at: 1))
                if let sec = Formatters.parseTimestamp(ts) {
                    attr.addAttributes([
                        .link: URL(string: "litetube-seek://\(Int(sec))")!,
                        .foregroundColor: YTTheme.linkBlue
                    ], range: m.range(at: 1))
                }
            }
        }
        // Highlight URLs
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            detector.enumerateMatches(in: raw, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m = m, let url = m.url else { return }
                attr.addAttributes([.link: url, .foregroundColor: YTTheme.linkBlue], range: m.range)
            }
        }
        descTextView.textStorage?.setAttributedString(attr)
        needsDescLayout = true
        updateDescriptionHeight()
    }

    private func updateDescriptionHeight() {
        guard let lm = descTextView.layoutManager, let tc = descTextView.textContainer else { return }
        let targetWidth = max(120, descTextView.bounds.width)
        guard needsDescLayout || abs(targetWidth - lastDescLayoutWidth) > 0.5 else { return }
        lastDescLayoutWidth = targetWidth
        needsDescLayout = false
        tc.maximumNumberOfLines = 0
        tc.lineBreakMode = .byWordWrapping
        lm.ensureLayout(for: tc)

        var lineCount = 0
        var threeLineMaxY: CGFloat = 0
        let totalRange = lm.glyphRange(for: tc)
        lm.enumerateLineFragments(forGlyphRange: totalRange) { _, usedRect, _, _, stop in
            lineCount += 1
            if lineCount <= 3 {
                threeLineMaxY = usedRect.maxY
            }
            if lineCount > 3 {
                stop.pointee = true
            }
        }
        let fullUsed = lm.usedRect(for: tc).height
        let hasOverflow = lineCount > 3

        if !hasOverflow {
            descTextHeightConstraint.constant = max(18, ceil(fullUsed) + 2)
            descToggleBtn.isHidden = true
            descToggleTopConstraint.constant = 0
            descToggleHeightConstraint.constant = 0
        } else if isDescriptionExpanded {
            descTextHeightConstraint.constant = max(54, ceil(fullUsed) + 8)
            descToggleBtn.isHidden = false
            descToggleTopConstraint.constant = 6
            descToggleHeightConstraint.constant = 18
            setDescToggleTitle("Show less")
        } else {
            tc.maximumNumberOfLines = 3
            tc.lineBreakMode = .byTruncatingTail
            lm.ensureLayout(for: tc)
            let clippedH = lm.usedRect(for: tc).height
            descTextHeightConstraint.constant = max(18, ceil(min(threeLineMaxY, clippedH)) + 2)
            descToggleBtn.isHidden = false
            descToggleTopConstraint.constant = 6
            descToggleHeightConstraint.constant = 18
            setDescToggleTitle("…more")
        }
    }

    private func setDescToggleTitle(_ text: String) {
        // Name the action and its state for VoiceOver, not just the visible glyphs.
        descToggleBtn.setAccessibilityLabel(text == "Show less" ? "Show less description" : "Show full description")
        descToggleBtn.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                // Link colour, so the toggle reads as tappable rather than as body text.
                .foregroundColor: YTTheme.linkBlue,
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
            ]
        )
    }

    @objc private func toggleDescription() {
        isDescriptionExpanded.toggle()
        needsDescLayout = true
        updateDescriptionHeight()
    }

    // MARK: - Comments

    private func setLoadMoreCommentsVisible(_ visible: Bool) {
        loadMoreCommentsBtn.isHidden = !visible
        commentsBottomConstraint.isActive = !visible
        loadMoreCommentsBottomConstraint.isActive = visible
    }

    private func loadComments(token: String, replace: Bool) {
        if !replace && isLoadingComments { return }
        commentsGeneration += 1
        if replace { loadingReplyIndices.removeAll() }
        let gen = loadGeneration
        let cGen = commentsGeneration
        isLoadingComments = true
        YouTubeAPI.shared.fetchComments(continuation: token) { [weak self] res in
            guard let self = self, self.loadGeneration == gen, self.commentsGeneration == cGen else { return }
            self.isLoadingComments = false
            switch res {
            case .failure:
                // The continuation token is kept, so the inline Try Again button repeats the same request.
                // The status follows the comment count rather than replacing it.
                let count = self.details?.commentCountText ?? ""
                self.commentsHeaderLabel.stringValue = count.isEmpty ? "Could not load comments." : "\(count) Comments · Could not load more"
                self.loadMoreCommentsBtn.title = "Try Again"
                self.setLoadMoreCommentsVisible(true)
                postAccessibilityAnnouncement("Could not load comments")
            case .success(let (newComments, nextTok)):
                if replace { self.comments = newComments }
                else { self.comments.append(contentsOf: newComments) }
                self.commentsContinuation = nextTok
                self.loadMoreCommentsBtn.title = "Load more comments"
                self.setLoadMoreCommentsVisible(nextTok != nil)
                if let total = self.details?.commentCountText, !total.isEmpty {
                    self.commentsHeaderLabel.stringValue = "\(total) Comments"
                } else {
                    self.commentsHeaderLabel.stringValue = "Comments"
                }
                // Say so instead of leaving the section blank.
                if self.comments.isEmpty {
                    // No list to count, so the header states that directly rather than repeating a total.
                    self.commentsHeaderLabel.stringValue = "No comments to show"
                }
                self.rebuildCommentsStack()
            }
        }
    }

    @objc private func sortCommentsTop() {
        sortTopBtn.isSelectedPill = true
        sortNewestBtn.isSelectedPill = false
        if let tok = details?.commentsContinuation {
            comments = []
            commentsContinuation = nil
            setLoadMoreCommentsVisible(false)
            commentsHeaderLabel.stringValue = "Comments (loading…)"
            rebuildCommentsStack()
            loadComments(token: tok, replace: true)
        }
    }

    @objc private func sortCommentsNewest() {
        sortTopBtn.isSelectedPill = false
        sortNewestBtn.isSelectedPill = true
        if let tok = details?.commentsNewestContinuation ?? details?.commentsContinuation {
            comments = []
            commentsContinuation = nil
            setLoadMoreCommentsVisible(false)
            commentsHeaderLabel.stringValue = "Comments (loading…)"
            rebuildCommentsStack()
            loadComments(token: tok, replace: true)
        }
    }

    @objc private func loadMoreComments() {
        if let tok = commentsContinuation { loadComments(token: tok, replace: false) }
    }

    private func rebuildCommentsStack() {
        commentsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (idx, c) in comments.enumerated() {
            let rView = makeCommentRow(c, index: idx, isReply: false)
            commentsStack.addArrangedSubview(rView)
            rView.widthAnchor.constraint(equalTo: commentsStack.widthAnchor).isActive = true
            if c.repliesExpanded {
                for r in c.replies {
                    let repView = makeCommentRow(r, index: idx, isReply: true)
                    commentsStack.addArrangedSubview(repView)
                    repView.widthAnchor.constraint(equalTo: commentsStack.widthAnchor).isActive = true
                }
            }
        }
    }

    private func makeCommentRow(_ c: CommentItem, index: Int, isReply: Bool) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let av = NSImageView()
        let avSz: CGFloat = isReply ? 24 : 34
        av.wantsLayer = true
        av.layer?.cornerRadius = avSz / 2
        av.layer?.masksToBounds = true
        av.imageScaling = .scaleProportionallyUpOrDown
        av.translatesAutoresizingMaskIntoConstraints = false
        ImageCache.shared.load(c.authorAvatarURL, maxPixelSize: 64) { img in av.image = img }

        var headerStr = "\(c.authorName)  ·  \(c.publishedTime)"
        if c.isPinned { headerStr = "Pinned  ·  " + headerStr }
        let hdr = makeLabel(headerStr, size: 12, weight: .semibold, color: c.isAuthorChannelOwner ? YTTheme.linkBlue : YTTheme.textSecondary)

        let body = makeLabel(c.text, size: 14, weight: .regular, color: YTTheme.textPrimary, maxLines: 0)
        body.isSelectable = true
        body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hdr.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var footParts: [String] = []
        if !c.likeCountText.isEmpty { footParts.append("Likes: \(c.likeCountText)") }
        if c.isCreatorHearted { footParts.append("Creator hearted") }
        let foot = makeLabel(footParts.joined(separator: "  ·  "), size: 12, color: YTTheme.textSecondary)
        foot.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [hdr, body, foot])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false

        if !isReply, let _ = c.repliesContinuation, !c.replyCountText.isEmpty {
            let rBtn = NSButton(title: "", target: self, action: #selector(toggleCommentReplies(_:)))
            rBtn.isBordered = false
            let rTitle = c.repliesExpanded ? "▾ Hide replies" : "▸ \(c.replyCountText) replies"
            rBtn.attributedTitle = NSAttributedString(
                string: rTitle,
                attributes: [
                    .foregroundColor: YTTheme.linkBlue,
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
                ]
            )
            // Name the action and its state, since the visible title carries a disclosure glyph.
            rBtn.setAccessibilityLabel(c.repliesExpanded ? "Hide replies" : "Show \(c.replyCountText) replies")
            rBtn.tag = index
            textStack.addArrangedSubview(rBtn)
        }

        row.addSubview(av)
        row.addSubview(textStack)

        let indent: CGFloat = isReply ? 44 : 0
        NSLayoutConstraint.activate([
            av.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: indent),
            av.topAnchor.constraint(equalTo: row.topAnchor, constant: 2),
            av.widthAnchor.constraint(equalToConstant: avSz),
            av.heightAnchor.constraint(equalToConstant: avSz),

            textStack.leadingAnchor.constraint(equalTo: av.trailingAnchor, constant: 12),
            textStack.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            textStack.topAnchor.constraint(equalTo: row.topAnchor),
            textStack.bottomAnchor.constraint(equalTo: row.bottomAnchor)
        ])
        return row
    }

    @objc private func toggleCommentReplies(_ sender: NSButton) {
        let idx = sender.tag
        guard idx >= 0 && idx < comments.count else { return }
        if comments[idx].repliesExpanded {
            comments[idx].repliesExpanded = false
            rebuildCommentsStack()
            return
        }
        if !comments[idx].replies.isEmpty {
            comments[idx].repliesExpanded = true
            rebuildCommentsStack()
            return
        }
        guard let tok = comments[idx].repliesContinuation, !loadingReplyIndices.contains(idx) else { return }
        loadingReplyIndices.insert(idx)
        let gen = loadGeneration
        let cGen = commentsGeneration
        YouTubeAPI.shared.fetchComments(continuation: tok) { [weak self] res in
            guard let self = self, self.loadGeneration == gen, self.commentsGeneration == cGen, idx < self.comments.count else { return }
            self.loadingReplyIndices.remove(idx)
            switch res {
            case .failure:
                // Inline recovery: the thread's reply control stays available and says what happened.
                self.comments[idx].repliesExpanded = false
                self.rebuildCommentsStack()
                self.navDelegate?.showToastMessage("Could not load replies. Try again.")
                postAccessibilityAnnouncement("Could not load replies")
            case .success(let (reps, _)):
                self.comments[idx].replies = reps
                self.comments[idx].repliesExpanded = true
                self.rebuildCommentsStack()
            }
        }
    }

    // MARK: - Actions (Subscribe, Like, Share, Save, Queue, Browser)

    private func updateActionButtons() {
        guard let v = currentVideo else { return }
        let subbed = !v.channelId.isEmpty && LocalStore.shared.isSubscribed(channelId: v.channelId)
        subscribeBtn.title = subbed ? "Subscribed ✓" : "Subscribe"
        // Selected means "active": the subscribed state is shown in the value, not in the fill colour.
        subscribeBtn.isSelectedPill = !subbed
        subscribeBtn.stateValue = subbed ? "Subscribed" : "Not subscribed"
        // Videos opened by URL have no channel ID, so Subscribe can't work yet: disable it and say why.
        subscribeBtn.isEnabled = !v.channelId.isEmpty
        subscribeBtn.toolTip = v.channelId.isEmpty ? "Channel details are still loading" : "Subscribe"
        // Disabled controls do not reliably speak their tooltip, so the reason is also exposed as help text.
        subscribeBtn.setAccessibilityHelp(v.channelId.isEmpty ? "Channel details are still loading" : nil)

        let liked = LocalStore.shared.isLiked(v.id)
        likeBtn.isSelectedPill = liked
        likeBtn.stateValue = liked ? "Liked" : "Not liked"
        let saved = LocalStore.shared.isInWatchLater(v.id)
        // Same toggle pattern as Like: a fixed label and a selected state, not a changing title.
        saveBtn.title = "Save"
        saveBtn.isSelectedPill = saved
        // Save opens a menu (Watch Later, Playlists), so the spoken name says so instead of promising a one-tap toggle.
        saveBtn.setAccessibilityLabel("Save options")
        saveBtn.stateValue = saved ? "Saved" : "Not saved"

        updateQueueBanner()
    }

    private func updateQueueBanner() {
        let q = LocalStore.shared.queue
        let showQ = activeSideTab == .upNext && !q.isEmpty
        queueHeaderView.isHidden = !showQ
        queueCountLabel.stringValue = "Queue · \(q.count) video\(q.count == 1 ? "" : "s")"
        let needsAux = showQ || activeSideTab == .transcript
        NSLayoutConstraint.deactivate([sideTableTopNormal, sideTableTopWithAux])
        sideTableTopNormal.isActive = !needsAux
        sideTableTopWithAux.isActive = needsAux
    }

    /// An empty subscriber count is removed from the stack rather than laid out as a zero-width label, which made the channel block ambiguous.
    private func setSubscriberCount(_ text: String) {
        subCountLabel.stringValue = text
        let hasText = !text.isEmpty
        if hasText && subCountLabel.superview == nil {
            channelInfoBox.addSubview(subCountLabel)
            subCountLabel.translatesAutoresizingMaskIntoConstraints = false
            let top = subCountLabel.topAnchor.constraint(equalTo: channelBtn.bottomAnchor, constant: 1)
            let leading = subCountLabel.leadingAnchor.constraint(equalTo: channelBtn.leadingAnchor)
            let bottom = channelInfoBox.bottomAnchor.constraint(equalTo: subCountLabel.bottomAnchor)
            NSLayoutConstraint.activate([top, leading, bottom])
            subCountTopConstraint = top
            subCountBottomConstraint = bottom
            channelBoxBottomConstraint?.isActive = false
        }
        if !hasText && subCountLabel.superview != nil {
            NSLayoutConstraint.deactivate([subCountTopConstraint, subCountBottomConstraint].compactMap { $0 })
            subCountLabel.removeFromSuperview()
            channelBoxBottomConstraint?.isActive = true
        }
    }

    private func setLoadMoreRelatedVisible(_ visible: Bool) {
        loadMoreRelatedBtn.isHidden = !visible
        NSLayoutConstraint.deactivate([sideTableBottomToSidebar, loadMoreRelatedTopConstraint, loadMoreRelatedBottomConstraint])
        if visible {
            loadMoreRelatedTopConstraint.isActive = true
            loadMoreRelatedBottomConstraint.isActive = true
        } else {
            // Keep the hidden button positioned under the table so its frame is fully determined.
            loadMoreRelatedTopConstraint.isActive = true
            sideTableBottomToSidebar.isActive = true
        }
    }

    @objc private func openCurrentChannel() {
        guard let v = currentVideo, !v.channelId.isEmpty else { return }
        navDelegate?.openChannel(channelId: v.channelId, name: v.channelName)
    }

    @objc private func toggleSubscribe() {
        guard let v = currentVideo, !v.channelId.isEmpty else { return }
        let nowSub = LocalStore.shared.toggleSubscription(
            channelId: v.channelId,
            name: v.channelName,
            avatarURL: v.channelAvatarURL ?? "",
            subscriberCountText: details?.subscriberCountText ?? ""
        )
        updateActionButtons()
        navDelegate?.showToastMessage(nowSub ? "Subscribed to \(v.channelName)" : "Unsubscribed from \(v.channelName)")
    }

    @objc private func toggleLike() {
        guard let v = currentVideo else { return }
        let liked = LocalStore.shared.toggleLike(v)
        updateActionButtons()
        navDelegate?.showToastMessage(liked ? "Added to Liked Videos" : "Removed from Liked Videos")
    }

    @objc private func shareClicked() {
        guard currentVideo != nil else { return }
        let menu = NSMenu()
        let copyPlain = NSMenuItem(title: "Copy video URL", action: #selector(copyPlainURL), keyEquivalent: "")
        copyPlain.target = self
        let t = Int(playerView.currentTime)
        let copyAtTime = NSMenuItem(title: "Copy URL at \(Formatters.timeString(Double(t)))", action: #selector(copyURLAtTime), keyEquivalent: "")
        copyAtTime.target = self
        menu.addItem(copyPlain)
        menu.addItem(copyAtTime)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: shareBtn)
    }

    @objc private func copyPlainURL() {
        guard let v = currentVideo else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(v.watchURL, forType: .string)
        navDelegate?.showToastMessage("Copied \(v.watchURL)")
    }

    @objc private func copyURLAtTime() {
        guard let v = currentVideo else { return }
        let url = "\(v.watchURL)&t=\(Int(playerView.currentTime))s"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        navDelegate?.showToastMessage("Copied timestamped URL")
    }

    @objc private func saveClicked() {
        guard let v = currentVideo else { return }
        let menu = NSMenu()
        let wl = NSMenuItem(title: "Watch Later", action: #selector(toggleWatchLaterCurrent), keyEquivalent: "")
        wl.target = self
        wl.state = LocalStore.shared.isInWatchLater(v.id) ? .on : .off
        menu.addItem(wl)
        menu.addItem(.separator())
        for pl in LocalStore.shared.playlists {
            let mi = NSMenuItem(title: pl.name, action: #selector(addToPlaylistMenu(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = pl.id
            mi.state = pl.videos.contains(where: { $0.id == v.id }) ? .on : .off
            menu.addItem(mi)
        }
        let newPl = NSMenuItem(title: "+ New Playlist...", action: #selector(createNewPlaylistAndAdd), keyEquivalent: "")
        newPl.target = self
        menu.addItem(.separator())
        menu.addItem(newPl)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: saveBtn)
    }

    @objc private func toggleWatchLaterCurrent() {
        guard let v = currentVideo else { return }
        let added = LocalStore.shared.toggleWatchLater(v)
        updateActionButtons()
        navDelegate?.showToastMessage(added ? "Saved to Watch Later" : "Removed from Watch Later")
    }

    @objc private func addToPlaylistMenu(_ sender: NSMenuItem) {
        guard let v = currentVideo, let pid = sender.representedObject as? String else { return }
        if sender.state == .on {
            LocalStore.shared.remove(videoId: v.id, fromPlaylist: pid)
            navDelegate?.showToastMessage("Removed from \(sender.title)")
        } else {
            LocalStore.shared.add(v, toPlaylist: pid)
            navDelegate?.showToastMessage("Saved to \(sender.title)")
        }
    }

    @objc private func createNewPlaylistAndAdd() {
        guard let v = currentVideo else { return }
        let alert = NSAlert()
        alert.messageText = "New Playlist"
        alert.informativeText = "Enter a name for the playlist:"
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        tf.placeholderString = "Playlist name"
        tf.setAccessibilityLabel("Playlist name")
        alert.accessoryView = tf
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.layout()
        alert.window.initialFirstResponder = tf
        let handleResponse: (NSApplication.ModalResponse) -> Void = { [weak self] resp in
            guard resp == .alertFirstButtonReturn else { return }
            let name = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                let pl = LocalStore.shared.createPlaylist(name: name)
                LocalStore.shared.add(v, toPlaylist: pl.id)
                self?.navDelegate?.showToastMessage("Saved to \"\(name)\"")
            }
        }
        if let win = view.window {
            alert.beginSheetModal(for: win, completionHandler: handleResponse)
        } else {
            handleResponse(alert.runModal())
        }
    }

    @objc private func addCurrentToQueue() {
        guard let v = currentVideo else { return }
        LocalStore.shared.addToQueue(v)
        navDelegate?.showToastMessage("Added to Queue")
    }

    @objc private func openInBrowser() {
        guard let v = currentVideo, let url = URL(string: "\(v.watchURL)&t=\(Int(playerView.currentTime))s") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Sidebar Tabs (Up Next / Chapters / Transcript)

    @objc private func selectUpNextTab() { switchSideTab(.upNext) }
    @objc private func selectChaptersTab() { switchSideTab(.chapters) }
    @objc private func selectTranscriptTab() { switchSideTab(.transcript) }

    private func reloadSideTable() {
        sideTable.reloadData()
        let count = numberOfRows(in: sideTable)
        let rowH: CGFloat
        switch activeSideTab {
        case .upNext: rowH = 94
        case .chapters: rowH = 62
        case .transcript: rowH = 46
        }
        let pitch = rowH + 8
        let needed = CGFloat(count) * pitch + 8
        if currentLayoutMode == .wideNormal {
            let maxRows = max(1, floor(680.0 / pitch))
            let snappedMax = maxRows * pitch
            sideTableScroll.hasVerticalScroller = needed > snappedMax
            sideTableHeightConstraint.constant = count == 0 ? 120 : min(snappedMax, max(120, needed))
        } else {
            sideTableScroll.hasVerticalScroller = false
            sideTableHeightConstraint.constant = count == 0 ? 120 : max(120, needed)
        }

        if count == 0 {
            switch activeSideTab {
            case .upNext:
                sideEmptyLabel.stringValue = "No related videos. Try another video from search or your feeds."
            case .chapters:
                sideEmptyLabel.stringValue = "No chapters for this video"
            case .transcript:
                let q = transcriptSearch.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                sideEmptyLabel.stringValue = q.isEmpty ? "No transcript available" : "No matching transcript lines"
            }
            sideEmptyLabel.isHidden = false
        } else {
            sideEmptyLabel.isHidden = true
        }
    }

    private func switchSideTab(_ tab: SidebarTab) {
        activeSideTab = tab
        tabUpNextBtn.isSelectedPill = (tab == .upNext)
        tabChaptersBtn.isSelectedPill = (tab == .chapters)
        tabTranscriptBtn.isSelectedPill = (tab == .transcript)
        transcriptSearch.isHidden = (tab != .transcript)
        setLoadMoreRelatedVisible(tab == .upNext && relatedContinuation != nil)
        updateQueueBanner()
        if tab == .transcript { filterTranscript() }
        reloadSideTable()
    }

    private func filterTranscript() {
        let q = transcriptSearch.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            filteredCues = playerView.captionCues
        } else {
            filteredCues = playerView.captionCues.filter { $0.text.lowercased().contains(q) }
        }
        reloadSideTable()
    }

    func controlTextDidChange(_ obj: Notification) {
        if activeSideTab == .transcript { filterTranscript() }
    }

    @objc private func clearQueueClicked() {
        guard confirmDestructive("Clear the playback queue?", detail: "All videos in your queue will be removed. It can't be undone.", confirmTitle: "Clear Queue") else { return }
        LocalStore.shared.clearQueue()
    }

    @objc private func onQueueChanged() {
        updateQueueBanner()
        if activeSideTab == .upNext { reloadSideTable() }
    }

    @objc private func onStoreChanged() {
        updateActionButtons()
    }

    @objc private func loadMoreRelated() {
        guard let tok = relatedContinuation else { return }
        let gen = loadGeneration
        relatedContinuation = nil
        loadMoreRelatedBtn.title = "Loading…"
        loadMoreRelatedBtn.isEnabled = false
        YouTubeAPI.shared.fetchRelatedContinuation(token: tok) { [weak self] res in
            guard let self = self, self.loadGeneration == gen else { return }
            self.loadMoreRelatedBtn.title = "Show more related"
            self.loadMoreRelatedBtn.isEnabled = true
            switch res {
            case .failure:
                self.relatedContinuation = tok
                self.setLoadMoreRelatedVisible(self.activeSideTab == .upNext)
            case .success(let (more, nextTok)):
                let existing = Set(self.relatedVideos.map(\.id))
                self.relatedVideos.append(contentsOf: more.filter { !existing.contains($0.id) })
                self.relatedContinuation = nextTok
                self.setLoadMoreRelatedVisible(nextTok != nil && self.activeSideTab == .upNext)
                if self.activeSideTab == .upNext { self.reloadSideTable() }
            }
        }
    }

    // MARK: - Sidebar Table DataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        switch activeSideTab {
        case .upNext: return LocalStore.shared.queue.count + relatedVideos.count
        case .chapters: return details?.chapters.count ?? 0
        case .transcript: return filteredCues.count
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch activeSideTab {
        case .upNext: return 94
        case .chapters: return 62
        case .transcript: return 46
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        FocusHighlightRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch activeSideTab {
        case .upNext:
            let q = LocalStore.shared.queue
            if row < q.count {
                return makeCompactVideoRow(q[row], isQueued: true)
            }
            let relIdx = row - q.count
            guard relIdx >= 0 && relIdx < relatedVideos.count else { return nil }
            return makeCompactVideoRow(relatedVideos[relIdx], isQueued: false)
        case .chapters:
            guard let chs = details?.chapters, row >= 0 && row < chs.count else { return nil }
            return makeChapterRow(chs[row])
        case .transcript:
            guard row >= 0 && row < filteredCues.count else { return nil }
            return makeTranscriptRow(filteredCues[row])
        }
    }

    private func makeCompactVideoRow(_ v: VideoItem, isQueued: Bool) -> NSView {
        let cell = NSView()
        let thumb = NSImageView()
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 8
        thumb.layer?.masksToBounds = true
        thumb.layer?.backgroundColor = YTTheme.surface.cgColor
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.translatesAutoresizingMaskIntoConstraints = false
        ImageCache.shared.load(v.bestThumbnailURL, maxPixelSize: 280) { img in thumb.image = img }

        let badge = DurationBadgeView()
        badge.configure(text: v.durationText, isLive: v.isLive)

        let title = makeLabel(v.title, size: 14, weight: .semibold, color: YTTheme.textPrimary, maxLines: 2)
        let ch = makeLabel((isQueued ? "QUEUE · " : "") + v.channelName, size: 11, color: isQueued ? YTTheme.linkBlue : YTTheme.textSecondary)
        let meta = makeLabel([v.viewsText, v.publishedText].filter { !$0.isEmpty }.joined(separator: " • "), size: 12, color: YTTheme.textSecondary)

        cell.addSubview(thumb)
        cell.addSubview(badge)
        cell.addSubview(title)
        cell.addSubview(ch)
        cell.addSubview(meta)

        NSLayoutConstraint.activate([
            thumb.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            thumb.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: 152),
            thumb.heightAnchor.constraint(equalToConstant: 86),

            badge.trailingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: -5),
            badge.bottomAnchor.constraint(equalTo: thumb.bottomAnchor, constant: -5),

            title.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 10),
            title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            title.topAnchor.constraint(equalTo: thumb.topAnchor, constant: 2),

            ch.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            ch.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            ch.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),

            meta.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            meta.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            meta.topAnchor.constraint(equalTo: ch.bottomAnchor, constant: 2)
        ])
        return cell
    }

    private func makeChapterRow(_ ch: VideoChapter) -> NSView {
        let cell = NSView()
        let thumb = NSImageView()
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 6
        thumb.layer?.masksToBounds = true
        thumb.layer?.backgroundColor = YTTheme.surface.cgColor
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.translatesAutoresizingMaskIntoConstraints = false
        if let u = ch.thumbnailURL { ImageCache.shared.load(u, maxPixelSize: 180) { img in thumb.image = img } }

        let t = makeLabel(ch.title, size: 14, weight: .semibold, color: YTTheme.textPrimary, maxLines: 2)
        let ts = makeLabel(ch.timeText, size: 11, weight: .semibold, color: YTTheme.linkBlue)
        cell.addSubview(thumb)
        cell.addSubview(t)
        cell.addSubview(ts)

        NSLayoutConstraint.activate([
            thumb.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            thumb.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: 96),
            thumb.heightAnchor.constraint(equalToConstant: 54),

            t.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 10),
            t.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            t.topAnchor.constraint(equalTo: thumb.topAnchor, constant: 4),

            ts.leadingAnchor.constraint(equalTo: t.leadingAnchor),
            ts.topAnchor.constraint(equalTo: t.bottomAnchor, constant: 3)
        ])
        return cell
    }

    private func makeTranscriptRow(_ cue: CaptionCue) -> NSView {
        let cell = NSView()
        let ts = makeLabel(Formatters.timeString(cue.startTime), size: 11, weight: .semibold, color: YTTheme.linkBlue)
        ts.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let txt = makeLabel(cue.text, size: 12, color: YTTheme.textPrimary, maxLines: 2)
        cell.addSubview(ts)
        cell.addSubview(txt)
        NSLayoutConstraint.activate([
            ts.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            ts.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6),
            ts.widthAnchor.constraint(equalToConstant: 56),

            txt.leadingAnchor.constraint(equalTo: ts.trailingAnchor, constant: 8),
            txt.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            txt.topAnchor.constraint(equalTo: cell.topAnchor, constant: 5)
        ])
        return cell
    }

    @objc private func sideTableClicked() {
        activateSideTableRow(sideTable.clickedRow)
    }

    private func activateSideTableRow(_ row: Int) {
        guard row >= 0 else { return }
        switch activeSideTab {
        case .upNext:
            let q = LocalStore.shared.queue
            if row < q.count {
                navDelegate?.openVideo(q[row], startSeconds: nil)
            } else {
                let relIdx = row - q.count
                guard relIdx >= 0 && relIdx < relatedVideos.count else { return }
                navDelegate?.openVideo(relatedVideos[relIdx], startSeconds: nil)
            }
        case .chapters:
            if let chs = details?.chapters, row < chs.count {
                playerView.seek(to: chs[row].startSeconds)
            }
        case .transcript:
            if row < filteredCues.count {
                playerView.seek(to: filteredCues[row].startTime)
            }
        }
    }

    // MARK: - PlayerViewDelegate

    func playerDidRequestNext(_ playerView: PlayerView) {
        if let cur = currentVideo, let next = LocalStore.shared.nextInQueue(after: cur.id) {
            navDelegate?.openVideo(next, startSeconds: nil)
        } else if let firstRelated = relatedVideos.first {
            navDelegate?.openVideo(firstRelated, startSeconds: nil)
        }
    }

    func playerDidRequestPrevious(_ playerView: PlayerView) {
        if let cur = currentVideo, let prev = LocalStore.shared.previousInQueue(before: cur.id) {
            navDelegate?.openVideo(prev, startSeconds: nil)
        } else if let prevHist = LocalStore.shared.history.first(where: { $0.video.id != currentVideo?.id })?.video {
            navDelegate?.openVideo(prevHist, startSeconds: nil)
        }
    }

    func playerDidToggleTheater(_ playerView: PlayerView) {
        // Theater has no visible effect in the stacked layout, so don't change hidden state.
        guard playerView.theaterSupported else { return }
        isTheaterMode.toggle()
        updateResponsiveLayoutMode()
        view.needsLayout = true
        updatePlayerAspectHeight()
    }

    func playerDidToggleMiniplayer(_ playerView: PlayerView) {
        guard let v = currentVideo else { return }
        navDelegate?.enterMiniplayer(with: playerView, video: v)
    }

    func playerDidToggleFullscreen(_ playerView: PlayerView) {
        view.window?.toggleFullScreen(nil)
    }

    func recordExactHistoryPosition() {
        let t = playerView.currentTime
        let d = playerView.duration
        if let v = currentVideo, d > 5, !v.title.isEmpty, v.title != "Loading..." {
            lastRecordedHistorySec = t
            LocalStore.shared.recordWatch(video: v, position: t, duration: d)
        }
    }

    func playerView(_ playerView: PlayerView, didResolveVideoMetadata video: VideoItem) {
        guard currentVideo?.id == video.id else { return }
        var cur = currentVideo ?? video
        if (cur.title.isEmpty || cur.title == "Loading...") && !video.title.isEmpty {
            cur.title = video.title
            titleLabel.stringValue = video.title
        }
        if cur.channelName.isEmpty && !video.channelName.isEmpty {
            cur.channelName = video.channelName
            setChannelButtonTitle(video.channelName)
        }
        if cur.channelId.isEmpty && !video.channelId.isEmpty {
            cur.channelId = video.channelId
        }
        currentVideo = cur
        navDelegate?.updateCurrentVideoMetadata(video: cur)
    }

    func playerDidUpdateTime(_ playerView: PlayerView, currentTime: Double, duration: Double) {
        // Persist watch history every 10 seconds once title has resolved
        if let v = currentVideo, duration > 10, !v.title.isEmpty, v.title != "Loading...", abs(currentTime - lastRecordedHistorySec) >= 10 {
            lastRecordedHistorySec = currentTime
            LocalStore.shared.recordWatch(video: v, position: currentTime, duration: duration)
        }
    }

    func playerDidSelectChapterList(_ playerView: PlayerView) {
        switchSideTab(.chapters)
    }

    func playerDidFinishVideo(_ playerView: PlayerView) {
        if LocalStore.shared.settings.autoplayNext {
            playerDidRequestNext(playerView)
        }
    }

    func playerDidLoadCaptions(_ playerView: PlayerView) {
        if activeSideTab == .transcript {
            filterTranscript()
        }
    }

    // MARK: - Theme

    @objc private func onThemeChanged() { applyTheme() }

    func applyTheme() {
        view.layer?.backgroundColor = YTTheme.bg.cgColor
        titleLabel.textColor = YTTheme.textPrimary
        avatarView.layer?.backgroundColor = YTTheme.surface.cgColor
        setChannelButtonTitle(channelBtn.attributedTitle.string.isEmpty ? (currentVideo?.channelName ?? "") : channelBtn.attributedTitle.string)
        subCountLabel.textColor = YTTheme.textSecondary
        descBox.layer?.backgroundColor = YTTheme.surface.cgColor
        descMetaLabel.textColor = YTTheme.textPrimary
        setDescriptionText(details?.descriptionText ?? currentVideo?.descriptionSnippet ?? "")
        commentsHeaderLabel.textColor = YTTheme.textPrimary
        rebuildCommentsStack()
        queueHeaderView.layer?.backgroundColor = YTTheme.surface.cgColor
        queueCountLabel.textColor = YTTheme.textPrimary
        clearQueueBtn.attributedTitle = NSAttributedString(
            string: "Clear",
            attributes: [.foregroundColor: YTTheme.linkBlue, .font: NSFont.systemFont(ofSize: 12, weight: .semibold)]
        )
        for btn in [subscribeBtn, likeBtn, shareBtn, saveBtn, queueBtn, browserBtn, sortTopBtn, sortNewestBtn, loadMoreCommentsBtn, tabUpNextBtn, tabChaptersBtn, tabTranscriptBtn, loadMoreRelatedBtn] {
            btn.normalBg = YTTheme.surface
            btn.activeBg = YTTheme.chipActiveBg
            btn.normalFg = YTTheme.textPrimary
            btn.activeFg = YTTheme.chipActiveText
            btn.updateStyle()
        }
        reloadSideTable()
    }
}

extension WatchViewController: NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL, url.scheme == "litetube-seek", let sec = Double(url.host ?? "") {
            playerView.seek(to: sec)
            return true
        }
        if let url = link as? URL {
            if let parsed = Formatters.parseYouTubeURL(url.absoluteString) {
                let placeholder = VideoItem(id: parsed.videoId, title: "Loading...", channelName: "", channelId: "", channelAvatarURL: nil, thumbnailURL: "", durationText: "", viewsText: "", publishedText: "")
                navDelegate?.openVideo(placeholder, startSeconds: parsed.startSeconds)
                return true
            }
            NSWorkspace.shared.open(url)
            return true
        }
        return false
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ p: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        priority = p
        return self
    }
}

import AppKit

protocol WatchNavigationDelegate: AnyObject {
    func openVideo(_ video: VideoItem, startSeconds: Double?)
    func openChannel(channelId: String, name: String)
    func enterMiniplayer(with playerView: PlayerView, video: VideoItem)
    func showToastMessage(_ message: String)
}

final class WatchViewController: NSViewController, PlayerViewDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    weak var navDelegate: WatchNavigationDelegate?

    let playerView = PlayerView()
    private var currentVideo: VideoItem?
    private var details: WatchDetails?
    private var isTheaterMode = false
    private var isDescriptionExpanded = false

    // Main scroll layout
    private let scrollView = NSScrollView()
    private let docView = FlippedView()
    private let playerSlot = NSView()
    private let playerHeightConstraintRef = NSMutableArray()
    private var playerHeightConstraint: NSLayoutConstraint!
    private var mainColumnTrailingToSidebar: NSLayoutConstraint!
    private var mainColumnTrailingFull: NSLayoutConstraint!
    private var sidebarTopNormal: NSLayoutConstraint!
    private var sidebarTopTheater: NSLayoutConstraint!
    private var sidebarLeadingNormal: NSLayoutConstraint!
    private var sidebarLeadingTheater: NSLayoutConstraint!

    // Main metadata & comments
    private let mainColumn = NSView()
    private let titleLabel = makeLabel("", size: 19, weight: .bold, maxLines: 2)
    private let avatarView = NSImageView()
    private let channelBtn = NSButton()
    private let subCountLabel = makeLabel("", size: 12, color: YTTheme.textSecondary)
    private let subscribeBtn = PillButton()
    private let likeBtn = PillButton()
    private let dislikeBtn = PillButton()
    private let shareBtn = PillButton()
    private let saveBtn = PillButton()
    private let queueBtn = PillButton()
    private let browserBtn = PillButton()

    private let descBox = NSView()
    private let descMetaLabel = makeLabel("", size: 13, weight: .semibold)
    private let descTextView = NSTextView()
    private var descTextHeightConstraint: NSLayoutConstraint!
    private let descToggleBtn = NSButton()

    // Comments
    private let commentsHeaderLabel = makeLabel("Comments", size: 16, weight: .bold)
    private let sortTopBtn = PillButton()
    private let sortNewestBtn = PillButton()
    private let commentsStack = NSStackView()
    private let loadMoreCommentsBtn = PillButton()
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
    private let sideTableScroll = NSScrollView()
    private let sideTable = NSTableView()
    private let loadMoreRelatedBtn = PillButton()

    private var sideTableTopNormal: NSLayoutConstraint!
    private var sideTableTopWithAux: NSLayoutConstraint!
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
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupLayout() {
        scrollView.hasVerticalScroller = true
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
        avatarView.imageScaling = .scaleProportionallyUpOrDown
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        let avClick = NSClickGestureRecognizer(target: self, action: #selector(openCurrentChannel))
        avatarView.addGestureRecognizer(avClick)

        channelBtn.isBordered = false
        channelBtn.font = .systemFont(ofSize: 15, weight: .semibold)
        channelBtn.target = self; channelBtn.action = #selector(openCurrentChannel)
        channelBtn.translatesAutoresizingMaskIntoConstraints = false

        subscribeBtn.title = "Subscribe"
        subscribeBtn.cornerRadiusValue = 18
        subscribeBtn.target = self; subscribeBtn.action = #selector(toggleSubscribe)
        subscribeBtn.translatesAutoresizingMaskIntoConstraints = false

        likeBtn.title = "Like"
        likeBtn.image = NSImage(systemSymbolName: "hand.thumbsup", accessibilityDescription: nil)
        likeBtn.cornerRadiusValue = 16
        likeBtn.target = self; likeBtn.action = #selector(toggleLike)

        dislikeBtn.title = ""
        dislikeBtn.image = NSImage(systemSymbolName: "hand.thumbsdown", accessibilityDescription: nil)
        dislikeBtn.cornerRadiusValue = 16
        dislikeBtn.horizontalPadding = 10
        dislikeBtn.target = self; dislikeBtn.action = #selector(dislikeClicked)

        shareBtn.title = "Share"
        shareBtn.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        shareBtn.cornerRadiusValue = 16
        shareBtn.target = self; shareBtn.action = #selector(shareClicked)

        saveBtn.title = "Save"
        saveBtn.image = NSImage(systemSymbolName: "bookmark", accessibilityDescription: nil)
        saveBtn.cornerRadiusValue = 16
        saveBtn.target = self; saveBtn.action = #selector(saveClicked)

        queueBtn.title = "Queue"
        queueBtn.image = NSImage(systemSymbolName: "text.badge.plus", accessibilityDescription: nil)
        queueBtn.cornerRadiusValue = 16
        queueBtn.target = self; queueBtn.action = #selector(addCurrentToQueue)

        browserBtn.title = ""
        browserBtn.image = NSImage(systemSymbolName: "safari", accessibilityDescription: nil)
        browserBtn.toolTip = "Open in default browser"
        browserBtn.cornerRadiusValue = 16
        browserBtn.horizontalPadding = 10
        browserBtn.target = self; browserBtn.action = #selector(openInBrowser)

        let chInfoStack = NSStackView(views: [channelBtn, subCountLabel])
        chInfoStack.orientation = .vertical
        chInfoStack.alignment = .leading
        chInfoStack.spacing = 1

        let leftMeta = NSStackView(views: [avatarView, chInfoStack, subscribeBtn])
        leftMeta.orientation = .horizontal
        leftMeta.spacing = 10
        leftMeta.alignment = .centerY

        let actionsStack = NSStackView(views: [likeBtn, dislikeBtn, shareBtn, saveBtn, queueBtn, browserBtn])
        actionsStack.orientation = .horizontal
        actionsStack.spacing = 8
        actionsStack.alignment = .centerY

        let metaBar = NSStackView(views: [leftMeta, NSView(), actionsStack])
        metaBar.orientation = .horizontal
        metaBar.alignment = .centerY
        metaBar.translatesAutoresizingMaskIntoConstraints = false

        // Description box
        descBox.wantsLayer = true
        descBox.layer?.cornerRadius = 12
        descBox.translatesAutoresizingMaskIntoConstraints = false

        descTextView.isEditable = false
        descTextView.isSelectable = true
        descTextView.drawsBackground = false
        descTextView.textContainerInset = .zero
        descTextView.textContainer?.lineFragmentPadding = 0
        descTextView.delegate = self
        descTextView.translatesAutoresizingMaskIntoConstraints = false

        descToggleBtn.title = "...more"
        descToggleBtn.isBordered = false
        descToggleBtn.font = .systemFont(ofSize: 13, weight: .semibold)
        descToggleBtn.target = self; descToggleBtn.action = #selector(toggleDescription)
        descToggleBtn.translatesAutoresizingMaskIntoConstraints = false

        descBox.addSubview(descMetaLabel)
        descBox.addSubview(descTextView)
        descBox.addSubview(descToggleBtn)

        // Comments header + sort
        sortTopBtn.title = "Top"
        sortTopBtn.isSelectedPill = true
        sortTopBtn.cornerRadiusValue = 14
        sortTopBtn.target = self; sortTopBtn.action = #selector(sortCommentsTop)

        sortNewestBtn.title = "Newest"
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
        transcriptSearch.delegate = self
        transcriptSearch.isHidden = true
        transcriptSearch.translatesAutoresizingMaskIntoConstraints = false
        sidebarColumn.addSubview(transcriptSearch)

        queueHeaderView.wantsLayer = true
        queueHeaderView.layer?.cornerRadius = 8
        queueHeaderView.isHidden = true
        queueHeaderView.translatesAutoresizingMaskIntoConstraints = false
        clearQueueBtn.title = "Clear"
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
        sideTable.selectionHighlightStyle = .none
        sideTable.intercellSpacing = NSSize(width: 0, height: 8)
        sideTable.dataSource = self
        sideTable.delegate = self
        sideTable.action = #selector(sideTableClicked)
        sideTable.target = self

        sideTableScroll.documentView = sideTable
        sideTableScroll.hasVerticalScroller = true
        sideTableScroll.drawsBackground = false
        sideTableScroll.translatesAutoresizingMaskIntoConstraints = false
        sidebarColumn.addSubview(sideTableScroll)

        loadMoreRelatedBtn.title = "Show more related"
        loadMoreRelatedBtn.cornerRadiusValue = 14
        loadMoreRelatedBtn.target = self; loadMoreRelatedBtn.action = #selector(loadMoreRelated)
        loadMoreRelatedBtn.isHidden = true
        loadMoreRelatedBtn.translatesAutoresizingMaskIntoConstraints = false
        sidebarColumn.addSubview(loadMoreRelatedBtn)

        playerHeightConstraint = playerSlot.heightAnchor.constraint(equalToConstant: 460)
        descTextHeightConstraint = descTextView.heightAnchor.constraint(equalToConstant: 56)

        mainColumnTrailingToSidebar = playerSlot.trailingAnchor.constraint(equalTo: sidebarColumn.leadingAnchor, constant: -20)
        mainColumnTrailingFull = playerSlot.trailingAnchor.constraint(equalTo: docView.trailingAnchor, constant: -20)

        sidebarTopNormal = sidebarColumn.topAnchor.constraint(equalTo: docView.topAnchor, constant: 16)
        sidebarTopTheater = sidebarColumn.topAnchor.constraint(equalTo: playerSlot.bottomAnchor, constant: 16)
        sidebarLeadingNormal = sidebarColumn.widthAnchor.constraint(equalToConstant: 375)
        sidebarLeadingTheater = sidebarColumn.widthAnchor.constraint(equalToConstant: 375)
        sideTableTopNormal = sideTableScroll.topAnchor.constraint(equalTo: tabStack.bottomAnchor, constant: 12)
        sideTableTopWithAux = sideTableScroll.topAnchor.constraint(equalTo: tabStack.bottomAnchor, constant: 48)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            docView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            docView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            docView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            // Player slot
            playerSlot.topAnchor.constraint(equalTo: docView.topAnchor, constant: 16),
            playerSlot.leadingAnchor.constraint(equalTo: docView.leadingAnchor, constant: 20),
            mainColumnTrailingToSidebar,
            playerHeightConstraint,

            // Main column below player
            mainColumn.topAnchor.constraint(equalTo: playerSlot.bottomAnchor, constant: 14),
            mainColumn.leadingAnchor.constraint(equalTo: docView.leadingAnchor, constant: 20),
            mainColumn.trailingAnchor.constraint(equalTo: sidebarColumn.leadingAnchor, constant: -20),
            mainColumn.bottomAnchor.constraint(lessThanOrEqualTo: docView.bottomAnchor, constant: -32),

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

            descToggleBtn.topAnchor.constraint(equalTo: descTextView.bottomAnchor, constant: 6),
            descToggleBtn.leadingAnchor.constraint(equalTo: descBox.leadingAnchor, constant: 14),
            descToggleBtn.bottomAnchor.constraint(equalTo: descBox.bottomAnchor, constant: -10),

            cHeaderStack.topAnchor.constraint(equalTo: descBox.bottomAnchor, constant: 22),
            cHeaderStack.leadingAnchor.constraint(equalTo: mainColumn.leadingAnchor),

            commentsStack.topAnchor.constraint(equalTo: cHeaderStack.bottomAnchor, constant: 14),
            commentsStack.leadingAnchor.constraint(equalTo: mainColumn.leadingAnchor),
            commentsStack.trailingAnchor.constraint(equalTo: mainColumn.trailingAnchor),

            loadMoreCommentsBtn.topAnchor.constraint(equalTo: commentsStack.bottomAnchor, constant: 14),
            loadMoreCommentsBtn.centerXAnchor.constraint(equalTo: mainColumn.centerXAnchor),
            loadMoreCommentsBtn.bottomAnchor.constraint(equalTo: mainColumn.bottomAnchor, constant: -16),

            // Sidebar column
            sidebarTopNormal,
            sidebarColumn.trailingAnchor.constraint(equalTo: docView.trailingAnchor, constant: -20),
            sidebarLeadingNormal,
            sidebarColumn.heightAnchor.constraint(greaterThanOrEqualToConstant: 760),
            sidebarColumn.bottomAnchor.constraint(lessThanOrEqualTo: docView.bottomAnchor, constant: -32),

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
            sideTableScroll.heightAnchor.constraint(equalToConstant: 680),

            loadMoreRelatedBtn.topAnchor.constraint(equalTo: sideTableScroll.bottomAnchor, constant: 10),
            loadMoreRelatedBtn.centerXAnchor.constraint(equalTo: sidebarColumn.centerXAnchor),
            loadMoreRelatedBtn.bottomAnchor.constraint(equalTo: sidebarColumn.bottomAnchor)
        ])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updatePlayerAspectHeight()
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

    // MARK: - Open Video

    func loadVideo(_ video: VideoItem, startSeconds: Double? = nil) {
        currentVideo = video
        details = nil
        comments = []
        commentsContinuation = nil
        relatedVideos = []
        relatedContinuation = nil
        isDescriptionExpanded = false
        lastRecordedHistorySec = -99

        attachPlayerView()
        titleLabel.stringValue = video.title.isEmpty ? "Loading..." : video.title
        channelBtn.title = video.channelName
        subCountLabel.stringValue = ""
        descMetaLabel.stringValue = "\(video.viewsText)  \(video.publishedText)"
        setDescriptionText(video.descriptionSnippet)
        commentsHeaderLabel.stringValue = "Comments"
        rebuildCommentsStack()
        updateActionButtons()
        sideTable.reloadData()

        // 1. Start native HLS stream immediately
        playerView.loadVideo(video, startSeconds: startSeconds)

        // 2. Fetch full Watch page metadata, chapters, related videos, and comments token
        YouTubeAPI.shared.fetchWatchDetails(videoId: video.id) { [weak self] res in
            guard let self = self, self.currentVideo?.id == video.id else { return }
            switch res {
            case .failure: break
            case .success(let d):
                self.details = d
                if !d.title.isEmpty {
                    self.titleLabel.stringValue = d.title
                    self.currentVideo?.title = d.title
                }
                if !d.channelName.isEmpty {
                    self.channelBtn.title = d.isVerified ? "\(d.channelName) ✓" : d.channelName
                    self.currentVideo?.channelName = d.channelName
                }
                if !d.channelId.isEmpty { self.currentVideo?.channelId = d.channelId }
                if !d.channelAvatarURL.isEmpty {
                    self.currentVideo?.channelAvatarURL = d.channelAvatarURL
                    ImageCache.shared.load(d.channelAvatarURL, maxPixelSize: 80) { [weak self] img in
                        self?.avatarView.image = img
                    }
                }
                self.subCountLabel.stringValue = d.subscriberCountText
                self.likeBtn.title = d.likeCountText.isEmpty ? "Like" : d.likeCountText
                self.descMetaLabel.stringValue = [d.viewCountText, d.dateText.isEmpty ? d.relativeDateText : d.dateText]
                    .filter { !$0.isEmpty }.joined(separator: "  •  ")
                self.setDescriptionText(d.descriptionText)
                self.commentsHeaderLabel.stringValue = d.commentCountText.isEmpty ? "Comments" : "\(d.commentCountText) Comments"

                self.playerView.updateChapters(d.chapters)
                self.tabChaptersBtn.title = d.chapters.isEmpty ? "Chapters" : "Chapters (\(d.chapters.count))"

                self.relatedVideos = d.relatedVideos
                self.relatedContinuation = d.relatedContinuation
                self.loadMoreRelatedBtn.isHidden = (d.relatedContinuation == nil || self.activeSideTab != .upNext)
                self.sideTable.reloadData()
                self.updateActionButtons()

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
                .font: NSFont.systemFont(ofSize: 13),
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
        updateDescriptionHeight()
    }

    private func updateDescriptionHeight() {
        if isDescriptionExpanded {
            descTextView.layoutManager?.ensureLayout(for: descTextView.textContainer!)
            let used = descTextView.layoutManager?.usedRect(for: descTextView.textContainer!).height ?? 100
            descTextHeightConstraint.constant = max(60, min(600, used + 12))
            descToggleBtn.title = "Show less"
        } else {
            descTextHeightConstraint.constant = 56
            descToggleBtn.title = "...more"
        }
    }

    @objc private func toggleDescription() {
        isDescriptionExpanded.toggle()
        updateDescriptionHeight()
    }

    // MARK: - Comments

    private func loadComments(token: String, replace: Bool) {
        guard !isLoadingComments else { return }
        isLoadingComments = true
        YouTubeAPI.shared.fetchComments(continuation: token) { [weak self] res in
            guard let self = self else { return }
            self.isLoadingComments = false
            switch res {
            case .failure: break
            case .success(let (newComments, nextTok)):
                if replace { self.comments = newComments }
                else { self.comments.append(contentsOf: newComments) }
                self.commentsContinuation = nextTok
                self.loadMoreCommentsBtn.isHidden = (nextTok == nil)
                self.rebuildCommentsStack()
            }
        }
    }

    @objc private func sortCommentsTop() {
        sortTopBtn.isSelectedPill = true
        sortNewestBtn.isSelectedPill = false
        if let tok = details?.commentsContinuation { loadComments(token: tok, replace: true) }
    }

    @objc private func sortCommentsNewest() {
        sortTopBtn.isSelectedPill = false
        sortNewestBtn.isSelectedPill = true
        if let tok = details?.commentsNewestContinuation ?? details?.commentsContinuation {
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
        if c.isPinned { headerStr = "📌 Pinned  ·  " + headerStr }
        let hdr = makeLabel(headerStr, size: 12, weight: .semibold, color: c.isAuthorChannelOwner ? YTTheme.linkBlue : YTTheme.textSecondary)

        let body = makeLabel(c.text, size: 13, weight: .regular, color: YTTheme.textPrimary, maxLines: 0)
        body.isSelectable = true
        body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hdr.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var footParts: [String] = []
        if !c.likeCountText.isEmpty { footParts.append("👍 \(c.likeCountText)") }
        if c.isCreatorHearted { footParts.append("❤️ Creator hearted") }
        let foot = makeLabel(footParts.joined(separator: "   "), size: 11, color: YTTheme.textSecondary)
        foot.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [hdr, body, foot])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false

        if !isReply, let _ = c.repliesContinuation, !c.replyCountText.isEmpty {
            let rBtn = NSButton(title: c.repliesExpanded ? "▾ Hide replies" : "▸ \(c.replyCountText) replies", target: self, action: #selector(toggleCommentReplies(_:)))
            rBtn.isBordered = false
            rBtn.font = .systemFont(ofSize: 12, weight: .semibold)
            rBtn.contentTintColor = YTTheme.linkBlue
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
        guard let tok = comments[idx].repliesContinuation else { return }
        YouTubeAPI.shared.fetchComments(continuation: tok) { [weak self] res in
            guard let self = self, idx < self.comments.count else { return }
            if case .success(let (reps, _)) = res {
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
        subscribeBtn.isSelectedPill = !subbed

        let liked = LocalStore.shared.isLiked(v.id)
        likeBtn.isSelectedPill = liked
        let saved = LocalStore.shared.isInWatchLater(v.id)
        saveBtn.title = saved ? "Saved ✓" : "Save"

        updateQueueBanner()
    }

    private func updateQueueBanner() {
        let q = LocalStore.shared.queue
        let showQ = activeSideTab == .upNext && !q.isEmpty
        queueHeaderView.isHidden = !showQ
        queueCountLabel.stringValue = "Queue · \(q.count) video\(q.count == 1 ? "" : "s")"
        let needsAux = showQ || activeSideTab == .transcript
        sideTableTopNormal.isActive = !needsAux
        sideTableTopWithAux.isActive = needsAux
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

    @objc private func dislikeClicked() {
        navDelegate?.showToastMessage("Disliked (stored locally)")
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
        alert.accessoryView = tf
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let name = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                let pl = LocalStore.shared.createPlaylist(name: name)
                LocalStore.shared.add(v, toPlaylist: pl.id)
                navDelegate?.showToastMessage("Saved to \"\(name)\"")
            }
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

    private func switchSideTab(_ tab: SidebarTab) {
        activeSideTab = tab
        tabUpNextBtn.isSelectedPill = (tab == .upNext)
        tabChaptersBtn.isSelectedPill = (tab == .chapters)
        tabTranscriptBtn.isSelectedPill = (tab == .transcript)
        transcriptSearch.isHidden = (tab != .transcript)
        loadMoreRelatedBtn.isHidden = (tab != .upNext || relatedContinuation == nil)
        updateQueueBanner()
        if tab == .transcript { filterTranscript() }
        sideTable.reloadData()
    }

    private func filterTranscript() {
        let q = transcriptSearch.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            filteredCues = playerView.captionCues
        } else {
            filteredCues = playerView.captionCues.filter { $0.text.lowercased().contains(q) }
        }
        sideTable.reloadData()
    }

    func controlTextDidChange(_ obj: Notification) {
        if activeSideTab == .transcript { filterTranscript() }
    }

    @objc private func clearQueueClicked() {
        LocalStore.shared.clearQueue()
    }

    @objc private func onQueueChanged() {
        updateQueueBanner()
        if activeSideTab == .upNext { sideTable.reloadData() }
    }

    @objc private func loadMoreRelated() {
        guard let tok = relatedContinuation else { return }
        relatedContinuation = nil
        YouTubeAPI.shared.fetchRelatedContinuation(token: tok) { [weak self] res in
            guard let self = self else { return }
            if case .success(let (more, nextTok)) = res {
                let existing = Set(self.relatedVideos.map(\.id))
                self.relatedVideos.append(contentsOf: more.filter { !existing.contains($0.id) })
                self.relatedContinuation = nextTok
                self.loadMoreRelatedBtn.isHidden = (nextTok == nil || self.activeSideTab != .upNext)
                if self.activeSideTab == .upNext { self.sideTable.reloadData() }
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

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch activeSideTab {
        case .upNext:
            let q = LocalStore.shared.queue
            let isQueued = row < q.count
            let v = isQueued ? q[row] : relatedVideos[row - q.count]
            return makeCompactVideoRow(v, isQueued: isQueued)
        case .chapters:
            guard let ch = details?.chapters[row] else { return nil }
            return makeChapterRow(ch)
        case .transcript:
            guard row < filteredCues.count else { return nil }
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

        let badge = makeLabel(v.durationText, size: 10, weight: .bold, color: .white)
        badge.wantsLayer = true
        badge.layer?.backgroundColor = (v.isLive ? YTTheme.red : NSColor.black.withAlphaComponent(0.82)).cgColor
        badge.layer?.cornerRadius = 4
        badge.isHidden = v.durationText.isEmpty

        let title = makeLabel(v.title, size: 13, weight: .semibold, color: YTTheme.textPrimary, maxLines: 2)
        let ch = makeLabel((isQueued ? "QUEUE · " : "") + v.channelName, size: 11, color: isQueued ? YTTheme.linkBlue : YTTheme.textSecondary)
        let meta = makeLabel([v.viewsText, v.publishedText].filter { !$0.isEmpty }.joined(separator: " • "), size: 11, color: YTTheme.textSecondary)

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

        let t = makeLabel(ch.title, size: 13, weight: .semibold, color: YTTheme.textPrimary, maxLines: 2)
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
        let txt = makeLabel(cue.text, size: 12, color: YTTheme.textPrimary, maxLines: 2)
        cell.addSubview(ts)
        cell.addSubview(txt)
        NSLayoutConstraint.activate([
            ts.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            ts.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6),
            ts.widthAnchor.constraint(equalToConstant: 46),

            txt.leadingAnchor.constraint(equalTo: ts.trailingAnchor, constant: 8),
            txt.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            txt.topAnchor.constraint(equalTo: cell.topAnchor, constant: 5)
        ])
        return cell
    }

    @objc private func sideTableClicked() {
        let row = sideTable.clickedRow
        guard row >= 0 else { return }
        switch activeSideTab {
        case .upNext:
            let q = LocalStore.shared.queue
            let v = row < q.count ? q[row] : relatedVideos[row - q.count]
            navDelegate?.openVideo(v, startSeconds: nil)
        case .chapters:
            if let ch = details?.chapters[row] {
                playerView.seek(to: ch.startSeconds)
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
        } else if LocalStore.shared.history.count > 1 {
            navDelegate?.openVideo(LocalStore.shared.history[1].video, startSeconds: nil)
        }
    }

    func playerDidToggleTheater(_ playerView: PlayerView) {
        isTheaterMode.toggle()
        mainColumnTrailingToSidebar.isActive = !isTheaterMode
        mainColumnTrailingFull.isActive = isTheaterMode
        sidebarTopNormal.isActive = !isTheaterMode
        sidebarTopTheater.isActive = isTheaterMode
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

    func playerDidUpdateTime(_ playerView: PlayerView, currentTime: Double, duration: Double) {
        // Persist watch history every 10 seconds
        if let v = currentVideo, duration > 10, abs(currentTime - lastRecordedHistorySec) >= 10 {
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

    // MARK: - Theme

    @objc private func onThemeChanged() { applyTheme() }

    func applyTheme() {
        view.layer?.backgroundColor = YTTheme.bg.cgColor
        titleLabel.textColor = YTTheme.textPrimary
        channelBtn.contentTintColor = YTTheme.textPrimary
        subCountLabel.textColor = YTTheme.textSecondary
        descBox.layer?.backgroundColor = YTTheme.surface.cgColor
        descMetaLabel.textColor = YTTheme.textPrimary
        descToggleBtn.contentTintColor = YTTheme.textPrimary
        commentsHeaderLabel.textColor = YTTheme.textPrimary
        queueHeaderView.layer?.backgroundColor = YTTheme.surface.cgColor
        queueCountLabel.textColor = YTTheme.textPrimary
        clearQueueBtn.contentTintColor = YTTheme.linkBlue
        for btn in [subscribeBtn, likeBtn, dislikeBtn, shareBtn, saveBtn, queueBtn, browserBtn, sortTopBtn, sortNewestBtn, loadMoreCommentsBtn, tabUpNextBtn, tabChaptersBtn, tabTranscriptBtn, loadMoreRelatedBtn] {
            btn.normalBg = YTTheme.surface
            btn.activeBg = YTTheme.chipActiveBg
            btn.normalFg = YTTheme.textPrimary
            btn.activeFg = YTTheme.chipActiveText
            btn.updateStyle()
        }
        sideTable.reloadData()
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

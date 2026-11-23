import AppKit

protocol SearchNavigationDelegate: AnyObject {
    func openVideo(_ video: VideoItem, startSeconds: Double?)
    func openChannel(channelId: String, name: String)
    func openPlaylist(id: String, name: String)
    func showToastMessage(_ message: String)
}

final class SearchViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    weak var navDelegate: SearchNavigationDelegate?

    private(set) var query = ""
    private(set) var lastSearchFailed = false
    private var filters = SearchFilters()
    private var results: [SearchResultItem] = []
    private var continuationToken: String?
    private var isLoading = false
    private var isCompactThumb = false
    private var searchGeneration = 0

    // Filter bar
    private let topBar = NSView()
    private var topBarHeightConstraint: NSLayoutConstraint!
    private var topBarWideConstraints: [NSLayoutConstraint] = []
    private var topBarNarrowConstraints: [NSLayoutConstraint] = []
    private let resultSummary = makeLabel("", size: 14, color: YTTheme.textSecondary)
    private let sortPopup = NSPopUpButton()
    private let datePopup = NSPopUpButton()
    private let typePopup = NSPopUpButton()
    private let durPopup = NSPopUpButton()

    private let scrollView = NSScrollView()
    private let tableView = ActivatingTableView()
    private let spinner: NSProgressIndicator = {
        let s = NSProgressIndicator()
        s.setAccessibilityLabel("Loading results")
        return s
    }()
    private let emptyLabel = makeLabel("", size: 16, weight: .medium, color: YTTheme.textSecondary, maxLines: 3)
    private let retryBtn = PillButton()
    private let footerView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 56))
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
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)

        sortPopup.addItems(withTitles: SearchFilters.SortBy.allCases.map(\.rawValue))
        datePopup.addItems(withTitles: SearchFilters.UploadDate.allCases.map(\.rawValue))
        typePopup.addItems(withTitles: SearchFilters.ResultType.allCases.map(\.rawValue))
        durPopup.addItems(withTitles: SearchFilters.Duration.allCases.map(\.rawValue))
        sortPopup.setAccessibilityLabel("Sort results by")
        datePopup.setAccessibilityLabel("Filter by upload date")
        typePopup.setAccessibilityLabel("Filter by result type")
        durPopup.setAccessibilityLabel("Filter by duration")
        for p in [sortPopup, datePopup, typePopup, durPopup] {
            p.controlSize = .small
            p.target = self; p.action = #selector(filterChanged)
        }

        let filterStack = NSStackView(views: [sortPopup, datePopup, typePopup, durPopup])
        filterStack.orientation = .horizontal
        filterStack.spacing = 8
        filterStack.translatesAutoresizingMaskIntoConstraints = false

        resultSummary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        topBar.addSubview(resultSummary)
        topBar.addSubview(filterStack)

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("search"))
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.intercellSpacing = NSSize(width: 0, height: 14)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.action = #selector(rowClicked)
        tableView.target = self
        tableView.onActivateRow = { [weak self] row in
            self?.activateRow(row)
        }

        scrollView.documentView = tableView
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
        retryBtn.target = self; retryBtn.action = #selector(retrySearch)
        retryBtn.isHidden = true
        retryBtn.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(retryBtn)

        loadMoreBtn.title = "Load more"
        loadMoreBtn.cornerRadiusValue = 16
        loadMoreBtn.target = self; loadMoreBtn.action = #selector(loadMore)
        loadMoreBtn.translatesAutoresizingMaskIntoConstraints = false
        footerView.addSubview(loadMoreBtn)

        topBarHeightConstraint = topBar.heightAnchor.constraint(equalToConstant: 38)
        topBarWideConstraints = [
            resultSummary.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            resultSummary.trailingAnchor.constraint(lessThanOrEqualTo: filterStack.leadingAnchor, constant: -12),
            resultSummary.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            filterStack.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            filterStack.centerYAnchor.constraint(equalTo: topBar.centerYAnchor)
        ]
        topBarNarrowConstraints = [
            resultSummary.topAnchor.constraint(equalTo: topBar.topAnchor, constant: 2),
            resultSummary.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            resultSummary.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),

            filterStack.topAnchor.constraint(equalTo: resultSummary.bottomAnchor, constant: 6),
            filterStack.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            filterStack.trailingAnchor.constraint(lessThanOrEqualTo: topBar.trailingAnchor)
        ]

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            topBarHeightConstraint,

            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            spinner.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            retryBtn.topAnchor.constraint(equalTo: emptyLabel.bottomAnchor, constant: 14),
            retryBtn.centerXAnchor.constraint(equalTo: emptyLabel.centerXAnchor),

            loadMoreBtn.centerXAnchor.constraint(equalTo: footerView.centerXAnchor),
            loadMoreBtn.centerYAnchor.constraint(equalTo: footerView.centerYAnchor)
        ])
        NSLayoutConstraint.activate(topBarWideConstraints)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let narrow = view.bounds.width > 0 && view.bounds.width < 760
        if narrow && topBarWideConstraints.first?.isActive == true {
            NSLayoutConstraint.deactivate(topBarWideConstraints)
            NSLayoutConstraint.activate(topBarNarrowConstraints)
            topBarHeightConstraint.constant = 58
        } else if !narrow && topBarNarrowConstraints.first?.isActive == true {
            NSLayoutConstraint.deactivate(topBarNarrowConstraints)
            NSLayoutConstraint.activate(topBarWideConstraints)
            topBarHeightConstraint.constant = 38
        }
        if narrow != isCompactThumb {
            isCompactThumb = narrow
            tableView.reloadData()
        }
    }

    var currentScrollY: CGFloat { scrollView.contentView.bounds.origin.y }

    func restoreScrollY(_ y: CGFloat) {
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func performSearch(_ q: String, resetFilters: Bool = true) {
        searchGeneration += 1
        let gen = searchGeneration
        self.query = q
        lastSearchFailed = false
        retryBtn.isHidden = true
        if resetFilters {
            filters = SearchFilters()
            sortPopup.selectItem(at: 0)
            datePopup.selectItem(at: 0)
            typePopup.selectItem(at: 0)
            durPopup.selectItem(at: 0)
        }
        results = []
        continuationToken = nil
        isLoading = false
        emptyLabel.isHidden = true
        resultSummary.stringValue = "Searching for \"\(q)\"…"
        tableView.reloadData()
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        spinner.startAnimation(nil)

        YouTubeAPI.shared.search(query: q, filters: filters) { [weak self] res in
            guard let self = self, self.searchGeneration == gen, self.query == q else { return }
            self.spinner.stopAnimation(nil)
            switch res {
            case .failure:
                self.lastSearchFailed = true
                self.resultSummary.stringValue = "Search failed"
                showRetryableError(message: "Could not load search results. Check your connection.", label: self.emptyLabel, retryButton: self.retryBtn)
            case .success(let (items, cont)):
                self.lastSearchFailed = false
                self.results = items
                self.continuationToken = cont
                self.resultSummary.stringValue = "\(items.count) results for \"\(q)\""
                if items.isEmpty {
                    self.emptyLabel.stringValue = "No results found for \"\(q)\".\nTry different keywords or adjust filters."
                    self.emptyLabel.isHidden = false
                    postAccessibilityAnnouncement("No results found")
                } else {
                    self.emptyLabel.isHidden = true
                }
                self.tableView.reloadData()
            }
        }
    }

    @objc private func retrySearch() {
        performSearch(query, resetFilters: false)
    }

    @objc private func filterChanged() {
        filters.sortBy = SearchFilters.SortBy.allCases[max(0, sortPopup.indexOfSelectedItem)]
        filters.uploadDate = SearchFilters.UploadDate.allCases[max(0, datePopup.indexOfSelectedItem)]
        filters.type = SearchFilters.ResultType.allCases[max(0, typePopup.indexOfSelectedItem)]
        filters.duration = SearchFilters.Duration.allCases[max(0, durPopup.indexOfSelectedItem)]
        if !query.isEmpty { performSearch(query, resetFilters: false) }
    }

    @objc private func loadMore() {
        guard let tok = continuationToken, !isLoading else { return }
        let gen = searchGeneration
        isLoading = true
        loadMoreBtn.title = "Loading…"
        loadMoreBtn.isEnabled = false
        YouTubeAPI.shared.search(query: query, filters: filters, continuation: tok) { [weak self] res in
            guard let self = self, self.searchGeneration == gen else { return }
            self.isLoading = false
            self.loadMoreBtn.title = "Load more"
            self.loadMoreBtn.isEnabled = true
            switch res {
            case .failure:
                self.navDelegate?.showToastMessage("Could not load more results. Check your connection.")
            case .success(let (more, next)):
                self.results.append(contentsOf: more)
                self.continuationToken = next
                self.resultSummary.stringValue = "\(self.results.count) results for \"\(self.query)\""
                self.tableView.reloadData()
            }
        }
    }

    // MARK: - TableView

    func numberOfRows(in tableView: NSTableView) -> Int {
        results.count + (continuationToken != nil ? 1 : 0)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        FocusHighlightRowView()
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if row >= results.count { return 56 }
        switch results[row] {
        case .video: return isCompactThumb ? 136 : 174
        case .channel: return 132
        case .playlist: return isCompactThumb ? 124 : 156
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if row >= results.count { return footerView }
        switch results[row] {
        case .video(let v): return makeVideoResultRow(v, row: row)
        case .channel(let c): return makeChannelResultRow(c, row: row)
        case .playlist(let p): return makePlaylistResultRow(p, row: row)
        }
    }

    private func makeVideoResultRow(_ v: VideoItem, row: Int) -> NSView {
        let cell = ClickableView()
        cell.actsAsAccessibilityElement = false
        cell.layer?.cornerRadius = 10
        cell.hoverBgColor = YTTheme.bgElevated
        cell.normalBgColor = .clear
        cell.onClick = { [weak self] in self?.activateRow(row) }
        cell.onRightClick = { [weak self] anchor in
            self?.presentVideoContextMenu(for: v, from: anchor)
        }
        let thumbW: CGFloat = isCompactThumb ? 220 : 296
        let thumbH: CGFloat = isCompactThumb ? 124 : 166
        let thumb = NSImageView()
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 12
        thumb.layer?.masksToBounds = true
        thumb.layer?.backgroundColor = YTTheme.surface.cgColor
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.translatesAutoresizingMaskIntoConstraints = false
        ImageCache.shared.load(v.bestThumbnailURL, maxPixelSize: 420) { img in thumb.image = img }

        let badge = DurationBadgeView()
        badge.configure(text: v.durationText, isLive: v.isLive)

        let title = makeLabel(v.title, size: 16, weight: .semibold, color: YTTheme.textPrimary, maxLines: 2)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let moreBtn = makeSymbolButton("ellipsis", size: 14, color: YTTheme.textSecondary, tooltip: "More options", hoverBg: YTTheme.surface)
        moreBtn.tag = row
        moreBtn.target = self
        moreBtn.action = #selector(videoMoreClicked(_:))
        moreBtn.setAccessibilityLabel("More options for \(v.title)")

        let meta = makeLabel([v.viewsText, v.publishedText].filter { !$0.isEmpty }.joined(separator: " • "), size: 12, color: YTTheme.textSecondary)

        let hasChannel = !v.channelName.isEmpty || !(v.channelAvatarURL ?? "").isEmpty
        let av = NSImageView()
        av.wantsLayer = true
        av.layer?.cornerRadius = 12
        av.layer?.masksToBounds = true
        av.layer?.backgroundColor = YTTheme.surface.cgColor
        av.imageScaling = .scaleProportionallyUpOrDown
        av.translatesAutoresizingMaskIntoConstraints = false
        av.isHidden = !hasChannel
        if let u = v.channelAvatarURL { ImageCache.shared.load(u, maxPixelSize: 56) { img in av.image = img } }

        let ch = makeLabel(v.isVerified ? "\(v.channelName) ✓" : v.channelName, size: 14, weight: .medium, color: YTTheme.textSecondary)
        ch.isHidden = v.channelName.isEmpty
        let snip = makeLabel(v.descriptionSnippet, size: 12, color: YTTheme.textSecondary, maxLines: 2)
        snip.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        cell.addSubview(thumb)
        cell.addSubview(badge)
        cell.addSubview(title)
        cell.addSubview(moreBtn)
        cell.addSubview(meta)
        cell.addSubview(av)
        cell.addSubview(ch)
        cell.addSubview(snip)

        var constraints: [NSLayoutConstraint] = [
            thumb.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            thumb.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
            thumb.widthAnchor.constraint(equalToConstant: thumbW),
            thumb.heightAnchor.constraint(equalToConstant: thumbH),

            badge.trailingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: -6),
            badge.bottomAnchor.constraint(equalTo: thumb.bottomAnchor, constant: -6),

            moreBtn.topAnchor.constraint(equalTo: thumb.topAnchor, constant: 2),
            moreBtn.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            moreBtn.widthAnchor.constraint(equalToConstant: IconScale.moreTarget),
            moreBtn.heightAnchor.constraint(equalToConstant: IconScale.moreTarget),

            title.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 16),
            title.trailingAnchor.constraint(equalTo: moreBtn.leadingAnchor, constant: -8),
            title.topAnchor.constraint(equalTo: thumb.topAnchor, constant: 2),

            meta.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            meta.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
            meta.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),

            snip.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            snip.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8)
        ]
        if hasChannel {
            constraints.append(contentsOf: [
                av.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                av.topAnchor.constraint(equalTo: meta.bottomAnchor, constant: 10),
                av.widthAnchor.constraint(equalToConstant: 24),
                av.heightAnchor.constraint(equalToConstant: 24),
                ch.leadingAnchor.constraint(equalTo: av.trailingAnchor, constant: 8),
                ch.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
                ch.centerYAnchor.constraint(equalTo: av.centerYAnchor),
                snip.topAnchor.constraint(equalTo: av.bottomAnchor, constant: 10)
            ])
        } else {
            constraints.append(snip.topAnchor.constraint(equalTo: meta.bottomAnchor, constant: 10))
        }
        NSLayoutConstraint.activate(constraints)
        return cell
    }

    private func makeChannelResultRow(_ c: ChannelCard, row: Int) -> NSView {
        let cell = ClickableView()
        cell.actsAsAccessibilityElement = false
        cell.layer?.cornerRadius = 10
        cell.hoverBgColor = YTTheme.bgElevated
        cell.normalBgColor = .clear
        cell.onClick = { [weak self] in self?.activateRow(row) }
        cell.onRightClick = { [weak self] anchor in
            self?.presentChannelContextMenu(for: c, from: anchor)
        }
        let av = NSImageView()
        av.wantsLayer = true
        av.layer?.cornerRadius = 52
        av.layer?.masksToBounds = true
        av.layer?.backgroundColor = YTTheme.surface.cgColor
        av.imageScaling = .scaleProportionallyUpOrDown
        av.translatesAutoresizingMaskIntoConstraints = false
        ImageCache.shared.load(c.avatarURL, maxPixelSize: 160) { img in av.image = img }

        let name = makeLabel(c.isVerified ? "\(c.name) ✓" : c.name, size: 16, weight: .bold, color: YTTheme.textPrimary)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let sub = makeLabel([c.handle, c.subscriberCountText].filter { !$0.isEmpty }.joined(separator: " • "), size: 12, color: YTTheme.textSecondary)
        sub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let desc = makeLabel(c.descriptionSnippet, size: 12, color: YTTheme.textSecondary, maxLines: 2)
        desc.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let subBtn = PillButton()
        let isSub = LocalStore.shared.isSubscribed(channelId: c.id)
        subBtn.title = isSub ? "Subscribed ✓" : "Subscribe"
        subBtn.isSelectedPill = !isSub
        subBtn.stateValue = isSub ? "Subscribed" : "Not subscribed"
        subBtn.cornerRadiusValue = 18
        subBtn.identifier = NSUserInterfaceItemIdentifier(c.id)
        subBtn.target = self; subBtn.action = #selector(toggleChannelSub(_:))
        subBtn.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(av)
        cell.addSubview(name)
        cell.addSubview(sub)
        cell.addSubview(desc)
        cell.addSubview(subBtn)

        NSLayoutConstraint.activate([
            av.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 48),
            av.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            av.widthAnchor.constraint(equalToConstant: 104),
            av.heightAnchor.constraint(equalToConstant: 104),

            name.leadingAnchor.constraint(equalTo: av.trailingAnchor, constant: 24),
            name.trailingAnchor.constraint(lessThanOrEqualTo: subBtn.leadingAnchor, constant: -12),
            name.topAnchor.constraint(equalTo: cell.topAnchor, constant: 22),

            sub.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            sub.trailingAnchor.constraint(lessThanOrEqualTo: subBtn.leadingAnchor, constant: -12),
            sub.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 4),

            desc.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            desc.trailingAnchor.constraint(equalTo: subBtn.leadingAnchor, constant: -16),
            desc.topAnchor.constraint(equalTo: sub.bottomAnchor, constant: 6),

            subBtn.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -16),
            subBtn.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func makePlaylistResultRow(_ p: PlaylistCard, row: Int) -> NSView {
        let cell = ClickableView()
        cell.actsAsAccessibilityElement = false
        cell.layer?.cornerRadius = 10
        cell.hoverBgColor = YTTheme.bgElevated
        cell.normalBgColor = .clear
        cell.onClick = { [weak self] in self?.activateRow(row) }
        cell.onRightClick = { [weak self] anchor in
            self?.presentPlaylistContextMenu(for: p, from: anchor)
        }
        let thumbW: CGFloat = isCompactThumb ? 200 : 260
        let thumbH: CGFloat = isCompactThumb ? 112 : 146
        let thumb = NSImageView()
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 12
        thumb.layer?.masksToBounds = true
        thumb.layer?.backgroundColor = YTTheme.surface.cgColor
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.translatesAutoresizingMaskIntoConstraints = false
        ImageCache.shared.load(p.thumbnailURL, maxPixelSize: 380) { img in thumb.image = img }

        let title = makeLabel("Playlist · \(p.title)", size: 16, weight: .semibold, color: YTTheme.textPrimary, maxLines: 2)
        let sub = makeLabel([p.channelName, p.videoCountText].filter { !$0.isEmpty }.joined(separator: " • "), size: 12, color: YTTheme.textSecondary)

        cell.addSubview(thumb)
        cell.addSubview(title)
        cell.addSubview(sub)
        NSLayoutConstraint.activate([
            thumb.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            thumb.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: thumbW),
            thumb.heightAnchor.constraint(equalToConstant: thumbH),

            title.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 16),
            title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
            title.topAnchor.constraint(equalTo: thumb.topAnchor, constant: 8),

            sub.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6)
        ])
        return cell
    }

    @objc private func toggleChannelSub(_ sender: PillButton) {
        guard let cid = sender.identifier?.rawValue else { return }
        for item in results {
            if case .channel(let c) = item, c.id == cid {
                let now = LocalStore.shared.toggleSubscription(channelId: c.id, name: c.name, avatarURL: c.avatarURL, subscriberCountText: c.subscriberCountText)
                sender.title = now ? "Subscribed ✓" : "Subscribe"
                sender.isSelectedPill = !now
                sender.stateValue = now ? "Subscribed" : "Not subscribed"
                navDelegate?.showToastMessage(now ? "Subscribed to \(c.name)" : "Unsubscribed")
                break
            }
        }
    }

    @objc private func rowClicked() {
        activateRow(tableView.clickedRow)
    }

    private func activateRow(_ row: Int) {
        guard row >= 0 && row < results.count else { return }
        switch results[row] {
        case .video(let v): navDelegate?.openVideo(v, startSeconds: nil)
        case .channel(let c): navDelegate?.openChannel(channelId: c.id, name: c.name)
        case .playlist(let p): navDelegate?.openPlaylist(id: p.id, name: p.title)
        }
    }

    @objc private func videoMoreClicked(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0 && row < results.count, case .video(let video) = results[row] else { return }
        presentVideoContextMenu(for: video, from: sender)
    }

    private func presentVideoContextMenu(for video: VideoItem, from sender: NSView) {
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

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: sender)
    }

    private func presentChannelContextMenu(for channel: ChannelCard, from sender: NSView) {
        let menu = NSMenu()
        let openItem = NSMenuItem(title: "Open Channel", action: #selector(ctxOpenChannelCard(_:)), keyEquivalent: "")
        openItem.target = self; openItem.representedObject = channel
        menu.addItem(openItem)
        let copyItem = NSMenuItem(title: "Copy Channel URL", action: #selector(ctxCopyChannelURL(_:)), keyEquivalent: "")
        copyItem.target = self; copyItem.representedObject = channel
        menu.addItem(copyItem)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: sender)
    }

    private func presentPlaylistContextMenu(for playlist: PlaylistCard, from sender: NSView) {
        let menu = NSMenu()
        let openItem = NSMenuItem(title: "Open Playlist", action: #selector(ctxOpenPlaylistCard(_:)), keyEquivalent: "")
        openItem.target = self; openItem.representedObject = playlist
        menu.addItem(openItem)
        let copyItem = NSMenuItem(title: "Copy Playlist URL", action: #selector(ctxCopyPlaylistURL(_:)), keyEquivalent: "")
        copyItem.target = self; copyItem.representedObject = playlist
        menu.addItem(copyItem)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: sender)
    }

    @objc private func ctxOpenChannelCard(_ s: NSMenuItem) {
        if let c = s.representedObject as? ChannelCard { navDelegate?.openChannel(channelId: c.id, name: c.name) }
    }
    @objc private func ctxCopyChannelURL(_ s: NSMenuItem) {
        if let c = s.representedObject as? ChannelCard {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("https://www.youtube.com/channel/\(c.id)", forType: .string)
            navDelegate?.showToastMessage("Copied URL")
        }
    }
    @objc private func ctxOpenPlaylistCard(_ s: NSMenuItem) {
        if let p = s.representedObject as? PlaylistCard { navDelegate?.openPlaylist(id: p.id, name: p.title) }
    }
    @objc private func ctxCopyPlaylistURL(_ s: NSMenuItem) {
        if let p = s.representedObject as? PlaylistCard {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("https://www.youtube.com/playlist?list=\(p.id)", forType: .string)
            navDelegate?.showToastMessage("Copied URL")
        }
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

    @objc private func onThemeChanged() { applyTheme() }

    func applyTheme() {
        view.layer?.backgroundColor = YTTheme.bg.cgColor
        resultSummary.textColor = YTTheme.textSecondary
        emptyLabel.textColor = YTTheme.textSecondary
        loadMoreBtn.normalBg = YTTheme.surface
        loadMoreBtn.normalFg = YTTheme.textPrimary
        loadMoreBtn.updateStyle()
        tableView.reloadData()
    }
}

import AppKit

protocol SearchNavigationDelegate: AnyObject {
    func openVideo(_ video: VideoItem, startSeconds: Double?)
    func openChannel(channelId: String, name: String)
    func openPlaylist(id: String, name: String)
    func showToastMessage(_ message: String)
}

final class SearchViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    weak var navDelegate: SearchNavigationDelegate?

    private var query = ""
    private var filters = SearchFilters()
    private var results: [SearchResultItem] = []
    private var continuationToken: String?
    private var isLoading = false

    // Filter bar
    private let topBar = NSView()
    private let resultSummary = makeLabel("", size: 13, color: YTTheme.textSecondary)
    private let sortPopup = NSPopUpButton()
    private let datePopup = NSPopUpButton()
    private let typePopup = NSPopUpButton()
    private let durPopup = NSPopUpButton()

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
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
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)

        sortPopup.addItems(withTitles: SearchFilters.SortBy.allCases.map(\.rawValue))
        datePopup.addItems(withTitles: SearchFilters.UploadDate.allCases.map(\.rawValue))
        typePopup.addItems(withTitles: SearchFilters.ResultType.allCases.map(\.rawValue))
        durPopup.addItems(withTitles: SearchFilters.Duration.allCases.map(\.rawValue))
        for p in [sortPopup, datePopup, typePopup, durPopup] {
            p.controlSize = .small
            p.target = self; p.action = #selector(filterChanged)
        }

        let filterStack = NSStackView(views: [sortPopup, datePopup, typePopup, durPopup])
        filterStack.orientation = .horizontal
        filterStack.spacing = 8
        filterStack.translatesAutoresizingMaskIntoConstraints = false

        topBar.addSubview(resultSummary)
        topBar.addSubview(filterStack)

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("search"))
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = NSSize(width: 0, height: 14)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.action = #selector(rowClicked)
        tableView.target = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        spinner.style = .spinning
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        loadMoreBtn.title = "Load more results"
        loadMoreBtn.cornerRadiusValue = 16
        loadMoreBtn.isHidden = true
        loadMoreBtn.target = self; loadMoreBtn.action = #selector(loadMore)
        loadMoreBtn.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(loadMoreBtn)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            topBar.heightAnchor.constraint(equalToConstant: 38),

            resultSummary.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            resultSummary.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            filterStack.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            filterStack.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -48),

            spinner.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            loadMoreBtn.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            loadMoreBtn.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])
    }

    func performSearch(_ q: String, resetFilters: Bool = true) {
        self.query = q
        if resetFilters {
            filters = SearchFilters()
            sortPopup.selectItem(at: 0)
            datePopup.selectItem(at: 0)
            typePopup.selectItem(at: 0)
            durPopup.selectItem(at: 0)
        }
        results = []
        continuationToken = nil
        loadMoreBtn.isHidden = true
        resultSummary.stringValue = "Searching for \"\(q)\"..."
        tableView.reloadData()
        spinner.startAnimation(nil)

        YouTubeAPI.shared.search(query: q, filters: filters) { [weak self] res in
            guard let self = self, self.query == q else { return }
            self.spinner.stopAnimation(nil)
            switch res {
            case .failure(let e):
                self.resultSummary.stringValue = "Search error: \(e.localizedDescription)"
            case .success(let (items, cont)):
                self.results = items
                self.continuationToken = cont
                self.loadMoreBtn.isHidden = (cont == nil)
                self.resultSummary.stringValue = "\(items.count) results for \"\(q)\""
                self.tableView.reloadData()
            }
        }
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
        isLoading = true
        YouTubeAPI.shared.search(query: query, filters: filters, continuation: tok) { [weak self] res in
            guard let self = self else { return }
            self.isLoading = false
            if case .success(let (more, next)) = res {
                self.results.append(contentsOf: more)
                self.continuationToken = next
                self.loadMoreBtn.isHidden = (next == nil)
                self.resultSummary.stringValue = "\(self.results.count) results for \"\(self.query)\""
                self.tableView.reloadData()
            }
        }
    }

    // MARK: - TableView

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch results[row] {
        case .video: return 174
        case .channel: return 132
        case .playlist: return 156
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch results[row] {
        case .video(let v): return makeVideoResultRow(v)
        case .channel(let c): return makeChannelResultRow(c)
        case .playlist(let p): return makePlaylistResultRow(p)
        }
    }

    private func makeVideoResultRow(_ v: VideoItem) -> NSView {
        let cell = NSView()
        let thumb = NSImageView()
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 12
        thumb.layer?.masksToBounds = true
        thumb.layer?.backgroundColor = YTTheme.surface.cgColor
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.translatesAutoresizingMaskIntoConstraints = false
        ImageCache.shared.load(v.bestThumbnailURL, maxPixelSize: 420) { img in thumb.image = img }

        let badge = makeLabel(" \(v.durationText) ", size: 11, weight: .bold, color: .white)
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 4
        badge.layer?.backgroundColor = (v.isLive ? YTTheme.red : NSColor.black.withAlphaComponent(0.84)).cgColor
        badge.isHidden = v.durationText.isEmpty

        let title = makeLabel(v.title, size: 17, weight: .semibold, color: YTTheme.textPrimary, maxLines: 2)
        let meta = makeLabel([v.viewsText, v.publishedText].filter { !$0.isEmpty }.joined(separator: " • "), size: 12, color: YTTheme.textSecondary)

        let av = NSImageView()
        av.wantsLayer = true
        av.layer?.cornerRadius = 12
        av.layer?.masksToBounds = true
        av.layer?.backgroundColor = YTTheme.surface.cgColor
        av.imageScaling = .scaleProportionallyUpOrDown
        av.translatesAutoresizingMaskIntoConstraints = false
        if let u = v.channelAvatarURL { ImageCache.shared.load(u, maxPixelSize: 56) { img in av.image = img } }

        let ch = makeLabel(v.isVerified ? "\(v.channelName) ✓" : v.channelName, size: 13, weight: .medium, color: YTTheme.textSecondary)
        let snip = makeLabel(v.descriptionSnippet, size: 12, color: YTTheme.textSecondary, maxLines: 2)

        cell.addSubview(thumb)
        cell.addSubview(badge)
        cell.addSubview(title)
        cell.addSubview(meta)
        cell.addSubview(av)
        cell.addSubview(ch)
        cell.addSubview(snip)

        NSLayoutConstraint.activate([
            thumb.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            thumb.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
            thumb.widthAnchor.constraint(equalToConstant: 296),
            thumb.heightAnchor.constraint(equalToConstant: 166),

            badge.trailingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: -6),
            badge.bottomAnchor.constraint(equalTo: thumb.bottomAnchor, constant: -6),

            title.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 16),
            title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            title.topAnchor.constraint(equalTo: thumb.topAnchor, constant: 2),

            meta.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            meta.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),

            av.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            av.topAnchor.constraint(equalTo: meta.bottomAnchor, constant: 10),
            av.widthAnchor.constraint(equalToConstant: 24),
            av.heightAnchor.constraint(equalToConstant: 24),

            ch.leadingAnchor.constraint(equalTo: av.trailingAnchor, constant: 8),
            ch.centerYAnchor.constraint(equalTo: av.centerYAnchor),

            snip.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            snip.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            snip.topAnchor.constraint(equalTo: av.bottomAnchor, constant: 10)
        ])
        return cell
    }

    private func makeChannelResultRow(_ c: ChannelCard) -> NSView {
        let cell = NSView()
        let av = NSImageView()
        av.wantsLayer = true
        av.layer?.cornerRadius = 52
        av.layer?.masksToBounds = true
        av.layer?.backgroundColor = YTTheme.surface.cgColor
        av.imageScaling = .scaleProportionallyUpOrDown
        av.translatesAutoresizingMaskIntoConstraints = false
        ImageCache.shared.load(c.avatarURL, maxPixelSize: 160) { img in av.image = img }

        let name = makeLabel(c.isVerified ? "\(c.name) ✓" : c.name, size: 17, weight: .bold, color: YTTheme.textPrimary)
        let sub = makeLabel([c.handle, c.subscriberCountText].filter { !$0.isEmpty }.joined(separator: " • "), size: 12, color: YTTheme.textSecondary)
        let desc = makeLabel(c.descriptionSnippet, size: 12, color: YTTheme.textSecondary, maxLines: 2)

        let subBtn = PillButton()
        let isSub = LocalStore.shared.isSubscribed(channelId: c.id)
        subBtn.title = isSub ? "Subscribed ✓" : "Subscribe"
        subBtn.isSelectedPill = !isSub
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
            av.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 96),
            av.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            av.widthAnchor.constraint(equalToConstant: 104),
            av.heightAnchor.constraint(equalToConstant: 104),

            name.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 312),
            name.topAnchor.constraint(equalTo: cell.topAnchor, constant: 22),

            sub.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            sub.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 4),

            desc.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            desc.trailingAnchor.constraint(equalTo: subBtn.leadingAnchor, constant: -16),
            desc.topAnchor.constraint(equalTo: sub.bottomAnchor, constant: 6),

            subBtn.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -16),
            subBtn.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func makePlaylistResultRow(_ p: PlaylistCard) -> NSView {
        let cell = NSView()
        let thumb = NSImageView()
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 12
        thumb.layer?.masksToBounds = true
        thumb.layer?.backgroundColor = YTTheme.surface.cgColor
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.translatesAutoresizingMaskIntoConstraints = false
        ImageCache.shared.load(p.thumbnailURL, maxPixelSize: 380) { img in thumb.image = img }

        let title = makeLabel("📑 \(p.title)", size: 16, weight: .semibold, color: YTTheme.textPrimary, maxLines: 2)
        let sub = makeLabel([p.channelName, p.videoCountText].filter { !$0.isEmpty }.joined(separator: " • "), size: 12, color: YTTheme.textSecondary)

        cell.addSubview(thumb)
        cell.addSubview(title)
        cell.addSubview(sub)
        NSLayoutConstraint.activate([
            thumb.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            thumb.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: 260),
            thumb.heightAnchor.constraint(equalToConstant: 146),

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
                navDelegate?.showToastMessage(now ? "Subscribed to \(c.name)" : "Unsubscribed")
                break
            }
        }
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0 && row < results.count else { return }
        switch results[row] {
        case .video(let v): navDelegate?.openVideo(v, startSeconds: nil)
        case .channel(let c): navDelegate?.openChannel(channelId: c.id, name: c.name)
        case .playlist(let p): navDelegate?.openPlaylist(id: p.id, name: p.title)
        }
    }

    @objc private func onThemeChanged() { applyTheme() }

    func applyTheme() {
        view.layer?.backgroundColor = YTTheme.bg.cgColor
        resultSummary.textColor = YTTheme.textSecondary
        loadMoreBtn.normalBg = YTTheme.surface
        loadMoreBtn.normalFg = YTTheme.textPrimary
        loadMoreBtn.updateStyle()
        tableView.reloadData()
    }
}

import AppKit
import AVFoundation

final class ShortsViewController: NSViewController, PlayerViewDelegate {
    weak var navDelegate: FeedNavigationDelegate?

    let playerView = PlayerView()
    private var shorts: [VideoItem] = []
    private var currentIndex = 0
    private var loadGeneration = 0

    private let cardFrame = NSView()
    private let titleLabel = makeLabel("", size: 16, weight: .bold, color: .white, maxLines: 2)
    private let channelLabel = makeLabel("", size: 14, weight: .semibold, color: .white)
    private let counterLabel = makeLabel("Shorts", size: 12, color: YTTheme.textSecondary)
    // Secondary text, since the empty state sits on the dark background rather than over a video.
    private let emptyLabel = makeLabel("", size: 16, weight: .medium, color: YTTheme.textSecondary, maxLines: 3)
    private let retryBtn = PillButton()

    private let prevBtn = makeSymbolButton("chevron.up.circle", size: 22, color: YTTheme.textPrimary, tooltip: "Previous Short (↑)", hoverBg: YTTheme.surface)
    private let nextBtn = makeSymbolButton("chevron.down.circle", size: 22, color: YTTheme.textPrimary, tooltip: "Next Short (↓)", hoverBg: YTTheme.surface)
    private let likeCountLabel = makeLabel("", size: 12, weight: .semibold, color: YTTheme.textPrimary)
    private var detailsRequestId = ""
    private let likeBtn = makeSymbolButton("hand.thumbsup", size: 22, color: YTTheme.textPrimary, tooltip: "Like", hoverBg: YTTheme.surface)
    private let openWatchBtn = makeSymbolButton("arrow.up.right.square", size: 22, color: YTTheme.textPrimary, tooltip: "Open in Full Watch Page", hoverBg: YTTheme.surface)
    private let spinner: NSProgressIndicator = {
        let s = NSProgressIndicator()
        s.setAccessibilityLabel("Loading Shorts")
        return s
    }()

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
        cardFrame.wantsLayer = true
        cardFrame.layer?.cornerRadius = 16
        cardFrame.layer?.masksToBounds = true
        cardFrame.layer?.backgroundColor = NSColor.black.cgColor
        cardFrame.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cardFrame)

        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.delegate = self
        playerView.setMiniMode(true, isShorts: true)
        cardFrame.addSubview(playerView)

        let infoBg = NSView()
        infoBg.wantsLayer = true
        infoBg.layer?.backgroundColor = YTTheme.playerBadgeBg.cgColor
        infoBg.layer?.cornerRadius = 8
        infoBg.translatesAutoresizingMaskIntoConstraints = false
        cardFrame.addSubview(infoBg)
        infoBg.addSubview(channelLabel)
        infoBg.addSubview(titleLabel)

        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        cardFrame.addSubview(emptyLabel)
        retryBtn.title = "Try Again"
        retryBtn.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Try again")
        retryBtn.cornerRadiusValue = 16
        retryBtn.horizontalPadding = 14
        retryBtn.target = self; retryBtn.action = #selector(retryShorts)
        retryBtn.isHidden = true
        retryBtn.translatesAutoresizingMaskIntoConstraints = false
        cardFrame.addSubview(retryBtn)

        prevBtn.target = self; prevBtn.action = #selector(prevShort)
        nextBtn.target = self; nextBtn.action = #selector(nextShort)
        likeBtn.target = self; likeBtn.action = #selector(likeShort)
        openWatchBtn.target = self; openWatchBtn.action = #selector(openInWatch)
        // Explicit names so VoiceOver announces each control, not just the icon.
        prevBtn.setAccessibilityLabel("Previous Short")
        nextBtn.setAccessibilityLabel("Next Short")
        likeBtn.setAccessibilityLabel("Like this Short")
        openWatchBtn.setAccessibilityLabel("Open in Full Watch Page")

        likeCountLabel.alignment = .center
        let sideStack = NSStackView(views: [counterLabel, prevBtn, nextBtn, likeBtn, likeCountLabel, openWatchBtn])
        sideStack.orientation = .vertical
        sideStack.spacing = 16
        sideStack.alignment = .centerX
        sideStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sideStack)

        for b in [prevBtn, nextBtn, likeBtn, openWatchBtn] {
            NSLayoutConstraint.activate([
                b.widthAnchor.constraint(equalToConstant: 34),
                b.heightAnchor.constraint(equalToConstant: 34)
            ])
        }

        spinner.style = .spinning
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        let prefH = cardFrame.heightAnchor.constraint(equalTo: view.heightAnchor, constant: -48)
        prefH.priority = .defaultHigh

        NSLayoutConstraint.activate([
            cardFrame.centerXAnchor.constraint(equalTo: view.centerXAnchor, constant: -24),
            cardFrame.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            prefH,
            cardFrame.heightAnchor.constraint(lessThanOrEqualTo: view.heightAnchor, constant: -48),
            cardFrame.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -140),
            cardFrame.widthAnchor.constraint(equalTo: cardFrame.heightAnchor, multiplier: 9.0 / 16.0),

            playerView.topAnchor.constraint(equalTo: cardFrame.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: cardFrame.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: cardFrame.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: cardFrame.bottomAnchor),

            infoBg.leadingAnchor.constraint(equalTo: cardFrame.leadingAnchor, constant: 10),
            infoBg.trailingAnchor.constraint(equalTo: cardFrame.trailingAnchor, constant: -10),
            infoBg.bottomAnchor.constraint(equalTo: cardFrame.bottomAnchor, constant: -68),

            emptyLabel.centerXAnchor.constraint(equalTo: cardFrame.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: cardFrame.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: cardFrame.widthAnchor, constant: -32),
            retryBtn.topAnchor.constraint(equalTo: emptyLabel.bottomAnchor, constant: 14),
            retryBtn.centerXAnchor.constraint(equalTo: emptyLabel.centerXAnchor),

            channelLabel.topAnchor.constraint(equalTo: infoBg.topAnchor, constant: 8),
            channelLabel.leadingAnchor.constraint(equalTo: infoBg.leadingAnchor, constant: 10),
            channelLabel.trailingAnchor.constraint(equalTo: infoBg.trailingAnchor, constant: -10),
            titleLabel.topAnchor.constraint(equalTo: channelLabel.bottomAnchor, constant: 4),
            titleLabel.leadingAnchor.constraint(equalTo: infoBg.leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: infoBg.trailingAnchor, constant: -10),
            titleLabel.bottomAnchor.constraint(equalTo: infoBg.bottomAnchor, constant: -8),

            sideStack.leadingAnchor.constraint(equalTo: cardFrame.trailingAnchor, constant: 20),
            sideStack.centerYAnchor.constraint(equalTo: cardFrame.centerYAnchor),

            spinner.centerXAnchor.constraint(equalTo: cardFrame.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: cardFrame.centerYAnchor)
        ])
    }

    func activate() {
        loadGeneration += 1
        let gen = loadGeneration
        emptyLabel.isHidden = true
        retryBtn.isHidden = true
        if shorts.isEmpty {
            spinner.startAnimation(nil)
            YouTubeAPI.shared.fetchShortsFeed { [weak self] items, failed in
                guard let self = self, self.loadGeneration == gen else { return }
                self.spinner.stopAnimation(nil)
                self.shorts = items
                self.currentIndex = 0
                if items.isEmpty {
                    // With nothing to act on, the action controls are disabled too.
                    self.setActionsEnabled(false)
                    let message = failed
                        ? "Could not load Shorts. Check your connection and try again."
                        : "No Shorts are available right now. Use Try Again to reload."
                    showRetryableError(message: message, label: self.emptyLabel, retryButton: self.retryBtn)
                    self.counterLabel.stringValue = ""
                    self.counterLabel.setAccessibilityLabel("Shorts counter")
                } else {
                    self.playCurrent()
                }
            }
        } else {
            playCurrent()
        }
    }

    @objc private func retryShorts() {
        shorts = []
        activate()
    }

    func deactivate() {
        loadGeneration += 1
        spinner.stopAnimation(nil)
        playerView.stopAndReleaseMemory()
    }

    private func setActionsEnabled(_ enabled: Bool) {
        for b in [prevBtn, nextBtn, likeBtn, openWatchBtn] {
            b.isEnabled = enabled
            b.alphaValue = enabled ? 1.0 : 0.5
        }
    }

    private func playCurrent() {
        guard currentIndex >= 0 && currentIndex < shorts.count else { return }
        setActionsEnabled(true)
        let s = shorts[currentIndex]
        titleLabel.stringValue = s.title
        channelLabel.stringValue = s.channelName.isEmpty ? "YouTube Shorts" : "@\(s.channelName)"
        counterLabel.stringValue = "\(currentIndex + 1) / \(shorts.count)"
        counterLabel.setAccessibilityLabel("Short \(currentIndex + 1) of \(shorts.count)")
        prevBtn.isEnabled = currentIndex > 0
        prevBtn.alphaValue = currentIndex > 0 ? 1.0 : 0.5
        nextBtn.isEnabled = currentIndex + 1 < shorts.count
        nextBtn.alphaValue = (currentIndex + 1 < shorts.count) ? 1.0 : 0.5
        let liked = LocalStore.shared.isLiked(s.id)
        // Filled glyph when liked, outline when not, so the state reads without relying on colour.
        likeBtn.image = NSImage(systemSymbolName: liked ? "hand.thumbsup.fill" : "hand.thumbsup", accessibilityDescription: "Like")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 22, weight: .medium))
        likeBtn.contentTintColor = liked ? YTTheme.red : YTTheme.textPrimary
        likeBtn.accessibilityValueText = LocalStore.shared.isLiked(s.id) ? "Liked" : "Not liked"
        playerView.loadVideo(s, startSeconds: 0)
        // Shorts from search carry no like count, so fetch the Short's details and show the count beside Like.
        likeCountLabel.stringValue = ""
        // Reset the spoken count too, so a previous Short's count is never announced for this one.
        likeBtn.setAccessibilityLabel("Like this Short")
        detailsRequestId = s.id
        YouTubeAPI.shared.fetchWatchDetails(videoId: s.id) { [weak self] res in
            guard let self = self, self.detailsRequestId == s.id, case .success(let d) = res else { return }
            self.likeCountLabel.stringValue = d.likeCountText
            self.likeBtn.setAccessibilityLabel(d.likeCountText.isEmpty ? "Like this Short" : "Like this Short, \(d.likeCountText) likes")
        }
    }

    func handleKeyEvent(_ event: NSEvent) -> Bool {
        if event.keyCode == 126 { prevShort(); return true }
        if event.keyCode == 125 { nextShort(); return true }
        return playerView.handleKeyEvent(event)
    }

    @objc func prevShort() {
        guard currentIndex > 0 else { return }
        currentIndex -= 1
        playCurrent()
    }

    @objc func nextShort() {
        guard currentIndex + 1 < shorts.count else { return }
        currentIndex += 1
        playCurrent()
    }

    @objc private func likeShort() {
        guard currentIndex < shorts.count else { return }
        let liked = LocalStore.shared.toggleLike(shorts[currentIndex])
        likeBtn.contentTintColor = liked ? YTTheme.red : YTTheme.textPrimary
        likeBtn.accessibilityValueText = liked ? "Liked" : "Not liked"
        navDelegate?.showToastMessage(liked ? "Liked Short" : "Removed Like")
    }

    @objc private func openInWatch() {
        guard currentIndex < shorts.count else { return }
        let v = shorts[currentIndex]
        deactivate()
        navDelegate?.openVideo(v, startSeconds: nil)
    }

    // MARK: - PlayerViewDelegate

    func playerDidRequestNext(_ playerView: PlayerView) { nextShort() }
    func playerDidRequestPrevious(_ playerView: PlayerView) { prevShort() }
    func playerDidToggleTheater(_ playerView: PlayerView) {}
    func playerDidToggleMiniplayer(_ playerView: PlayerView) { openInWatch() }
    func playerDidToggleFullscreen(_ playerView: PlayerView) { view.window?.toggleFullScreen(nil) }
    func playerDidUpdateTime(_ playerView: PlayerView, currentTime: Double, duration: Double) {}
    func playerDidSelectChapterList(_ playerView: PlayerView) {}
    func playerDidFinishVideo(_ playerView: PlayerView) {
        playerView.seek(to: 0)
        playerView.player.playImmediately(atRate: playerView.playbackRate)
    }

    @objc private func onThemeChanged() { applyTheme() }

    func applyTheme() {
        view.layer?.backgroundColor = YTTheme.bg.cgColor
        prevBtn.contentTintColor = YTTheme.textPrimary
        prevBtn.hoverBgColor = YTTheme.surface
        nextBtn.contentTintColor = YTTheme.textPrimary
        nextBtn.hoverBgColor = YTTheme.surface
        openWatchBtn.contentTintColor = YTTheme.textPrimary
        openWatchBtn.hoverBgColor = YTTheme.surface
        likeBtn.hoverBgColor = YTTheme.surface
        if currentIndex < shorts.count, LocalStore.shared.isLiked(shorts[currentIndex].id) {
            likeBtn.contentTintColor = YTTheme.red
        } else {
            likeBtn.contentTintColor = YTTheme.textPrimary
        }
        counterLabel.textColor = YTTheme.textSecondary
    }
}

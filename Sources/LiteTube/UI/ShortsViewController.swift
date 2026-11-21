import AppKit
import AVFoundation

final class ShortsViewController: NSViewController {
    weak var navDelegate: FeedNavigationDelegate?

    private let playerView = PlayerView()
    private var shorts: [VideoItem] = []
    private var currentIndex = 0

    private let cardFrame = NSView()
    private let titleLabel = makeLabel("", size: 15, weight: .bold, color: .white, maxLines: 2)
    private let channelLabel = makeLabel("", size: 13, weight: .semibold, color: .white)
    private let counterLabel = makeLabel("Shorts", size: 12, color: YTTheme.textSecondary)

    private let prevBtn = makeSymbolButton("chevron.up.circle.fill", size: 28, color: YTTheme.textPrimary, tooltip: "Previous Short (↑)")
    private let nextBtn = makeSymbolButton("chevron.down.circle.fill", size: 28, color: YTTheme.textPrimary, tooltip: "Next Short (↓)")
    private let likeBtn = makeSymbolButton("hand.thumbsup.fill", size: 22, color: YTTheme.textPrimary, tooltip: "Like")
    private let openWatchBtn = makeSymbolButton("arrow.up.right.square", size: 22, color: YTTheme.textPrimary, tooltip: "Open in Full Watch Page")
    private let spinner = NSProgressIndicator()

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
        playerView.setMiniMode(true)
        cardFrame.addSubview(playerView)

        let infoBg = NSView()
        infoBg.wantsLayer = true
        infoBg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        infoBg.layer?.cornerRadius = 8
        infoBg.translatesAutoresizingMaskIntoConstraints = false
        cardFrame.addSubview(infoBg)
        infoBg.addSubview(channelLabel)
        infoBg.addSubview(titleLabel)

        prevBtn.target = self; prevBtn.action = #selector(prevShort)
        nextBtn.target = self; nextBtn.action = #selector(nextShort)
        likeBtn.target = self; likeBtn.action = #selector(likeShort)
        openWatchBtn.target = self; openWatchBtn.action = #selector(openInWatch)

        let sideStack = NSStackView(views: [prevBtn, counterLabel, nextBtn, likeBtn, openWatchBtn])
        sideStack.orientation = .vertical
        sideStack.spacing = 18
        sideStack.alignment = .centerX
        sideStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sideStack)

        spinner.style = .spinning
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        NSLayoutConstraint.activate([
            cardFrame.centerXAnchor.constraint(equalTo: view.centerXAnchor, constant: -24),
            cardFrame.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            cardFrame.heightAnchor.constraint(equalTo: view.heightAnchor, constant: -48),
            cardFrame.widthAnchor.constraint(equalTo: cardFrame.heightAnchor, multiplier: 9.0 / 16.0),

            playerView.topAnchor.constraint(equalTo: cardFrame.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: cardFrame.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: cardFrame.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: cardFrame.bottomAnchor),

            infoBg.leadingAnchor.constraint(equalTo: cardFrame.leadingAnchor, constant: 10),
            infoBg.trailingAnchor.constraint(equalTo: cardFrame.trailingAnchor, constant: -10),
            infoBg.bottomAnchor.constraint(equalTo: cardFrame.bottomAnchor, constant: -80),

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
        if shorts.isEmpty {
            spinner.startAnimation(nil)
            YouTubeAPI.shared.fetchShortsFeed { [weak self] items in
                guard let self = self else { return }
                self.spinner.stopAnimation(nil)
                self.shorts = items
                self.currentIndex = 0
                self.playCurrent()
            }
        } else {
            playCurrent()
        }
    }

    func deactivate() {
        playerView.stopAndReleaseMemory()
    }

    private func playCurrent() {
        guard currentIndex >= 0 && currentIndex < shorts.count else { return }
        let s = shorts[currentIndex]
        titleLabel.stringValue = s.title
        channelLabel.stringValue = s.channelName.isEmpty ? "YouTube Shorts" : "@\(s.channelName)"
        counterLabel.stringValue = "\(currentIndex + 1) / \(shorts.count)"
        likeBtn.contentTintColor = LocalStore.shared.isLiked(s.id) ? YTTheme.red : YTTheme.textPrimary
        playerView.loadVideo(s, startSeconds: 0)
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
        navDelegate?.showToastMessage(liked ? "Liked Short" : "Removed Like")
    }

    @objc private func openInWatch() {
        guard currentIndex < shorts.count else { return }
        let v = shorts[currentIndex]
        deactivate()
        navDelegate?.openVideo(v, startSeconds: nil)
    }

    @objc private func onThemeChanged() { applyTheme() }

    func applyTheme() {
        view.layer?.backgroundColor = YTTheme.bg.cgColor
        prevBtn.contentTintColor = YTTheme.textPrimary
        nextBtn.contentTintColor = YTTheme.textPrimary
        openWatchBtn.contentTintColor = YTTheme.textPrimary
        counterLabel.textColor = YTTheme.textSecondary
    }
}

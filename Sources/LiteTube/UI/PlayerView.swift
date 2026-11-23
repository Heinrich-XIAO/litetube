import AppKit
import AVFoundation
import AVKit
import MediaPlayer

protocol PlayerViewDelegate: AnyObject {
    func playerDidRequestNext(_ playerView: PlayerView)
    func playerDidRequestPrevious(_ playerView: PlayerView)
    func playerDidToggleTheater(_ playerView: PlayerView)
    func playerDidToggleMiniplayer(_ playerView: PlayerView)
    func playerDidToggleFullscreen(_ playerView: PlayerView)
    func playerDidUpdateTime(_ playerView: PlayerView, currentTime: Double, duration: Double)
    func playerDidSelectChapterList(_ playerView: PlayerView)
    func playerDidFinishVideo(_ playerView: PlayerView)
    func playerDidLoadCaptions(_ playerView: PlayerView)
    func playerView(_ playerView: PlayerView, didResolveVideoMetadata video: VideoItem)
}

extension PlayerViewDelegate {
    func playerDidLoadCaptions(_ playerView: PlayerView) {}
    func playerView(_ playerView: PlayerView, didResolveVideoMetadata video: VideoItem) {}
}

final class YouTubeVolumeSliderCell: NSSliderCell {
    override func barRect(flipped: Bool) -> NSRect {
        let base = super.barRect(flipped: flipped)
        return NSRect(x: base.minX + 5.5, y: base.midY - 1.75, width: max(8, base.width - 11), height: 3.5)
    }

    override func knobRect(flipped: Bool) -> NSRect {
        let bar = barRect(flipped: flipped)
        let range = max(0.0001, maxValue - minValue)
        let frac = CGFloat(max(0, min(1, (doubleValue - minValue) / range)))
        let cx = bar.minX + bar.width * frac
        return NSRect(x: cx - 5.5, y: bar.midY - 5.5, width: 11, height: 11)
    }

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let bar = barRect(flipped: flipped)
        NSColor.white.withAlphaComponent(0.32).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 1.75, yRadius: 1.75).fill()

        let range = max(0.0001, maxValue - minValue)
        let frac = CGFloat(max(0, min(1, (doubleValue - minValue) / range)))
        let fillRect = NSRect(x: bar.minX, y: bar.minY, width: bar.width * frac, height: bar.height)
        if fillRect.width > 0 {
            NSColor.white.setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: 1.75, yRadius: 1.75).fill()
        }
    }

    override func drawKnob(_ knobRect: NSRect) {
        let r: CGFloat = 5.5
        let cx = knobRect.midX
        let cy = knobRect.midY
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)).fill()
    }
}

private final class VideoClickHostView: NSView {
    var onSingleClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    private var pendingSingleWork: DispatchWorkItem?

    override func mouseUp(with event: NSEvent) {
        if event.clickCount >= 2 {
            pendingSingleWork?.cancel()
            pendingSingleWork = nil
            onDoubleClick?()
        } else if event.clickCount == 1 {
            pendingSingleWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.onSingleClick?()
            }
            pendingSingleWork = work
            let delay = min(0.22, max(0.14, NSEvent.doubleClickInterval * 0.45))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }
}

// MARK: - Custom YouTube Timeline Scrubber with Chapters, SponsorBlock & Storyboard Hover

final class YouTubeScrubberView: NSView {
    var duration: Double = 0 { didSet { needsDisplay = true } }
    var currentTime: Double = 0 { didSet { if !isScrubbing { needsDisplay = true } } }
    var bufferedTime: Double = 0 { didSet { needsDisplay = true } }
    var chapters: [VideoChapter] = [] { didSet { needsDisplay = true } }
    var sponsorSegments: [SponsorSegment] = [] { didSet { needsDisplay = true } }

    var onSeek: ((Double) -> Void)?
    var onHoverTime: ((Double?, CGFloat) -> Void)?

    private var isHovering = false
    private var isScrubbing = false
    private var hoverX: CGFloat = 0
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        if duration > 0 {
            let step: Double = event.modifierFlags.contains(.shift) ? 10.0 : 5.0
            if event.keyCode == 123 { // Left arrow
                let target = max(0, currentTime - step)
                currentTime = target
                onSeek?(target)
                needsDisplay = true
                return
            }
            if event.keyCode == 124 { // Right arrow
                let target = min(duration, currentTime + step)
                currentTime = target
                onSeek?(target)
                needsDisplay = true
                return
            }
        }
        super.keyDown(with: event)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityLabel() -> String? { "Video timeline" }
    override func accessibilityMinValue() -> Any? { NSNumber(value: 0) }
    override func accessibilityMaxValue() -> Any? { NSNumber(value: max(0, duration)) }
    override func accessibilityValue() -> Any? {
        "\(Formatters.timeString(currentTime)) of \(Formatters.timeString(duration))"
    }
    override func accessibilityPerformIncrement() -> Bool {
        guard duration > 0 else { return false }
        let step = max(5.0, duration * 0.02)
        let target = min(duration, currentTime + step)
        currentTime = target
        onSeek?(target)
        return true
    }
    override func accessibilityPerformDecrement() -> Bool {
        guard duration > 0 else { return false }
        let step = max(5.0, duration * 0.02)
        let target = max(0, currentTime - step)
        currentTime = target
        onSeek?(target)
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }

    private func timeAt(x: CGFloat) -> Double {
        guard bounds.width > 0 && duration > 0 else { return 0 }
        let frac = max(0, min(1, Double(x / bounds.width)))
        return frac * duration
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        let pt = convert(event.locationInWindow, from: nil)
        hoverX = max(0, min(bounds.width, pt.x))
        onHoverTime?(timeAt(x: hoverX), hoverX)
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        hoverX = max(0, min(bounds.width, pt.x))
        onHoverTime?(timeAt(x: hoverX), hoverX)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        if !isScrubbing { onHoverTime?(nil, 0) }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        isScrubbing = true
        let pt = convert(event.locationInWindow, from: nil)
        hoverX = max(0, min(bounds.width, pt.x))
        let t = timeAt(x: hoverX)
        currentTime = t
        onHoverTime?(t, hoverX)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        hoverX = max(0, min(bounds.width, pt.x))
        let t = timeAt(x: hoverX)
        currentTime = t
        onHoverTime?(t, hoverX)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        hoverX = max(0, min(bounds.width, pt.x))
        let t = timeAt(x: hoverX)
        isScrubbing = false
        currentTime = t
        onSeek?(t)
        if !isHovering { onHoverTime?(nil, 0) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 4 else { return }
        let barH: CGFloat = (isHovering || isScrubbing) ? 5.5 : 3.5
        let barY = (bounds.height - barH) / 2
        let w = bounds.width

        // Track background
        NSColor.white.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: barY, width: w, height: barH), xRadius: barH/2, yRadius: barH/2).fill()

        guard duration > 0 else { return }

        // Buffered bar
        let bufW = CGFloat(max(0, min(1, bufferedTime / duration))) * w
        if bufW > 0 {
            NSColor.white.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: barY, width: bufW, height: barH), xRadius: barH/2, yRadius: barH/2).fill()
        }

        // Hover preview ghost fill
        if isHovering && !isScrubbing {
            NSColor.white.withAlphaComponent(0.32).setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: barY, width: hoverX, height: barH), xRadius: barH/2, yRadius: barH/2).fill()
        }

        // Red played progress
        let curW = CGFloat(max(0, min(1, currentTime / duration))) * w
        if curW > 0 {
            YTTheme.red.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: barY, width: curW, height: barH), xRadius: barH/2, yRadius: barH/2).fill()
        }

        // SponsorBlock segment markers
        for seg in sponsorSegments {
            let sx = CGFloat(max(0, min(1, seg.startTime / duration))) * w
            let ex = CGFloat(max(0, min(1, seg.endTime / duration))) * w
            if ex > sx {
                YTTheme.sponsorColor(for: seg.category).withAlphaComponent(0.9).setFill()
                NSRect(x: sx, y: barY, width: max(2, ex - sx), height: barH).fill()
            }
        }

        // Chapter notch dividers
        if chapters.count > 1 {
            YTTheme.playerGradientTop.setFill()
            for ch in chapters.dropFirst() {
                let cx = CGFloat(max(0, min(1, ch.startSeconds / duration))) * w
                NSRect(x: cx - 1, y: barY, width: 2, height: barH).fill()
            }
        }

        // Scrubber thumb dot
        if isHovering || isScrubbing {
            let r: CGFloat = 6.5
            let tx = max(r, min(w - r, curW))
            YTTheme.red.setFill()
            NSBezierPath(ovalIn: NSRect(x: tx - r, y: bounds.midY - r, width: r * 2, height: r * 2)).fill()
        }

        if window?.firstResponder === self {
            YTTheme.linkBlue.withAlphaComponent(0.9).setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }
}

// MARK: - Main Authentic YouTube Player View

final class PlayerView: NSView, AVPictureInPictureControllerDelegate {
    static let playbackSpeeds: [Float] = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    /// False when the watch page stacks vertically, where theater mode has no effect.
    var theaterSupported = true {
        didSet { if oldValue != theaterSupported { updateResponsiveControls() } }
    }
    weak var delegate: PlayerViewDelegate?
    var onPlayStateChanged: ((Bool) -> Void)?
    var onMiniDoubleClick: (() -> Void)?

    let player = AVPlayer()
    private let playerLayer = AVPlayerLayer()
    private let videoHostView = VideoClickHostView()
    private let audioOnlyOverlay = NSView()
    private let audioOnlyThumb = NSImageView()
    private let audioOnlyLabel = makeLabel("Audio-Only Mode (Ultra-Low RAM)", size: 14, weight: .semibold, color: .white)

    private let loadingSpinner: NSProgressIndicator = {
        let s = NSProgressIndicator()
        s.setAccessibilityLabel("Loading video")
        return s
    }()
    private let errorLabel = makeLabel("", size: 14, weight: .medium, color: .white, maxLines: 3)

    // Bottom chrome
    private let controlsContainer = NSView()
    private var controlsHeightConstraint: NSLayoutConstraint!
    private let gradientLayer = CAGradientLayer()
    private let scrubber = YouTubeScrubberView()
    private let playPauseBtn = makeSymbolButton("play.fill", size: 16, color: .white, tooltip: "Play / Pause (k)", hoverBg: NSColor.white.withAlphaComponent(0.16))
    private let nextBtn = makeSymbolButton("forward.end.fill", size: 14, color: .white, tooltip: "Next (Shift+N)", hoverBg: NSColor.white.withAlphaComponent(0.16))
    private let muteBtn = makeSymbolButton("speaker.wave.2.fill", size: 16, color: .white, tooltip: "Mute (m)", hoverBg: NSColor.white.withAlphaComponent(0.16))
    private let volumeSlider = NSSlider()
    private let timeLabel = makeLabel("0:00 / 0:00", size: 12, weight: .medium, color: .white)
    private let chapterPillBtn = NSButton()
    private let autoplayBtn = makeSymbolButton("play.circle.fill", size: 16, color: .white, tooltip: "Autoplay next", hoverBg: NSColor.white.withAlphaComponent(0.16))
    private let ccBtn = makeSymbolButton("captions.bubble", size: 16, color: .white, tooltip: "Subtitles/CC (c)", hoverBg: NSColor.white.withAlphaComponent(0.16))
    private let settingsBtn = makeSymbolButton("gearshape.fill", size: 16, color: .white, tooltip: "Settings (Quality, Speed, Audio-Only)", hoverBg: NSColor.white.withAlphaComponent(0.16))
    private let miniBtn = makeSymbolButton("pip.enter", size: 16, color: .white, tooltip: "Miniplayer (i)", hoverBg: NSColor.white.withAlphaComponent(0.16))
    private let theaterBtn = makeSymbolButton("rectangle.inset.filled", size: 16, color: .white, tooltip: "Theater mode (t)", hoverBg: NSColor.white.withAlphaComponent(0.16))
    private let pipBtn = makeSymbolButton("rectangle.on.rectangle", size: 16, color: .white, tooltip: "Picture in Picture", hoverBg: NSColor.white.withAlphaComponent(0.16))
    private let fullscreenBtn = makeSymbolButton("arrow.up.left.and.arrow.down.right", size: 16, color: .white, tooltip: "Fullscreen (f)", hoverBg: NSColor.white.withAlphaComponent(0.16))

    // Overlays: Captions, Storyboard Hover Preview, SponsorBlock Toast, Center Flash HUD, Stats for Nerds
    private let captionBox = NSView()
    private let captionLabel = makeLabel("", size: 16, weight: .medium, color: .white, maxLines: 3)

    private let previewPopup = NSView()
    private let previewImage = NSImageView()
    private var previewImageHeightConstraint: NSLayoutConstraint!
    private let previewTimeLabel = makeLabel("", size: 11, weight: .semibold, color: .white)
    private let previewChapterLabel = makeLabel("", size: 11, weight: .medium, color: .white, maxLines: 1)

    private static weak var activeRemoteOwner: PlayerView?
    private static var remoteHandlersInstalled = false

    private let toastView = NSView()
    private let toastLabel = makeLabel("", size: 12, weight: .semibold, color: .white)
    private let toastUndoBtn = NSButton()
    private var lastSkippedStart: Double?

    private let hudBadge = NSView()
    private let hudLabel = makeLabel("", size: 16, weight: .bold, color: .white)

    private let statsBox = NSView()
    private let statsLabel = makeLabel("", size: 11, weight: .regular, color: .white, maxLines: 10)

    // State
    private(set) var currentPlayerResponse: PlayerResponse?
    private(set) var currentVideo: VideoItem?
    private(set) var selectedQuality: String = LocalStore.shared.settings.preferredQuality
    private(set) var playbackRate: Float = LocalStore.shared.settings.defaultSpeed
    private(set) var isLooping: Bool = false
    private(set) var isCaptionsOn: Bool = LocalStore.shared.settings.showCaptionsByDefault
    private(set) var isAudioOnly: Bool = false
    private(set) var showStatsForNerds: Bool = false
    private(set) var activeVideoFormat: StreamFormat?
    private(set) var activeAudioFormat: StreamFormat?

    private var captionTracks: [CaptionTrack] = []
    private var selectedCaptionTrack: CaptionTrack?
    private(set) var captionCues: [CaptionCue] = []
    private var chapters: [VideoChapter] = []
    private var sponsorSegments: [SponsorSegment] = []
    private var skippedSegmentIds = Set<String>()
    private var storyboard: StoryboardLevel?

    private var timeObserver: Any?
    private var itemEndObserver: NSObjectProtocol?
    private var itemStatusObs: NSKeyValueObservation?
    private var hideControlsWork: DispatchWorkItem?
    private var hudWork: DispatchWorkItem?
    private var toastWork: DispatchWorkItem?
    private var pipController: AVPictureInPictureController?
    private var lastVolume: Float = LocalStore.shared.settings.defaultVolume
    private var tracking: NSTrackingArea?
    private var isMiniMode: Bool = false
    private var isShortsMode: Bool = false
    private var isSettingsMenuOpen: Bool = false
    private var videoLoadGeneration: Int = 0
    private var streamGeneration: Int = 0
    private var activeHLSSessionId: String?
    private var activeProgSessionId: String?
    private var hoverCropIndex: Int = -1
    private var hudToken = UUID()
    private var pendingSeekSeconds: Double?

    var currentTime: Double {
        let s = player.currentTime().seconds
        return s.isFinite ? max(0, s) : 0
    }
    var duration: Double {
        let d = player.currentItem?.duration.seconds ?? currentPlayerResponse?.lengthSeconds ?? 0
        return (d.isFinite && d > 0) ? d : (currentPlayerResponse?.lengthSeconds ?? 0)
    }
    var isPlaying: Bool { player.rate > 0 }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
        setupPlayerObservers()
        setupRemoteCommands()
        NotificationCenter.default.addObserver(self, selector: #selector(onStoreChanged), name: .liteTubeStoreDidChange, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let obs = timeObserver { player.removeTimeObserver(obs) }
        if let endObs = itemEndObserver { NotificationCenter.default.removeObserver(endObs) }
        itemStatusObs?.invalidate()
    }

    @objc private func onStoreChanged() {
        updateAutoplayIcon()
    }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        // Video layer host
        videoHostView.wantsLayer = true
        videoHostView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(videoHostView)
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        videoHostView.layer?.addSublayer(playerLayer)

        // Audio-only overlay
        audioOnlyOverlay.wantsLayer = true
        audioOnlyOverlay.layer?.backgroundColor = YTTheme.playerOverlayBg.cgColor
        audioOnlyOverlay.isHidden = true
        audioOnlyOverlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(audioOnlyOverlay)

        audioOnlyThumb.imageScaling = .scaleProportionallyUpOrDown
        audioOnlyThumb.wantsLayer = true
        audioOnlyThumb.layer?.cornerRadius = 10
        audioOnlyThumb.layer?.masksToBounds = true
        audioOnlyThumb.translatesAutoresizingMaskIntoConstraints = false
        audioOnlyOverlay.addSubview(audioOnlyThumb)
        audioOnlyOverlay.addSubview(audioOnlyLabel)

        // Loading spinner & error label
        loadingSpinner.style = .spinning
        loadingSpinner.controlSize = .regular
        loadingSpinner.isDisplayedWhenStopped = false
        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(loadingSpinner)

        errorLabel.alignment = .center
        errorLabel.isHidden = true
        addSubview(errorLabel)

        // Captions box
        captionBox.wantsLayer = true
        captionBox.layer?.backgroundColor = YTTheme.playerCaptionBg.cgColor
        captionBox.layer?.cornerRadius = 6
        captionBox.isHidden = true
        captionBox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(captionBox)
        captionLabel.alignment = .center
        captionBox.addSubview(captionLabel)

        // Controls overlay container
        controlsContainer.wantsLayer = true
        controlsContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controlsContainer)

        gradientLayer.colors = [NSColor.clear.cgColor, YTTheme.playerGradientTop.cgColor]
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 1.0)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 0.0)
        controlsContainer.layer?.addSublayer(gradientLayer)

        scrubber.translatesAutoresizingMaskIntoConstraints = false
        scrubber.onSeek = { [weak self] t in self?.seek(to: t) }
        scrubber.onHoverTime = { [weak self] t, x in self?.handleScrubHover(time: t, x: x) }
        controlsContainer.addSubview(scrubber)

        // Left controls stack
        playPauseBtn.target = self; playPauseBtn.action = #selector(togglePlayPause)
        nextBtn.target = self; nextBtn.action = #selector(nextClicked)
        muteBtn.target = self; muteBtn.action = #selector(toggleMute)

        volumeSlider.cell = YouTubeVolumeSliderCell()
        volumeSlider.minValue = 0; volumeSlider.maxValue = 1
        volumeSlider.floatValue = lastVolume
        volumeSlider.controlSize = .mini
        volumeSlider.setAccessibilityLabel("Volume")
        volumeSlider.target = self; volumeSlider.action = #selector(volumeChanged)
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
        player.volume = lastVolume

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)

        chapterPillBtn.isBordered = false
        chapterPillBtn.font = .systemFont(ofSize: 12, weight: .medium)
        chapterPillBtn.lineBreakMode = .byTruncatingTail
        chapterPillBtn.setAccessibilityLabel("View chapters")
        chapterPillBtn.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chapterPillBtn.target = self; chapterPillBtn.action = #selector(chapterPillClicked)
        chapterPillBtn.isHidden = true
        chapterPillBtn.translatesAutoresizingMaskIntoConstraints = false

        // Right controls
        autoplayBtn.target = self; autoplayBtn.action = #selector(toggleAutoplay)
        ccBtn.target = self; ccBtn.action = #selector(toggleCaptions)
        settingsBtn.target = self; settingsBtn.action = #selector(showSettingsMenu)
        miniBtn.target = self; miniBtn.action = #selector(miniClicked)
        theaterBtn.target = self; theaterBtn.action = #selector(theaterClicked)
        pipBtn.target = self; pipBtn.action = #selector(togglePiP)
        fullscreenBtn.target = self; fullscreenBtn.action = #selector(fullscreenClicked)

        updateAutoplayIcon()
        updateCCIcon()

        let leftStack = NSStackView(views: [playPauseBtn, nextBtn, muteBtn, volumeSlider, timeLabel, chapterPillBtn])
        leftStack.orientation = .horizontal
        leftStack.spacing = 6
        leftStack.alignment = .centerY
        leftStack.translatesAutoresizingMaskIntoConstraints = false

        let rightStack = NSStackView(views: [autoplayBtn, ccBtn, settingsBtn, miniBtn, theaterBtn, pipBtn, fullscreenBtn])
        rightStack.orientation = .horizontal
        rightStack.spacing = 6
        rightStack.alignment = .centerY
        rightStack.translatesAutoresizingMaskIntoConstraints = false

        for symBtn in [playPauseBtn, nextBtn, muteBtn, autoplayBtn, ccBtn, settingsBtn, miniBtn, theaterBtn, pipBtn, fullscreenBtn] {
            NSLayoutConstraint.activate([
                symBtn.widthAnchor.constraint(equalToConstant: 28),
                symBtn.heightAnchor.constraint(equalToConstant: 28)
            ])
        }
        chapterPillBtn.widthAnchor.constraint(lessThanOrEqualToConstant: 150).isActive = true

        controlsContainer.addSubview(leftStack)
        controlsContainer.addSubview(rightStack)

        // Storyboard preview popup
        previewPopup.wantsLayer = true
        previewPopup.layer?.backgroundColor = YTTheme.playerScrim.cgColor
        previewPopup.layer?.cornerRadius = 6
        previewPopup.layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        previewPopup.layer?.borderWidth = 1
        previewPopup.isHidden = true
        addSubview(previewPopup)

        previewImage.imageScaling = .scaleAxesIndependently
        previewImage.wantsLayer = true
        previewImage.layer?.cornerRadius = 4
        previewImage.layer?.masksToBounds = true
        previewImage.translatesAutoresizingMaskIntoConstraints = false
        previewPopup.addSubview(previewImage)
        previewChapterLabel.alignment = .center
        previewTimeLabel.alignment = .center
        previewPopup.addSubview(previewChapterLabel)
        previewPopup.addSubview(previewTimeLabel)

        // SponsorBlock skip toast
        toastView.wantsLayer = true
        toastView.layer?.backgroundColor = YTTheme.playerToastBg.cgColor
        toastView.layer?.cornerRadius = 8
        toastView.layer?.borderColor = YTTheme.greenGood.withAlphaComponent(0.7).cgColor
        toastView.layer?.borderWidth = 1
        toastView.isHidden = true
        toastView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toastView)

        toastUndoBtn.title = ""
        toastUndoBtn.isBordered = false
        toastUndoBtn.attributedTitle = NSAttributedString(
            string: "Un-skip",
            attributes: [
                .foregroundColor: YTTheme.playerToastLink,
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
            ]
        )
        toastUndoBtn.setAccessibilityLabel("Undo SponsorBlock skip")
        toastUndoBtn.target = self; toastUndoBtn.action = #selector(unskipSponsor)
        toastUndoBtn.translatesAutoresizingMaskIntoConstraints = false
        toastView.addSubview(toastLabel)
        toastView.addSubview(toastUndoBtn)

        // Center HUD flash badge
        hudBadge.wantsLayer = true
        hudBadge.layer?.backgroundColor = YTTheme.playerBadgeBg.cgColor
        hudBadge.layer?.cornerRadius = 24
        hudBadge.isHidden = true
        hudBadge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hudBadge)
        hudBadge.addSubview(hudLabel)

        // Stats for Nerds HUD
        statsBox.wantsLayer = true
        statsBox.layer?.backgroundColor = YTTheme.playerCaptionBg.cgColor
        statsBox.layer?.cornerRadius = 8
        statsBox.isHidden = true
        statsBox.translatesAutoresizingMaskIntoConstraints = false
        statsLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        addSubview(statsBox)
        statsBox.addSubview(statsLabel)

        controlsHeightConstraint = controlsContainer.heightAnchor.constraint(equalToConstant: 74)

        NSLayoutConstraint.activate([
            videoHostView.topAnchor.constraint(equalTo: topAnchor),
            videoHostView.leadingAnchor.constraint(equalTo: leadingAnchor),
            videoHostView.trailingAnchor.constraint(equalTo: trailingAnchor),
            videoHostView.bottomAnchor.constraint(equalTo: bottomAnchor),

            audioOnlyOverlay.topAnchor.constraint(equalTo: topAnchor),
            audioOnlyOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            audioOnlyOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            audioOnlyOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            audioOnlyThumb.centerXAnchor.constraint(equalTo: audioOnlyOverlay.centerXAnchor),
            audioOnlyThumb.centerYAnchor.constraint(equalTo: audioOnlyOverlay.centerYAnchor, constant: -14),
            audioOnlyThumb.widthAnchor.constraint(equalToConstant: 240),
            audioOnlyThumb.heightAnchor.constraint(equalToConstant: 135),
            audioOnlyLabel.topAnchor.constraint(equalTo: audioOnlyThumb.bottomAnchor, constant: 12),
            audioOnlyLabel.centerXAnchor.constraint(equalTo: audioOnlyOverlay.centerXAnchor),

            loadingSpinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            loadingSpinner.centerYAnchor.constraint(equalTo: centerYAnchor),

            errorLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            errorLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),

            controlsContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            controlsContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            controlsContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            controlsHeightConstraint,

            scrubber.leadingAnchor.constraint(equalTo: controlsContainer.leadingAnchor, constant: 12),
            scrubber.trailingAnchor.constraint(equalTo: controlsContainer.trailingAnchor, constant: -12),
            scrubber.bottomAnchor.constraint(equalTo: leftStack.topAnchor, constant: -2),
            scrubber.heightAnchor.constraint(equalToConstant: 18),

            leftStack.leadingAnchor.constraint(equalTo: controlsContainer.leadingAnchor, constant: 14),
            leftStack.bottomAnchor.constraint(equalTo: controlsContainer.bottomAnchor, constant: -10),
            volumeSlider.widthAnchor.constraint(equalToConstant: 66),

            rightStack.trailingAnchor.constraint(equalTo: controlsContainer.trailingAnchor, constant: -14),
            rightStack.bottomAnchor.constraint(equalTo: controlsContainer.bottomAnchor, constant: -10),
            rightStack.leadingAnchor.constraint(greaterThanOrEqualTo: leftStack.trailingAnchor, constant: 12),

            captionBox.centerXAnchor.constraint(equalTo: centerXAnchor),
            captionBox.bottomAnchor.constraint(equalTo: controlsContainer.topAnchor, constant: -8),
            captionBox.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
            captionLabel.topAnchor.constraint(equalTo: captionBox.topAnchor, constant: 5),
            captionLabel.bottomAnchor.constraint(equalTo: captionBox.bottomAnchor, constant: -5),
            captionLabel.leadingAnchor.constraint(equalTo: captionBox.leadingAnchor, constant: 10),
            captionLabel.trailingAnchor.constraint(equalTo: captionBox.trailingAnchor, constant: -10),

            toastView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            toastView.bottomAnchor.constraint(equalTo: controlsContainer.topAnchor, constant: -12),
            toastLabel.leadingAnchor.constraint(equalTo: toastView.leadingAnchor, constant: 12),
            toastLabel.topAnchor.constraint(equalTo: toastView.topAnchor, constant: 7),
            toastLabel.bottomAnchor.constraint(equalTo: toastView.bottomAnchor, constant: -7),
            toastUndoBtn.leadingAnchor.constraint(equalTo: toastLabel.trailingAnchor, constant: 10),
            toastUndoBtn.trailingAnchor.constraint(equalTo: toastView.trailingAnchor, constant: -12),
            toastUndoBtn.centerYAnchor.constraint(equalTo: toastView.centerYAnchor),

            hudBadge.centerXAnchor.constraint(equalTo: centerXAnchor),
            hudBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            hudLabel.topAnchor.constraint(equalTo: hudBadge.topAnchor, constant: 10),
            hudLabel.bottomAnchor.constraint(equalTo: hudBadge.bottomAnchor, constant: -10),
            hudLabel.leadingAnchor.constraint(equalTo: hudBadge.leadingAnchor, constant: 18),
            hudLabel.trailingAnchor.constraint(equalTo: hudBadge.trailingAnchor, constant: -18),

            statsBox.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            statsBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            statsLabel.topAnchor.constraint(equalTo: statsBox.topAnchor, constant: 8),
            statsLabel.bottomAnchor.constraint(equalTo: statsBox.bottomAnchor, constant: -8),
            statsLabel.leadingAnchor.constraint(equalTo: statsBox.leadingAnchor, constant: 10),
            statsLabel.trailingAnchor.constraint(equalTo: statsBox.trailingAnchor, constant: -10),

            previewImage.topAnchor.constraint(equalTo: previewPopup.topAnchor, constant: 4),
            previewImage.leadingAnchor.constraint(equalTo: previewPopup.leadingAnchor, constant: 4),
            previewImage.trailingAnchor.constraint(equalTo: previewPopup.trailingAnchor, constant: -4),
            {
                let c = previewImage.heightAnchor.constraint(equalToConstant: 90)
                previewImageHeightConstraint = c
                return c
            }(),
            previewChapterLabel.topAnchor.constraint(equalTo: previewImage.bottomAnchor, constant: 3),
            previewChapterLabel.leadingAnchor.constraint(equalTo: previewPopup.leadingAnchor, constant: 4),
            previewChapterLabel.trailingAnchor.constraint(equalTo: previewPopup.trailingAnchor, constant: -4),
            previewTimeLabel.topAnchor.constraint(equalTo: previewChapterLabel.bottomAnchor, constant: 1),
            previewTimeLabel.centerXAnchor.constraint(equalTo: previewPopup.centerXAnchor),
            previewTimeLabel.bottomAnchor.constraint(equalTo: previewPopup.bottomAnchor, constant: -4)
        ])

        // Double-click to fullscreen (or expand miniplayer), single-click to play/pause
        videoHostView.onSingleClick = { [weak self] in self?.togglePlayPause() }
        videoHostView.onDoubleClick = { [weak self] in
            guard let self = self else { return }
            if self.isMiniMode {
                self.onMiniDoubleClick?()
            } else {
                self.fullscreenClicked()
            }
        }

        if AVPictureInPictureController.isPictureInPictureSupported() {
            pipController = AVPictureInPictureController(playerLayer: playerLayer)
            pipController?.delegate = self
        } else {
            pipBtn.isHidden = true
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = videoHostView.bounds
        gradientLayer.frame = controlsContainer.bounds
        CATransaction.commit()
        updateResponsiveControls()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }

    override func mouseMoved(with event: NSEvent) { showControlsTemporarily() }
    override func mouseEntered(with event: NSEvent) { showControlsTemporarily() }
    override func mouseExited(with event: NSEvent) {
        previewPopup.isHidden = true
        if isPlaying { scheduleHideControls(delay: 0.8) }
    }

    func setMiniMode(_ mini: Bool, isShorts: Bool = false) {
        isMiniMode = mini
        isShortsMode = isShorts
        controlsHeightConstraint.constant = (mini && isShorts) ? 58 : (mini ? 56 : 74)
        updateResponsiveControls()
    }

    private func updateResponsiveControls() {
        if isMiniMode {
            playPauseBtn.isHidden = !isShortsMode
            theaterBtn.isHidden = true
            pipBtn.isHidden = true
            chapterPillBtn.isHidden = true
            autoplayBtn.isHidden = true
            volumeSlider.isHidden = true
            miniBtn.isHidden = true
            fullscreenBtn.isHidden = true
            ccBtn.isHidden = !isShortsMode
            settingsBtn.isHidden = !isShortsMode
            nextBtn.isHidden = true
            return
        }
        let w = bounds.width
        let compact = w > 0 && w < 480
        let ultraNarrow = w > 0 && w < 400
        playPauseBtn.isHidden = false
        miniBtn.isHidden = false
        fullscreenBtn.isHidden = false
        ccBtn.isHidden = false
        settingsBtn.isHidden = false
        nextBtn.isHidden = ultraNarrow
        theaterBtn.isHidden = compact || !theaterSupported
        volumeSlider.isHidden = (w > 0 && w < 560)
        autoplayBtn.isHidden = (w > 0 && w < 600)
        pipBtn.isHidden = (w > 0 && w < 600) || pipController == nil
        chapterPillBtn.isHidden = (w > 0 && w < 680) || chapters.isEmpty
    }

    // MARK: - Loading a Video

    func loadVideo(_ video: VideoItem, startSeconds: Double? = nil) {
        PlayerView.activeRemoteOwner = self
        videoLoadGeneration += 1
        streamGeneration += 1
        let vGen = videoLoadGeneration
        currentVideo = video
        currentPlayerResponse = nil
        // Re-read defaults per video so changes made in Settings apply to the next video without a relaunch.
        let defaults = LocalStore.shared.settings
        selectedQuality = defaults.preferredQuality
        playbackRate = defaults.defaultSpeed
        isCaptionsOn = defaults.showCaptionsByDefault
        lastVolume = defaults.defaultVolume
        player.volume = defaults.defaultVolume
        player.isMuted = false
        updateMuteIcon()
        volumeSlider.floatValue = defaults.defaultVolume
        updateCCIcon()
        isAudioOnly = (selectedQuality == "Audio Only")
        audioOnlyOverlay.isHidden = !isAudioOnly
        activeVideoFormat = nil
        activeAudioFormat = nil
        captionTracks = []
        captionCues = []
        selectedCaptionTrack = nil
        chapters = []
        sponsorSegments = []
        skippedSegmentIds.removeAll()
        lastSkippedStart = nil
        isLooping = false
        storyboard = nil
        scrubber.chapters = []
        scrubber.sponsorSegments = []
        scrubber.currentTime = 0
        scrubber.bufferedTime = 0
        scrubber.duration = 0
        timeLabel.stringValue = "0:00 / 0:00"
        chapterPillBtn.isHidden = true
        audioOnlyThumb.image = nil
        previewPopup.isHidden = true
        toastView.isHidden = true
        toastWork?.cancel()
        hudBadge.isHidden = true
        hudWork?.cancel()
        captionBox.isHidden = true
        errorLabel.isHidden = true
        pendingSeekSeconds = startSeconds ?? LocalStore.shared.savedPosition(for: video.id)
        updatePlayPauseIcon()

        player.replaceCurrentItem(with: nil)
        loadingSpinner.startAnimation(nil)

        ImageCache.shared.load(video.bestThumbnailURL, maxPixelSize: 480) { [weak self] img in
            guard let self = self, self.videoLoadGeneration == vGen else { return }
            self.audioOnlyThumb.image = img
        }

        // Fetch streams via IOS Innertube
        YouTubeAPI.shared.fetchPlayer(videoId: video.id) { [weak self] res in
            guard let self = self, self.videoLoadGeneration == vGen, self.currentVideo?.id == video.id else { return }
            switch res {
            case .failure:
                self.loadingSpinner.stopAnimation(nil)
                self.showError("This video could not be played. Check your connection, then choose it again.")
            case .success(let resp):
                self.currentPlayerResponse = resp
                if var cur = self.currentVideo {
                    var changed = false
                    if (cur.title.isEmpty || cur.title == "Loading...") && !resp.title.isEmpty {
                        cur.title = resp.title
                        changed = true
                    }
                    if cur.channelName.isEmpty && !resp.author.isEmpty {
                        cur.channelName = resp.author
                        changed = true
                    }
                    if cur.channelId.isEmpty && !resp.channelId.isEmpty {
                        cur.channelId = resp.channelId
                        changed = true
                    }
                    if changed {
                        self.currentVideo = cur
                        self.delegate?.playerView(self, didResolveVideoMetadata: cur)
                    }
                }
                if let errMsg = resp.playabilityError, resp.videoFormats.isEmpty && resp.hlsManifestURL == nil {
                    self.loadingSpinner.stopAnimation(nil)
                    self.showError(errMsg)
                    return
                }
                self.captionTracks = resp.captions
                self.storyboard = YouTubeAPI.parseStoryboardSpec(resp.storyboardSpec, videoDuration: resp.lengthSeconds)
                self.scrubber.duration = resp.lengthSeconds
                self.startSelectedQuality(seekTo: self.pendingSeekSeconds)

                // Auto-load English captions (needed for both CC and Transcript!)
                if let track = resp.captions.first(where: { $0.languageCode.hasPrefix("en") && !$0.isAutoGenerated })
                    ?? resp.captions.first(where: { $0.languageCode.hasPrefix("en") })
                    ?? resp.captions.first {
                    self.loadCaptionTrack(track)
                }
            }
        }

        // Fetch SponsorBlock segments in parallel
        if LocalStore.shared.settings.sponsorBlockEnabled {
            YouTubeAPI.shared.fetchSponsorSegments(videoId: video.id) { [weak self] segs in
                guard let self = self, self.videoLoadGeneration == vGen, self.currentVideo?.id == video.id else { return }
                self.sponsorSegments = segs
                self.scrubber.sponsorSegments = segs
            }
        }
    }

    func updateChapters(_ chapters: [VideoChapter]) {
        self.chapters = chapters
        self.scrubber.chapters = chapters
        updateActiveChapterLabel(at: currentTime)
    }

    func loadCaptionTrack(_ track: CaptionTrack, completion: (([CaptionCue]) -> Void)? = nil) {
        let vGen = videoLoadGeneration
        selectedCaptionTrack = track
        YouTubeAPI.shared.fetchCaptions(track: track) { [weak self] cues in
            guard let self = self, self.videoLoadGeneration == vGen else { return }
            self.captionCues = cues
            self.delegate?.playerDidLoadCaptions(self)
            completion?(cues)
        }
    }

    /// Starts playback using our zero-copy in-process HLS v7 bridge.
    func startSelectedQuality(seekTo resumeTime: Double? = nil, autoPlay: Bool = true) {
        guard let resp = currentPlayerResponse else { return }
        PlayerView.activeRemoteOwner = self
        streamGeneration += 1
        let gen = streamGeneration
        loadingSpinner.startAnimation(nil)
        errorLabel.isHidden = true

        // 1. Live stream → direct HLS URL
        if resp.isLive, let hls = resp.hlsManifestURL, let url = URL(string: hls) {
            attachPlayerURL(url, seekTo: nil, autoPlay: autoPlay)
            return
        }

        // 2. Pick compatible MP4 audio (AAC-LC)
        let mp4Audios = resp.audioFormats.filter { $0.isMP4 && $0.initRange != nil && $0.indexRange != nil }
        let chosenAudio = mp4Audios.first(where: { $0.itag == 140 }) ?? mp4Audios.first

        // 3. Audio-Only mode!
        if isAudioOnly || selectedQuality == "Audio Only" {
            isAudioOnly = true
            audioOnlyOverlay.isHidden = false
            activeVideoFormat = nil
            activeAudioFormat = chosenAudio
            if let aud = chosenAudio {
                LocalHLSServer.shared.probeAdaptiveUnrestricted(format: aud) { [weak self] ok in
                    guard let self = self, self.streamGeneration == gen else { return }
                    if ok {
                        LocalHLSServer.shared.prepareSession(videoFormats: [], audioFormat: aud, previousSessionId: self.activeHLSSessionId) { [weak self] res in
                            guard let self = self, self.streamGeneration == gen else { return }
                            if case .success(let (sid, masterURL)) = res {
                                self.activeHLSSessionId = sid
                                self.attachPlayerURL(masterURL, seekTo: resumeTime, autoPlay: autoPlay)
                            } else if let prog = resp.progressiveFormats.first {
                                let pRes = LocalHLSServer.shared.prepareProgressiveSession(format: prog, previousSessionId: self.activeProgSessionId)
                                self.activeProgSessionId = pRes.sessionId
                                self.attachPlayerURL(pRes.url, seekTo: resumeTime, disableVideoTrack: true, autoPlay: autoPlay)
                            }
                        }
                    } else if let prog = resp.progressiveFormats.first {
                        let pRes = LocalHLSServer.shared.prepareProgressiveSession(format: prog, previousSessionId: self.activeProgSessionId)
                        DispatchQueue.main.async {
                            guard self.streamGeneration == gen else { return }
                            self.activeProgSessionId = pRes.sessionId
                            self.attachPlayerURL(pRes.url, seekTo: resumeTime, disableVideoTrack: true, autoPlay: autoPlay)
                        }
                    } else {
                        DispatchQueue.main.async {
                            guard self.streamGeneration == gen else { return }
                            self.loadingSpinner.stopAnimation(nil)
                            self.showError("No unrestricted audio stream available.")
                        }
                    }
                }
                return
            } else if let prog = resp.progressiveFormats.first {
                let pRes = LocalHLSServer.shared.prepareProgressiveSession(format: prog, previousSessionId: activeProgSessionId)
                activeProgSessionId = pRes.sessionId
                attachPlayerURL(pRes.url, seekTo: resumeTime, disableVideoTrack: true, autoPlay: autoPlay)
                return
            }
        }

        isAudioOnly = false
        audioOnlyOverlay.isHidden = true

        // 4. Pick compatible MP4 video formats (H.264 preferred for hardware decode + low RAM, AV1 for >1080p)
        let mp4Videos = resp.videoFormats.filter { $0.isMP4 && ($0.isH264 || $0.isAV1) && $0.initRange != nil && $0.indexRange != nil }
        var selectedVideos: [StreamFormat] = []

        if selectedQuality == "Auto" {
            var seenHeights = Set<Int>()
            for vf in mp4Videos where vf.height <= 1080 {
                if seenHeights.insert(vf.height).inserted {
                    selectedVideos.append(vf)
                }
            }
        } else {
            let targetHeight = Int(selectedQuality.replacingOccurrences(of: "p60", with: "").replacingOccurrences(of: "p", with: "")) ?? 1080
            if let exact = mp4Videos.first(where: { $0.height == targetHeight }) {
                selectedVideos = [exact]
            } else if let bestUnder = mp4Videos.first(where: { $0.height <= targetHeight }) {
                selectedVideos = [bestUnder]
            } else if let first = mp4Videos.first {
                selectedVideos = [first]
            }
        }

        activeVideoFormat = selectedVideos.first
        activeAudioFormat = chosenAudio

        // Probe whether adaptive DASH is unrestricted past 75%; if YouTube's GVS PO-Token gates it with 403,
        // transparently switch to our unrestricted loopback Range-proxied progressive MP4 stream!
        if let probeTarget = selectedVideos.first {
            LocalHLSServer.shared.probeAdaptiveUnrestricted(format: probeTarget) { [weak self] unrestricted in
                guard let self = self, self.streamGeneration == gen else { return }
                if unrestricted {
                    LocalHLSServer.shared.prepareSession(videoFormats: selectedVideos, audioFormat: chosenAudio, previousSessionId: self.activeHLSSessionId) { [weak self] res in
                        guard let self = self, self.streamGeneration == gen else { return }
                        switch res {
                        case .failure:
                            if let prog = resp.progressiveFormats.first {
                                self.activeVideoFormat = prog
                                self.activeAudioFormat = prog
                                let pRes = LocalHLSServer.shared.prepareProgressiveSession(format: prog, previousSessionId: self.activeProgSessionId)
                                self.activeProgSessionId = pRes.sessionId
                                self.attachPlayerURL(pRes.url, seekTo: resumeTime, autoPlay: autoPlay)
                            } else {
                                self.loadingSpinner.stopAnimation(nil)
                                self.showError("Failed to prepare stream.")
                            }
                        case .success(let (sid, masterURL)):
                            self.activeHLSSessionId = sid
                            self.attachPlayerURL(masterURL, seekTo: resumeTime, autoPlay: autoPlay)
                        }
                    }
                } else if let prog = resp.progressiveFormats.first {
                    DispatchQueue.main.async {
                        guard self.streamGeneration == gen else { return }
                        self.activeVideoFormat = prog
                        self.activeAudioFormat = prog
                        let pRes = LocalHLSServer.shared.prepareProgressiveSession(format: prog, previousSessionId: self.activeProgSessionId)
                        self.activeProgSessionId = pRes.sessionId
                        self.attachPlayerURL(pRes.url, seekTo: resumeTime, autoPlay: autoPlay)
                    }
                } else {
                    // No progressive fallback; still try HLS session
                    LocalHLSServer.shared.prepareSession(videoFormats: selectedVideos, audioFormat: chosenAudio, previousSessionId: self.activeHLSSessionId) { [weak self] res in
                        guard let self = self, self.streamGeneration == gen else { return }
                        if case .success(let (sid, masterURL)) = res {
                            self.activeHLSSessionId = sid
                            self.attachPlayerURL(masterURL, seekTo: resumeTime, autoPlay: autoPlay)
                        } else {
                            self.loadingSpinner.stopAnimation(nil)
                            self.showError("Stream restricted by YouTube.")
                        }
                    }
                }
            }
            return
        }

        if let prog = resp.progressiveFormats.first {
            activeVideoFormat = prog
            activeAudioFormat = prog
            let pRes = LocalHLSServer.shared.prepareProgressiveSession(format: prog, previousSessionId: activeProgSessionId)
            activeProgSessionId = pRes.sessionId
            attachPlayerURL(pRes.url, seekTo: resumeTime, autoPlay: autoPlay)
            return
        }

        loadingSpinner.stopAnimation(nil)
        showError("No compatible video stream found for this video.")
    }

    private func attachPlayerURL(_ url: URL, seekTo resumeTime: Double?, disableVideoTrack: Bool = false, autoPlay: Bool = true) {
        let sGen = streamGeneration
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        // CRITICAL MEMORY CAP: limit forward buffer to 5s (instead of AVPlayer's 60s default!)
        let memMB = MemoryMonitor.currentFootprintMB()
        item.preferredForwardBufferDuration = memMB > 80 ? 3.0 : 5.0
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false

        itemStatusObs?.invalidate()
        itemStatusObs = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            DispatchQueue.main.async {
                guard let self = self, self.streamGeneration == sGen else { return }
                switch it.status {
                case .readyToPlay:
                    self.loadingSpinner.stopAnimation(nil)
                    if disableVideoTrack {
                        for tr in it.tracks where tr.assetTrack?.mediaType == .video {
                            tr.isEnabled = false
                        }
                    }
                    if let t = resumeTime, t > 0.25 {
                        self.player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                            guard let self = self, self.streamGeneration == sGen else { return }
                            if autoPlay {
                                self.player.playImmediately(atRate: self.playbackRate)
                            }
                            self.updatePlayPauseIcon()
                            self.updateNowPlaying()
                            self.scheduleHideControls()
                        }
                    } else {
                        if autoPlay {
                            self.player.playImmediately(atRate: self.playbackRate)
                        }
                        self.updatePlayPauseIcon()
                        self.updateNowPlaying()
                        self.scheduleHideControls()
                    }
                case .failed:
                    self.loadingSpinner.stopAnimation(nil)
                    self.showError("Playback failed. Open the video in your browser to watch it.")
                default: break
                }
            }
        }

        if let endObs = itemEndObserver { NotificationCenter.default.removeObserver(endObs) }
        itemEndObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            if self.isLooping {
                self.seek(to: 0)
                self.player.playImmediately(atRate: self.playbackRate)
            } else {
                self.updatePlayPauseIcon()
                self.delegate?.playerDidFinishVideo(self)
            }
        }

        player.replaceCurrentItem(with: item)
        player.automaticallyWaitsToMinimizeStalling = true
        player.volume = volumeSlider.floatValue
    }

    func pausePlayback() {
        if player.currentItem == nil {
            videoLoadGeneration += 1
            streamGeneration += 1
            loadingSpinner.stopAnimation(nil)
        }
        player.pause()
        updatePlayPauseIcon()
        showControlsTemporarily(autoHide: false)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func stopAndReleaseMemory() {
        videoLoadGeneration += 1
        streamGeneration += 1
        loadingSpinner.stopAnimation(nil)
        itemStatusObs?.invalidate()
        itemStatusObs = nil
        if let endObs = itemEndObserver {
            NotificationCenter.default.removeObserver(endObs)
            itemEndObserver = nil
        }
        hideControlsWork?.cancel()
        hudWork?.cancel()
        toastWork?.cancel()
        previewPopup.isHidden = true
        hudBadge.isHidden = true
        toastView.isHidden = true
        pendingSeekSeconds = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let sid = activeHLSSessionId {
            LocalHLSServer.shared.removeSession(id: sid)
            activeHLSSessionId = nil
        }
        if let pid = activeProgSessionId {
            LocalHLSServer.shared.removeProgressiveSession(id: pid)
            activeProgSessionId = nil
        }
        updatePlayPauseIcon()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Observers & Periodic Sync

    private func setupPlayerObservers() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] cmTime in
            guard let self = self else { return }
            let t = cmTime.seconds.isFinite ? max(0, cmTime.seconds) : 0
            let d = self.duration
            self.scrubber.currentTime = t
            self.scrubber.duration = d
            self.timeLabel.stringValue = "\(Formatters.timeString(t)) / \(Formatters.timeString(d))"

            // Buffered range
            if let range = self.player.currentItem?.loadedTimeRanges.first?.timeRangeValue {
                let bufEnd = range.start.seconds + range.duration.seconds
                if bufEnd.isFinite { self.scrubber.bufferedTime = bufEnd }
            }

            // Captions overlay
            self.updateCaptionOverlay(at: t)
            // Chapter pill
            self.updateActiveChapterLabel(at: t)
            // SponsorBlock auto-skip
            self.checkSponsorSkip(at: t)
            // Stats for Nerds
            if self.showStatsForNerds { self.refreshStatsForNerds() }
            // Notify delegate
            self.delegate?.playerDidUpdateTime(self, currentTime: t, duration: d)
        }
    }

    private func updateCaptionOverlay(at time: Double) {
        guard isCaptionsOn, !captionCues.isEmpty else {
            captionBox.isHidden = true
            return
        }
        if let cue = captionCues.first(where: { time >= $0.startTime && time <= $0.endTime }) {
            captionLabel.stringValue = cue.text
            captionBox.isHidden = false
        } else {
            captionBox.isHidden = true
        }
    }

    private func updateActiveChapterLabel(at time: Double) {
        let narrow = bounds.width > 0 && bounds.width < 680
        guard !chapters.isEmpty, !isMiniMode, !narrow else {
            chapterPillBtn.isHidden = true
            return
        }
        let active = chapters.last(where: { $0.startSeconds <= time + 0.5 }) ?? chapters.first
        if let ch = active {
            chapterPillBtn.attributedTitle = NSAttributedString(
                string: "• \(ch.title) ▸",
                attributes: [
                    .foregroundColor: YTTheme.playerChapterText,
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium)
                ]
            )
            chapterPillBtn.isHidden = false
        }
    }

    private func checkSponsorSkip(at time: Double) {
        guard LocalStore.shared.settings.sponsorBlockEnabled,
              LocalStore.shared.settings.sponsorBlockAutoSkip,
              isPlaying else { return }
        for seg in sponsorSegments {
            if time >= seg.startTime && time < seg.endTime - 0.5 && !skippedSegmentIds.contains(seg.id) {
                skippedSegmentIds.insert(seg.id)
                lastSkippedStart = seg.startTime
                seek(to: seg.endTime)
                showToast("Skipped \(seg.displayName)")
                break
            }
        }
    }

    private func handleScrubHover(time: Double?, x: CGFloat) {
        guard let t = time, !isMiniMode else {
            hoverCropIndex = -1
            previewPopup.isHidden = true
            return
        }
        let hasThumb = (storyboard != nil)
        previewImage.isHidden = !hasThumb
        previewImageHeightConstraint.constant = hasThumb ? 90 : 0

        if let ch = chapters.last(where: { $0.startSeconds <= t }) {
            previewChapterLabel.stringValue = ch.title
            previewChapterLabel.isHidden = false
        } else {
            previewChapterLabel.stringValue = ""
            previewChapterLabel.isHidden = true
        }
        previewTimeLabel.stringValue = Formatters.timeString(t)
        previewPopup.layoutSubtreeIfNeeded()
        let fit = previewPopup.fittingSize
        let popupW: CGFloat = hasThumb ? 168 : max(72, min(180, ceil(fit.width)))
        let popupH: CGFloat = max(28, ceil(fit.height))
        let clampedX = max(8, min(bounds.width - popupW - 8, x - popupW / 2))
        let popupY = controlsContainer.frame.maxY + 4
        previewPopup.frame = NSRect(x: clampedX, y: popupY, width: popupW, height: popupH)
        previewPopup.isHidden = false

        // Crop storyboard frame if available
        if let sb = storyboard {
            let vGen = videoLoadGeneration
            let idx = max(0, min(sb.thumbCount - 1, Int((t * 1000.0) / sb.intervalMs)))
            hoverCropIndex = idx
            let perSheet = sb.cols * sb.rows
            let sheetIdx = idx / perSheet
            let inSheet = idx % perSheet
            let row = inSheet / sb.cols
            let col = inSheet % sb.cols
            let url = sb.urlTemplate.replacingOccurrences(of: "$M", with: "\(sheetIdx)")
            ImageCache.shared.loadStoryboardSheet(url) { [weak self] cg in
                guard let self = self, self.videoLoadGeneration == vGen, self.hoverCropIndex == idx, let cg = cg else { return }
                let rawCrop = CGRect(x: col * sb.thumbWidth, y: row * sb.thumbHeight, width: sb.thumbWidth, height: sb.thumbHeight)
                let clampedCrop = rawCrop.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
                guard !clampedCrop.isEmpty, let sub = cg.cropping(to: clampedCrop) else { return }
                self.previewImage.image = NSImage(cgImage: sub, size: NSSize(width: clampedCrop.width, height: clampedCrop.height))
            }
        } else {
            hoverCropIndex = -1
        }
    }

    // MARK: - Playback Controls & Keyboard Shortcuts

    @objc func togglePlayPause() {
        PlayerView.activeRemoteOwner = self
        if isPlaying {
            player.pause()
            flashHUD("Paused")
            showControlsTemporarily(autoHide: false)
        } else {
            player.playImmediately(atRate: playbackRate)
            flashHUD("Play")
            scheduleHideControls()
        }
        updatePlayPauseIcon()
        updateNowPlaying()
    }

    func seek(to seconds: Double) {
        let clamped = max(0, min(duration > 0 ? duration : seconds, seconds))
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        scrubber.currentTime = clamped
        updateNowPlaying()
    }

    func seekRelative(_ delta: Double) {
        seek(to: currentTime + delta)
        let arrow = delta >= 0 ? "+\(Int(delta))s" : "\(Int(delta))s"
        flashHUD(arrow)
    }

    func stepFrame(_ count: Int) {
        player.pause()
        player.currentItem?.step(byCount: count)
        updatePlayPauseIcon()
    }

    func adjustVolume(_ delta: Float) {
        let next = max(0, min(1, player.volume + delta))
        player.volume = next
        player.isMuted = (next == 0)
        volumeSlider.floatValue = next
        if next > 0 { lastVolume = next }
        updateMuteIcon()
        flashHUD("Volume \(Int(next * 100))%")
    }

    func adjustSpeed(_ delta: Float) {
        let speeds = PlayerView.playbackSpeeds
        let curIdx = speeds.firstIndex(where: { abs($0 - playbackRate) < 0.05 }) ?? 3
        let nextIdx = max(0, min(speeds.count - 1, curIdx + (delta > 0 ? 1 : -1)))
        setPlaybackRate(speeds[nextIdx])
    }

    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying { player.rate = rate }
        flashHUD("\(String(format: "%g", rate))× Speed")
        updateNowPlaying()
    }

    @objc func toggleMute() {
        if player.isMuted || player.volume == 0 {
            player.isMuted = false
            player.volume = max(0.15, lastVolume)
            volumeSlider.floatValue = player.volume
            flashHUD("Volume \(Int(player.volume * 100))%")
        } else {
            lastVolume = player.volume
            player.isMuted = true
            volumeSlider.floatValue = 0
            flashHUD("Muted")
        }
        updateMuteIcon()
    }

    @objc private func volumeChanged() {
        let v = volumeSlider.floatValue
        player.volume = v
        player.isMuted = (v == 0)
        if v > 0 { lastVolume = v }
        updateMuteIcon()
    }

    @objc func toggleCaptions() {
        isCaptionsOn.toggle()
        updateCCIcon()
        updateCaptionOverlay(at: currentTime)
        flashHUD(isCaptionsOn ? "CC On" : "CC Off")
    }

    @objc private func toggleAutoplay() {
        var s = LocalStore.shared.settings
        s.autoplayNext.toggle()
        LocalStore.shared.settings = s
        updateAutoplayIcon()
        flashHUD(s.autoplayNext ? "Autoplay On" : "Autoplay Off")
    }

    @objc private func nextClicked() { delegate?.playerDidRequestNext(self) }
    @objc private func chapterPillClicked() { delegate?.playerDidSelectChapterList(self) }
    @objc private func miniClicked() { delegate?.playerDidToggleMiniplayer(self) }
    @objc private func theaterClicked() { delegate?.playerDidToggleTheater(self) }
    @objc private func fullscreenClicked() { delegate?.playerDidToggleFullscreen(self) }

    @objc private func togglePiP() {
        guard let pip = pipController else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() }
        else { pip.startPictureInPicture() }
    }

    @objc private func unskipSponsor() {
        if let start = lastSkippedStart {
            seek(to: start)
            toastView.isHidden = true
        }
    }

    // MARK: - Settings Gear Menu (Quality, Speed, CC Track, Audio-Only, SponsorBlock, Loop, Stats)

    @objc private func showSettingsMenu() {
        let menu = NSMenu()

        // 1. Quality submenu
        let qItem = NSMenuItem(title: "Quality (\(isAudioOnly ? "Audio Only" : selectedQuality))", action: nil, keyEquivalent: "")
        let qMenu = NSMenu()
        var availableQualities: [String] = ["Auto"]
        if let resp = currentPlayerResponse {
            var heights = Set<Int>()
            for vf in resp.videoFormats where vf.isMP4 && (vf.isH264 || vf.isAV1) && vf.initRange != nil && vf.height > 0 {
                heights.insert(vf.height)
            }
            for h in heights.sorted(by: >) {
                availableQualities.append("\(h)p")
            }
        }
        availableQualities.append("Audio Only")

        for q in availableQualities {
            let mi = NSMenuItem(title: q == "Audio Only" ? "Audio Only (~30 MB RAM)" : q, action: #selector(pickQuality(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = q
            mi.state = ((isAudioOnly && q == "Audio Only") || (!isAudioOnly && selectedQuality == q)) ? .on : .off
            qMenu.addItem(mi)
        }
        qItem.submenu = qMenu
        menu.addItem(qItem)

        // 2. Playback Speed submenu
        let sItem = NSMenuItem(title: "Playback Speed (\(String(format: "%g", playbackRate))×)", action: nil, keyEquivalent: "")
        let sMenu = NSMenu()
        for sp in PlayerView.playbackSpeeds {
            let label = sp == 1.0 ? "Normal (1×)" : "\(String(format: "%g", sp))×"
            let mi = NSMenuItem(title: label, action: #selector(pickSpeed(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = NSNumber(value: sp)
            mi.state = abs(playbackRate - sp) < 0.05 ? .on : .off
            sMenu.addItem(mi)
        }
        sItem.submenu = sMenu
        menu.addItem(sItem)

        // 3. Captions track submenu
        if !captionTracks.isEmpty {
            let cItem = NSMenuItem(title: "Subtitles / CC", action: nil, keyEquivalent: "")
            let cMenu = NSMenu()
            let offItem = NSMenuItem(title: "Off", action: #selector(pickCaptionOff), keyEquivalent: "")
            offItem.target = self
            offItem.state = !isCaptionsOn ? .on : .off
            cMenu.addItem(offItem)
            cMenu.addItem(.separator())
            for tr in captionTracks {
                let lbl = tr.isAutoGenerated ? "\(tr.name) (auto)" : tr.name
                let mi = NSMenuItem(title: lbl, action: #selector(pickCaptionTrack(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = tr
                mi.state = (isCaptionsOn && selectedCaptionTrack?.id == tr.id) ? .on : .off
                cMenu.addItem(mi)
            }
            cItem.submenu = cMenu
            menu.addItem(cItem)
        }

        menu.addItem(.separator())

        // 4. Loop
        let loopItem = NSMenuItem(title: "Loop Video", action: #selector(toggleLoop), keyEquivalent: "")
        loopItem.target = self
        loopItem.state = isLooping ? .on : .off
        menu.addItem(loopItem)

        // 5. SponsorBlock
        let sbItem = NSMenuItem(title: "SponsorBlock Auto-Skip", action: #selector(toggleSponsorBlock), keyEquivalent: "")
        sbItem.target = self
        sbItem.state = LocalStore.shared.settings.sponsorBlockAutoSkip ? .on : .off
        menu.addItem(sbItem)

        // 6. Stats for Nerds
        let statsItem = NSMenuItem(title: "Stats for Nerds", action: #selector(toggleStatsForNerds), keyEquivalent: "")
        statsItem.target = self
        statsItem.state = showStatsForNerds ? .on : .off
        menu.addItem(statsItem)

        isSettingsMenuOpen = true
        hideControlsWork?.cancel()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: settingsBtn.bounds.height + 6), in: settingsBtn)
        isSettingsMenuOpen = false
        if isPlaying { scheduleHideControls() }
    }

    @objc private func pickQuality(_ sender: NSMenuItem) {
        guard let q = sender.representedObject as? String else { return }
        let t = currentTime
        let wasPlaying = isPlaying
        isAudioOnly = (q == "Audio Only")
        selectedQuality = q
        startSelectedQuality(seekTo: t, autoPlay: wasPlaying)
        flashHUD(q)
    }

    @objc private func pickSpeed(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? NSNumber else { return }
        setPlaybackRate(n.floatValue)
    }

    @objc private func pickCaptionOff() {
        isCaptionsOn = false
        updateCCIcon()
        captionBox.isHidden = true
    }

    @objc private func pickCaptionTrack(_ sender: NSMenuItem) {
        guard let tr = sender.representedObject as? CaptionTrack else { return }
        isCaptionsOn = true
        updateCCIcon()
        loadCaptionTrack(tr)
    }

    @objc private func toggleLoop() {
        isLooping.toggle()
        flashHUD(isLooping ? "Loop On" : "Loop Off")
    }

    @objc private func toggleSponsorBlock() {
        var s = LocalStore.shared.settings
        s.sponsorBlockAutoSkip.toggle()
        LocalStore.shared.settings = s
        flashHUD(s.sponsorBlockAutoSkip ? "SponsorBlock On" : "SponsorBlock Off")
    }

    @objc private func toggleStatsForNerds() {
        showStatsForNerds.toggle()
        statsBox.isHidden = !showStatsForNerds
        if showStatsForNerds { refreshStatsForNerds() }
    }

    private func refreshStatsForNerds() {
        let vid = currentVideo?.id ?? "-"
        let vf = activeVideoFormat
        let af = activeAudioFormat
        let res = isAudioOnly ? "Audio Only" : (vf != nil ? "\(vf!.width)×\(vf!.height)@\(vf!.fps) (\(vf!.codecShortName) itag \(vf!.itag))" : "Auto")
        let aud = af != nil ? "\(af!.codecShortName) \(af!.bitrate/1000) kbps (itag \(af!.itag))" : "-"
        let buf = max(0, scrubber.bufferedTime - currentTime)
        let mem = MemoryMonitor.detailedStats()
        statsLabel.stringValue = """
        Video ID:  \(vid)
        Video:     \(res)
        Audio:     \(aud)
        Buffer:    \(String(format: "%.1fs", buf)) (capped @ 5s)
        App RAM:   \(String(format: "%.1f MB", mem.footprintMB)) phys_footprint (img cache \(String(format: "%.1f MB", mem.imageCacheMB)))
        """
    }

    // MARK: - Keyboard Shortcut Dispatcher

    func handleKeyEvent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.shift, .command, .option, .control])
        guard !flags.contains(.command), !flags.contains(.control), !flags.contains(.option) else { return false }
        let chars = event.charactersIgnoringModifiers ?? ""

        if flags.contains(.shift) {
            if chars == "N" || chars == "n" { delegate?.playerDidRequestNext(self); return true }
            if chars == "P" || chars == "p" { delegate?.playerDidRequestPrevious(self); return true }
            if chars == ">" || chars == "." { adjustSpeed(0.25); return true }
            if chars == "<" || chars == "," { adjustSpeed(-0.25); return true }
        }

        switch event.keyCode {
        case 49: togglePlayPause(); return true // Space
        case 123: seekRelative(event.modifierFlags.contains(.shift) ? -10 : -5); return true // Left (Shift = 10s)
        case 124: seekRelative(event.modifierFlags.contains(.shift) ? 10 : 5); return true  // Right (Shift = 10s)
        case 126: adjustVolume(0.05); return true // Up
        case 125: adjustVolume(-0.05); return true // Down
        case 53: // Escape leaves fullscreen, as in every macOS video app
            guard let win = window, win.styleMask.contains(.fullScreen) else { return false }
            win.toggleFullScreen(nil); return true
        default: break
        }

        switch chars.lowercased() {
        case "k": togglePlayPause(); return true
        case "j": seekRelative(-10); return true
        case "l": seekRelative(10); return true
        case "m": toggleMute(); return true
        case "c": toggleCaptions(); return true
        case "f": delegate?.playerDidToggleFullscreen(self); return true
        case "t": delegate?.playerDidToggleTheater(self); return true
        case "i": delegate?.playerDidToggleMiniplayer(self); return true
        case ",": stepFrame(-1); return true
        case ".": stepFrame(1); return true
        case "0"..."9":
            if let digit = Int(chars), duration > 0 {
                seek(to: duration * Double(digit) / 10.0)
                flashHUD("\(digit * 10)%")
                return true
            }
        default: break
        }
        return false
    }

    // MARK: - Helpers & macOS Now Playing

    private func updatePlayPauseIcon() {
        let playing = isPlaying
        let sym = playing ? "pause.fill" : "play.fill"
        let cfg = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        playPauseBtn.image = NSImage(systemSymbolName: sym, accessibilityDescription: playing ? "Pause" : "Play")?.withSymbolConfiguration(cfg)
        playPauseBtn.setAccessibilityLabel(playing ? "Pause" : "Play")
        onPlayStateChanged?(playing)
    }

    private func updateMuteIcon() {
        let sym: String
        let label: String
        if player.isMuted || player.volume == 0 {
            sym = "speaker.slash.fill"
            label = "Unmute"
        } else if player.volume < 0.45 {
            sym = "speaker.wave.1.fill"
            label = "Mute (low volume)"
        } else {
            sym = "speaker.wave.2.fill"
            label = "Mute"
        }
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        muteBtn.image = NSImage(systemSymbolName: sym, accessibilityDescription: label)?.withSymbolConfiguration(cfg)
        muteBtn.setAccessibilityLabel(label)
    }

    private func updateAutoplayIcon() {
        let on = LocalStore.shared.settings.autoplayNext
        autoplayBtn.contentTintColor = on ? YTTheme.red : NSColor.white.withAlphaComponent(0.85)
        autoplayBtn.accessibilityValueText = on ? "On" : "Off"
    }

    private func updateCCIcon() {
        ccBtn.contentTintColor = isCaptionsOn ? YTTheme.red : NSColor.white.withAlphaComponent(0.85)
        ccBtn.accessibilityValueText = isCaptionsOn ? "On" : "Off"
    }

    private func showControlsTemporarily(autoHide: Bool = true) {
        hideControlsWork?.cancel()
        controlsContainer.isHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = motionDuration(0.15)
            controlsContainer.animator().alphaValue = 1
        }
        if autoHide && isPlaying { scheduleHideControls() }
    }

    /// Keyboard users tabbing through the bar must not lose it while a control inside has focus.
    private func isFocusInsideControls() -> Bool {
        guard let fr = window?.firstResponder as? NSView else { return false }
        return fr.isDescendant(of: controlsContainer)
    }

    private func isPointerInsideControls() -> Bool {
        guard let win = window, !controlsContainer.isHidden else { return false }
        let pt = controlsContainer.convert(win.mouseLocationOutsideOfEventStream, from: nil)
        return controlsContainer.bounds.contains(pt)
    }

    private func scheduleHideControls(delay: TimeInterval = 2.6) {
        hideControlsWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.isPlaying else { return }
            if self.isSettingsMenuOpen || self.isPointerInsideControls() || self.isFocusInsideControls() {
                self.scheduleHideControls(delay: 1.5)
                return
            }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = motionDuration(0.25)
                self.controlsContainer.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self = self, self.isPlaying, !self.isSettingsMenuOpen, self.controlsContainer.alphaValue <= 0.01 else { return }
                self.controlsContainer.isHidden = true
            })
        }
        hideControlsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func flashHUD(_ text: String) {
        let token = UUID()
        hudToken = token
        hudLabel.stringValue = text
        hudBadge.isHidden = false
        hudBadge.alphaValue = 1
        hudWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = motionDuration(0.25)
                self?.hudBadge.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self = self, self.hudToken == token, self.hudBadge.alphaValue <= 0.01 else { return }
                self.hudBadge.isHidden = true
            })
        }
        hudWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: w)
    }

    private func showToast(_ text: String) {
        toastLabel.stringValue = text
        toastView.isHidden = false
        postAccessibilityAnnouncement(text)
        toastWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.toastView.isHidden = true }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5, execute: w)
    }

    private func showError(_ msg: String) {
        errorLabel.stringValue = msg
        errorLabel.isHidden = false
        postAccessibilityAnnouncement(msg)
    }

    private func setupRemoteCommands() {
        PlayerView.activeRemoteOwner = self
        guard !PlayerView.remoteHandlersInstalled else { return }
        PlayerView.remoteHandlersInstalled = true
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.addTarget { _ in
            guard let owner = PlayerView.activeRemoteOwner else { return .commandFailed }
            if !owner.isPlaying { owner.togglePlayPause() }
            return .success
        }
        cc.pauseCommand.addTarget { _ in
            guard let owner = PlayerView.activeRemoteOwner else { return .commandFailed }
            if owner.isPlaying { owner.togglePlayPause() }
            return .success
        }
        cc.togglePlayPauseCommand.addTarget { _ in
            guard let owner = PlayerView.activeRemoteOwner else { return .commandFailed }
            owner.togglePlayPause()
            return .success
        }
        cc.nextTrackCommand.addTarget { _ in
            guard let owner = PlayerView.activeRemoteOwner else { return .commandFailed }
            owner.delegate?.playerDidRequestNext(owner)
            return .success
        }
        cc.previousTrackCommand.addTarget { _ in
            guard let owner = PlayerView.activeRemoteOwner else { return .commandFailed }
            owner.delegate?.playerDidRequestPrevious(owner)
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let v = currentVideo else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentPlayerResponse?.title.isEmpty == false ? currentPlayerResponse!.title : v.title,
            MPMediaItemPropertyArtist: currentPlayerResponse?.author.isEmpty == false ? currentPlayerResponse!.author : v.channelName,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? playbackRate : 0.0
        ]
        if let img = audioOnlyThumb.image {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

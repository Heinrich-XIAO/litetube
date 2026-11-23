import AppKit

/// A slim bar at the top of every page while an update is available, installing, or has failed.
/// It reads the same AppUpdater state as the Settings section, so both always agree.
final class UpdateBanner: NSView {
    static let height: CGFloat = 40
    static let dismissedKey = "updateDismissedVersion"

    private let label = makeLabel("", size: 13, weight: .medium, maxLines: 1)
    private let actionBtn = PillButton()
    private let dismissBtn = PillButton()
    private(set) var isShown = false
    /// Called when the banner appears or disappears, so the page layout can make room for it.
    var onVisibilityChange: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = true

        actionBtn.cornerRadiusValue = 15
        actionBtn.isSelectedPill = true
        actionBtn.target = self; actionBtn.action = #selector(actionClicked)
        dismissBtn.title = "Dismiss"
        dismissBtn.cornerRadiusValue = 15
        dismissBtn.target = self; dismissBtn.action = #selector(dismissClicked)

        let row = NSStackView(views: [label, actionBtn, dismissBtn])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            row.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: AppUpdater.didChange, object: nil)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func actionClicked() { AppUpdater.shared.startInstall() }

    @objc private func dismissClicked() {
        AppUpdater.shared.dismissBanner()
    }

    @objc func refresh() {
        let u = AppUpdater.shared
        let s = u.status
        let latest = s.latest ?? ""
        var text: String?
        var action: String?
        var canDismiss = true

        switch s.phase {
        case .downloading:
            text = "Downloading LiteTube \(latest)… \(s.pct)%"
            canDismiss = false
        case .installing:
            text = "Installing LiteTube \(latest)…"
            canDismiss = false
        case .ready:
            text = "macOS Installer is finishing the update."
            canDismiss = false
        case .failed:
            text = "The update failed: \(s.error ?? "unknown error")"
            action = "Try Again"
        case .idle, .checking:
            if s.available, !latest.isEmpty, UserDefaults.standard.string(forKey: UpdateBanner.dismissedKey) != latest {
                if u.canInstall {
                    text = "LiteTube \(latest) is available."
                    action = "Install"
                } else {
                    text = "LiteTube \(latest) is available. Move LiteTube to Applications to install it."
                }
            }
        }

        label.stringValue = text ?? ""
        label.setAccessibilityValue(text ?? "")
        actionBtn.isHidden = action == nil
        actionBtn.title = action ?? ""
        dismissBtn.isHidden = !canDismiss
        let shown = text != nil
        isHidden = !shown
        if shown != isShown {
            isShown = shown
            onVisibilityChange?()
        }
    }
}

import AppKit

/// The "Updates" group in Settings: current version, status, release notes, and the check and install buttons.
final class UpdatesSection: NSView {
    private let versionLabel = makeLabel("", size: 12, weight: .medium, color: YTTheme.textSecondary, maxLines: 1)
    private let statusLabel = makeLabel("", size: 13, maxLines: 2)
    private let notesLabel = makeLabel("", size: 12, color: YTTheme.textSecondary, maxLines: 6)
    private let rollbackLabel = makeLabel("", size: 12, color: YTTheme.textSecondary, maxLines: 3)
    private let checkBtn = PillButton()
    private let installBtn = PillButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        checkBtn.title = "Check for Updates"
        checkBtn.cornerRadiusValue = 16
        checkBtn.target = self; checkBtn.action = #selector(checkClicked)
        checkBtn.setAccessibilityLabel("Check for updates")

        installBtn.cornerRadiusValue = 16
        installBtn.isSelectedPill = true
        installBtn.target = self; installBtn.action = #selector(installClicked)
        installBtn.isHidden = true

        let buttons = NSStackView(views: [checkBtn, installBtn])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.alignment = .centerY

        let stack = NSStackView(views: [versionLabel, statusLabel, notesLabel, rollbackLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        // Labels wrap only when pinned to the section's width; a leading-aligned label otherwise keeps its one-line width.
        for label in [statusLabel, notesLabel, rollbackLabel, versionLabel] {
            label.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: AppUpdater.didChange, object: nil)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func checkClicked() { AppUpdater.shared.checkNow() }
    @objc private func installClicked() { AppUpdater.shared.startInstall() }

    @objc private func refresh() {
        let u = AppUpdater.shared
        let s = u.status
        versionLabel.stringValue = "Version \(u.currentVersion)"

        var text: String
        switch s.phase {
        case .checking: text = "Checking for updates…"
        case .downloading: text = "Downloading the update… \(s.pct)%"
        case .installing: text = "Installing the update…"
        case .ready: text = "macOS Installer is finishing the update."
        case .failed: text = s.error ?? "The update failed."
        case .idle:
            if s.available, let latest = s.latest {
                text = "Version \(latest) is available."
            } else if let err = s.error {
                text = err
            } else if s.checked != nil {
                text = "LiteTube is up to date."
            } else {
                text = "Check for updates to see if a new version is available."
            }
        }
        if s.available && !u.canInstall && s.phase == .idle {
            text += " Move LiteTube to Applications to install it from here."
        }
        statusLabel.stringValue = text
        statusLabel.setAccessibilityValue(text)

        let busy = s.phase == .checking || s.phase == .downloading || s.phase == .installing || s.phase == .ready
        checkBtn.isEnabled = !busy
        installBtn.title = s.latest.map { "Install \($0)" } ?? "Install Update"
        installBtn.isEnabled = !busy && u.canInstall
        installBtn.isHidden = !(s.available && (s.phase == .idle || s.phase == .failed))

        notesLabel.stringValue = (s.available ? (s.notes ?? "") : "").trimmingCharacters(in: .whitespacesAndNewlines)
        notesLabel.isHidden = notesLabel.stringValue.isEmpty

        rollbackLabel.stringValue = u.rollbackAvailable
            ? "The previous version is kept at /Applications/LiteTube.app.old. To restore it, quit LiteTube and replace /Applications/LiteTube.app with that copy."
            : ""
        rollbackLabel.isHidden = rollbackLabel.stringValue.isEmpty
    }
}

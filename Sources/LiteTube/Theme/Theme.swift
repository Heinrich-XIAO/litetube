import AppKit
import Darwin

// MARK: - YouTube Exact Color System (Dark & Light)

enum YTTheme {
    static var isDark: Bool { LocalStore.shared.settings.darkMode }

    private static func dyn(_ darkHex: UInt32, _ darkAlpha: CGFloat = 1.0, _ lightHex: UInt32, _ lightAlpha: CGFloat = 1.0) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return dark ? NSColor(hex: darkHex, alpha: darkAlpha) : NSColor(hex: lightHex, alpha: lightAlpha)
        }
    }

    static let bg = dyn(0x0F0F0F, 1.0, 0xFFFFFF, 1.0)
    static let bgElevated = dyn(0x181818, 1.0, 0xF9F9F9, 1.0)
    static let surface = dyn(0x272727, 1.0, 0xF2F2F2, 1.0)
    static let surfaceHover = dyn(0x3F3F3F, 1.0, 0xE5E5E5, 1.0)
    static let searchBg = dyn(0x121212, 1.0, 0xFFFFFF, 1.0)
    static let border = dyn(0x626262, 1.0, 0x8A8A8A, 1.0)
    static let divider = dyn(0x272727, 1.0, 0xE5E5E5, 1.0)
    static let textPrimary = dyn(0xF1F1F1, 1.0, 0x0F0F0F, 1.0)
    static let textSecondary = dyn(0xAAAAAA, 1.0, 0x606060, 1.0)
    static let chipActiveBg = dyn(0xF1F1F1, 1.0, 0x0F0F0F, 1.0)
    static let chipActiveText = dyn(0x0F0F0F, 1.0, 0xFFFFFF, 1.0)
    static let red = NSColor(hex: 0xFF0033)
    static let liveRed = NSColor(hex: 0xCC0000)
    static let linkBlue = dyn(0x3EA6FF, 1.0, 0x065FD4, 1.0)
    // Player surfaces stay dark in both themes, so they have fixed tokens instead of inline hex values.
    static let playerOverlayBg = NSColor(hex: 0x111111)
    static let playerToastBg = NSColor(hex: 0x1E1E1E, alpha: 0.92)
    static let playerToastLink = NSColor(hex: 0x3EA6FF)
    static let playerCaptionBg = NSColor.black.withAlphaComponent(0.78)
    static let playerGradientTop = NSColor.black.withAlphaComponent(0.85)
    static let mainToastBg = NSColor(hex: 0x222222, alpha: 0.94)
    static let playerScrim = NSColor.black.withAlphaComponent(0.9)
    static let progressTrackBg = NSColor.white.withAlphaComponent(0.5)
    static let durationBadgeBg = NSColor.black.withAlphaComponent(0.84)
    static let playerBadgeBg = NSColor.black.withAlphaComponent(0.72)
    static let playerChapterText = NSColor.white.withAlphaComponent(0.92)
    static let greenGood = NSColor(hex: 0x2BA640)
    static let amberWarn = NSColor(hex: 0xF59E0B)
    // Healthy memory is shown quietly; amber and red stay loud because they signal a problem.
    static let ramGreenFg = dyn(0xAAAAAA, 1.0, 0x555555, 1.0)
    static let ramGreenBg = dyn(0x272727, 1.0, 0xF0F0F0, 1.0)
    static let ramAmberFg = dyn(0xFBBF24, 1.0, 0x854D0E, 1.0)
    static let ramAmberBg = dyn(0xFBBF24, 0.20, 0xFEF3C7, 1.0)
    static let ramRedFg = dyn(0xFF6B81, 1.0, 0x9F1239, 1.0)
    static let ramRedBg = dyn(0xFF6B81, 0.20, 0xFFE4E6, 1.0)

    static func sponsorColor(for category: String) -> NSColor {
        switch category {
        case "sponsor": return NSColor(hex: 0x00D400)
        case "selfpromo": return NSColor(hex: 0xFFFF00)
        case "interaction": return NSColor(hex: 0xCC00FF)
        case "intro": return NSColor(hex: 0x00FFFF)
        case "outro": return NSColor(hex: 0x0202ED)
        case "preview": return NSColor(hex: 0x008FD6)
        case "music_offtopic": return NSColor(hex: 0xFF9900)
        default: return NSColor(hex: 0x00D400)
        }
    }

    static var appearance: NSAppearance? {
        NSAppearance(named: isDark ? .darkAqua : .aqua)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: alpha
        )
    }
}

// MARK: - Real-time macOS Physical Memory Monitor

struct MemoryStats {
    let footprintMB: Double   // Exact Activity Monitor "Memory" column (phys_footprint)
    let residentMB: Double    // Resident set size
    let compressedMB: Double  // Compressed pages
    let imageCacheMB: Double
    let hlsSessionsCount: Int
}

enum MemoryMonitor {
    static func currentFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576.0
    }

    static func detailedStats() -> MemoryStats {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let fp = kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576.0 : 0
        let res = kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576.0 : 0
        let comp = kr == KERN_SUCCESS ? Double(info.compressed) / 1_048_576.0 : 0
        return MemoryStats(
            footprintMB: fp,
            residentMB: res,
            compressedMB: comp,
            imageCacheMB: ImageCache.shared.estimatedMB,
            hlsSessionsCount: LocalHLSServer.shared.activeSessionCount
        )
    }
}

// MARK: - Reusable UI Helpers

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class ClickableView: NSView {
    var onClick: (() -> Void)?
    var onRightClick: ((NSView) -> Void)?
    var onHover: ((Bool) -> Void)?
    var hoverBgColor: NSColor?
    var normalBgColor: NSColor? {
        didSet {
            if !isHovered {
                layer?.backgroundColor = normalBgColor?.cgColor
            }
        }
    }
    var accessibilityTitle: String?
    var accessibilitySelectedState: Bool = false
    var allowsKeyboardFocus: Bool = false
    var actsAsAccessibilityElement: Bool = true
    var focusRingCornerRadius: CGFloat = 8
    private var isHovered = false
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { allowsKeyboardFocus }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: focusRingCornerRadius, yRadius: focusRingCornerRadius).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func becomeFirstResponder() -> Bool {
        if allowsKeyboardFocus {
            layer?.borderWidth = 1.5
            layer?.borderColor = YTTheme.linkBlue.cgColor
        }
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        if allowsKeyboardFocus {
            layer?.borderWidth = 0
            layer?.borderColor = nil
        }
        return super.resignFirstResponder()
    }

    override func rightMouseDown(with event: NSEvent) {
        if let onRightClick = onRightClick {
            onRightClick(self)
            return
        }
        super.rightMouseDown(with: event)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if allowsKeyboardFocus, window?.firstResponder === self {
            layer?.borderColor = YTTheme.linkBlue.cgColor
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        if newSuperview == nil {
            isHovered = false
            layer?.backgroundColor = normalBgColor?.cgColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        if let h = hoverBgColor { layer?.backgroundColor = h.cgColor }
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        layer?.backgroundColor = normalBgColor?.cgColor
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func keyDown(with event: NSEvent) {
        if allowsKeyboardFocus && (event.keyCode == 36 || event.keyCode == 49 || event.keyCode == 76) {
            onClick?()
            return
        }
        super.keyDown(with: event)
    }

    override func isAccessibilityElement() -> Bool { actsAsAccessibilityElement }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { accessibilityTitle ?? toolTip }
    override func isAccessibilitySelected() -> Bool { accessibilitySelectedState }
    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

/// Draws pill content inside the horizontal padding, so the icon and label sit centred
/// rather than hugging the left edge. The intrinsic width already reserves that padding.
final class PillButtonCell: NSButtonCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let inset = (controlView as? PillButton)?.horizontalPadding ?? 0
        return super.drawingRect(forBounds: rect).insetBy(dx: inset, dy: 0)
    }
}

final class PillButton: NSButton {
    var useDynamicThemeColors: Bool = true
    var normalBg: NSColor = YTTheme.surface { didSet { updateStyle() } }
    var activeBg: NSColor = YTTheme.chipActiveBg { didSet { updateStyle() } }
    var normalFg: NSColor = YTTheme.textPrimary { didSet { updateStyle() } }
    var activeFg: NSColor = YTTheme.chipActiveText { didSet { updateStyle() } }
    var isSelectedPill: Bool = false { didSet { updateStyle() } }
    var cornerRadiusValue: CGFloat = 16 { didSet { layer?.cornerRadius = cornerRadiusValue } }
    var horizontalPadding: CGFloat = 12 { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    private var isHovered: Bool = false
    private var isPressed: Bool = false
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = PillButtonCell(textCell: "")
        isBordered = false
        focusRingType = .default
        wantsLayer = true
        font = .systemFont(ofSize: 14, weight: .medium)
        layer?.cornerRadius = cornerRadiusValue
        imagePosition = .imageLeading
        updateStyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: cornerRadiusValue, yRadius: cornerRadiusValue).fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        if newSuperview == nil && isHovered {
            isHovered = false
            updateStyle()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if useDynamicThemeColors {
            normalBg = YTTheme.surface
            activeBg = YTTheme.chipActiveBg
            normalFg = YTTheme.textPrimary
            activeFg = YTTheme.chipActiveText
        } else {
            updateStyle()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateStyle()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateStyle()
    }

    override var intrinsicContentSize: NSSize {
        // The cell's size already includes the horizontal padding (see PillButtonCell), so don't add it again.
        let base = super.intrinsicContentSize
        let minW: CGFloat = title.isEmpty ? 32 : 0
        // Icon-only pills use the same 32pt height as labelled ones, so the square doesn't stand taller in the row.
        let height: CGFloat = title.isEmpty ? 32 : max(32, base.height + 8)
        return NSSize(width: max(minW, base.width), height: height)
    }

    override var isEnabled: Bool { didSet { updateStyle() } }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        updateStyle()
        super.mouseDown(with: event)
        isPressed = false
        updateStyle()
    }

    func updateStyle() {
        imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        let blendTarget: NSColor = YTTheme.isDark ? .white : .black
        let base = isSelectedPill ? activeBg : normalBg
        // Hover and press lighten whichever base is active, so selected pills respond too.
        let bg: NSColor
        if isPressed {
            bg = base.blended(withFraction: 0.18, of: blendTarget) ?? base
        } else if isHovered {
            bg = isSelectedPill
                ? (base.blended(withFraction: 0.08, of: blendTarget) ?? base)
                : (useDynamicThemeColors ? YTTheme.surfaceHover : (normalBg.blended(withFraction: 0.12, of: blendTarget) ?? normalBg))
        } else {
            bg = base
        }
        // Disabled pills are dimmed so they don't look like working controls.
        let fg = (isSelectedPill ? activeFg : normalFg).withAlphaComponent(isEnabled ? 1 : 0.4)
        layer?.backgroundColor = (isEnabled ? bg : bg.withAlphaComponent(0.5)).cgColor
        contentTintColor = fg
        if title.isEmpty {
            attributedTitle = NSAttributedString(string: "")
        } else {
            attributedTitle = NSAttributedString(
                string: title,
                attributes: [
                    .foregroundColor: fg,
                    .font: font ?? NSFont.systemFont(ofSize: 14, weight: .medium)
                ]
            )
        }
    }

    override var title: String {
        didSet {
            invalidateIntrinsicContentSize()
            updateStyle()
        }
    }

    /// Explicit accessibility state (e.g. "Subscribed"). Falls back to the selection flag.
    var stateValue: String?

    override func accessibilityValue() -> Any? {
        stateValue ?? (isSelectedPill ? "Selected" : nil)
    }
}

final class DurationBadgeView: NSView {
    private let label = makeLabel("", size: 11, weight: .bold, color: .white)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(text: String, isLive: Bool) {
        isHidden = text.isEmpty
        label.stringValue = text
        layer?.backgroundColor = (isLive ? YTTheme.liveRed : YTTheme.durationBadgeBg).cgColor
    }
}

func postAccessibilityAnnouncement(_ message: String) {
    guard !message.isEmpty, let window = NSApp.mainWindow ?? NSApp.windows.first else { return }
    NSAccessibility.post(
        element: window,
        notification: .announcementRequested,
        userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue]
    )
}

final class FocusAwareTextField: NSTextField {
    var onFocusChanged: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChanged?(true) }
        return ok
    }
}

final class WrappingFlowView: NSView {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 8
    var alignRight: Bool = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let maxW = bounds.width > 0 ? bounds.width : 1000
        var rows: [[(NSView, NSSize)]] = []
        var currentRow: [(NSView, NSSize)] = []
        var x: CGFloat = 0
        for sub in subviews where !sub.isHidden {
            let sz = sub.fittingSize
            if !currentRow.isEmpty && x + sz.width > maxW {
                rows.append(currentRow)
                currentRow = []
                x = 0
            }
            currentRow.append((sub, sz))
            x += sz.width + horizontalSpacing
        }
        if !currentRow.isEmpty { rows.append(currentRow) }

        var y: CGFloat = 0
        for row in rows {
            let rowW = row.reduce(CGFloat(0)) { $0 + $1.1.width } + CGFloat(max(0, row.count - 1)) * horizontalSpacing
            let rowH = row.map { $0.1.height }.max() ?? 0
            var rx: CGFloat = alignRight ? max(0, maxW - rowW) : 0
            for (sub, sz) in row {
                let w = min(sz.width, maxW)
                sub.frame = NSRect(x: rx, y: y + (rowH - sz.height) / 2, width: w, height: sz.height)
                rx += w + horizontalSpacing
            }
            y += rowH + verticalSpacing
        }
    }

    override var intrinsicContentSize: NSSize {
        let maxW = bounds.width > 0 ? bounds.width : 1000
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0
        for sub in subviews where !sub.isHidden {
            let sz = sub.fittingSize
            if x > 0 && x + sz.width > maxW {
                x = 0
                y += rowH + verticalSpacing
                rowH = 0
            }
            x += sz.width + horizontalSpacing
            rowH = max(rowH, sz.height)
        }
        return NSSize(width: NSView.noIntrinsicMetric, height: max(32, y + rowH))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if changed { invalidateIntrinsicContentSize() }
    }
}

final class ActivatingTableView: NSTableView {
    var onActivateRow: ((Int) -> Void)?
    var activatesOnSpace: Bool = true

    override func keyDown(with event: NSEvent) {
        let isSpace = event.keyCode == 49
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if (isReturn || (isSpace && activatesOnSpace)), selectedRow >= 0 {
            onActivateRow?(selectedRow)
            return
        }
        super.keyDown(with: event)
    }
}

final class PassThroughScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard let doc = documentView else {
            super.scrollWheel(with: event)
            return
        }
        let contentH = doc.bounds.height
        let visibleH = contentView.bounds.height
        if contentH <= visibleH + 1 {
            superview?.scrollWheel(with: event)
            return
        }
        let dy = event.scrollingDeltaY
        let curY = contentView.bounds.origin.y
        let atTop = curY <= 0.5 && dy > 0
        let atBottom = curY >= (contentH - visibleH - 0.5) && dy < 0
        if atTop || atBottom {
            superview?.scrollWheel(with: event)
            return
        }
        super.scrollWheel(with: event)
    }
}

final class HoverSymbolButton: NSButton {
    var normalBgColor: NSColor = .clear {
        didSet { if !isHovered { layer?.backgroundColor = normalBgColor.cgColor } }
    }
    var hoverBgColor: NSColor?
    var accessibilityValueText: String?
    private var isHovered = false
    private var tracking: NSTrackingArea?

    override func drawFocusRingMask() {
        NSBezierPath(ovalIn: bounds).fill()
    }

    override func accessibilityValue() -> Any? { accessibilityValueText }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func layout() {
        super.layout()
        if hoverBgColor != nil || normalBgColor != .clear {
            layer?.cornerRadius = min(bounds.width, bounds.height) / 2
        }
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        if newSuperview == nil {
            isHovered = false
            layer?.backgroundColor = normalBgColor.cgColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        if let h = hoverBgColor { layer?.backgroundColor = h.cgColor }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        layer?.backgroundColor = normalBgColor.cgColor
    }
}

enum GridLayoutHelper {
    static func columns(forAvailableWidth w: CGFloat) -> Int {
        if w >= 2160 { return 6 }
        if w >= 1720 { return 5 }
        if w >= 1320 { return 4 }
        if w >= 920 { return 3 }
        if w >= 580 { return 2 }
        return 1
    }

    static func cardWidth(forAvailableWidth w: CGFloat, spacing: CGFloat = 16) -> CGFloat {
        let cols = columns(forAvailableWidth: w)
        let totalGap = CGFloat(cols - 1) * spacing
        return floor((w - totalGap) / CGFloat(cols))
    }
}

final class FocusHighlightRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 2, dy: 2)
        YTTheme.surfaceHover.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        if window?.firstResponder === superview {
            YTTheme.linkBlue.withAlphaComponent(0.7).setStroke()
            let stroke = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 10, yRadius: 10)
            stroke.lineWidth = 1.5
            stroke.stroke()
        }
    }
}

/// Draws YouTube's signature rounded red play badge vector icon cleanly at any DPI.
final class YouTubeLogoView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let rect = NSRect(x: 0, y: (bounds.height - 20) / 2, width: 29, height: 20)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5.5, yRadius: 5.5)
        YTTheme.red.setFill()
        path.fill()

        let tri = NSBezierPath()
        let cx = rect.midX + 1.0
        let cy = rect.midY
        tri.move(to: NSPoint(x: cx - 4.2, y: cy - 4.5))
        tri.line(to: NSPoint(x: cx - 4.2, y: cy + 4.5))
        tri.line(to: NSPoint(x: cx + 4.5, y: cy))
        tri.close()
        NSColor.white.setFill()
        tri.fill()
    }
}

func makeLabel(_ text: String = "", size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = YTTheme.textPrimary, maxLines: Int = 1) -> NSTextField {
    let tf = NSTextField(labelWithString: text)
    tf.font = .systemFont(ofSize: size, weight: weight)
    tf.textColor = color
    tf.maximumNumberOfLines = maxLines
    tf.lineBreakMode = maxLines == 1 ? .byTruncatingTail : .byWordWrapping
    tf.cell?.truncatesLastVisibleLine = true
    tf.translatesAutoresizingMaskIntoConstraints = false
    return tf
}

/// One style for every section heading, in the sidebar and in Settings: uppercase, bold, primary text.
func sectionHeadingLabel(_ title: String) -> NSTextField {
    makeLabel(title.uppercased(), size: 12, weight: .bold, color: YTTheme.textPrimary)
}

/// Icon sizes shared by the masthead and sidebar so the chrome reads as one system.
enum IconScale {
    static let chrome: CGFloat = 16
    static let small: CGFloat = 13
    /// Hit target for the More buttons on cards and rows, shared so Home and Search cannot drift apart.
    static let moreTarget: CGFloat = 28
    /// Corner radius for tab and category chips, so they match the Watch tabs as full pills.
    static let tabChipRadius: CGFloat = 15
}

func makeSymbolButton(_ symbol: String, size: CGFloat = 15, color: NSColor = YTTheme.textPrimary, tooltip: String = "", hoverBg: NSColor? = nil) -> HoverSymbolButton {
    let btn = HoverSymbolButton()
    btn.isBordered = false
    btn.wantsLayer = true
    btn.bezelStyle = .regularSquare
    let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
    // VoiceOver gets the name without the keyboard hint, e.g. "Play / Pause (k)" is announced as "Play / Pause".
    let spokenName = tooltip.replacingOccurrences(of: #" \([^)]*\)$"#, with: "", options: .regularExpression)
    btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: spokenName.isEmpty ? nil : spokenName)?.withSymbolConfiguration(cfg)
    btn.contentTintColor = color
    btn.hoverBgColor = hoverBg
    if !tooltip.isEmpty {
        btn.toolTip = tooltip
        btn.setAccessibilityLabel(tooltip)
    }
    btn.translatesAutoresizingMaskIntoConstraints = false
    return btn
}

/// Asks before a destructive action. Returns true only when the user confirms.
func confirmDestructive(_ message: String, detail: String, confirmTitle: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = message
    alert.informativeText = detail
    alert.alertStyle = .warning
    // Cancel is first so it is the default (Return) button; the destructive action needs a deliberate click.
    alert.addButton(withTitle: "Cancel")
    let confirm = alert.addButton(withTitle: confirmTitle)
    confirm.hasDestructiveAction = true
    return alert.runModal() == .alertSecondButtonReturn
}

/// One path for every screen's error state: message, visible label, Try Again button, and a VoiceOver announcement.
func showRetryableError(message: String, label: NSTextField, retryButton: NSButton) {
    label.stringValue = message
    label.isHidden = false
    retryButton.isHidden = false
    postAccessibilityAnnouncement(message)
}

/// Animation length that respects the system Reduce Motion setting: animations jump straight to the end when it is on.
func motionDuration(_ seconds: Double) -> Double {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : seconds
}

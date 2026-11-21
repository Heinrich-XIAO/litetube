import AppKit
import Darwin

// MARK: - YouTube Exact Color System (Dark & Light)

enum YTTheme {
    static var isDark: Bool { LocalStore.shared.settings.darkMode }

    static var bg: NSColor {
        isDark ? NSColor(hex: 0x0F0F0F) : NSColor(hex: 0xFFFFFF)
    }
    static var bgElevated: NSColor {
        isDark ? NSColor(hex: 0x181818) : NSColor(hex: 0xF9F9F9)
    }
    static var surface: NSColor {
        isDark ? NSColor(hex: 0x272727) : NSColor(hex: 0xF2F2F2)
    }
    static var surfaceHover: NSColor {
        isDark ? NSColor(hex: 0x3F3F3F) : NSColor(hex: 0xE5E5E5)
    }
    static var searchBg: NSColor {
        isDark ? NSColor(hex: 0x121212) : NSColor(hex: 0xFFFFFF)
    }
    static var border: NSColor {
        isDark ? NSColor(hex: 0x303030) : NSColor(hex: 0xD3D3D3)
    }
    static var divider: NSColor {
        isDark ? NSColor(hex: 0x272727) : NSColor(hex: 0xE5E5E5)
    }
    static var textPrimary: NSColor {
        isDark ? NSColor(hex: 0xF1F1F1) : NSColor(hex: 0x0F0F0F)
    }
    static var textSecondary: NSColor {
        isDark ? NSColor(hex: 0xAAAAAA) : NSColor(hex: 0x606060)
    }
    static var chipActiveBg: NSColor {
        isDark ? NSColor(hex: 0xF1F1F1) : NSColor(hex: 0x0F0F0F)
    }
    static var chipActiveText: NSColor {
        isDark ? NSColor(hex: 0x0F0F0F) : NSColor(hex: 0xFFFFFF)
    }
    static var red: NSColor { NSColor(hex: 0xFF0033) }
    static var linkBlue: NSColor {
        isDark ? NSColor(hex: 0x3EA6FF) : NSColor(hex: 0x065FD4)
    }
    static var greenGood: NSColor { NSColor(hex: 0x2BA640) }
    static var amberWarn: NSColor { NSColor(hex: 0xF59E0B) }

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
    var onHover: ((Bool) -> Void)?
    var hoverBgColor: NSColor?
    var normalBgColor: NSColor? {
        didSet { layer?.backgroundColor = normalBgColor?.cgColor }
    }
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }

    override func mouseEntered(with event: NSEvent) {
        if let h = hoverBgColor { layer?.backgroundColor = h.cgColor }
        onHover?(true)
        NSCursor.pointingHand.push()
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = normalBgColor?.cgColor
        onHover?(false)
        NSCursor.pop()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

final class PillButton: NSButton {
    var normalBg: NSColor = YTTheme.surface { didSet { updateStyle() } }
    var activeBg: NSColor = YTTheme.chipActiveBg { didSet { updateStyle() } }
    var normalFg: NSColor = YTTheme.textPrimary { didSet { updateStyle() } }
    var activeFg: NSColor = YTTheme.chipActiveText { didSet { updateStyle() } }
    var isSelectedPill: Bool = false { didSet { updateStyle() } }
    var cornerRadiusValue: CGFloat = 16 { didSet { layer?.cornerRadius = cornerRadiusValue } }
    var horizontalPadding: CGFloat = 12

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        wantsLayer = true
        font = .systemFont(ofSize: 13, weight: .medium)
        layer?.cornerRadius = cornerRadiusValue
        imagePosition = .imageLeading
        updateStyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        return NSSize(width: base.width + horizontalPadding * 2, height: max(32, base.height + 8))
    }

    func updateStyle() {
        let bg = isSelectedPill ? activeBg : normalBg
        let fg = isSelectedPill ? activeFg : normalFg
        layer?.backgroundColor = bg.cgColor
        contentTintColor = fg
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: fg,
                .font: font ?? NSFont.systemFont(ofSize: 13, weight: .medium)
            ]
        )
    }

    override var title: String {
        didSet { updateStyle() }
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

func makeSymbolButton(_ symbol: String, size: CGFloat = 15, color: NSColor = YTTheme.textPrimary, tooltip: String = "") -> NSButton {
    let btn = NSButton()
    btn.isBordered = false
    btn.wantsLayer = true
    btn.bezelStyle = .regularSquare
    let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
    btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?.withSymbolConfiguration(cfg)
    btn.contentTintColor = color
    btn.toolTip = tooltip
    btn.translatesAutoresizingMaskIntoConstraints = false
    return btn
}

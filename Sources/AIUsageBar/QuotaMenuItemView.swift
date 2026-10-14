import AppKit

/// A clickable quota card with a shared left edge for label, bar, and subtitle.
@MainActor
final class QuotaMenuItemView: NSView {
    private weak var item: NSMenuItem?
    private let label: String
    private let usage: UsageWindow
    private let subtitle: String?
    private let selected: Bool

    override var isFlipped: Bool { true }

    init(item: NSMenuItem, label: String, window: UsageWindow, subtitle: String?, selected: Bool) {
        self.item = item
        self.label = label
        self.usage = window
        self.subtitle = subtitle
        self.selected = selected
        super.init(frame: NSRect(x: 0, y: 0, width: 390, height: subtitle == nil ? 60 : 82))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(label), \(Format.percent(window.usedPercent)) used\(subtitle.map { ", \($0)" } ?? "")")
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = 18
        let width = bounds.width - inset * 2
        let color: NSColor = usage.isActive ? .systemOrange : .labelColor
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let percent = Format.percent(usage.usedPercent)
        let percentWidth = (percent as NSString).size(withAttributes: attributes).width
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        var labelAttributes = attributes
        labelAttributes[.paragraphStyle] = paragraph
        (((selected ? "✓ " : "") + label) as NSString).draw(
            in: NSRect(x: inset, y: 10, width: width - percentWidth - 12, height: 18),
            withAttributes: labelAttributes)
        (percent as NSString).draw(at: NSPoint(x: bounds.width - inset - percentWidth, y: 10),
                                  withAttributes: attributes)

        let track = NSRect(x: inset, y: 36, width: width, height: 6)
        NSColor.labelColor.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        let fraction = min(1, max(0, usage.usedPercent / 100))
        if fraction > 0 {
            (usage.isActive ? NSColor.systemOrange : NSColor.controlAccentColor).setFill()
            NSBezierPath(roundedRect: NSRect(x: inset, y: 36, width: max(6, width * fraction), height: 6),
                         xRadius: 3, yRadius: 3).fill()
        }
        if let subtitle {
            (subtitle as NSString).draw(
                in: NSRect(x: inset, y: 51, width: width, height: 27),
                withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                                 .foregroundColor: NSColor.secondaryLabelColor])
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        activate()
    }

    override func accessibilityPerformPress() -> Bool {
        activate()
        return true
    }

    private func activate() {
        guard let item, let action = item.action else { return }
        item.menu?.cancelTracking()
        NSApp.sendAction(action, to: item.target, from: item)
    }
}

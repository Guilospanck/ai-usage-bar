import AppKit

/// Toggles a provider's details without dismissing the dropdown.
@MainActor
final class ProviderHeaderView: NSView {
    private weak var item: NSMenuItem?
    private let title: String
    private let icon: NSImage?
    private var hovered = false
    private var hoverTrackingArea: NSTrackingArea?
    var collapsed: Bool {
        didSet {
            needsDisplay = true
            setAccessibilityValue(collapsed ? "Collapsed" : "Expanded")
        }
    }

    override var isFlipped: Bool { true }

    init(item: NSMenuItem, title: String, provider: ProviderKind, collapsed: Bool) {
        self.item = item
        self.title = title
        self.collapsed = collapsed
        icon = provider.iconImage(pointSize: 13).copy() as? NSImage
        icon?.isTemplate = true
        super.init(frame: NSRect(x: 0, y: 0, width: 390, height: 28))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilityValue(collapsed ? "Collapsed" : "Expanded")
        setAccessibilityHelp("Show or hide this provider's usage details")
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        icon?.draw(in: NSRect(x: 15, y: 7, width: 14, height: 14),
                   from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: nil)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (title as NSString).draw(
            in: NSRect(x: 36, y: 5, width: bounds.width - 70, height: 20),
            withAttributes: [.font: NSFont.boldSystemFont(ofSize: 13),
                             .foregroundColor: NSColor.secondaryLabelColor,
                             .paragraphStyle: paragraph])
        // Draw at native proportions rather than stretching an SF Symbol into
        // a square. Rounded ends keep the small disclosure indicator crisp.
        let center = NSPoint(x: bounds.width - 23, y: bounds.midY)
        let badge = NSRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20)
        NSColor.labelColor.withAlphaComponent(hovered ? 0.10 : 0.04).setFill()
        NSBezierPath(ovalIn: badge).fill()

        let chevron = NSBezierPath()
        chevron.lineWidth = 1.6
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        if collapsed {
            chevron.move(to: NSPoint(x: center.x - 1.5, y: center.y - 3.5))
            chevron.line(to: NSPoint(x: center.x + 2, y: center.y))
            chevron.line(to: NSPoint(x: center.x - 1.5, y: center.y + 3.5))
        } else {
            chevron.move(to: NSPoint(x: center.x - 3.5, y: center.y - 1.5))
            chevron.line(to: NSPoint(x: center.x, y: center.y + 2))
            chevron.line(to: NSPoint(x: center.x + 3.5, y: center.y - 1.5))
        }
        (hovered ? NSColor.labelColor : NSColor.secondaryLabelColor).setStroke()
        chevron.stroke()
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
        NSApp.sendAction(action, to: item.target, from: item)
    }
}

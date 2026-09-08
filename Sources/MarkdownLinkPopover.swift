import AppKit

/// The card that appears above a link in a rendered Markdown document: the
/// address, in blue, clickable.
///
/// A borderless child window rather than an `NSPopover`, because a popover
/// always draws an arrow pointing back at the text and there is no supported
/// way to ask it not to. The window never becomes key, so the caret stays where
/// the reader left it and the editor keeps the focus ring.
final class MarkdownLinkCard {
    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless],
                                backing: .buffered, defer: false)
    private let label = LinkLabelView()

    /// Called when the address is clicked.
    var onOpen: (() -> Void)? {
        get { label.onClick }
        set { label.onClick = newValue }
    }

    /// One number for every edge, as everywhere else in the app's cards.
    static let padding: CGFloat = 8
    /// The gap between the card and the text it belongs to.
    static let gap: CGFloat = 6
    static let maximumWidth: CGFloat = 460

    init() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = true
        panel.contentView = label
    }

    var isVisible: Bool { panel.isVisible }
    /// Where the card is on screen, for deciding whether the pointer is on it.
    var screenFrame: NSRect { panel.frame }

    /// Put the card above `anchor`, which is in screen coordinates.
    func show(destination: String, above anchor: NSRect, in parent: NSWindow?) {
        label.text = destination
        let size = label.fittingCardSize
        let frame = Self.frame(size: size, above: anchor,
                               within: parent?.screen?.visibleFrame)
        panel.setFrame(frame, display: false)
        if let parent, panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        label.needsDisplay = true
    }

    func close() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// Above the text, left edges aligned, and kept on the screen it is on.
    /// Deliberately separate from the window so the placement is testable
    /// without one.
    static func frame(size: NSSize, above anchor: NSRect, within visible: NSRect?) -> NSRect {
        var origin = NSPoint(x: anchor.minX, y: anchor.maxY + gap)
        guard let visible else { return NSRect(origin: origin, size: size) }
        origin.x = min(max(visible.minX + 4, origin.x), visible.maxX - size.width - 4)
        // No room above — the link is at the top of the screen — so the card
        // goes under it rather than off the edge.
        if origin.y + size.height > visible.maxY {
            origin.y = anchor.minY - gap - size.height
        }
        origin.y = max(visible.minY + 4, origin.y)
        return NSRect(origin: origin, size: size)
    }

    var destinationForTesting: String { label.text }
    var contentViewForTesting: NSView { label }
    func fittingSizeForTesting(_ destination: String) -> NSSize {
        label.text = destination
        return label.fittingCardSize
    }
    func clickForTesting() { label.onClick?() }
}

/// The card's only content: the address, drawn as a link and clickable.
private final class LinkLabelView: NSView {
    var onClick: (() -> Void)?
    var text: String = "" { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    private var attributes: [NSAttributedString.Key: Any] {
        [.font: Theme.uiFont(11.5),
         .foregroundColor: Theme.blue,
         .underlineStyle: NSUnderlineStyle.single.rawValue]
    }

    /// The card is as wide as the address, up to a limit, and one line tall.
    var fittingCardSize: NSSize {
        let measured = (text as NSString).size(withAttributes: attributes)
        let padding = MarkdownLinkCard.padding
        return NSSize(width: min(ceil(measured.width) + padding * 2,
                                 MarkdownLinkCard.maximumWidth),
                      height: ceil(measured.height) + padding * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: 6, yRadius: 6)
        Theme.panelBackground.setFill()
        body.fill()
        Theme.border.setStroke()
        body.lineWidth = 1
        body.stroke()
        let padding = MarkdownLinkCard.padding
        let text = self.text as NSString
        text.draw(in: bounds.insetBy(dx: padding, dy: padding), withAttributes: attributes)
    }

    // The card belongs to a window that never becomes key, so the click has to
    // be taken on the first press rather than spent activating the window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

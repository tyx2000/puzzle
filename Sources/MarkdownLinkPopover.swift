import AppKit

/// The card that appears above a link in a rendered Markdown document: the
/// address, in blue, clickable. Under the link the caret is in, the same card
/// is the link's bar, and can offer to show the link as written.
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
    /// Offers Edit at the card's end while set.
    var onEdit: (() -> Void)? {
        get { label.onEdit }
        set { label.onEdit = newValue }
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
        show(destination: destination, at: anchor, below: false, in: parent)
    }

    /// Put the card under `anchor`, which is in screen coordinates.
    func show(destination: String, below anchor: NSRect, in parent: NSWindow?) {
        show(destination: destination, at: anchor, below: true, in: parent)
    }

    private func show(destination: String, at anchor: NSRect, below: Bool,
                      in parent: NSWindow?) {
        label.text = destination
        let size = label.fittingCardSize
        let visible = parent?.screen?.visibleFrame
        let frame = below
            ? Self.frame(size: size, below: anchor, within: visible)
            : Self.frame(size: size, above: anchor, within: visible)
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

    /// Under the text, left edges aligned — above it only when there is no
    /// room under it on the screen.
    static func frame(size: NSSize, below anchor: NSRect, within visible: NSRect?) -> NSRect {
        var origin = NSPoint(x: anchor.minX, y: anchor.minY - gap - size.height)
        guard let visible else { return NSRect(origin: origin, size: size) }
        origin.x = min(max(visible.minX + 4, origin.x), visible.maxX - size.width - 4)
        if origin.y < visible.minY + 4 {
            origin.y = anchor.maxY + gap
        }
        origin.y = min(visible.maxY - size.height - 4, origin.y)
        return NSRect(origin: origin, size: size)
    }

    var destinationForTesting: String { label.text }
    var contentViewForTesting: NSView { label }
    func fittingSizeForTesting(_ destination: String) -> NSSize {
        label.text = destination
        return label.fittingCardSize
    }
    func clickForTesting() { label.onClick?() }
    func editForTesting() { label.onEdit?() }
    var offersEditForTesting: Bool { label.onEdit != nil }
}

/// The card's content: the address, drawn as a link and clickable — and,
/// when the card belongs to the caret, Edit after it.
private final class LinkLabelView: NSView {
    var onClick: (() -> Void)?
    var onEdit: (() -> Void)? {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var text: String = "" { didSet { needsDisplay = true } }

    private static let editTitle = "Edit"
    private var editAttributes: [NSAttributedString.Key: Any] {
        [.font: Theme.uiFont(11.5), .foregroundColor: Theme.foreground]
    }
    /// Edit's own width, the gap and rule before it included; none without it.
    private var editWidth: CGFloat {
        guard onEdit != nil else { return 0 }
        let title = (Self.editTitle as NSString).size(withAttributes: editAttributes)
        return ceil(title.width) + MarkdownLinkCard.padding * 2 + 1
    }
    /// Where Edit is, at the card's end.
    private var editRect: NSRect {
        NSRect(x: bounds.maxX - editWidth, y: 0, width: editWidth, height: bounds.height)
    }

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
                                 MarkdownLinkCard.maximumWidth) + editWidth,
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
        var address = bounds.insetBy(dx: padding, dy: padding)
        address.size.width -= editWidth
        let text = self.text as NSString
        text.draw(in: address, withAttributes: attributes)
        guard onEdit != nil else { return }
        let edit = editRect
        Theme.border.setFill()
        NSRect(x: edit.minX, y: 4, width: 1, height: bounds.height - 8).fill()
        (Self.editTitle as NSString).draw(
            at: NSPoint(x: edit.minX + 1 + padding, y: padding), withAttributes: editAttributes)
    }

    // The card belongs to a window that never becomes key, so the click has to
    // be taken on the first press rather than spent activating the window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let onEdit, editRect.contains(point) {
            onEdit()
        } else {
            onClick?()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

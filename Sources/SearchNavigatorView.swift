import AppKit

/// The hand over a button that floats over code, or sits beside it.
///
/// A cursor rectangle is not enough there. The code's own I-beam covers the
/// whole visible area, the button's rectangle overlaps it, and AppKit kept the
/// I-beam; the title band's letters had no cursor of their own at all and kept
/// whatever the pointer arrived with. So the button sets the hand itself
/// whenever the pointer arrives or moves on it, and on the way out hands the
/// cursor back to what is underneath.
enum PointerCursor {
    static let trackingOptions: NSTrackingArea.Options = [
        .mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect,
    ]

    static func enter() { NSCursor.pointingHand.set() }

    /// What is under the pointer now that it has left `view`: text takes the
    /// I-beam, anything else the arrow.
    static func leave(_ view: NSView, event: NSEvent) {
        // `hitTest` takes the point in the superview's coordinates.
        guard let content = view.window?.contentView,
              let hit = content.hitTest(
                content.superview?.convert(event.locationInWindow, from: nil)
                    ?? event.locationInWindow) else {
            NSCursor.arrow.set()
            return
        }
        var candidate: NSView? = hit
        while let current = candidate {
            if current is NSTextView {
                NSCursor.iBeam.set()
                return
            }
            candidate = current.superview
        }
        NSCursor.arrow.set()
    }
}

/// One round button in the search navigator.
final class RoundIconButton: FlatView {
    var onClick: (() -> Void)?

    private let symbol: NSImage?
    private let label: String
    private var hovered = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    init(symbol name: String, label: String, pointSize: CGFloat = 16) {
        self.symbol = NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .medium))
        self.label = label
        super.init(frame: .zero)
        fillColor = .clear
        toolTip = label
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: PointerCursor.trackingOptions,
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    var trackingOptionsForTesting: NSTrackingArea.Options? { tracking?.options }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        PointerCursor.enter()
    }
    override func mouseMoved(with event: NSEvent) { PointerCursor.enter() }
    override func cursorUpdate(with event: NSEvent) { PointerCursor.enter() }
    override func mouseExited(with event: NSEvent) {
        hovered = false
        pressed = false
        PointerCursor.leave(self, event: event)
    }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        let was = pressed
        pressed = false
        guard was, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    /// What the last `resetCursorRects` claimed, so a test can hold the whole
    /// button to the hand that says it can be clicked.
    private(set) var cursorRectForTesting: (rect: NSRect, cursor: NSCursor)?

    override func resetCursorRects() {
        super.resetCursorRects()
        cursorRectForTesting = (bounds, .pointingHand)
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// The buttons float over the code, so the caret must stay where it is:
    /// taking focus would end the edit the search is being run against.
    override var acceptsFirstResponder: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        (pressed || hovered ? Theme.selectedControl : Theme.activeTab).setFill()
        circle.fill()
        Theme.border.setStroke()
        circle.lineWidth = 1
        circle.stroke()
        SidebarCellDrawing.image(
            symbol, tint: hovered ? Theme.foreground : Theme.dimText,
            in: bounds.insetBy(dx: bounds.width / 3, dy: bounds.height / 3))
    }

    var isHoveredForTesting: Bool { hovered }
    func clickForTesting() { onClick?() }
}

/// Round buttons down the right edge of the code area: the one before, the one
/// after, and — for a search — done. A search steps through its results with
/// them; a diff through its changes, with no third button, since there is
/// nothing to close.
///
/// The find bar and the diff's header are at the top of the pane, which is a
/// long way from the text being read; these sit beside it.
final class SearchNavigatorView: FlatView {
    static let buttonSize: CGFloat = 48
    static let spacing: CGFloat = 8
    /// Clear of the scroller that rides the same edge.
    static let trailingInset: CGFloat = 16

    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onClear: (() -> Void)?
    /// The code the buttons float over. They are its sibling, not its child,
    /// so a scroll over them would otherwise climb to the pane and go nowhere.
    weak var scrollTarget: NSView?

    private let previous: RoundIconButton
    private let next: RoundIconButton
    private let clear: RoundIconButton?
    private var buttons: [RoundIconButton] { [previous, next] + (clear.map { [$0] } ?? []) }

    /// `stepping` names what the arrows move between; `closing`, when there is
    /// one, labels the button that ends it.
    init(stepping noun: String, closing: String?) {
        previous = RoundIconButton(symbol: "chevron.up", label: "Previous \(noun)")
        next = RoundIconButton(symbol: "chevron.down", label: "Next \(noun)")
        clear = closing.map { RoundIconButton(symbol: "xmark", label: $0) }
        super.init(frame: .zero)
        fillColor = .clear
        previous.onClick = { [weak self] in self?.onPrevious?() }
        next.onClick = { [weak self] in self?.onNext?() }
        clear?.onClick = { [weak self] in self?.onClear?() }

        let stack = NSStackView(views: buttons)
        stack.orientation = .vertical
        stack.spacing = Self.spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        var constraints: [NSLayoutConstraint] = [
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ]
        for button in buttons {
            constraints.append(button.widthAnchor.constraint(equalToConstant: Self.buttonSize))
            constraints.append(button.heightAnchor.constraint(equalToConstant: Self.buttonSize))
        }
        NSLayoutConstraint.activate(constraints)
    }
    /// A search's: its matches, and a button to close it.
    convenience override init(frame frameRect: NSRect) {
        self.init(stepping: "match", closing: "Close search")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Only the buttons take clicks; the gaps between them belong to the code
    /// underneath. The stack that arranges them spans the whole of this view,
    /// so anything that is not inside a button is let through — not just this
    /// view itself.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return buttons.contains { hit === $0 || hit.isDescendant(of: $0) } ? hit : nil
    }

    /// A scroll over a button moves the code the button is floating over.
    override func scrollWheel(with event: NSEvent) {
        guard let scrollTarget else {
            super.scrollWheel(with: event)
            return
        }
        scrollTarget.scrollWheel(with: event)
    }

    var buttonsForTesting: [RoundIconButton] { buttons }
    func clickPreviousForTesting() { previous.clickForTesting() }
    func clickNextForTesting() { next.clickForTesting() }
    func clickClearForTesting() { clear?.clickForTesting() }
}

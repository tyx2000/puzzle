import AppKit

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
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow,
                                            .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false; pressed = false }
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

/// Three round buttons down the right edge of the code area while a search has
/// results: the match before, the match after, and done.
///
/// The find bar is at the top of the pane, which is a long way from the text
/// being read; these sit beside it.
final class SearchNavigatorView: FlatView {
    static let buttonSize: CGFloat = 48
    static let spacing: CGFloat = 8
    /// Clear of the scroller that rides the same edge.
    static let trailingInset: CGFloat = 16

    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onClear: (() -> Void)?

    private let previous = RoundIconButton(symbol: "chevron.up", label: "Previous match")
    private let next = RoundIconButton(symbol: "chevron.down", label: "Next match")
    private let clear = RoundIconButton(symbol: "xmark", label: "Close search")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        fillColor = .clear
        previous.onClick = { [weak self] in self?.onPrevious?() }
        next.onClick = { [weak self] in self?.onNext?() }
        clear.onClick = { [weak self] in self?.onClear?() }

        let stack = NSStackView(views: [previous, next, clear])
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
        for button in [previous, next, clear] {
            constraints.append(button.widthAnchor.constraint(equalToConstant: Self.buttonSize))
            constraints.append(button.heightAnchor.constraint(equalToConstant: Self.buttonSize))
        }
        NSLayoutConstraint.activate(constraints)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Only the buttons take clicks; the gaps between them belong to the code
    /// underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    var buttonsForTesting: [RoundIconButton] { [previous, next, clear] }
    func clickPreviousForTesting() { previous.clickForTesting() }
    func clickNextForTesting() { next.clickForTesting() }
    func clickClearForTesting() { clear.clickForTesting() }
}

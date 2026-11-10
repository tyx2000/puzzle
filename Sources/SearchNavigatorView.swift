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

    /// What a counting button shows in place of an arrow: the change the diff
    /// is on, on the accent, or how many there are.
    enum Count { case current, total }

    /// Room round a counting button's disc for its shadow, which lifts it off
    /// the code it floats over.
    static let shadowMargin: CGFloat = 4

    private let symbol: NSImage?
    private let counting: Count?
    private let label: String
    private var hovered = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?
    /// The number a counting button shows.
    var count = "" { didSet { if count != oldValue { needsDisplay = true } } }

    convenience init(symbol name: String, label: String, pointSize: CGFloat = 16) {
        self.init(symbol: NSImage(systemSymbolName: name, accessibilityDescription: label)?
                    .withSymbolConfiguration(.init(pointSize: pointSize, weight: .medium)),
                  counting: nil, label: label)
    }

    convenience init(counting: Count, label: String) {
        self.init(symbol: nil, counting: counting, label: label)
    }

    private init(symbol: NSImage?, counting: Count?, label: String) {
        self.symbol = symbol
        self.counting = counting
        self.label = label
        super.init(frame: .zero)
        fillColor = .clear
        toolTip = label
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The disc itself: the whole button, or inside a counting one's margin.
    private var disc: NSRect {
        counting == nil ? bounds
            : bounds.insetBy(dx: Self.shadowMargin, dy: Self.shadowMargin)
    }

    /// The shadow's margin is not part of the button.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard counting != nil else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        return NSBezierPath(ovalIn: disc).contains(local) ? super.hitTest(point) : nil
    }

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
        cursorRectForTesting = (disc, .pointingHand)
        addCursorRect(disc, cursor: .pointingHand)
    }

    /// The buttons float over the code, so the caret must stay where it is:
    /// taking focus would end the edit the search is being run against.
    override var acceptsFirstResponder: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        if let counting {
            drawCount(counting)
            return
        }
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

    /// The change the diff is on stands out on the accent; the count of them
    /// sits on the raised surface the app's cards use. Both are lifted off the
    /// code by a soft shadow.
    private func drawCount(_ counting: Count) {
        let circle = NSBezierPath(ovalIn: disc)
        let isCurrent = counting == .current
        var fill = isCurrent ? Theme.blue
            : (pressed || hovered ? Theme.selectedControl : Theme.raisedSurface)
        if isCurrent, pressed || hovered {
            fill = fill.blended(withFraction: pressed ? 0.2 : 0.1, of: .black) ?? fill
        }
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(
            Self.luminance(Theme.editorBackground) < 0.5 ? 0.5 : 0.16)
        shadow.shadowBlurRadius = 7
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        fill.setFill()
        circle.fill()
        NSGraphicsContext.restoreGraphicsState()
        if !isCurrent {
            Theme.raisedEdge.setStroke()
            let edge = NSBezierPath(ovalIn: disc.insetBy(dx: 0.5, dy: 0.5))
            edge.lineWidth = 1
            edge.stroke()
        }
        let ink = isCurrent ? Self.ink(on: Theme.blue)
            : (pressed || hovered ? Theme.foreground : Theme.dimText)
        // Rounded digits of one width, so the number does not shift as it
        // counts; a long one is set smaller rather than run past the disc.
        var size: CGFloat = isCurrent ? 17 : 16
        var font = Self.digits(size, weight: isCurrent ? .semibold : .regular)
        while size > 9,
              (count as NSString).size(withAttributes: [.font: font]).width > disc.width - 12 {
            size -= 1
            font = Self.digits(size, weight: isCurrent ? .semibold : .regular)
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        let measured = (count as NSString).size(withAttributes: attributes)
        // Centred on the digits' ink, which stands on the baseline to the cap
        // height; the line box carries room the digits never use.
        let origin = NSPoint(x: disc.midX - measured.width / 2,
                             y: disc.midY - font.capHeight / 2 + font.descender)
        (count as NSString).draw(at: NSPoint(x: (origin.x * 2).rounded() / 2,
                                             y: (origin.y * 2).rounded() / 2),
                                 withAttributes: attributes)
        inkForTesting = ink
    }

    private static func digits(_ size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        return font.fontDescriptor.withDesign(.rounded)
            .flatMap { NSFont(descriptor: $0, size: size) } ?? font
    }

    /// Dark ink on a light accent — Ayu's blue is a pale cyan — and white on
    /// a deep one.
    private static func ink(on fill: NSColor) -> NSColor {
        luminance(fill) > 0.55 ? Theme.editorBackground : .white
    }

    private static func luminance(_ colour: NSColor) -> CGFloat {
        guard let c = colour.usingColorSpace(.sRGB) else { return 0 }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
    }

    var isHoveredForTesting: Bool { hovered }
    private(set) var inkForTesting: NSColor?
    var discForTesting: NSRect { disc }
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
    /// How far in from the code's right edge this view sits, so its discs are
    /// `trailingInset` in whatever room their shadows take.
    let edgeInset: CGFloat

    /// `stepping` names what the arrows move between; `closing`, when there is
    /// one, labels the button that ends it.
    convenience init(stepping noun: String, closing: String?) {
        self.init(previous: RoundIconButton(symbol: "chevron.up", label: "Previous \(noun)"),
                  next: RoundIconButton(symbol: "chevron.down", label: "Next \(noun)"),
                  clear: closing.map { RoundIconButton(symbol: "xmark", label: $0) },
                  margin: 0)
    }

    /// A diff's: the same two buttons, counting instead of pointing — the one
    /// above shows the change the diff is on, the one below how many there are.
    convenience init(counting noun: String) {
        self.init(previous: RoundIconButton(counting: .current, label: "Previous \(noun)"),
                  next: RoundIconButton(counting: .total, label: "Next \(noun)"),
                  clear: nil, margin: RoundIconButton.shadowMargin)
    }

    /// `margin` is the room round each disc for its shadow: the buttons grow
    /// by it, and the gap between the discs stays `spacing`.
    private init(previous: RoundIconButton, next: RoundIconButton, clear: RoundIconButton?,
                 margin: CGFloat) {
        self.previous = previous
        self.next = next
        self.clear = clear
        edgeInset = Self.trailingInset - margin
        super.init(frame: .zero)
        fillColor = .clear
        previous.onClick = { [weak self] in self?.onPrevious?() }
        next.onClick = { [weak self] in self?.onNext?() }
        clear?.onClick = { [weak self] in self?.onClear?() }

        let stack = NSStackView(views: buttons)
        stack.orientation = .vertical
        stack.spacing = Self.spacing - margin * 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        var constraints: [NSLayoutConstraint] = [
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ]
        for button in buttons {
            let size = Self.buttonSize + margin * 2
            constraints.append(button.widthAnchor.constraint(equalToConstant: size))
            constraints.append(button.heightAnchor.constraint(equalToConstant: size))
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

    /// The change the diff is on, from 0 — nil before there is one — and how
    /// many there are, on the counting buttons.
    func showCount(current: Int?, of total: Int) {
        previous.count = current.map { "\($0 + 1)" } ?? "–"
        next.count = "\(total)"
        let value = current.map { "\($0 + 1) of \(total)" } ?? "\(total)"
        previous.setAccessibilityValue(value)
        next.setAccessibilityValue(value)
    }

    var countsForTesting: (current: String, total: String) { (previous.count, next.count) }
    var buttonsForTesting: [RoundIconButton] { buttons }
    func clickPreviousForTesting() { previous.clickForTesting() }
    func clickNextForTesting() { next.clickForTesting() }
    func clickClearForTesting() { clear?.clickForTesting() }
}

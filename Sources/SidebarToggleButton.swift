import AppKit

/// The sidebar's switch, beside the traffic lights and before the project's
/// name. It stays where it is whether the sidebar is out or away: out, it
/// sits in the sidebar's title band; away, in the editor's tab row, whose
/// first tab starts after it. With the sidebar away, the pointer resting on it
/// brings the sidebar out over the editor — `RootViewController` decides when.
final class SidebarToggleButton: NSButton {
    static let size = NSSize(width: 28, height: 22)
    /// Between the button and what follows it: the project's name, or, with
    /// the sidebar away, the first tab.
    static let trailingGap: CGFloat = 4

    /// The pointer arrived (true) or left (false), as the tracking area says.
    var onHoverChange: ((Bool) -> Void)?
    /// Out, the button can name itself under the pointer. Away, resting on it
    /// brings the sidebar out instead, and a card would sit on top of it.
    var showsHint = true {
        didSet { if !showsHint { hideHint() } }
    }

    private var isHovered = false
    private var hoverTracking: NSTrackingArea?
    private var hintWork: DispatchWorkItem?

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        image = Theme.symbol("sidebar.left", pointSize: 13, weight: .regular)
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        contentTintColor = Theme.dimText
        setAccessibilityRole(.button)
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Out or away, for VoiceOver and the card.
    func describe(sidebarAway: Bool) {
        setAccessibilityLabel(sidebarAway ? "Show Sidebar" : "Hide Sidebar")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: PointerCursor.trackingOptions,
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
        PointerCursor.enter()
    }

    override func mouseMoved(with event: NSEvent) { PointerCursor.enter() }

    override func cursorUpdate(with event: NSEvent) { PointerCursor.enter() }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
        PointerCursor.leave(self, event: event)
    }

    /// Clicking is past needing the name.
    override func mouseDown(with event: NSEvent) {
        hideHint()
        super.mouseDown(with: event)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    /// The box it is given is the box it fills: the button's own padding
    /// made it 27pt tall in a 22pt slot, and its hover 5pt taller than the
    /// letter buttons'.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override var isHidden: Bool {
        didSet { if isHidden { setHovered(false) } }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { setHovered(false) }
    }

    private func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        contentTintColor = hovered ? Theme.foreground : Theme.dimText
        needsDisplay = true
        hideHint()
        if hovered, showsHint {
            let work = DispatchWorkItem { [weak self] in self?.showHint() }
            hintWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + TitleLetterButton.hintDelay,
                                          execute: work)
        }
        onHoverChange?(hovered)
    }

    private func showHint() {
        guard isHovered, showsHint, let window else { return }
        let onScreen = window.convertToScreen(convert(bounds, to: nil))
        TitleButtonHintCard.shared.show(accessibilityLabel() ?? "", shortcut: "⌘B",
                                        below: onScreen, in: window, owner: self)
    }

    private func hideHint() {
        hintWork?.cancel()
        hintWork = nil
        TitleButtonHintCard.shared.hide(owner: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            Theme.hover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
    }

    func refreshAppearance() {
        contentTintColor = isHovered ? Theme.foreground : Theme.dimText
        needsDisplay = true
    }

    var isHoveredForTesting: Bool { isHovered }
    /// The pointer arriving or leaving, as the tracking area reports it.
    func setHoveredForTesting(_ hovered: Bool) { setHovered(hovered) }
}

/// What holds the sidebar while it floats over the editor: the sidebar at
/// the width it has when it is out, with an edge and a shadow on the side it
/// overlaps. It tells its owner when the pointer arrives or leaves anywhere
/// over it.
final class SidebarFloatView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    /// How far the shadow reaches past the edge, so a float slid out of view
    /// leaves none of it behind.
    static let shadowReach: CGFloat = 40
    private static let shadowOpacity: Float = 1

    private let edge = FlatView()
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 6, height: 0)
        self.shadow = shadow
        edge.fillColor = Theme.border
        edge.translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Take the sidebar's view, filling this one, with the edge over it.
    func hold(_ content: NSView) {
        guard content.superview !== self else { return }
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content, positioned: .below, relativeTo: edge.superview === self ? edge : nil)
        if edge.superview !== self { addSubview(edge) }
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            edge.topAnchor.constraint(equalTo: topAnchor),
            edge.bottomAnchor.constraint(equalTo: bottomAnchor),
            edge.trailingAnchor.constraint(equalTo: trailingAnchor),
            edge.widthAnchor.constraint(equalToConstant: 1),
        ])
    }

    /// A rectangle the shadow is cast from, so it is not worked out from the
    /// sidebar's pixels on every frame of a slide.
    override func layout() {
        super.layout()
        layer?.masksToBounds = false
        layer?.shadowPath = CGPath(rect: bounds, transform: nil)
    }

    /// The float becomes the sidebar in place: its shadow goes over the
    /// time the editor takes to move out from under it.
    func fadeShadow(over duration: TimeInterval) {
        guard let layer else { return }
        let fade = CABasicAnimation(keyPath: "shadowOpacity")
        fade.fromValue = layer.shadowOpacity
        fade.toValue = 0
        fade.duration = duration
        layer.add(fade, forKey: "fade")
        layer.shadowOpacity = 0
    }

    func restoreShadow() {
        layer?.removeAnimation(forKey: "fade")
        layer?.shadowOpacity = Self.shadowOpacity
    }

    func refreshAppearance() {
        edge.fillColor = Theme.border
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
}

import AppKit

/// A list or a code view that lights what the pointer is over, and works out
/// again what that is when asked.
protocol PointerHoverRefreshing: AnyObject {
    func refreshHoverState()
}

/// A handle laid over a pane's edge, whose cursors leave out the scrollers
/// showing under it.
@objc protocol ScrollerCursorRebuilding {
    func scrollersMoved()
}

/// The scrollbar, drawn from the theme and the same everywhere.
///
/// AppKit's dark-mode knob is a fixed light grey, and against surfaces this
/// near black it is the brightest thing on screen. Drawing it ourselves keeps
/// it in the palette.
///
/// It is shown and hidden as the system's own are: with scrollers set to show
/// only while scrolling it floats over the content, hidden at rest, and comes
/// up while the content scrolls or the pointer is on it; set to show always,
/// it is a column of its own and always there. Under the pointer it widens,
/// to be caught more easily.
final class PuzzleScroller: NSScroller {
    /// Required, or AppKit silently falls back to its own scroller for the
    /// overlay style.
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    /// How far across the knob is at rest.
    static let thickness: CGFloat = 5
    /// How far across it is under the pointer and while it is held — and so
    /// the column a scroller takes, which is where it can be caught.
    static let grabThickness: CGFloat = 8

    /// The knob is laid over the surface it scrolls at some of its colour:
    /// pale at rest, there to be found rather than to be looked at; stronger
    /// and wider under the pointer, which says it can be taken hold of; whole
    /// while it is held. It widens within its own column, so nothing beside
    /// it moves.
    enum KnobState { case resting, hovered, dragged }
    static func knobOpacity(_ state: KnobState) -> CGFloat {
        switch state {
        case .resting: return 0.6
        case .hovered: return 0.85
        case .dragged: return 1
        }
    }
    private(set) var knobState = KnobState.resting {
        didSet {
            guard knobState != oldValue else { return }
            redrawKnob()
            if knobState == .resting { concealLater() } else { reveal() }
        }
    }

    /// How far across the knob is painted in a state.
    static func knobThickness(_ state: KnobState) -> CGFloat {
        state == .resting ? thickness : grabThickness
    }

    /// The window's own resize border reaches this far in from its edges,
    /// and a press there resizes the window whatever lies under it. A
    /// scroller along a window edge — the code's, on the right and at the
    /// foot — is that much wider, its knob the same against the edge, so as
    /// much of it can be caught as of any other. It is marked by the large
    /// control size, which is how AppKit asks a scroller's class its width.
    static let windowBorderReach: CGFloat = 3

    /// The same in either style: over the content, it is the strip where the
    /// pointer brings the scroller up; beside it, the column it stands in.
    override class func scrollerWidth(for controlSize: NSControl.ControlSize,
                                      scrollerStyle: NSScroller.Style) -> CGFloat {
        controlSize == .large ? grabThickness + windowBorderReach : grabThickness
    }

    /// No slot: the knob is drawn over the surface it scrolls, the way it was
    /// while scrollers were overlaid.
    override func drawKnobSlot(in slotRect: NSRect, highlight: Bool) {}

    /// The knob is painted in the scroller's own layer, not in the one AppKit
    /// keeps for it. AppKit lays that layer out for a scroller of its own
    /// width — 11pt across and 3pt off the far edge — so in a narrower one
    /// only part of it showed, and not against the edge.
    override func drawKnob() {}

    override var wantsUpdateLayer: Bool { false }

    private(set) var drawsForTesting = 0

    override func draw(_ dirtyRect: NSRect) {
        drawsForTesting += 1
        let rect = Self.knobPaintRect(for: rect(for: .knob), in: bounds, vertical: isVertical,
                                      width: Self.knobThickness(knobState))
        guard !rect.isEmpty else { return }
        let radius = min(rect.width, rect.height) / 2
        Theme.scrollerKnob.withAlphaComponent(Self.knobOpacity(knobState)).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    /// AppKit moves its own knob layer as the content scrolls; this one is
    /// drawn again — whatever scrolled it. While AppKit drags the knob it
    /// sets the value its own way, and the painted knob stood still as the
    /// list ran past under it.
    override var doubleValue: Double { didSet { redrawKnob() } }
    override var knobProportion: CGFloat { didSet { redrawKnob() } }

    /// NSScroller takes `needsDisplay` for the layers AppKit keeps for its
    /// own knob and track, and this view's own layer — where the knob is
    /// painted — was never drawn again: the list scrolled and the knob stayed
    /// where it was. The layer is asked directly.
    private func redrawKnob() {
        if let layer { layer.setNeedsDisplay() } else { needsDisplay = true }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(
            self, name: NSView.boundsDidChangeNotification, object: nil)
        guard let clip = (superview as? NSScrollView)?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(contentScrolled),
            name: NSView.boundsDidChangeNotification, object: clip)
    }

    @objc private func contentScrolled() {
        redrawKnob()
        reveal()
        concealLater()
    }

    // MARK: - Shown and hidden

    /// Over the content, the scroller is up while the content scrolls, while
    /// the pointer is on it and while it is held, and fades this long after
    /// the last of them — as the system's own do. Beside the content, in a
    /// column of its own, it is always up.
    static let lingering: TimeInterval = 1.0
    static let fadingOut: TimeInterval = 0.25
    private var isUpForNow = false
    private var concealWork: DispatchWorkItem?

    var isRevealed: Bool { scrollerStyle == .legacy || isUpForNow }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyVisibility(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var scrollerStyle: NSScroller.Style {
        didSet {
            guard scrollerStyle != oldValue else { return }
            applyVisibility(animated: false)
            showingChanged()
        }
    }

    private func reveal() {
        concealWork?.cancel()
        concealWork = nil
        guard !isUpForNow else { return }
        isUpForNow = true
        applyVisibility(animated: false)
        showingChanged()
    }

    private func concealLater() {
        concealWork?.cancel()
        concealWork = nil
        guard isUpForNow, !isHeld, knobState == .resting else { return }
        let work = DispatchWorkItem { [weak self] in self?.conceal() }
        concealWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lingering, execute: work)
    }

    private func conceal() {
        concealWork = nil
        guard isUpForNow, !isHeld, knobState == .resting else { return }
        isUpForNow = false
        applyVisibility(animated: true)
        showingChanged()
    }

    private func applyVisibility(animated: Bool) {
        let alpha: CGFloat = isRevealed ? 1 : 0
        guard animated else {
            alphaValue = alpha
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadingOut
            animator().alphaValue = alpha
        }
    }

    /// Hidden, it takes no press: the row under it does. The pointer coming
    /// onto it — which its tracking area hears of all the same — brings it
    /// up, and then the press is its own. AppKit's own answer follows only
    /// its own showing and hiding, which the pointer does not reach.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isRevealed && !isHidden && frame.contains(point) ? self : nil
    }

    /// AppKit decides what a press is on from its own geometry, which puts
    /// its 11pt knob mostly off a scroller this narrow: only the knob's first
    /// 2pt took hold of it, and the rest paged. A press on the knob that is
    /// painted takes hold of it; one beside it, along the track, pages
    /// towards it. `point` is in the window's coordinates.
    override func testPart(_ point: NSPoint) -> NSScroller.Part {
        let local = convert(point, from: nil)
        guard bounds.contains(local) else { return super.testPart(point) }
        let knob = Self.knobCatchRect(for: rect(for: .knob), in: bounds, vertical: isVertical)
        guard !knob.isEmpty else { return .noPart }
        if knob.contains(local) { return .knob }
        // The scroller is flipped: the top end is where a vertical knob
        // starts, the left where a horizontal one does.
        let before = isVertical ? local.y < knob.minY : local.x < knob.minX
        return before ? .decrementPage : .incrementPage
    }

    /// Where the knob can be caught: where along the scroller AppKit says it
    /// is, and all the way across.
    static func knobCatchRect(for knob: NSRect, in bounds: NSRect, vertical: Bool) -> NSRect {
        guard knob.width > 0, knob.height > 0, bounds.width > 0, bounds.height > 0 else {
            return .zero
        }
        return vertical
            ? NSRect(x: bounds.minX, y: knob.minY, width: bounds.width, height: knob.height)
            : NSRect(x: knob.minX, y: bounds.minY, width: knob.width, height: bounds.height)
    }

    /// The capsule to paint: the caught rect's outer `width` — against the
    /// edge of the area it scrolls, the right or the foot, with nothing
    /// between them. The scroller is flipped, so the foot is its `maxY`.
    static func knobPaintRect(for knob: NSRect, in bounds: NSRect, vertical: Bool,
                              width: CGFloat = thickness) -> NSRect {
        let caught = knobCatchRect(for: knob, in: bounds, vertical: vertical)
        guard !caught.isEmpty else { return .zero }
        if vertical {
            let across = min(width, caught.width)
            return NSRect(x: caught.maxX - across, y: caught.minY, width: across, height: caught.height)
        }
        let across = min(width, caught.height)
        return NSRect(x: caught.minX, y: caught.maxY - across, width: caught.width, height: across)
    }

    private var isVertical: Bool { bounds.height > bounds.width }

    /// True while any scroller is being dragged. The rows the drag scrolls
    /// pass under the pointer as it goes, and lighting each in turn made the
    /// lists — and the code — flicker the whole way down.
    private(set) static var isDragging = false

    /// AppKit tracks the drag inside this call and returns when the button
    /// comes up.
    override func mouseDown(with event: NSEvent) {
        beginDragging()
        defer { endDragging() }
        super.mouseDown(with: event)
    }

    private func beginDragging() {
        Self.isDragging = true
        isHeld = true
        refreshKnobState()
        hoverRefreshing?.refreshHoverState()
    }

    private func endDragging() {
        Self.isDragging = false
        isHeld = false
        refreshKnobState()
        hoverRefreshing?.refreshHoverState()
    }

    private var isHeld = false
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        refreshKnobState()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        refreshKnobState()
    }

    /// Held, under the pointer, or at rest — read from the pointer itself,
    /// which a drag may have carried off the scroller.
    private func refreshKnobState() {
        guard !isHeld else {
            knobState = .dragged
            return
        }
        guard let window, !isHiddenOrHasHiddenAncestor else {
            knobState = .resting
            return
        }
        knobState = bounds.contains(convert(window.pointerLocation, from: nil)) ? .hovered : .resting
    }

    /// What this scroller scrolls, when that lights the row under the pointer.
    /// A scroller is the scroll view's own subview, not inside its document,
    /// so `enclosingScrollView` has nothing to say about it.
    private var hoverRefreshing: PointerHoverRefreshing? {
        (superview as? NSScrollView)?.documentView as? PointerHoverRefreshing
    }

    // MARK: - Under the handles

    /// The invisible handles laid over the panes' edges — a divider's grab
    /// band, the window's own resize border — lie over the scrollers along
    /// those edges, and took every press there for a resize. Where a scroller
    /// is showing, the pointer is the scroller's: the handles ask here, and
    /// rebuild their cursors when told a scroller has come, gone or moved.
    static let showingDidChange = Notification.Name("PuzzleScrollerShowingDidChange")

    private static let all = NSHashTable<PuzzleScroller>.weakObjects()

    /// Have `view` told — through its `scrollersMoved` — when a scroller in
    /// its window comes, goes or moves; nothing once it leaves the window.
    static func rebuildCursors<View: NSView & ScrollerCursorRebuilding>(of view: View) {
        NotificationCenter.default.removeObserver(view, name: showingDidChange, object: nil)
        guard let window = view.window else { return }
        NotificationCenter.default.addObserver(view, selector: #selector(View.scrollersMoved),
                                               name: showingDidChange, object: window)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { Self.all.remove(self) } else { Self.all.add(self) }
        showingChanged()
    }

    override var isHidden: Bool {
        didSet { if isHidden != oldValue { showingChanged() } }
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        let moved = newOrigin != frame.origin
        super.setFrameOrigin(newOrigin)
        if moved { showingChanged() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let resized = newSize != frame.size
        super.setFrameSize(newSize)
        if resized { showingChanged() }
    }

    private func showingChanged() {
        guard let window else { return }
        NotificationCenter.default.post(name: Self.showingDidChange, object: window)
    }

    /// Where scrollers are up in `window`, in its coordinates. One that is
    /// hidden over the content leaves the handles over it as they were.
    static func showingRects(in window: NSWindow) -> [NSRect] {
        all.allObjects.compactMap { scroller in
            guard scroller.window === window, !scroller.isHiddenOrHasHiddenAncestor,
                  scroller.isRevealed, !scroller.bounds.isEmpty else { return nil }
            return scroller.convert(scroller.bounds, to: nil)
        }
    }

    /// The scroller showing at a point of `window`, in its coordinates.
    static func showing(at point: NSPoint, in window: NSWindow?) -> PuzzleScroller? {
        guard let window else { return nil }
        return all.allObjects.first { scroller in
            scroller.window === window && !scroller.isHiddenOrHasHiddenAncestor
                && scroller.isRevealed && scroller.convert(scroller.bounds, to: nil).contains(point)
        }
    }

    /// Whether a scroller is showing at a point of `window`, in its
    /// coordinates.
    static func isShowing(at point: NSPoint, in window: NSWindow?) -> Bool {
        showing(at: point, in: window) != nil
    }

    /// What of `rect`, in `view`'s coordinates, no showing scroller covers.
    static func uncovered(_ rect: NSRect, in view: NSView) -> [NSRect] {
        guard let window = view.window else { return [rect] }
        return showingRects(in: window).reduce([rect]) { pieces, scroller in
            let hole = view.convert(scroller, from: nil)
            return pieces.flatMap { subtract(hole, from: $0) }
        }
    }

    /// `rect` with `hole` taken out, as up to four rects.
    static func subtract(_ hole: NSRect, from rect: NSRect) -> [NSRect] {
        let overlap = rect.intersection(hole)
        guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return [rect] }
        return [
            NSRect(x: rect.minX, y: rect.minY, width: overlap.minX - rect.minX, height: rect.height),
            NSRect(x: overlap.maxX, y: rect.minY, width: rect.maxX - overlap.maxX, height: rect.height),
            NSRect(x: overlap.minX, y: rect.minY, width: overlap.width, height: overlap.minY - rect.minY),
            NSRect(x: overlap.minX, y: overlap.maxY, width: overlap.width, height: rect.maxY - overlap.maxY),
        ].filter { $0.width > 0 && $0.height > 0 }
    }

    /// Make a scroll view the app's own: themed scrollers, in the style the
    /// system is set to, and none of AppKit's automatic content insets.
    ///
    /// Those insets are meant for a scroll view running under a window's
    /// titlebar. Every list here sits below a header the app draws itself, so
    /// the inset is pure extra space at the top — which is why the first row of
    /// the branch list sat further from the toolbar above it than the toolbar
    /// sat from the tabs.
    ///
    /// `alongWindowEdge` is for a scroll view whose scrollers lie against the
    /// window's own edge — the right, or the foot — where its resize border
    /// takes the outermost points.
    static func adopt(_ scrollView: NSScrollView, alongWindowEdge: Bool = false) {
        scrollView.verticalScroller = PuzzleScroller()
        scrollView.horizontalScroller = PuzzleScroller()
        if alongWindowEdge {
            scrollView.verticalScroller?.controlSize = .large
            scrollView.horizontalScroller?.controlSize = .large
        }
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
    }

    // MARK: - Regression-test surface

    /// The colour a knob actually paints with over `surface`, read back from
    /// a render.
    static func knobColourForTesting(over surface: NSColor, state: KnobState = .resting,
                                     size: NSSize = NSSize(width: thickness, height: 60)) -> NSColor? {
        let scroller = PuzzleScroller(frame: NSRect(origin: .zero, size: size))
        scroller.scrollerStyle = .legacy
        scroller.knobState = state
        scroller.knobProportion = 0.6
        scroller.doubleValue = 0.5
        let image = NSImage(size: size)
        image.lockFocus()
        surface.setFill()
        NSRect(origin: .zero, size: size).fill()
        scroller.draw(scroller.bounds)
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)
    }

    /// Run `body` as if a scroller were being dragged meanwhile.
    static func whileDraggingForTesting(_ body: () throws -> Void) rethrows {
        isDragging = true
        defer { isDragging = false }
        try body()
    }

    func beginDraggingForTesting() { beginDragging() }
    func endDraggingForTesting() { endDragging() }
    func refreshKnobStateForTesting() { refreshKnobState() }
    func revealForTesting() { reveal() }
    func concealForTesting() { conceal() }
}

import AppKit

/// Where a divider is taken hold of. Its line runs the whole length between
/// two panes; the pointer anywhere on it brings a capsule up, fading in, but
/// only the capsule's own span moves it — anywhere else a press is the
/// pane's. The capsule stays up for the whole of a drag.
///
/// The lines down the panel — beside the tree, beside the code — are taken
/// hold of where the line across it, between the changes and the history,
/// meets them; the line across keeps to its middle, as does any line with
/// nothing crossing it.
enum DividerGrip {
    /// The capsule: this long along the line, this thick across it.
    static let length: CGFloat = 48
    static let thickness: CGFloat = 4
    /// How much of the line answers to a press: a little more than the
    /// capsule, so it can be caught without aiming at it.
    static let reach: CGFloat = 64
    /// How far either side of the line it answers — to the pointer coming
    /// onto it as well as to a press.
    static let radius: CGFloat = 6
    /// How long the capsule takes to come up or go.
    static let fade: TimeInterval = 0.15
    /// Pale: there to be found, not looked at.
    static var colour: NSColor { Theme.dimText.withAlphaComponent(0.6) }

    /// The part of `band` — the strip either side of a line — that takes
    /// hold: `reach` of it, centred at `centre` along the line (its middle
    /// when there is none), and kept within the band.
    static func grabRect(in band: NSRect, lineIsVertical: Bool, centre: CGFloat? = nil) -> NSRect {
        let length = lineIsVertical ? band.height : band.width
        let start = lineIsVertical ? band.minY : band.minX
        let wanted = centre ?? (start + length / 2)
        let middle = min(max(wanted, start + reach / 2), start + length - reach / 2)
        let span = lineIsVertical
            ? NSRect(x: band.minX, y: (middle - reach / 2).rounded(), width: band.width, height: reach)
            : NSRect(x: (middle - reach / 2).rounded(), y: band.minY, width: reach, height: band.height)
        return span.intersection(band)
    }

    /// The capsule's frame, centred on `point` of a line.
    static func capsuleRect(centredOn point: NSPoint, lineIsVertical: Bool) -> NSRect {
        let size = lineIsVertical
            ? NSSize(width: thickness, height: length)
            : NSSize(width: length, height: thickness)
        return NSRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Where the line across the panel lies in `window`, in its coordinates;
    /// nil when it is not on screen.
    static func crossing(in window: NSWindow?) -> CGFloat? {
        ProjectColumnsView.crossingY(in: window)
    }

    /// The line across the panel has moved, come or gone: the lines down it
    /// take hold somewhere else. Posted with its window.
    static let crossingDidMove = Notification.Name("DividerGripCrossingDidMove")

    /// The capsule itself: one layer of one colour with round ends, so it
    /// costs no bitmap. It never takes the pointer — the view under it does.
    final class Capsule: FlatView {
        private(set) var isShown = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.cornerRadius = DividerGrip.thickness / 2
            fillColor = DividerGrip.colour
            alphaValue = 0
            setAccessibilityElement(false)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// Up or gone, fading. An explicit animation: the views that hold a
        /// capsule refuse implicit ones, so their panes do not slide.
        func show(_ shown: Bool) {
            guard shown != isShown else { return }
            isShown = shown
            let from = layer?.presentation()?.opacity ?? Float(alphaValue)
            alphaValue = shown ? 1 : 0
            guard let layer else { return }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = from
            fade.toValue = Float(alphaValue)
            fade.duration = DividerGrip.fade
            layer.add(fade, forKey: "fade")
        }

        var fadeForTesting: CAAnimation? { layer?.animation(forKey: "fade") }
    }
}

/// An explicit invisible target over the sidebar/editor divider. Keeping this
/// separate from the drawn one-pixel divider makes the interaction predictable
/// even when AppKit's effective-divider rect varies between macOS releases.
final class SplitDividerHandleView: NSView, ScrollerCursorRebuilding {
    static let hitWidth: CGFloat = DividerGrip.radius * 2 + 1

    var onDragBegan: (() -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    /// Width of the hairline this view paints over — AppKit's own divider,
    /// which has no colour API. Set from the split view's `dividerThickness`.
    var dividerThickness: CGFloat = 1 { didSet { needsDisplay = true; needsLayout = true } }
    private var initialMouseX: CGFloat = 0
    private let capsule = DividerGrip.Capsule()
    private var gripArea: NSTrackingArea?
    private var isDragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
        addSubview(capsule)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The handle runs the line's whole length, but only the span where the
    /// line across the panel meets it takes hold — its middle, when there is
    /// none; past that the press goes to whatever is under it.
    private var grabRect: NSRect {
        DividerGrip.grabRect(in: bounds, lineIsVertical: true, centre: crossing)
    }

    /// Where the line across the panel meets this one, in this view.
    private var crossing: CGFloat? {
        DividerGrip.crossing(in: window).map { convert(NSPoint(x: 0, y: $0), from: nil).y }
    }

    /// The handle reaches into the panel either side of the line, where the
    /// panel's lists keep their scrollers. Where one is showing, the press is
    /// the scroller's — handed to it straight, since under this handle lies
    /// AppKit's own divider, which would take it otherwise.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point),
              grabRect.contains(convert(point, from: superview)) else { return nil }
        let inWindow = superview?.convert(point, to: nil) ?? point
        return PuzzleScroller.showing(at: inWindow, in: window) ?? hit
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        PuzzleScroller.rebuildCursors(of: self)
        NotificationCenter.default.removeObserver(self, name: DividerGrip.crossingDidMove, object: nil)
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(crossingMoved),
                                               name: DividerGrip.crossingDidMove, object: window)
    }

    @objc func scrollersMoved() {
        window?.invalidateCursorRects(for: self)
        refreshGrip()
    }

    @objc private func crossingMoved() {
        needsLayout = true
        window?.invalidateCursorRects(for: self)
    }

    /// The handle straddles the divider, so painting its middle column replaces
    /// AppKit's fixed grey hairline with the same 1pt `Theme.border` line the
    /// activity bar and the title band draw.
    override func draw(_ dirtyRect: NSRect) {
        Theme.border.setFill()
        paintedDividerRect.fill()
    }

    private var paintedDividerRect: NSRect {
        NSRect(x: bounds.midX, y: 0, width: dividerThickness, height: bounds.height)
    }

    /// The constraints that size the handle do not always lay out what is
    /// inside it, and the capsule keeps to the middle of the line.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        placeCapsule()
    }

    /// Across the line, where it takes hold.
    private func placeCapsule() {
        capsule.frame = DividerGrip.capsuleRect(
            centredOn: NSPoint(x: paintedDividerRect.midX, y: grabRect.midY), lineIsVertical: true)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    var paintedDividerRectForTesting: NSRect { paintedDividerRect }
    var grabRectForTesting: NSRect { grabRect }
    var showsGripForTesting: Bool { capsule.isShown }
    var gripRectForTesting: NSRect { capsule.frame }
    var gripFadeForTesting: CAAnimation? { capsule.fadeForTesting }
    func refreshGripForTesting() { refreshGrip() }

    override func resetCursorRects() {
        super.resetCursorRects()
        let cursor: NSCursor
        if #available(macOS 15.0, *) {
            cursor = .columnResize
        } else {
            cursor = .resizeLeftRight
        }
        for rect in PuzzleScroller.uncovered(grabRect, in: self) {
            addCursorRect(rect, cursor: cursor)
        }
    }

    /// The pointer anywhere on the line brings the capsule up.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let gripArea { removeTrackingArea(gripArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        gripArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        refreshGrip()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        refreshGrip()
    }

    /// Up while held, or while the pointer is on the line and not on a
    /// scroller that is up there — read from the pointer itself, which a drag
    /// may have carried off.
    private func refreshGrip() {
        guard !isDragging else {
            capsule.show(true)
            return
        }
        guard let window, !isHiddenOrHasHiddenAncestor else {
            capsule.show(false)
            return
        }
        let pointer = window.pointerLocation
        placeCapsule()
        capsule.show(bounds.contains(convert(pointer, from: nil))
                        && !PuzzleScroller.isShowing(at: pointer, in: window))
    }

    override func mouseDown(with event: NSEvent) {
        initialMouseX = Pointer.location.x
        isDragging = true
        refreshGrip()
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(Pointer.location.x - initialMouseX)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        refreshGrip()
    }
}

/// Transparent, pointer-only resize handles just inside a full-size window.
/// The native outside border remains active; this adds a forgiving internal
/// target without changing the visible chrome or intercepting the content away
/// from the perimeter.
final class WindowResizeHandleView: NSView, ScrollerCursorRebuilding {
    struct Edges: OptionSet {
        let rawValue: UInt8
        static let left = Edges(rawValue: 1 << 0)
        static let right = Edges(rawValue: 1 << 1)
        static let bottom = Edges(rawValue: 1 << 2)
        static let top = Edges(rawValue: 1 << 3)
    }

    static let hitThickness: CGFloat = 8
    private static let cornerLength: CGFloat = 16

    private var activeEdges: Edges = []
    private var initialMouse = NSPoint.zero
    private var initialFrame = NSRect.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The border lies over the code's scrollers along the right and bottom
    /// edges. Where one is showing, the pointer is the scroller's; the
    /// window's own border, just outside, still resizes it there.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !edges(at: point).isEmpty,
              window?.styleMask.contains(.resizable) == true,
              window?.styleMask.contains(.fullScreen) != true,
              !PuzzleScroller.isShowing(at: superview?.convert(point, to: nil) ?? point,
                                        in: window) else { return nil }
        return self
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        PuzzleScroller.rebuildCursors(of: self)
    }

    @objc func scrollersMoved() { window?.invalidateCursorRects(for: self) }

    override func resetCursorRects() {
        super.resetCursorRects()
        let t = Self.hitThickness
        let c = Self.cornerLength
        func add(_ rect: NSRect, _ cursor: NSCursor) {
            for piece in PuzzleScroller.uncovered(rect, in: self) {
                addCursorRect(piece, cursor: cursor)
            }
        }

        add(NSRect(x: 0, y: c, width: t, height: max(0, bounds.height - 2 * c)),
            horizontalCursor())
        add(NSRect(x: bounds.maxX - t, y: c, width: t, height: max(0, bounds.height - 2 * c)),
            horizontalCursor())
        add(NSRect(x: c, y: 0, width: max(0, bounds.width - 2 * c), height: t),
            verticalCursor())
        add(NSRect(x: c, y: bounds.maxY - t, width: max(0, bounds.width - 2 * c), height: t),
            verticalCursor())

        add(NSRect(x: 0, y: 0, width: c, height: t), cornerCursor(top: false, left: true))
        add(NSRect(x: bounds.maxX - c, y: 0, width: c, height: t),
            cornerCursor(top: false, left: false))
        add(NSRect(x: 0, y: bounds.maxY - t, width: c, height: t),
            cornerCursor(top: true, left: true))
        add(NSRect(x: bounds.maxX - c, y: bounds.maxY - t, width: c, height: t),
            cornerCursor(top: true, left: false))
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        activeEdges = edges(at: point)
        guard !activeEdges.isEmpty, let window else { return }
        initialMouse = Pointer.location
        initialFrame = window.frame
    }

    override func mouseDragged(with event: NSEvent) {
        guard !activeEdges.isEmpty, let window else { return }
        let mouse = Pointer.location
        let deltaX = mouse.x - initialMouse.x
        let deltaY = mouse.y - initialMouse.y
        window.setFrame(Self.resizedFrame(initialFrame,
                                          edges: activeEdges,
                                          deltaX: deltaX,
                                          deltaY: deltaY,
                                          minimumSize: window.minSize),
                        display: true)
    }

    override func mouseUp(with event: NSEvent) {
        activeEdges = []
    }

    static func resizedFrame(_ original: NSRect, edges: Edges,
                             deltaX: CGFloat, deltaY: CGFloat,
                             minimumSize: NSSize) -> NSRect {
        var frame = original
        let minimumWidth = max(320, minimumSize.width)
        let minimumHeight = max(240, minimumSize.height)

        if edges.contains(.left) {
            let width = max(minimumWidth, original.width - deltaX)
            frame.origin.x = original.maxX - width
            frame.size.width = width
        } else if edges.contains(.right) {
            frame.size.width = max(minimumWidth, original.width + deltaX)
        }

        if edges.contains(.bottom) {
            let height = max(minimumHeight, original.height - deltaY)
            frame.origin.y = original.maxY - height
            frame.size.height = height
        } else if edges.contains(.top) {
            frame.size.height = max(minimumHeight, original.height + deltaY)
        }
        return frame
    }

    private func edges(at point: NSPoint) -> Edges {
        let t = Self.hitThickness
        var result: Edges = []
        if point.x <= bounds.minX + t { result.insert(.left) }
        if point.x >= bounds.maxX - t { result.insert(.right) }
        if point.y <= bounds.minY + t { result.insert(.bottom) }
        if point.y >= bounds.maxY - t { result.insert(.top) }
        return result
    }

    private func horizontalCursor() -> NSCursor {
        if #available(macOS 15.0, *) {
            return .columnResize
        }
        return .resizeLeftRight
    }

    private func verticalCursor() -> NSCursor {
        if #available(macOS 15.0, *) {
            return .rowResize
        }
        return .resizeUpDown
    }

    private func cornerCursor(top: Bool, left: Bool) -> NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch (top, left) {
            case (true, true): position = .topLeft
            case (true, false): position = .topRight
            case (false, true): position = .bottomLeft
            case (false, false): position = .bottomRight
            }
            return .frameResize(position: position, directions: .all)
        }
        return horizontalCursor()
    }
}

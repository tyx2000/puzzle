import AppKit

/// A line between two panes, taken hold of anywhere along it. The pointer on
/// it, or a press holding it, lights it the way a diff frames its change: the
/// line in the theme's blue, with a faint band of the same colour either side,
/// fading in. The pointer is the resize cursor for the way the line moves, and
/// a double-click puts the line back where it started. Where a list's scroller
/// shows under it, the pointer and a press are the scroller's.
enum DividerGrip {
    /// How far either side of the line answers to the pointer and to a press.
    static let radius: CGFloat = 4
    /// How long the light takes to come up or go.
    static let fade: TimeInterval = 0.15
    /// The lit line and the band round it are a diff frame's.
    static var lineWidth: CGFloat { ChangeFrameOverlay.strokeWidth }
    static var glowWidth: CGFloat { ChangeFrameOverlay.glowWidth }
    static var glowAlpha: CGFloat { ChangeFrameOverlay.glowAlpha }
    static var colour: NSColor { Theme.blue }

    /// Over a line, and while it is held: a line down the panel moves from side
    /// to side, one across it up and down. Made once, so the one held can be
    /// told from the others.
    static func cursor(lineIsVertical: Bool) -> NSCursor {
        lineIsVertical ? columnCursor : rowCursor
    }
    private static let columnCursor: NSCursor = {
        if #available(macOS 15.0, *) { return .columnResize }
        return .resizeLeftRight
    }()
    private static let rowCursor: NSCursor = {
        if #available(macOS 15.0, *) { return .rowResize }
        return .resizeUpDown
    }()

    /// The light's frame over the 1pt `line`: its whole length, and the band
    /// either side.
    static func lightRect(over line: NSRect, lineIsVertical: Bool) -> NSRect {
        let thickness = lineWidth + glowWidth * 2
        return lineIsVertical
            ? NSRect(x: line.midX - thickness / 2, y: line.minY, width: thickness, height: line.height)
            : NSRect(x: line.minX, y: line.midY - thickness / 2, width: line.width, height: thickness)
    }

    /// The lit line over a divider, over the panes either side of it. It never
    /// takes the pointer — the view under it does.
    final class Light: NSView {
        private(set) var isShown = false
        var lineIsVertical = true {
            didSet { if lineIsVertical != oldValue { needsDisplay = true } }
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            alphaValue = 0
            setAccessibilityElement(false)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            DividerGrip.colour.withAlphaComponent(DividerGrip.glowAlpha).setFill()
            bounds.fill()
            let width = DividerGrip.lineWidth
            let line = lineIsVertical
                ? NSRect(x: bounds.midX - width / 2, y: 0, width: width, height: bounds.height)
                : NSRect(x: 0, y: bounds.midY - width / 2, width: bounds.width, height: width)
            DividerGrip.colour.setFill()
            line.fill()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }

        /// Up or gone, fading. An explicit animation: the views that hold a
        /// light refuse implicit ones, so their panes do not slide.
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

/// An explicit target over the sidebar/editor divider, its whole height.
/// Keeping this separate from the drawn one-pixel divider makes the
/// interaction predictable even when AppKit's effective-divider rect varies
/// between macOS releases.
final class SplitDividerHandleView: NSView, ScrollerCursorRebuilding {
    static let hitWidth: CGFloat = DividerGrip.radius * 2 + 1

    var onDragBegan: (() -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    /// A double-click: put the panel back at its opening width.
    var onReset: (() -> Void)?
    /// Width of the hairline this view paints over — AppKit's own divider,
    /// which has no colour API. Set from the split view's `dividerThickness`.
    var dividerThickness: CGFloat = 1 { didSet { needsDisplay = true; needsLayout = true } }
    private var initialMouseX: CGFloat = 0
    private let light = DividerGrip.Light()
    private var lightArea: NSTrackingArea?
    private var isDragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
        addSubview(light)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The handle reaches into the panel either side of the line, where the
    /// panel's lists keep their scrollers. Where one is showing, the press is
    /// the scroller's — handed to it straight, since under this handle lies
    /// AppKit's own divider, which would take it otherwise.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        let inWindow = superview?.convert(point, to: nil) ?? point
        return PuzzleScroller.showing(at: inWindow, in: window) ?? hit
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        PuzzleScroller.rebuildCursors(of: self)
    }

    @objc func scrollersMoved() {
        window?.invalidateCursorRects(for: self)
        refreshLight()
    }

    /// The handle straddles the divider, so painting its middle column replaces
    /// AppKit's fixed grey hairline with the same 1pt `Theme.divider` line the
    /// title band and the project strip draw.
    override func draw(_ dirtyRect: NSRect) {
        Theme.divider.setFill()
        paintedDividerRect.fill()
    }

    private var paintedDividerRect: NSRect {
        NSRect(x: bounds.midX, y: 0, width: dividerThickness, height: bounds.height)
    }

    /// The constraints that size the handle do not always lay out what is
    /// inside it, and the light keeps to the line.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        light.frame = DividerGrip.lightRect(over: paintedDividerRect, lineIsVertical: true)
        updateTrackingAreas()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    var paintedDividerRectForTesting: NSRect { paintedDividerRect }
    var showsLightForTesting: Bool { light.isShown }
    var lightRectForTesting: NSRect { light.frame }
    var lightFadeForTesting: CAAnimation? { light.fadeForTesting }
    func refreshLightForTesting() { refreshLight() }

    override func resetCursorRects() {
        super.resetCursorRects()
        for rect in PuzzleScroller.uncovered(bounds, in: self) {
            addCursorRect(rect, cursor: DividerGrip.cursor(lineIsVertical: true))
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let lightArea { removeTrackingArea(lightArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        lightArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        refreshLight()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        refreshLight()
    }

    /// Lit while held, or while the pointer is where a press would take hold
    /// — read from the pointer itself, which a drag may have carried off.
    private func refreshLight() {
        guard !isDragging else {
            light.show(true)
            return
        }
        guard let window, !isHiddenOrHasHiddenAncestor else {
            light.show(false)
            return
        }
        let pointer = window.pointerLocation
        light.show(bounds.contains(convert(pointer, from: nil))
                    && !PuzzleScroller.isShowing(at: pointer, in: window))
    }

    /// A double-click puts the panel back first; a drag carried on from it
    /// starts from there.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onReset?() }
        initialMouseX = Pointer.location.x
        if !isDragging { DividerGrip.cursor(lineIsVertical: true).push() }
        isDragging = true
        refreshLight()
        onDragBegan?()
    }

    /// The window works the cursors out again as the pointer moves, and the
    /// pointer can leave the line sideways while the line follows it.
    override func mouseDragged(with event: NSEvent) {
        DividerGrip.cursor(lineIsVertical: true).set()
        onDrag?(Pointer.location.x - initialMouseX)
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging { NSCursor.pop() }
        isDragging = false
        refreshLight()
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

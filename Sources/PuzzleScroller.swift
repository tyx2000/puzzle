import AppKit

/// A list or a code view that lights what the pointer is over, and works out
/// again what that is when asked.
protocol PointerHoverRefreshing: AnyObject {
    func refreshHoverState()
}

/// The scrollbar, drawn from the theme and the same everywhere.
///
/// AppKit's dark-mode knob is a fixed light grey, and against surfaces this
/// near black it is the brightest thing on screen. Drawing it ourselves keeps
/// it in the palette.
///
/// It is shown whenever there is something to scroll to, not only while
/// scrolling — macOS hides overlay scrollers until the content moves, so a
/// list gave no sign it went on past its foot. A legacy scroller is a column
/// of its own beside the content, which also keeps the pointer that is
/// dragging it off the rows it scrolls.
final class PuzzleScroller: NSScroller {
    /// Required, or AppKit silently falls back to its own scroller for the
    /// overlay style.
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    /// How far across a scroller is, wherever it is.
    static let thickness: CGFloat = 8

    override class func scrollerWidth(for controlSize: NSControl.ControlSize,
                                      scrollerStyle: NSScroller.Style) -> CGFloat {
        scrollerStyle == .legacy
            ? thickness
            : super.scrollerWidth(for: controlSize, scrollerStyle: scrollerStyle)
    }

    /// No slot: the knob is drawn over the surface it scrolls, the way it was
    /// while scrollers were overlaid.
    override func drawKnobSlot(in slotRect: NSRect, highlight: Bool) {}

    /// The knob is painted in the scroller's own layer, not in the one AppKit
    /// keeps for it. AppKit lays that layer out for a scroller of its own
    /// width — 11pt across and 3pt off the far edge — so in one 8pt wide only
    /// 5pt of it showed, and not against the edge.
    override func drawKnob() {}

    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let rect = Self.knobPaintRect(for: rect(for: .knob), in: bounds, vertical: isVertical)
        guard !rect.isEmpty else { return }
        let radius = min(rect.width, rect.height) / 2
        Theme.scrollerKnob.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    /// AppKit moves its own knob layer as the content scrolls; this one is
    /// drawn again.
    override var doubleValue: Double { didSet { needsDisplay = true } }
    override var knobProportion: CGFloat { didSet { needsDisplay = true } }

    /// The capsule to paint for AppKit's knob: where along the scroller it
    /// says, and all the way across — so it lies against the edge of the area
    /// it scrolls, with nothing between them.
    static func knobPaintRect(for knob: NSRect, in bounds: NSRect, vertical: Bool) -> NSRect {
        guard knob.width > 0, knob.height > 0, bounds.width > 0, bounds.height > 0 else {
            return .zero
        }
        return vertical
            ? NSRect(x: bounds.minX, y: knob.minY, width: bounds.width, height: knob.height)
            : NSRect(x: knob.minX, y: bounds.minY, width: knob.width, height: bounds.height)
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
        hoverRefreshing?.refreshHoverState()
    }

    private func endDragging() {
        Self.isDragging = false
        hoverRefreshing?.refreshHoverState()
    }

    /// What this scroller scrolls, when that lights the row under the pointer.
    /// A scroller is the scroll view's own subview, not inside its document,
    /// so `enclosingScrollView` has nothing to say about it.
    private var hoverRefreshing: PointerHoverRefreshing? {
        (superview as? NSScrollView)?.documentView as? PointerHoverRefreshing
    }

    /// Make a scroll view the app's own: themed scrollers, shown whenever
    /// there is more to see, and none of AppKit's automatic content insets.
    ///
    /// Those insets are meant for a scroll view running under a window's
    /// titlebar. Every list here sits below a header the app draws itself, so
    /// the inset is pure extra space at the top — which is why the first row of
    /// the branch list sat further from the toolbar above it than the toolbar
    /// sat from the tabs.
    static func adopt(_ scrollView: NSScrollView) {
        scrollView.verticalScroller = PuzzleScroller()
        scrollView.horizontalScroller = PuzzleScroller()
        scrollView.scrollerStyle = .legacy
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
    }

    // MARK: - Regression-test surface

    /// The colour a knob actually paints with, read back from a render.
    static func knobColourForTesting(size: NSSize = NSSize(width: 8, height: 60)) -> NSColor? {
        let scroller = PuzzleScroller(frame: NSRect(origin: .zero, size: size))
        scroller.scrollerStyle = .legacy
        scroller.knobProportion = 0.6
        scroller.doubleValue = 0.5
        let image = NSImage(size: size)
        image.lockFocus()
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
}

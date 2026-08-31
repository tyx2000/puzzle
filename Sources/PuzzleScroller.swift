import AppKit

/// The scrollbar knob, drawn from the theme.
///
/// AppKit's dark-mode knob is a fixed light grey, and against surfaces this
/// near black it is the brightest thing on screen. Drawing it ourselves keeps
/// it in the palette.
final class PuzzleScroller: NSScroller {
    /// Required, or AppKit silently falls back to its own scroller for the
    /// overlay style every window here uses.
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnobSlot(in slotRect: NSRect, highlight: Bool) {
        // Only the legacy style paints a slot, and then only while the pointer
        // is over it. An overlay scroller floats over the content.
        guard scrollerStyle == .legacy || highlight else { return }
        Theme.scrollerSlot.setFill()
        slotRect.fill()
    }

    override func drawKnob() {
        let rect = Self.knobPaintRect(for: rect(for: .knob), vertical: isVertical)
        guard !rect.isEmpty else { return }
        let radius = min(rect.width, rect.height) / 2
        Theme.scrollerKnob.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    /// The capsule to paint inside AppKit's knob rect.
    ///
    /// An overlay knob is only 6pt across, so the inset has to be a fraction of
    /// it: a fixed 3pt on each side collapsed the capsule to nothing, which is
    /// how a themed scrollbar became an invisible one.
    static func knobPaintRect(for knob: NSRect, vertical: Bool) -> NSRect {
        guard knob.width > 0, knob.height > 0 else { return .zero }
        let thickness = vertical ? knob.width : knob.height
        let inset = min(1, thickness / 6)
        let rect = knob.insetBy(dx: vertical ? inset : 0, dy: vertical ? 0 : inset)
        return rect.width > 0 && rect.height > 0 ? rect : knob
    }

    private var isVertical: Bool { bounds.height > bounds.width }

    /// Make a scroll view the app's own: themed scrollers, and none of
    /// AppKit's automatic content insets.
    ///
    /// Those insets are meant for a scroll view running under a window's
    /// titlebar. Every list here sits below a header the app draws itself, so
    /// the inset is pure extra space at the top — which is why the first row of
    /// the branch list sat further from the toolbar above it than the toolbar
    /// sat from the tabs.
    static func adopt(_ scrollView: NSScrollView) {
        scrollView.verticalScroller = PuzzleScroller()
        scrollView.horizontalScroller = PuzzleScroller()
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
    }

    // MARK: - Regression-test surface

    /// The colour a knob actually paints with, read back from a render.
    static func knobColourForTesting(size: NSSize = NSSize(width: 15, height: 60)) -> NSColor? {
        let scroller = PuzzleScroller(frame: NSRect(origin: .zero, size: size))
        scroller.knobProportion = 0.6
        scroller.doubleValue = 0.5
        // Drawn directly: an overlay scroller shows its knob only while
        // scrolling, so asking the view to render itself offscreen produces the
        // slot alone.
        let image = NSImage(size: size)
        image.lockFocus()
        scroller.drawKnob()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)
    }
}

import AppKit

/// A split view whose divider takes its colour from the theme. AppKit's default
/// hairline is a fixed system grey, unrelated to the line the activity bar and
/// the title band draw.
///
/// Only usable where Puzzle creates the split view itself (the editor panes).
/// `NSSplitViewController` insists on building its own, and assigning over it
/// raises inside AppKit's constraint pass, so the window's sidebar divider is
/// painted by `SplitDividerHandleView` instead.
final class PuzzleSplitView: NSSplitView {
    override var dividerColor: NSColor { Theme.border }
}

/// NSSplitViewController is its own split view's delegate, so we subclass it to
/// observe divider drags instead of replacing the delegate.
final class PuzzleSplitViewController: NSSplitViewController {
    private let dividerHitPadding: CGFloat = 6

    /// Called continuously while the user drags the divider, with the proposed
    /// sidebar width. Return value is passed straight through.
    var onDividerDrag: ((CGFloat) -> Void)?

    /// NOTE: NSSplitViewController does not itself implement this delegate
    /// method, so calling `super` here raises "unrecognized selector". Just pass
    /// the proposed position through.
    override func splitView(_ splitView: NSSplitView,
                            constrainSplitPosition proposedPosition: CGFloat,
                            ofSubviewAt dividerIndex: Int) -> CGFloat {
        if dividerIndex == 0 { onDividerDrag?(proposedPosition) }
        return proposedPosition
    }

    /// Keep the divider visually thin while making it much easier to acquire.
    /// AppKit uses this rectangle for pointer hit-testing and cursor feedback.
    ///
    /// Only the middle of the line takes hold, as on the handle laid over it
    /// (see `DividerGrip`); along the rest a press is the panes'.
    ///
    /// The band reaches into the panel, where its lists keep their scrollers
    /// against the line. A scroller showing there is the scroller's to catch:
    /// the divider keeps the largest part of its band that none covers, on
    /// the code's side.
    override func splitView(_ splitView: NSSplitView,
                            effectiveRect proposedEffectiveRect: NSRect,
                            forDrawnRect drawnRect: NSRect,
                            ofDividerAt dividerIndex: Int) -> NSRect {
        guard dividerIndex == 0 else { return proposedEffectiveRect }
        let expanded = splitView.isVertical
            ? drawnRect.insetBy(dx: -dividerHitPadding, dy: 0)
            : drawnRect.insetBy(dx: 0, dy: -dividerHitPadding)
        let band = DividerGrip.grabRect(
            in: proposedEffectiveRect.union(expanded).intersection(splitView.bounds),
            lineIsVertical: splitView.isVertical)
        return PuzzleScroller.uncovered(band, in: splitView)
            .max { $0.width * $0.height < $1.width * $1.height }
            ?? DividerGrip.grabRect(in: drawnRect, lineIsVertical: splitView.isVertical)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollersMoved(_:)),
            name: PuzzleScroller.showingDidChange, object: nil)
    }

    /// A scroller came, went or moved: the band's cursor is worked out again.
    @objc private func scrollersMoved(_ notification: Notification) {
        guard let window = splitView.window, notification.object as? NSWindow === window else {
            return
        }
        window.invalidateCursorRects(for: splitView)
    }
}

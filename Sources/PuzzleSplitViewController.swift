import AppKit

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
    override func splitView(_ splitView: NSSplitView,
                            effectiveRect proposedEffectiveRect: NSRect,
                            forDrawnRect drawnRect: NSRect,
                            ofDividerAt dividerIndex: Int) -> NSRect {
        guard dividerIndex == 0 else { return proposedEffectiveRect }
        let expanded = splitView.isVertical
            ? drawnRect.insetBy(dx: -dividerHitPadding, dy: 0)
            : drawnRect.insetBy(dx: 0, dy: -dividerHitPadding)
        return proposedEffectiveRect.union(expanded).intersection(splitView.bounds)
    }
}

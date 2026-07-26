import AppKit

/// NSSplitViewController is its own split view's delegate, so we subclass it to
/// observe divider drags instead of replacing the delegate.
final class PuzzleSplitViewController: NSSplitViewController {
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
}

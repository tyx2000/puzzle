import AppKit

/// The frame round the open tab's row, on its way to another row: a frame of
/// its own over the sidebar, from where the last row's was to where the new
/// row's will be, which then hands over to that row. The tree, the changes
/// and a commit's files share it, so one frame travels between the three.
///
/// Each list draws the frame in the row itself the rest of the time, so it
/// scrolls with the row and needs nothing from here.
enum RowFrameFlight {
    /// A step to the next row, and the longest flight, across the panel.
    static let shortest: TimeInterval = 0.22
    static let longest: TimeInterval = 0.32

    private static var flying: RowFrameView?
    private static weak var heldRow: FlatRowView?

    /// Longer the further it goes, so a flight across the panel does not
    /// read as a jump.
    static func duration(forDistance distance: CGFloat) -> TimeInterval {
        min(longest, shortest + TimeInterval(distance) / 4000)
    }

    /// Fly from `from` to `to`, rects in `host`'s coordinates of the frame
    /// itself. `row` is the row arriving, held back until the frame lands.
    /// Nothing flies without both ends, or with less motion asked for.
    static func fly(in host: NSView, from: NSRect?, to: NSRect?, landingOn row: FlatRowView?) {
        land()
        guard let from, let to, from != to, host.window != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let frame = RowFrameView(frame: from)
        host.addSubview(frame)
        flying = frame
        heldRow = row
        row?.holdsFrameBack = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration(forDistance: hypot(to.midX - from.midX,
                                                           to.midY - from.midY))
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            frame.animator().frame = to
        }, completionHandler: {
            if flying === frame { land() }
        })
    }

    /// Put down whatever is in flight: the row it was flying to shows its own
    /// frame. A new flight starts from where the last one was going.
    static func land() {
        flying?.removeFromSuperview()
        flying = nil
        heldRow?.holdsFrameBack = false
        heldRow = nil
    }

    static var isFlyingForTesting: Bool { flying != nil }
    static var flyingFrameForTesting: NSRect? { flying?.frame }
}

/// The frame drawn on its own, as a row draws it.
final class RowFrameView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.cornerRadius = FlatRowView.frameRadius
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.borderColor = Theme.cursor.cgColor }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

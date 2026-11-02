import AppKit

/// The frame round what the open tab shows — its tab, and its row in the
/// sidebar — drawn as a diff frames the change it is on, in the accent: a
/// 1.5pt line with 5pt corners, and a faint band of the same colour round
/// its outside.
enum OpenFrame {
    static var lineWidth: CGFloat { ChangeFrameOverlay.strokeWidth }
    static var cornerRadius: CGFloat { ChangeFrameOverlay.cornerRadius }
    static var glowWidth: CGFloat { ChangeFrameOverlay.glowWidth }
    static var glowAlpha: CGFloat { ChangeFrameOverlay.glowAlpha }
    static var colour: NSColor { Theme.cursor }

    /// A step to the next row or tab, and the longest move, across the panel.
    static let shortest: TimeInterval = 0.22
    static let longest: TimeInterval = 0.32
    /// The diff frame's curve: slow out of the old place and into the new.
    static let curve = CAMediaTimingFunction(controlPoints: 0.65, 0, 0.35, 1)

    /// Longer the further it goes, so a move across the panel does not read
    /// as a jump.
    static func duration(forDistance distance: CGFloat) -> TimeInterval {
        min(longest, shortest + TimeInterval(distance) / 4000)
    }
    static func duration(from: NSRect, to: NSRect) -> TimeInterval {
        duration(forDistance: hypot(to.midX - from.midX, to.midY - from.midY))
    }

    /// Where the band lies for a line at `rect`: all round it, outside.
    static func glowRect(for rect: NSRect) -> NSRect {
        rect.insetBy(dx: -glowWidth, dy: -glowWidth)
    }

    /// The frame drawn into the current context, line at `rect` — for a view
    /// rendered off screen.
    static func draw(in rect: NSRect) {
        let line = NSBezierPath(roundedRect: rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
                                xRadius: cornerRadius, yRadius: cornerRadius)
        let band = NSBezierPath(roundedRect: glowRect(for: rect).insetBy(dx: glowWidth / 2,
                                                                          dy: glowWidth / 2),
                                xRadius: cornerRadius + glowWidth / 2,
                                yRadius: cornerRadius + glowWidth / 2)
        colour.withAlphaComponent(glowAlpha).setStroke()
        band.lineWidth = glowWidth
        band.stroke()
        colour.setStroke()
        line.lineWidth = lineWidth
        line.stroke()
    }

    /// The two edges as layers, for a view that keeps the frame still inside
    /// itself. Each is a border, drawn by Core Animation at any size.
    static func makeLayers() -> (glow: CALayer, line: CALayer) {
        let glow = CALayer(), line = CALayer()
        glow.borderWidth = glowWidth
        glow.cornerRadius = cornerRadius + glowWidth
        line.borderWidth = lineWidth
        line.cornerRadius = cornerRadius
        for layer in [glow, line] {
            layer.zPosition = 100
            // Placed and coloured at once: it never animates on its own.
            layer.actions = ["frame": NSNull(), "bounds": NSNull(), "position": NSNull(),
                             "hidden": NSNull(), "borderColor": NSNull()]
        }
        return (glow, line)
    }
    static func style(glow: CALayer, line: CALayer, at rect: NSRect, hidden: Bool) {
        glow.isHidden = hidden
        line.isHidden = hidden
        glow.frame = glowRect(for: rect)
        line.frame = rect
        glow.borderColor = colour.withAlphaComponent(glowAlpha).cgColor
        line.borderColor = colour.cgColor
    }
}

/// One edge of the frame as a view of its own — the line, or the band round
/// it — so the pair can be moved together by animating their frames.
final class OpenFrameEdgeView: NSView {
    enum Part { case line, glow }
    let part: Part

    init(_ part: Part) {
        self.part = part
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = part == .line ? OpenFrame.lineWidth : OpenFrame.glowWidth
        layer?.cornerRadius = part == .line ? OpenFrame.cornerRadius
                                            : OpenFrame.cornerRadius + OpenFrame.glowWidth
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let colour = part == .line ? OpenFrame.colour
                                   : OpenFrame.colour.withAlphaComponent(OpenFrame.glowAlpha)
        layer?.borderColor = colour.cgColor
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The frame as a pair of views over what it frames, put down or moved as
/// one. `rect` is the line's; the band reaches outside it.
final class OpenFrameMarker {
    let glow = OpenFrameEdgeView(.glow)
    let line = OpenFrameEdgeView(.line)
    private(set) var rect: NSRect?

    /// On top of everything else in `host`, including views added after.
    func raise(in host: NSView) {
        host.addSubview(glow, positioned: .above, relativeTo: nil)
        host.addSubview(line, positioned: .above, relativeTo: nil)
    }
    func remove() {
        glow.removeFromSuperview()
        line.removeFromSuperview()
        rect = nil
    }
    var isHidden: Bool {
        get { line.isHidden }
        set {
            glow.isHidden = newValue
            line.isHidden = newValue
            if newValue { rect = nil }
        }
    }
    func refreshColour() {
        glow.needsDisplay = true
        line.needsDisplay = true
    }

    /// Put the frame at `target`, moving it there from where it was when
    /// `moving` — with less motion asked for, or nowhere to come from, it is
    /// simply put there.
    func place(_ target: NSRect, moving: Bool, completion: (() -> Void)? = nil) {
        let from = rect
        rect = target
        guard moving, let from, from != target, line.window != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            glow.frame = OpenFrame.glowRect(for: target)
            line.frame = target
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = OpenFrame.duration(from: from, to: target)
            context.timingFunction = OpenFrame.curve
            glow.animator().frame = OpenFrame.glowRect(for: target)
            line.animator().frame = target
        }, completionHandler: completion)
    }
}

/// The sidebar's frame on its way to another row: a frame of its own over
/// the sidebar, from where the last row's was to where the new row's will
/// be, which then hands over to that row. The tree, the changes and a
/// commit's files share it, so one frame travels between the three.
///
/// Each list draws the frame in the row itself the rest of the time, so it
/// scrolls with the row and needs nothing from here.
enum RowFrameFlight {
    static var shortest: TimeInterval { OpenFrame.shortest }
    static var longest: TimeInterval { OpenFrame.longest }

    private static var flying: OpenFrameMarker?
    private static weak var heldRow: FlatRowView?

    static func duration(forDistance distance: CGFloat) -> TimeInterval {
        OpenFrame.duration(forDistance: distance)
    }

    /// Fly from `from` to `to`, rects in `host`'s coordinates of the frame's
    /// line. `row` is the row arriving, held back until the frame lands.
    /// Nothing flies without both ends, or with less motion asked for.
    static func fly(in host: NSView, from: NSRect?, to: NSRect?, landingOn row: FlatRowView?) {
        land()
        guard let from, let to, from != to, host.window != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let marker = OpenFrameMarker()
        marker.raise(in: host)
        marker.place(from, moving: false)
        flying = marker
        heldRow = row
        row?.holdsFrameBack = true
        marker.place(to, moving: true) {
            if flying === marker { land() }
        }
    }

    /// Put down whatever is in flight: the row it was flying to shows its own
    /// frame. A new flight starts from where the last one was going.
    static func land() {
        flying?.remove()
        flying = nil
        heldRow?.holdsFrameBack = false
        heldRow = nil
    }

    static var isFlyingForTesting: Bool { flying != nil }
    static var flyingFrameForTesting: NSRect? { flying?.rect }
}

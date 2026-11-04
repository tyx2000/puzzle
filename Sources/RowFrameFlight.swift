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

/// One background travels between the sidebar's selected rows. Its cached
/// geometry is read by the row backgrounds, behind their cells and icons.
enum RowFrameFlight {
    static var shortest: TimeInterval { PuzzleTextView.lineFlightShortest }
    static var longest: TimeInterval { PuzzleTextView.lineFlightLongest }

    private struct Flight {
        let from: NSRect
        let to: NSRect
        let started: CFTimeInterval
        let duration: TimeInterval
    }
    private static var flight: Flight?
    private static weak var host: NSView?
    private static weak var heldRow: FlatRowView?
    private static var displayed: NSRect?
    private static var timer: Timer?
    private static let rows = NSHashTable<FlatRowView>.weakObjects()
    private static let scrollingClips = NSHashTable<NSClipView>.weakObjects()
    private static var scrollObservers: [NSObjectProtocol] = []

    static func register(_ row: FlatRowView) { rows.add(row) }

    static func duration(forDistance distance: CGFloat) -> TimeInterval {
        PuzzleTextView.lineFlightDuration(forDistance: distance)
    }

    static func controlsBackground(in row: FlatRowView) -> Bool {
        guard flight != nil, let host else { return false }
        return row.window === host.window && row.isDescendant(of: host)
    }

    /// The moving piece belonging to this row, in its own coordinates.
    static func background(in row: FlatRowView) -> NSRect? {
        backgroundShape(in: row).map { $0.intersection(row.bounds) }
    }

    /// Keep the complete shape so rounded corners belong to the band,
    /// rather than to each row-sized slice of it.
    static func backgroundShape(in row: FlatRowView) -> NSRect? {
        guard flight != nil, let host, let displayed,
              row.window === host.window, row.isDescendant(of: host) else { return nil }
        let shape = row.convert(displayed, from: host)
        let piece = shape.intersection(row.bounds)
        return piece.isNull || piece.isEmpty ? nil : shape
    }

    /// Rects are in the host's coordinates. An interrupted flight starts
    /// where it is displayed, even if it was heading in the other direction.
    static func fly(in newHost: NSView, from: NSRect?, to: NSRect?, landingOn row: FlatRowView?,
                    scrolling participating: [NSClipView]? = nil) {
        let current = host === newHost ? displayed : nil
        // A redirected background can be between lists. Keep observing the
        // lists it left as well as the one it is now heading into.
        let previousClips = host === newHost ? scrollingClips.allObjects : []
        land()
        guard let from = current ?? from, let to, from != to,
              newHost.window != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        host = newHost
        heldRow = row
        row?.holdsFrameBack = true
        displayed = from
        flight = Flight(from: from, to: to, started: CACurrentMediaTime(),
                        duration: duration(forDistance: hypot(to.midX - from.midX,
                                                              to.midY - from.midY)))
        // The sidebar knows the exact lists even when a horizontally wide
        // history row extends beyond its own viewport into another column.
        var clips = previousClips + (participating ?? participatingClips(in: newHost, from: from, to: to))
        if let clip = row?.enclosingScrollView?.contentView { clips.append(clip) }
        observeScrolling(in: clips)
        let ticker = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in advance() }
        timer = ticker
        RunLoop.main.add(ticker, forMode: .common)
        advance()
    }

    /// Only lists holding one of the two ends participate. Scrolling another
    /// list in the sidebar must not stop this background's movement.
    private static func participatingClips(in host: NSView, from: NSRect, to: NSRect) -> [NSClipView] {
        var clips: [NSClipView] = []
        func visit(_ view: NSView) {
            guard !view.isHidden else { return }
            if let clip = view as? NSClipView {
                let viewport = host.convert(clip.bounds, from: clip)
                if viewport.intersects(from) || viewport.intersects(to) { clips.append(clip) }
            }
            view.subviews.forEach(visit)
        }
        visit(host)
        return clips
    }

    private static func observeScrolling(in clips: [NSClipView]) {
        for clip in clips where !scrollingClips.contains(clip) {
            scrollingClips.add(clip)
            clip.postsBoundsChangedNotifications = true
            scrollObservers.append(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { _ in
                // The ends are in host coordinates, so scrolling would leave
                // them pointing at the old screen rows. Let the selected row
                // immediately take over its own, correctly scrolled ground.
                land()
            })
        }
    }

    private static func refreshRows() {
        for row in rows.allObjects { row.needsDisplay = true }
    }

    private static func advance() {
        guard let flight, let host, host.window != nil else { land(); return }
        let progress = min(1, max(0, (CACurrentMediaTime() - flight.started) / flight.duration))
        let t = ChangeFrameOverlay.eased(CGFloat(progress))
        displayed = NSRect(x: flight.from.minX + (flight.to.minX - flight.from.minX) * t,
                           y: flight.from.minY + (flight.to.minY - flight.from.minY) * t,
                           width: flight.from.width + (flight.to.width - flight.from.width) * t,
                           height: flight.from.height + (flight.to.height - flight.from.height) * t)
        refreshRows()
        if progress >= 1 { land() }
    }

    static func land() {
        scrollObservers.forEach { NotificationCenter.default.removeObserver($0) }
        scrollObservers.removeAll()
        scrollingClips.removeAllObjects()
        timer?.invalidate()
        timer = nil
        flight = nil
        displayed = nil
        host = nil
        heldRow?.holdsFrameBack = false
        heldRow = nil
        refreshRows()
    }

    static var isFlyingForTesting: Bool { flight != nil }
    static var flyingFrameForTesting: NSRect? { flight?.to }
    static var displayedBackgroundForTesting: NSRect? { displayed }
}

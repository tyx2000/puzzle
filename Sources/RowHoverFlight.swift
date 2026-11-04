import AppKit

/// The pointer's background follows its latest row without restarting an
/// easing curve at every boundary. Geometry stays in the list's coordinates;
/// each row draws only its piece of the complete rounded shape.
final class RowHoverFollower {
    static let responseTime: TimeInterval = 0.03
    private static let landingTolerance: CGFloat = 0.25
    private static let followers = NSHashTable<RowHoverFollower>.weakObjects()

    private weak var host: NSView?
    private let invalidate: ((NSRect) -> Void)?
    private(set) var targetRect: NSRect?
    private var followedRect: NSRect?
    private var timer: Timer?
    private var lastTick: CFTimeInterval?
    private weak var observedClip: NSClipView?
    private var scrollObserver: NSObjectProtocol?
    private var motionObserver: NSObjectProtocol?

    var displayedRect: NSRect? { followedRect ?? targetRect }
    var isFlyingForTesting: Bool { timer != nil }
    var reduceMotionForTesting: Bool? {
        didSet {
            if shouldReduceMotion { cancel(clear: false) }
        }
    }

    init(host: NSView, invalidate: ((NSRect) -> Void)? = nil) {
        self.host = host
        self.invalidate = invalidate
        Self.followers.add(self)
        motionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.shouldReduceMotion else { return }
            self.cancel(clear: false)
        }
    }

    deinit {
        timer?.invalidate()
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        if let motionObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(motionObserver)
        }
    }

    private var shouldReduceMotion: Bool {
        reduceMotionForTesting ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// A pointer burst replaces only the target. The next tick integrates
    /// from the last displayed position using the same running clock.
    func setTarget(_ rect: NSRect?, animated: Bool = true) {
        observeScrolling()
        let previous = displayedRect
        let canAnimate = animated && host?.window?.isVisible == true && !shouldReduceMotion
        guard rect != targetRect else {
            if !canAnimate { cancel(clear: false) }
            return
        }
        targetRect = rect
        guard canAnimate, let previous, let rect,
              distance(from: previous, to: rect) > Self.landingTolerance else {
            cancel(clear: false)
            refresh(previous, rect)
            return
        }
        followedRect = previous
        if timer == nil {
            lastTick = CACurrentMediaTime()
            let ticker = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                self?.advance()
            }
            timer = ticker
            RunLoop.main.add(ticker, forMode: .common)
        }
    }

    /// A scroll, exit, or disappearing host drops stale document geometry.
    /// With `clear: false`, the target remains and is displayed immediately.
    func cancel(clear: Bool = true) {
        let previous = displayedRect
        timer?.invalidate()
        timer = nil
        lastTick = nil
        followedRect = nil
        if clear { targetRect = nil }
        refresh(previous, targetRect)
    }

    private func observeScrolling() {
        let clip = host?.enclosingScrollView?.contentView
        guard observedClip !== clip else { return }
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        observedClip = clip
        guard let clip else { return }
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.cancel()
            // Re-evaluate a stationary pointer after the rows move under it.
            // Starting from no band makes the new geometry land immediately.
            (self.host as? PointerHoverRefreshing)?.refreshHoverState()
        }
    }

    private func advance() {
        let time = CACurrentMediaTime()
        let elapsed = max(0, time - (lastTick ?? time))
        lastTick = time
        integrate(elapsed: elapsed)
    }

    private func integrate(elapsed: TimeInterval) {
        guard timer != nil, let targetRect, let previous = followedRect,
              host?.window?.isVisible == true, !shouldReduceMotion else {
            cancel(clear: host?.window == nil)
            return
        }
        // Exact exponential integration gives a 30ms response even when a
        // frame runs late. Retargeting never inserts a new slow start.
        let fraction = CGFloat(-expm1(-max(0, elapsed) / Self.responseTime))
        let now = NSRect(x: previous.minX + (targetRect.minX - previous.minX) * fraction,
                         y: previous.minY + (targetRect.minY - previous.minY) * fraction,
                         width: previous.width + (targetRect.width - previous.width) * fraction,
                         height: previous.height + (targetRect.height - previous.height) * fraction)
        followedRect = now
        refresh(previous, now)
        if distance(from: now, to: targetRect) <= Self.landingTolerance {
            cancel(clear: false)
        }
    }

    private func distance(from: NSRect, to: NSRect) -> CGFloat {
        max(max(abs(from.minX - to.minX), abs(from.minY - to.minY)),
            max(abs(from.width - to.width), abs(from.height - to.height)))
    }

    private func refresh(_ previous: NSRect?, _ next: NSRect?) {
        guard let host else { return }
        let damage: NSRect
        if let previous {
            damage = next.map { previous.union($0) } ?? previous
        } else if let next {
            damage = next
        } else {
            return
        }
        if let invalidate {
            invalidate(damage)
        } else if let table = host as? NSTableView {
            table.enumerateAvailableRowViews { row, _ in
                guard row.convert(row.bounds, to: table).intersects(damage) else { return }
                row.needsDisplay = true
            }
        } else {
            host.setNeedsDisplay(damage)
        }
    }

    private static func follower(containing row: FlatRowView) -> RowHoverFollower? {
        let available = followers.allObjects
        var ancestor = row.superview
        while let view = ancestor {
            if view is NSTableView, let follower = available.first(where: { $0.host === view }) {
                return follower
            }
            ancestor = view.superview
        }
        return nil
    }

    static func controlsBackground(in row: FlatRowView) -> Bool {
        follower(containing: row) != nil
    }

    /// Return the whole band so the row boundary cannot add rounded seams.
    static func backgroundShape(in row: FlatRowView) -> NSRect? {
        guard let follower = follower(containing: row), let host = follower.host,
              let displayed = follower.displayedRect else { return nil }
        let shape = row.convert(displayed, from: host)
        let piece = shape.intersection(row.bounds)
        return piece.isNull || piece.isEmpty ? nil : shape
    }

    func advanceForTesting(elapsed: TimeInterval) { integrate(elapsed: elapsed) }
}

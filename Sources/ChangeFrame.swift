import AppKit

/// The change a diff's ↑↓ buttons are on, framed: a box round its rows, in
/// the colour the gutter marks that kind of change with — green for lines put
/// in, red for lines taken out, blue for both. It is on the first change when
/// a diff opens and stays where it is put. A step moves it to the next change,
/// and the code with it when that change is off screen, as one motion.
///
/// Laid over a scroll view's code, under the round buttons, taking no clicks.
/// The box is kept in the scrolled view's coordinates, so it moves with the
/// code however the code is scrolled; nothing under it is drawn again while
/// it moves.
final class ChangeFrameOverlay: NSView {
    static let strokeWidth: CGFloat = 1.5
    static let cornerRadius: CGFloat = 5
    /// The faint band of the frame's colour round its outside.
    static let glowWidth: CGFloat = 3
    static let glowAlpha: CGFloat = 0.16
    /// Clear of the scroller at the code's right edge.
    static let trailingInset: CGFloat = 6
    /// A step to a change already on screen.
    static let moveDuration: TimeInterval = 0.22
    /// A step that scrolls: the code and the frame together.
    static let scrollingMoveDuration: TimeInterval = 0.28
    static let appearDuration: TimeInterval = 0.2
    /// A change this close to the edge of the view is scrolled into it.
    static let margin: CGFloat = 24

    /// The view whose content the frame is anchored to.
    weak var scrollView: NSScrollView? {
        didSet { observeScrolling() }
    }
    /// Where the code starts, in this view's coordinates: past a gutter of
    /// line numbers, if the code has one.
    var codeMinX: () -> CGFloat = { 0 }

    /// The rows framed, in the document view's coordinates; nil for no frame.
    private(set) var rows: NSRect?
    private(set) var colour: NSColor = Theme.blue
    private var motion: Motion?
    private var timer: Timer?
    private var scrollObserver: NSObjectProtocol?

    private struct Motion {
        let fromRows: NSRect
        let toRows: NSRect
        let fromColour: NSColor
        let toColour: NSColor
        let fromScroll: CGFloat
        let toScroll: CGFloat
        let started: CFTimeInterval
        let duration: TimeInterval
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        timer?.invalidate()
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }

    /// Frame `rows` (in the document view's coordinates) in `colour`, and
    /// bring them on screen if they are not — unless `revealing` is false, for
    /// a tab come back to where it was left. Moved there when there was a
    /// frame already and `animated`; otherwise put there, fading in.
    func frame(rows target: NSRect, colour: NSColor, animated: Bool, revealing: Bool = true) {
        let clip = scrollView?.contentView
        let fromScroll = clip?.bounds.minY ?? 0
        let toScroll = revealing ? scrollTarget(for: target) ?? fromScroll : fromScroll
        timer?.invalidate()
        timer = nil
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animated, !reduceMotion, let from = currentRows else {
            motion = nil
            let appearing = rows == nil
            rows = target
            self.colour = colour
            scroll(to: toScroll)
            needsDisplay = true
            if appearing, !reduceMotion, window != nil {
                alphaValue = 0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Self.appearDuration
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    animator().alphaValue = 1
                }
            } else {
                alphaValue = 1
            }
            return
        }
        alphaValue = 1
        motion = Motion(fromRows: from, toRows: target,
                        fromColour: drawnColour, toColour: colour,
                        fromScroll: fromScroll, toScroll: toScroll,
                        started: CACurrentMediaTime(),
                        duration: toScroll != fromScroll
                            ? Self.scrollingMoveDuration : Self.moveDuration)
        rows = target
        self.colour = colour
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            self?.advance()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        advance()
    }

    func clear() {
        timer?.invalidate()
        timer = nil
        motion = nil
        rows = nil
        needsDisplay = true
    }

    /// Where the frame is drawn this moment: on its way, or where it was put.
    private var currentRows: NSRect? {
        guard let motion else { return rows }
        let progress = Self.eased(motionProgress(motion))
        return NSRect(x: 0,
                      y: motion.fromRows.minY + (motion.toRows.minY - motion.fromRows.minY) * progress,
                      width: 0,
                      height: motion.fromRows.height
                        + (motion.toRows.height - motion.fromRows.height) * progress)
    }

    /// The colour drawn this moment. A blend lasts only while the frame
    /// moves; at rest it is the theme's own colour, which follows a change
    /// of theme.
    private var drawnColour: NSColor {
        guard let motion,
              let from = motion.fromColour.usingColorSpace(.sRGB),
              let to = motion.toColour.usingColorSpace(.sRGB),
              let blended = from.blended(withFraction: Self.eased(motionProgress(motion)), of: to)
        else { return colour }
        return blended
    }

    private func motionProgress(_ motion: Motion) -> CGFloat {
        CGFloat(min(1, max(0, (CACurrentMediaTime() - motion.started) / motion.duration)))
    }

    /// Slow out of the old place and into the new, the code and the frame on
    /// the same curve so the frame stays on its rows.
    static func eased(_ t: CGFloat) -> CGFloat {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    private func advance() {
        guard let motion else {
            timer?.invalidate()
            timer = nil
            return
        }
        let progress = motionProgress(motion)
        let eased = Self.eased(progress)
        scroll(to: motion.fromScroll + (motion.toScroll - motion.fromScroll) * eased)
        needsDisplay = true
        if progress >= 1 {
            self.motion = nil
            timer?.invalidate()
            timer = nil
        }
    }

    /// Where the code scrolls to show `rows`: nowhere when they are already
    /// in view clear of its edges; otherwise with their top a quarter of the
    /// way down, within the code's length.
    private func scrollTarget(for rows: NSRect) -> CGFloat? {
        guard let scrollView, let document = scrollView.documentView else { return nil }
        let visible = scrollView.contentView.bounds
        if rows.minY >= visible.minY + Self.margin, rows.maxY <= visible.maxY - Self.margin {
            return nil
        }
        let maximum = max(0, document.bounds.height - visible.height)
        return min(max(0, (rows.minY - visible.height / 4).rounded()), maximum)
    }

    private func scroll(to y: CGFloat) {
        guard let scrollView else { return }
        let clip = scrollView.contentView
        guard abs(clip.bounds.minY - y) > 0.01 else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    private func observeScrolling() {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        guard let clip = scrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in
            guard let self, self.rows != nil else { return }
            self.needsDisplay = true
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if rows != nil { needsDisplay = true }
    }

    /// The box as drawn, in this view's coordinates.
    var boxRect: NSRect? {
        guard let rows = currentRows, let document = scrollView?.documentView else { return nil }
        let span = convert(NSRect(x: 0, y: rows.minY, width: 1, height: rows.height), from: document)
        let left = codeMinX() + Self.strokeWidth / 2
        let right = bounds.maxX - Self.trailingInset
        guard right > left else { return nil }
        return NSRect(x: left, y: span.minY + Self.strokeWidth / 2, width: right - left,
                      height: max(0, span.height - Self.strokeWidth))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let box = boxRect else { return }
        let colour = drawnColour
        let path = NSBezierPath(roundedRect: box, xRadius: Self.cornerRadius,
                                yRadius: Self.cornerRadius)
        // The glow lies outside the box only, so the rows inside keep their
        // own colours right up to the line.
        NSGraphicsContext.saveGraphicsState()
        let outside = NSBezierPath(rect: bounds)
        outside.append(path)
        outside.windingRule = .evenOdd
        outside.addClip()
        colour.withAlphaComponent(Self.glowAlpha).setStroke()
        path.lineWidth = Self.strokeWidth + Self.glowWidth * 2
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
        colour.setStroke()
        path.lineWidth = Self.strokeWidth
        path.stroke()
    }

    // MARK: - Regression-test surface

    var isMovingForTesting: Bool { motion != nil }
}

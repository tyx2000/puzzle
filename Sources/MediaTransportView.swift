import AppKit
import AVFoundation

/// Flat transport controls for an audio file: play/pause, elapsed and remaining
/// time, and a scrubber.
///
/// `AVPlayerView` is the right control for video — it hosts the picture, and its
/// bar floats over the frame and hides itself. With no picture there is nothing
/// for it to float over, so it paints its own backdrop, and a grey slab in the
/// middle of the editor is exactly what the rest of this app is drawn by hand to
/// avoid. This is the same set of controls in the editor's own colours.
final class MediaTransportView: NSView {
    private let playButton = NSButton()
    private let elapsedLabel = NSTextField(labelWithString: "0:00")
    private let remainingLabel = NSTextField(labelWithString: "0:00")
    private let scrubber = MediaScrubberView()

    /// Natural width of the bar. Stretching a scrubber across a wide pane makes
    /// it read as a progress bar for the window rather than for the file.
    static let preferredWidth: CGFloat = 420
    static let barHeight: CGFloat = 26

    var player: AVPlayer? {
        didSet {
            detach(from: oldValue)
            guard let player else {
                scrubber.progress = 0
                setTimes(elapsed: 0, duration: 0)
                updatePlayGlyph(playing: false)
                return
            }
            attach(to: player)
        }
    }

    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        playButton.image = Theme.symbol("play.fill", accessibilityDescription: "Play",
                                        pointSize: 12, weight: .medium)
        playButton.imagePosition = .imageOnly
        playButton.imageScaling = .scaleProportionallyDown
        playButton.bezelStyle = .inline
        playButton.isBordered = false
        playButton.contentTintColor = Theme.foreground
        playButton.target = self
        playButton.action = #selector(togglePlayback)
        addSubview(playButton)

        for label in [elapsedLabel, remainingLabel] {
            // Monospaced digits: a proportional font makes the whole bar twitch
            // sideways once a second as the numbers change width.
            label.font = NSFont.monospacedDigitSystemFont(
                ofSize: Theme.uiFont(10.5).pointSize, weight: .regular)
            label.textColor = Theme.dimText
            addSubview(label)
        }
        elapsedLabel.alignment = .left
        remainingLabel.alignment = .right

        scrubber.onSeek = { [weak self] fraction in self?.seek(toFraction: fraction) }
        addSubview(scrubber)
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { detach(from: player) }

    private func attach(to player: AVPlayer) {
        // A quarter second is below the threshold where a moving scrubber looks
        // stepped, and far above the cost of redrawing one small view.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main) { [weak self] time in
            self?.update(elapsed: time)
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) {
            [weak self] player, _ in
            DispatchQueue.main.async {
                self?.updatePlayGlyph(playing: player.timeControlStatus != .paused)
            }
        }
        // Reaching the end leaves the player paused at the very last frame; the
        // button has to say "play" again, and pressing it starts from the top.
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem,
            queue: .main) { [weak self] _ in
            self?.updatePlayGlyph(playing: false)
        }
    }

    /// `removeTimeObserver` has to be sent to the player the observer was added
    /// to — by the time `didSet` runs, that is `oldValue` and not `player`.
    private func detach(from previous: AVPlayer?) {
        if let timeObserver, let previous { previous.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }

    // MARK: - Updates

    private func update(elapsed: CMTime) {
        guard let item = player?.currentItem, item.duration.isNumeric else { return }
        let duration = item.duration.seconds
        let seconds = elapsed.seconds
        guard duration > 0, seconds.isFinite else { return }
        if !scrubber.isScrubbing { scrubber.progress = min(1, max(0, seconds / duration)) }
        setTimes(elapsed: seconds, duration: duration)
    }

    private func setTimes(elapsed: Double, duration: Double) {
        elapsedLabel.stringValue = MediaTransportView.clock(elapsed)
        remainingLabel.stringValue = duration > 0
            ? "-" + MediaTransportView.clock(max(0, duration - elapsed)) : "0:00"
        needsLayout = true
    }

    private func updatePlayGlyph(playing: Bool) {
        let symbol = playing ? "pause.fill" : "play.fill"
        playButton.image = Theme.symbol(symbol,
                                        accessibilityDescription: playing ? "Pause" : "Play",
                                        pointSize: 12, weight: .medium)
        playButton.setAccessibilityLabel(playing ? "Pause" : "Play")
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, (total / 60) % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Actions

    @objc private func togglePlayback() {
        guard let player else { return }
        if player.timeControlStatus == .paused {
            // Pressing play on a finished file starts it again rather than
            // doing nothing at the last frame.
            if let item = player.currentItem, item.duration.isNumeric,
               item.currentTime() >= item.duration {
                player.seek(to: .zero)
            }
            player.play()
        } else {
            player.pause()
        }
    }

    private func seek(toFraction fraction: CGFloat) {
        guard let player, let item = player.currentItem, item.duration.isNumeric else { return }
        let target = item.duration.seconds * Double(fraction)
        guard target.isFinite else { return }
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let height = bounds.height
        let button: CGFloat = 24
        playButton.frame = NSRect(x: 0, y: floor((height - button) / 2),
                                  width: button, height: button)
        let timeWidth: CGFloat = 44
        let labelHeight = elapsedLabel.intrinsicContentSize.height
        let labelY = floor((height - labelHeight) / 2)
        elapsedLabel.frame = NSRect(x: playButton.frame.maxX + 8, y: labelY,
                                    width: timeWidth, height: labelHeight)
        remainingLabel.frame = NSRect(x: bounds.width - timeWidth, y: labelY,
                                      width: timeWidth, height: labelHeight)
        let railLeft = elapsedLabel.frame.maxX + 10
        let railRight = remainingLabel.frame.minX - 10
        scrubber.frame = NSRect(x: railLeft, y: 0,
                                width: max(0, railRight - railLeft), height: height)
    }

    func refreshFonts() {
        let size = Theme.uiFont(10.5).pointSize
        for label in [elapsedLabel, remainingLabel] {
            label.font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
            label.textColor = Theme.dimText
        }
        playButton.contentTintColor = Theme.foreground
        scrubber.needsDisplay = true
        needsLayout = true
    }

    var isPlayingForTesting: Bool { player?.timeControlStatus != .paused }
    var progressForTesting: CGFloat { scrubber.progress }
    func togglePlaybackForTesting() { togglePlayback() }
}

/// The scrubber: a thin rail, the played portion in the cursor colour, and a
/// knob that can be dragged. Drawn rather than an `NSSlider` so it matches the
/// theme and keeps the same 1px-flat look as the rest of the app.
final class MediaScrubberView: NSView {
    var progress: CGFloat = 0 { didSet { if progress != oldValue { needsDisplay = true } } }
    private(set) var isScrubbing = false
    var onSeek: ((CGFloat) -> Void)?

    private let railHeight: CGFloat = 3
    private let knobRadius: CGFloat = 5

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Leave the backdrop to the preview. Filling with .clear uses AppKit's
        // copy compositing and can punch a rectangular hole through that fill.
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let midY = bounds.height / 2
        let inset = knobRadius
        let railWidth = max(0, bounds.width - inset * 2)
        guard railWidth > 0 else { return }

        let rail = NSRect(x: inset, y: midY - railHeight / 2,
                          width: railWidth, height: railHeight)
        Theme.scrollerSlot.setFill()
        NSBezierPath(roundedRect: rail, xRadius: railHeight / 2,
                     yRadius: railHeight / 2).fill()

        let played = NSRect(x: rail.minX, y: rail.minY,
                            width: rail.width * min(1, max(0, progress)),
                            height: rail.height)
        Theme.cursor.setFill()
        NSBezierPath(roundedRect: played, xRadius: railHeight / 2,
                     yRadius: railHeight / 2).fill()

        let knobX = rail.minX + rail.width * min(1, max(0, progress))
        let knob = NSRect(x: knobX - knobRadius, y: midY - knobRadius,
                          width: knobRadius * 2, height: knobRadius * 2)
        Theme.cursor.setFill()
        NSBezierPath(ovalIn: knob).fill()
    }

    override func mouseDown(with event: NSEvent) {
        isScrubbing = true
        seek(to: event)
    }

    override func mouseDragged(with event: NSEvent) { seek(to: event) }

    override func mouseUp(with event: NSEvent) {
        seek(to: event)
        isScrubbing = false
    }

    private func seek(to event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let inset = knobRadius
        let railWidth = max(1, bounds.width - inset * 2)
        let fraction = min(1, max(0, (point.x - inset) / railWidth))
        progress = fraction
        onSeek?(fraction)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

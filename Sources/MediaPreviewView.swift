import AppKit
import AVKit
import AVFoundation

/// Plays a video or audio file in the editor area.
///
/// Video goes to `AVPlayerView`, which hosts the picture and floats the system
/// controls over it. Audio never touches `AVPlayerView`: with no picture to
/// float over, it paints its own backdrop, and a grey slab in the middle of the
/// editor is the one thing this app is drawn by hand to avoid. Audio gets a
/// waveform glyph and `MediaTransportView`, low in the pane where a video's
/// controls would sit.
///
/// Nothing here loads the file. `AVPlayer` streams it off disk, which is why a
/// media tab costs a caption's worth of memory when it is idle and why a video
/// far larger than the editor's in-memory limit can open at all.
final class MediaPreviewView: FlatView {
    private var playerView: AVPlayerView?
    /// Stands in for the missing picture on an audio-only file.
    private let icon = NSImageView()
    private let transport = MediaTransportView()
    private let caption = NSTextField(labelWithString: "")

    /// Which file the current player was built for. Re-activating the same tab
    /// must not tear down a player that is mid-playback and start it over.
    private(set) var loadedURL: URL?
    /// The name·size line the document supplied, before duration and pixel size
    /// are known. Those arrive only once the player has inspected the file.
    private var baseCaption = ""
    private var statusObservation: NSKeyValueObservation?

    private var videoConstraints: [NSLayoutConstraint] = []
    private var audioConstraints: [NSLayoutConstraint] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        fillColor = Theme.editorBackground

        icon.image = Theme.symbol("waveform", accessibilityDescription: "Audio file",
                                  pointSize: 40, weight: .thin)
        icon.contentTintColor = Theme.dimText
        icon.isHidden = true
        icon.translatesAutoresizingMaskIntoConstraints = false

        caption.font = Theme.uiFont(10.5)
        caption.textColor = Theme.dimText
        caption.alignment = .center
        caption.lineBreakMode = .byTruncatingMiddle
        caption.translatesAutoresizingMaskIntoConstraints = false

        transport.translatesAutoresizingMaskIntoConstraints = false
        transport.isHidden = true

        addSubview(icon)
        addSubview(transport)
        addSubview(caption)
        NSLayoutConstraint.activate([
            caption.centerXAnchor.constraint(equalTo: centerXAnchor),
            caption.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            caption.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            caption.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])

        // The bar keeps its natural width and sits low in the pane, where the
        // controls over a video would be, rather than centred in open space.
        let preferredWidth = transport.widthAnchor.constraint(
            equalToConstant: MediaTransportView.preferredWidth)
        preferredWidth.priority = .defaultHigh
        audioConstraints = [
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -30),
            transport.centerXAnchor.constraint(equalTo: centerXAnchor),
            transport.bottomAnchor.constraint(equalTo: caption.topAnchor, constant: -22),
            transport.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor,
                                               constant: 24),
            transport.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor,
                                                constant: -24),
            transport.heightAnchor.constraint(equalToConstant: MediaTransportView.barHeight),
            preferredWidth,
        ]
    }
    required init?(coder: NSCoder) { fatalError() }

    private func makeVideoView() -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .inline
        playerView.videoGravity = .resizeAspect
        playerView.showsFullScreenToggleButton = true
        playerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(playerView)
        videoConstraints = [
            playerView.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            playerView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            playerView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            playerView.bottomAnchor.constraint(equalTo: caption.topAnchor, constant: -12),
        ]

        NSLayoutConstraint.activate(videoConstraints)
        self.playerView = playerView
        return playerView
    }

    /// Build a player for `url`. Playback never starts on its own: opening a
    /// file in an editor should not make noise.
    func show(url: URL, caption text: String, isVideo: Bool) {
        guard loadedURL != url else { return }
        clear()
        loadedURL = url
        baseCaption = text
        caption.stringValue = text

        icon.isHidden = isVideo
        transport.isHidden = isVideo
        if !isVideo { NSLayoutConstraint.activate(audioConstraints) }

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        if isVideo {
            makeVideoView().player = player
        } else {
            transport.player = player
        }
        // Duration and pixel size are not known until the player has read the
        // file's headers, so the caption is completed rather than composed.
        statusObservation = item.observe(\.status, options: [.initial, .new]) {
            [weak self] item, _ in
            DispatchQueue.main.async { self?.describe(item, isVideo: isVideo) }
        }
    }

    /// Stop playback and release the decoder. Called whenever the tab stops
    /// being the visible one — without it a video keeps decoding, and an audio
    /// file keeps playing, from a tab nobody is looking at.
    func clear() {
        statusObservation = nil
        playerView?.player?.pause()
        playerView?.player = nil
        NSLayoutConstraint.deactivate(videoConstraints + audioConstraints)
        videoConstraints.removeAll()
        playerView?.removeFromSuperview()
        playerView = nil
        transport.player?.pause()
        transport.player = nil
        loadedURL = nil
        baseCaption = ""
        caption.stringValue = ""
        icon.isHidden = true
        transport.isHidden = true
    }

    private func describe(_ item: AVPlayerItem, isVideo: Bool) {
        guard item === (playerView?.player ?? transport.player)?.currentItem else { return }
        switch item.status {
        case .readyToPlay:
            var parts = [baseCaption]
            let size = item.presentationSize
            if isVideo, size.width > 0, size.height > 0 {
                parts.append("\(Int(size.width)) × \(Int(size.height))")
            }
            if let length = Self.formattedDuration(item.duration) { parts.append(length) }
            caption.stringValue = parts.joined(separator: "  ·  ")
        case .failed:
            // A supported container can still hold a codec the system has no
            // decoder for. Say so rather than leaving dead controls on screen.
            let reason = item.error?.localizedDescription ?? "The file could not be played."
            caption.stringValue = "\(baseCaption)  ·  \(reason)"
        default:
            break
        }
    }

    /// `h:mm:ss` past an hour, `m:ss` below it. An indefinite duration (a
    /// stream, a file still being written) formats as nothing at all.
    static func formattedDuration(_ time: CMTime) -> String? {
        guard time.isValid, !time.isIndefinite, time.seconds.isFinite,
              time.seconds >= 1 else { return nil }
        let total = Int(time.seconds.rounded())
        let seconds = total % 60
        let minutes = (total / 60) % 60
        let hours = total / 3600
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    var hasPlayerForTesting: Bool { playerView?.player != nil || transport.player != nil }
    /// Audio must never build an `AVPlayerView`: that is what draws the slab.
    var usesSystemPlayerViewForTesting: Bool { playerView != nil }
    var captionForTesting: String { caption.stringValue }
    var showsAudioLayoutForTesting: Bool { !icon.isHidden }
    var transportFrameForTesting: NSRect { transport.frame }

    func refreshFonts() {
        caption.font = Theme.uiFont(10.5)
        caption.textColor = Theme.dimText
        icon.contentTintColor = Theme.dimText
        transport.refreshFonts()
        fillColor = Theme.editorBackground
        needsDisplay = true
    }
}

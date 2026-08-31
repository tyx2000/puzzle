import AppKit

/// Shows a decoded image centred in the editor area, scaled down to fit but
/// never blown up past 100% (so small icons stay crisp instead of turning into
/// a blurry wall). A caption underneath carries name · pixel size · file size.
final class ImagePreviewView: FlatView {
    private let imageView = NSImageView()
    private let caption = NSTextField(labelWithString: "")
    /// Checkerboard behind the picture so transparent PNGs read correctly.
    private var showsCheckerboard = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        fillColor = Theme.editorBackground

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.translatesAutoresizingMaskIntoConstraints = false

        caption.font = Theme.uiFont(10.5)
        caption.textColor = Theme.dimText
        caption.alignment = .center
        caption.lineBreakMode = .byTruncatingMiddle
        caption.translatesAutoresizingMaskIntoConstraints = false

        addSubview(imageView)
        addSubview(caption)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -14),
            imageView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            imageView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            imageView.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 24),

            caption.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 12),
            caption.centerXAnchor.constraint(equalTo: centerXAnchor),
            caption.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            caption.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            caption.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private var widthConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?
    private var aspectConstraint: NSLayoutConstraint?

    func show(image: NSImage, caption text: String) {
        imageView.image = image
        caption.stringValue = text

        // Natural pixel size (not the point size, which is DPI-adjusted).
        let rep = image.representations.first
        let pixelSize = NSSize(width: CGFloat(rep?.pixelsWide ?? Int(image.size.width)),
                               height: CGFloat(rep?.pixelsHigh ?? Int(image.size.height)))
        widthConstraint?.isActive = false
        heightConstraint?.isActive = false
        aspectConstraint?.isActive = false
        // Cap at natural size; the ≤ constraints above shrink it to fit.
        let w = imageView.widthAnchor.constraint(lessThanOrEqualToConstant: max(1, pixelSize.width))
        let h = imageView.heightAnchor.constraint(lessThanOrEqualToConstant: max(1, pixelSize.height))
        // Preserve aspect ratio while scaling down.
        let aspect = imageView.widthAnchor.constraint(
            equalTo: imageView.heightAnchor,
            multiplier: pixelSize.width / max(1, pixelSize.height))
        NSLayoutConstraint.activate([w, h, aspect])
        widthConstraint = w
        heightConstraint = h
        aspectConstraint = aspect
        needsDisplay = true
    }

    /// Release the decoded bitmap as soon as the preview is no longer visible.
    /// The document can decode/reload it again if its tab is revisited.
    func clear() {
        imageView.image = nil
        caption.stringValue = ""
        NSLayoutConstraint.deactivate(
            [widthConstraint, heightConstraint, aspectConstraint].compactMap { $0 })
        widthConstraint = nil
        heightConstraint = nil
        aspectConstraint = nil
        needsDisplay = true
    }

    var hasImageForTesting: Bool { imageView.image != nil }
    var dynamicConstraintCountForTesting: Int {
        [widthConstraint, heightConstraint, aspectConstraint].compactMap { $0 }.count
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard showsCheckerboard, imageView.image != nil else { return }
        // Light checkerboard under the picture so alpha is visible.
        let frame = imageView.frame
        guard frame.width > 1, frame.height > 1 else { return }
        let square: CGFloat = 8
        NSColor(white: 0.22, alpha: 1).setFill()
        frame.fill()
        NSColor(white: 0.27, alpha: 1).setFill()
        var row = 0
        var y = frame.minY
        while y < frame.maxY {
            var x = frame.minX + (row % 2 == 0 ? 0 : square)
            while x < frame.maxX {
                NSRect(x: x, y: y,
                       width: min(square, frame.maxX - x),
                       height: min(square, frame.maxY - y)).fill()
                x += square * 2
            }
            y += square
            row += 1
        }
    }

    func refreshFonts() {
        caption.font = Theme.uiFont(10.5)
        fillColor = Theme.editorBackground
        needsDisplay = true
    }
}

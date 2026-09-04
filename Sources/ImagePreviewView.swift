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

        caption.font = Theme.uiFont(10.5)
        caption.textColor = Theme.dimText
        caption.alignment = .center
        caption.lineBreakMode = .byTruncatingMiddle

        addSubview(imageView)
        addSubview(caption)
    }
    required init?(coder: NSCoder) { fatalError() }

    // Child frames are local to this viewport. An image's intrinsic dimensions
    // must never feed Auto Layout's window minimum-size calculation.
    private var imagePixelSize = NSSize.zero

    private var source: PreviewImageSource?
    private var decodedMaximum = 0
    private var resizeWork: DispatchWorkItem?

    func show(source: PreviewImageSource, caption text: String) {
        clear()
        self.source = source
        caption.stringValue = text
        imagePixelSize = source.pixelSize
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard imagePixelSize.width > 0, imagePixelSize.height > 0 else { return }
        let fit = min(1, max(0, bounds.width - 48) / imagePixelSize.width,
                      max(0, bounds.height - 80) / imagePixelSize.height)
        let size = NSSize(width: imagePixelSize.width * fit, height: imagePixelSize.height * fit)
        imageView.frame = NSRect(x: bounds.midX - size.width / 2,
                                 y: bounds.midY - size.height / 2 + 14,
                                 width: size.width, height: size.height)
        caption.frame = NSRect(x: 16, y: max(0, imageView.frame.minY - 30),
                               width: max(0, bounds.width - 32), height: 18)
        needsDisplay = true
        guard source != nil, size.width > 0, size.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let pixels = max(size.width, size.height) * scale
        let target = min(4096, Int(ceil(pixels / 64)) * 64)
        resizeWork?.cancel()
        resizeWork = nil
        guard target != decodedMaximum else { return }
        if imageView.image != nil {
            // Also debounce custom edge drags, which do not set inLiveResize.
            // Keep scaling the current bitmap until pointer movement settles.
            let work = DispatchWorkItem { [weak self] in self?.decode(maximum: target) }
            resizeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        } else {
            decode(maximum: target)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    private func decode(maximum: Int) {
        guard let source else { return }
        imageView.image = source.decode(maximum: maximum)
        decodedMaximum = maximum
        needsDisplay = true
    }

    func show(image: NSImage, caption text: String) {
        clear()
        imageView.image = image
        caption.stringValue = text

        // Natural pixel size (not the point size, which is DPI-adjusted).
        let rep = image.representations.first
        let pixelSize = NSSize(width: CGFloat(rep?.pixelsWide ?? Int(image.size.width)),
                               height: CGFloat(rep?.pixelsHigh ?? Int(image.size.height)))
        imagePixelSize = pixelSize
        needsLayout = true
    }

    /// Release the decoded bitmap as soon as the preview is no longer visible.
    /// The document can decode/reload it again if its tab is revisited.
    func clear() {
        resizeWork?.cancel()
        resizeWork = nil
        source = nil
        decodedMaximum = 0
        imageView.image = nil
        caption.stringValue = ""
        imagePixelSize = .zero
        imageView.frame = .zero
        needsDisplay = true
    }

    var decodedPixelsForTesting: Int {
        guard let frame = imageView.image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return 0 }
        return frame.width * frame.height
    }

    var hasImageForTesting: Bool { imageView.image != nil }
    var imageFrameForTesting: NSRect { imageView.frame }

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

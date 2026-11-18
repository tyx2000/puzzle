import AppKit

/// Fits the image at first, then lets the reader zoom and scroll it.
final class ImagePreviewView: FlatView {
    private let scrollView = NSScrollView()
    private let canvas = ImagePreviewCanvas()
    private let caption = NSTextField(labelWithString: "")
    private let zoomOutButton = NSButton()
    private let zoomButton = NSButton()
    private let zoomInButton = NSButton()
    private var manualZoom: CGFloat?
    private var zoom: CGFloat = 1
    private var fitZoom: CGFloat = 1
    private var needsCentering = true

    var imagePadding: CGFloat = 24
    private static let footerHeight: CGFloat = 28
    private static let zoomSteps: [CGFloat] = [
        0.01, 0.025, 0.05, 0.1, 0.125, 0.2, 0.25, 0.33, 0.5, 0.67, 0.8, 1,
        1.25, 1.5, 2, 2.5, 3, 4, 5, 6, 8
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        fillColor = Theme.editorBackground

        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = canvas
        addSubview(scrollView)

        caption.font = Theme.uiFont(10.5)
        caption.textColor = Theme.dimText
        caption.lineBreakMode = .byTruncatingMiddle
        addSubview(caption)

        configure(zoomOutButton, label: "Zoom out", action: #selector(zoomOut))
        zoomOutButton.image = Theme.symbol("minus.magnifyingglass",
            accessibilityDescription: "Zoom out", pointSize: 11, weight: .medium)
        configure(zoomInButton, label: "Zoom in", action: #selector(zoomIn))
        zoomInButton.image = Theme.symbol("plus.magnifyingglass",
            accessibilityDescription: "Zoom in", pointSize: 11, weight: .medium)
        configure(zoomButton, label: "Zoom to fit", action: #selector(zoomToFit))
        updateControls()
    }
    required init?(coder: NSCoder) { fatalError() }

    // Child frames are local to this viewport. An image's intrinsic dimensions
    // must never feed Auto Layout's window minimum-size calculation.
    private var imagePixelSize = NSSize.zero

    private var source: PreviewImageSource?
    private var decodedMaximum = 0
    private var resizeWork: DispatchWorkItem?

    private func configure(_ button: NSButton, label: String, action: Selector) {
        button.bezelStyle = .inline
        button.isBordered = false
        button.contentTintColor = Theme.dimText
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.target = self
        button.action = action
        addSubview(button)
    }

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
        let clip = scrollView.contentView
        let oldFrame = canvas.imageFrame
        let oldViewport = clip.bounds
        let focus = needsCentering || oldFrame.isEmpty ? NSPoint(x: 0.5, y: 0.5)
            : NSPoint(x: (oldViewport.midX - oldFrame.minX) / oldFrame.width,
                      y: (oldViewport.midY - oldFrame.minY) / oldFrame.height)
        let controlsLeft = max(4, bounds.width - 116)
        zoomOutButton.frame = NSRect(x: controlsLeft, y: 3, width: 26, height: 22)
        zoomButton.frame = NSRect(x: controlsLeft + 26, y: 3, width: 56, height: 22)
        zoomInButton.frame = NSRect(x: controlsLeft + 82, y: 3, width: 26, height: 22)
        caption.frame = NSRect(x: 12, y: 5, width: max(0, controlsLeft - 20), height: 18)
        scrollView.frame = NSRect(x: 0, y: Self.footerHeight, width: bounds.width,
                                  height: max(0, bounds.height - Self.footerHeight))
        let viewport = scrollView.contentSize
        guard hasPicture, viewport.width > 0, viewport.height > 0 else { return }
        // Keep the margins in ordinary panes and leave room for the picture
        // even when an SVG comparison column is very narrow.
        let padding = min(imagePadding, min(viewport.width, viewport.height) / 4)
        fitZoom = min(1, (viewport.width - 2 * padding) / imagePixelSize.width,
                      (viewport.height - 2 * padding) / imagePixelSize.height)
        zoom = manualZoom ?? fitZoom
        let size = NSSize(width: imagePixelSize.width * zoom, height: imagePixelSize.height * zoom)
        let extent = NSSize(width: max(viewport.width, ceil(size.width + 2 * padding)),
                            height: max(viewport.height, ceil(size.height + 2 * padding)))
        let frame = NSRect(x: (extent.width - size.width) / 2,
                           y: (extent.height - size.height) / 2,
                           width: size.width, height: size.height)
        if extent != canvas.frame.size || frame != oldFrame || needsCentering {
            canvas.setFrameSize(extent)
            canvas.imageFrame = frame
            let origin = NSPoint(x: frame.minX + focus.x * size.width - viewport.width / 2,
                                 y: frame.minY + focus.y * size.height - viewport.height / 2)
            clip.scroll(to: clip.constrainBoundsRect(
                NSRect(origin: origin, size: clip.bounds.size)).origin)
            scrollView.reflectScrolledClipView(clip)
        }
        needsCentering = false
        updateControls()
        guard source != nil, size.width > 0, size.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let pixels = min(4096, max(size.width, size.height) * scale)
        let target = Int(ceil(pixels / 64)) * 64
        resizeWork?.cancel()
        resizeWork = nil
        guard target != decodedMaximum else { return }
        if canvas.image != nil {
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
        canvas.image = source.decode(maximum: maximum)
        decodedMaximum = maximum
    }

    func show(image: NSImage, caption text: String) {
        clear()
        // Natural pixel size, independent of DPI metadata.
        let rep = image.representations.first
        let size = NSSize(width: rep.map { CGFloat($0.pixelsWide) } ?? image.size.width,
                          height: rep.map { CGFloat($0.pixelsHigh) } ?? image.size.height)
        setImage(image, size: size, caption: text)
    }

    /// An SVG can rerender while its source is edited. Keep its current zoom.
    func updateVectorImage(_ image: NSImage?, caption text: String) {
        setImage(image, size: image?.size ?? .zero, caption: text)
    }

    private func setImage(_ image: NSImage?, size: NSSize, caption text: String) {
        canvas.image = image
        caption.stringValue = text
        imagePixelSize = size
        updateControls()
        needsLayout = true
    }

    private var hasPicture: Bool { imagePixelSize.width > 0 && imagePixelSize.height > 0 }
    private var minimumZoom: CGFloat { min(Self.zoomSteps[0], fitZoom / 2) }

    @objc private func zoomOut() {
        let next = Self.zoomSteps.last { $0 < zoom / 1.04 } ?? minimumZoom
        setZoom(next)
    }

    @objc private func zoomIn() {
        let next = Self.zoomSteps.first { $0 > zoom * 1.04 } ?? Self.zoomSteps.last!
        setZoom(next)
    }

    @objc private func zoomToFit() { setZoom(nil) }

    private func setZoom(_ scale: CGFloat?) {
        guard hasPicture else { return }
        manualZoom = scale
        if scale == nil { needsCentering = true }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func updateControls() {
        let percentage = zoom * 100
        let title = percentage < 1 ? String(format: "%.2g%%", percentage)
            : "\(Int(percentage.rounded()))%"
        let visibleTitle = hasPicture ? title : ""
        if zoomButton.attributedTitle.string != visibleTitle {
            zoomButton.attributedTitle = NSAttributedString(string: visibleTitle, attributes: [
                .font: Theme.uiFont(10.5), .foregroundColor: Theme.foreground
            ])
            zoomButton.setAccessibilityLabel("Zoom \(title), click to fit")
        }
        zoomOutButton.isEnabled = hasPicture && zoom > minimumZoom
        zoomButton.isEnabled = hasPicture
        zoomInButton.isEnabled = hasPicture && zoom < Self.zoomSteps.last!
        for button in [zoomOutButton, zoomButton, zoomInButton] { button.isHidden = !hasPicture }
    }

    /// Release the decoded bitmap as soon as the preview is no longer visible.
    /// The document can decode/reload it again if its tab is revisited.
    func clear() {
        resizeWork?.cancel()
        resizeWork = nil
        source = nil
        decodedMaximum = 0
        canvas.image = nil
        canvas.imageFrame = .zero
        caption.stringValue = ""
        imagePixelSize = .zero
        manualZoom = nil
        zoom = 1
        fitZoom = 1
        needsCentering = true
        updateControls()
        needsLayout = true
    }

    var decodedPixelsForTesting: Int {
        guard let frame = canvas.image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return 0 }
        return frame.width * frame.height
    }

    var hasImageForTesting: Bool { canvas.image != nil }
    var imageFrameForTesting: NSRect { canvas.imageFrame }

    func refreshFonts() {
        caption.font = Theme.uiFont(10.5)
        zoomOutButton.contentTintColor = Theme.dimText
        zoomInButton.contentTintColor = Theme.dimText
        zoomButton.title = ""
        updateControls()
        fillColor = Theme.editorBackground
    }
}

private final class ImagePreviewCanvas: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var imageFrame = NSRect.zero { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let painted = dirtyRect.intersection(visibleRect).intersection(imageFrame)
        guard !painted.isEmpty else { return }
        let square: CGFloat = 8
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: painted).addClip()
        NSColor(white: 0.22, alpha: 1).setFill()
        painted.fill()
        NSColor(white: 0.27, alpha: 1).setFill()
        let firstRow = Int(floor((painted.minY - imageFrame.minY) / square))
        let lastRow = Int(ceil((painted.maxY - imageFrame.minY) / square))
        let firstColumn = Int(floor((painted.minX - imageFrame.minX) / square))
        let lastColumn = Int(ceil((painted.maxX - imageFrame.minX) / square))
        for row in firstRow..<lastRow {
            let start = firstColumn + (row + firstColumn) % 2
            for column in stride(from: start, to: lastColumn, by: 2) {
                NSRect(x: imageFrame.minX + CGFloat(column) * square,
                       y: imageFrame.minY + CGFloat(row) * square,
                       width: square, height: square).fill()
            }
        }
        image.draw(in: imageFrame)
        NSGraphicsContext.restoreGraphicsState()
    }
}

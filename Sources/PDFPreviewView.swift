import AppKit
import PDFKit

/// Shows a PDF: page thumbnails on the left, the pages on the right.
///
/// PDFKit does the rendering. Writing a PDF renderer would mean a font engine, a
/// PostScript-derived graphics model and a decade of malformed files, and the
/// system already ships one that the app links dynamically — so this file is the
/// chrome around it: the editor's own header, thumbnails, page stepping, zoom,
/// and remembering where the reader had got to.
///
/// Like media and books, the file is never read into a buffer: `PDFDocument`
/// maps it and renders the pages that are on screen.
final class PDFPreviewView: FlatView {
    private let header = FlatView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let pageLabel = NSTextField(labelWithString: "")
    private let thumbnailsButton = NSButton()
    private let zoomOutButton = NSButton()
    /// The zoom as a percentage; clicking it goes back to fitting the page.
    private let zoomButton = NSButton()
    private let zoomInButton = NSButton()
    private let previousButton = NSButton()
    private let nextButton = NSButton()

    private let thumbnails = PDFThumbnailView()
    private var thumbnailWidth: NSLayoutConstraint!

    private let pdfView = PDFView()
    /// Shown instead of the pages when the file is readable but its contents
    /// are not — an encrypted PDF is the common case.
    private let noticeLabel = NSTextField(labelWithString: "")

    private(set) var loadedURL: URL?
    private var showsThumbnails = true
    private var observers: [NSObjectProtocol] = []
    /// The zoom the header shows, so a scroll that leaves it alone costs nothing.
    private var shownZoom: CGFloat = 0

    private static let positionKey = "PuzzlePDFPages"
    private static let zoomKey = "PuzzlePDFZoom"
    private static let thumbnailColumnWidth: CGFloat = 150

    /// Where zooming in and out stops, as in a browser: round numbers a reader
    /// can come back to, rather than a factor applied again and again. The
    /// ends are wide enough for a poster fitted into a narrow pane.
    static let zoomSteps: [CGFloat] = [0.1, 0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1,
                                       1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5, 6, 8]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        fillColor = Theme.editorBackground

        header.fillColor = Theme.barBackground
        header.bottomBorder = true
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        titleLabel.font = Theme.uiFont(11.5)
        titleLabel.textColor = Theme.foreground
        titleLabel.lineBreakMode = .byTruncatingMiddle
        header.addSubview(titleLabel)

        pageLabel.font = Theme.uiFont(10.5)
        pageLabel.textColor = Theme.dimText
        pageLabel.alignment = .right
        header.addSubview(pageLabel)

        configure(thumbnailsButton, symbol: "sidebar.left", label: "Page thumbnails",
                  action: #selector(toggleThumbnails))
        configure(zoomOutButton, symbol: "minus.magnifyingglass", label: "Zoom out (⌘−)",
                  action: #selector(zoomOut))
        configure(zoomInButton, symbol: "plus.magnifyingglass", label: "Zoom in (⌘=)",
                  action: #selector(zoomIn))
        configure(previousButton, symbol: "chevron.left", label: "Previous page",
                  action: #selector(previousPage))
        configure(nextButton, symbol: "chevron.right", label: "Next page",
                  action: #selector(nextPage))
        zoomButton.bezelStyle = .inline
        zoomButton.isBordered = false
        zoomButton.toolTip = "Zoom to fit (⌘0)"
        zoomButton.setAccessibilityLabel("Zoom to fit")
        zoomButton.target = self
        zoomButton.action = #selector(zoomToFit)
        header.addSubview(zoomButton)

        pdfView.autoScales = true
        pdfView.minScaleFactor = Self.zoomSteps.first!
        pdfView.maxScaleFactor = Self.zoomSteps.last!
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = Theme.editorBackground
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pdfView)

        thumbnails.thumbnailSize = NSSize(width: 108, height: 140)
        thumbnails.backgroundColor = Theme.panelBackground
        thumbnails.translatesAutoresizingMaskIntoConstraints = false

        // PDFThumbnailView owns its scrolling; an outer scroll view would
        // leave its unconstrained document view at zero size.
        thumbnails.maximumNumberOfColumns = 1
        thumbnails.allowsDragging = false
        addSubview(thumbnails)

        noticeLabel.font = Theme.uiFont(12)
        noticeLabel.textColor = Theme.dimText
        noticeLabel.alignment = .center
        noticeLabel.isHidden = true
        noticeLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(noticeLabel)

        thumbnailWidth = thumbnails.widthAnchor.constraint(
            equalToConstant: Self.thumbnailColumnWidth)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 30),

            thumbnails.topAnchor.constraint(equalTo: header.bottomAnchor),
            thumbnails.leadingAnchor.constraint(equalTo: leadingAnchor),
            thumbnails.bottomAnchor.constraint(equalTo: bottomAnchor),
            thumbnailWidth,

            pdfView.topAnchor.constraint(equalTo: header.bottomAnchor),
            pdfView.leadingAnchor.constraint(equalTo: thumbnails.trailingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: bottomAnchor),

            noticeLabel.centerXAnchor.constraint(equalTo: pdfView.centerXAnchor),
            noticeLabel.centerYAnchor.constraint(equalTo: pdfView.centerYAnchor),
            noticeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor,
                                                 constant: 24),
            noticeLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor,
                                                  constant: -24),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func configure(_ button: NSButton, symbol: String, label: String,
                           action: Selector) {
        button.image = Theme.symbol(symbol, accessibilityDescription: label,
                                    pointSize: 11, weight: .medium)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.bezelStyle = .inline
        button.isBordered = false
        button.contentTintColor = Theme.dimText
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.target = self
        button.action = action
        header.addSubview(button)
    }

    override func layout() {
        super.layout()
        let size = NSSize(width: 28, height: 22)
        let y = floor((header.bounds.height - size.height) / 2)
        thumbnailsButton.frame = NSRect(x: 6, y: y, width: size.width, height: size.height)
        nextButton.frame = NSRect(x: header.bounds.width - size.width - 6, y: y,
                                  width: size.width, height: size.height)
        previousButton.frame = NSRect(x: nextButton.frame.minX - size.width, y: y,
                                      width: size.width, height: size.height)
        let left = thumbnailsButton.frame.maxX + 8
        let right = previousButton.frame.minX - 8

        // As wide as the last page's number, so the zoom beside it holds still
        // while the pages turn.
        let pageCount = pdfView.document?.pageCount ?? 0
        let widest = ("\(pageCount) / \(pageCount)" as NSString)
            .size(withAttributes: [.font: pageLabel.font ?? Theme.uiFont(10.5)]).width
        let pageWidth = ceil(widest) + 6
        pageLabel.frame = pageLabel.centeredFrame(x: max(left, right - pageWidth),
                                                  width: pageWidth, in: header)

        let zoomWidth: CGFloat = 40
        zoomInButton.frame = NSRect(x: pageLabel.frame.minX - 12 - size.width, y: y,
                                    width: size.width, height: size.height)
        zoomButton.frame = NSRect(x: zoomInButton.frame.minX - zoomWidth, y: y,
                                  width: zoomWidth, height: size.height)
        zoomOutButton.frame = NSRect(x: zoomButton.frame.minX - size.width, y: y,
                                     width: size.width, height: size.height)
        // A pane too narrow for the zoom still has the keys and the trackpad.
        let zoomFits = zoomOutButton.frame.minX >= left
        for button in [zoomOutButton, zoomButton, zoomInButton] { button.isHidden = !zoomFits }

        let titleRight = zoomFits ? zoomOutButton.frame.minX - 8 : pageLabel.frame.minX - 8
        titleLabel.frame = titleLabel.centeredFrame(x: left, width: max(0, titleRight - left),
                                                    in: header)
    }

    // MARK: - Loading

    /// Open a PDF, showing a readable notice for invalid or locked documents.
    @discardableResult
    func show(url: URL, caption: String) -> Bool {
        if loadedURL == url, pdfView.document != nil { return true }
        clear()
        loadedURL = url
        titleLabel.stringValue = caption
        titleLabel.toolTip = url.path
        guard let document = PDFDocument(url: url), document.pageCount > 0 || document.isLocked else {
            showNotice("This PDF could not be opened. It may be damaged or contain no pages.")
            return false
        }

        // An encrypted PDF parses but renders nothing. Say why rather than
        // showing an empty pane with working page buttons.
        if document.isLocked {
            showNotice("This PDF is password-protected. Open an unlocked copy to read it here.")
            return true
        }

        noticeLabel.isHidden = true
        pdfView.isHidden = false
        thumbnailsButton.isEnabled = true
        thumbnailWidth.constant = showsThumbnails ? Self.thumbnailColumnWidth : 0
        thumbnails.isHidden = !showsThumbnails
        pdfView.document = document
        thumbnails.pdfView = pdfView

        // The zoom the reader left it at, set before the page is gone to so the
        // page lands at the top at that size.
        if let zoom = Self.savedZoom(for: url) {
            pdfView.autoScales = false
            pdfView.scaleFactor = zoom
        } else {
            pdfView.autoScales = true
        }
        // PDFKit leaves a pinch free to 100x whatever its own limits say.
        pagesScrollView?.minMagnification = Self.zoomSteps.first!
        pagesScrollView?.maxMagnification = Self.zoomSteps.last!
        let savedIndex = min(max(0, Self.savedPage(for: url)), document.pageCount - 1)
        if let page = document.page(at: savedIndex) {
            pdfView.go(to: page)
        }
        observeChanges()
        updatePageLabel()
        updateZoom()
        needsLayout = true
        return true
    }

    private func showNotice(_ message: String) {
        noticeLabel.stringValue = message
        noticeLabel.maximumNumberOfLines = 0
        noticeLabel.lineBreakMode = .byWordWrapping
        noticeLabel.isHidden = false
        pdfView.isHidden = true
        thumbnails.isHidden = true
        thumbnailWidth.constant = 0
        thumbnailsButton.isEnabled = false
        previousButton.isEnabled = false
        nextButton.isEnabled = false
        updateZoom()
    }

    /// Release the rendered pages. PDFKit caches page bitmaps, and a document
    /// left loaded in a tab nobody is looking at keeps all of them.
    func clear() {
        rememberPage()
        stopObserving()
        thumbnails.pdfView = nil
        pdfView.document = nil
        loadedURL = nil
        titleLabel.stringValue = ""
        titleLabel.toolTip = nil
        pageLabel.stringValue = ""
        noticeLabel.isHidden = true
        updateZoom()
    }

    private func observeChanges() {
        stopObserving()
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            self?.updatePageLabel()
            self?.rememberPage()
        })
        observers.append(center.addObserver(
            forName: .PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self] _ in
            self?.updateZoom()
            self?.rememberZoom()
        })
        // A pinch on the trackpad is the magnification of PDFKit's own scroll
        // view, and PDFKit reports it as no scale change at all. The clip
        // view's bounds move with it, so the header follows the fingers, and
        // the zoom is kept once they lift.
        guard let scroll = pagesScrollView else { return }
        observers.append(center.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView,
            queue: .main) { [weak self] _ in
            guard let self, abs(self.pdfView.scaleFactor - self.shownZoom) > 0.0005 else { return }
            self.updateZoom()
        })
        observers.append(center.addObserver(
            forName: NSScrollView.didEndLiveMagnifyNotification, object: scroll,
            queue: .main) { [weak self] _ in
            self?.updateZoom()
            self?.rememberZoom()
        })
    }

    private func stopObserving() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    /// The scroll view PDFKit puts the pages in. Not API, so it is looked for
    /// rather than assumed; without it a pinch still zooms, and only the
    /// header lags until the next step.
    private var pagesScrollView: NSScrollView? {
        pdfView.subviews.lazy.compactMap { $0 as? NSScrollView }.first
    }

    private func updatePageLabel() {
        guard let document = pdfView.document else {
            pageLabel.stringValue = ""
            return
        }
        let index = currentPageIndex
        pageLabel.stringValue = "\(index + 1) / \(document.pageCount)"
        previousButton.isEnabled = index > 0
        nextButton.isEnabled = index + 1 < document.pageCount
    }

    private var currentPageIndex: Int {
        guard let document = pdfView.document, let page = pdfView.currentPage else { return 0 }
        return max(0, document.index(for: page))
    }

    // MARK: - Reading position

    private func rememberPage() {
        guard let loadedURL, pdfView.document != nil else { return }
        var pages = UserDefaults.standard
            .dictionary(forKey: Self.positionKey) as? [String: Int] ?? [:]
        pages[loadedURL.path] = currentPageIndex
        if pages.count > 200 { pages.removeValue(forKey: pages.keys.first!) }
        UserDefaults.standard.set(pages, forKey: Self.positionKey)
    }

    static func savedPage(for url: URL) -> Int {
        (UserDefaults.standard.dictionary(forKey: positionKey) as? [String: Int])?[url.path] ?? 0
    }

    /// Only a zoom the reader chose is kept: a page fitted to the pane has no
    /// entry, and fits whatever pane it is next opened in.
    private func rememberZoom() {
        guard let loadedURL, pdfView.document != nil else { return }
        var zooms = UserDefaults.standard
            .dictionary(forKey: Self.zoomKey) as? [String: Double] ?? [:]
        let zoom = pdfView.autoScales ? nil : Double(pdfView.scaleFactor)
        // Fitting follows every resize of the pane; nothing has changed.
        guard zooms[loadedURL.path] != zoom else { return }
        zooms[loadedURL.path] = zoom
        if zooms.count > 200 { zooms.removeValue(forKey: zooms.keys.first!) }
        UserDefaults.standard.set(zooms, forKey: Self.zoomKey)
    }

    static func savedZoom(for url: URL) -> CGFloat? {
        guard let zoom = (UserDefaults.standard.dictionary(forKey: zoomKey)
                            as? [String: Double])?[url.path] else { return nil }
        return min(max(CGFloat(zoom), zoomSteps.first!), zoomSteps.last!)
    }

    // MARK: - Zoom

    /// Whether there are pages to zoom; the menu's zoom commands ask.
    var canZoom: Bool { pdfView.document != nil && !pdfView.isHidden }

    /// A step passes over a round number only just beside the fitted size —
    /// 66% to 67% looks like a key that did nothing.
    private static let leastStep: CGFloat = 1.05

    @objc func zoomIn() {
        zoom(to: Self.zoomSteps.first { $0 > pdfView.scaleFactor * Self.leastStep }
                 ?? Self.zoomSteps.last!)
    }

    @objc func zoomOut() {
        zoom(to: Self.zoomSteps.last { $0 < pdfView.scaleFactor / Self.leastStep }
                 ?? Self.zoomSteps.first!)
    }

    /// Back to the page fitted to the pane, following the pane as it resizes.
    @objc func zoomToFit() {
        guard canZoom else { return }
        pdfView.autoScales = true
        updateZoom()
        rememberZoom()
    }

    private func zoom(to scale: CGFloat?) {
        guard canZoom, let scale else { return }
        pdfView.autoScales = false
        pdfView.scaleFactor = scale
        // A step that lands on the fitted size changes nothing PDFKit reports.
        updateZoom()
        rememberZoom()
    }

    private func updateZoom() {
        let zoomable = canZoom
        let scale = pdfView.scaleFactor
        shownZoom = zoomable ? scale : 0
        setZoomTitle(zoomable ? "\(Int((scale * 100).rounded()))%" : "")
        zoomButton.isEnabled = zoomable
        zoomOutButton.isEnabled = zoomable && scale > Self.zoomSteps.first! + 0.005
        zoomInButton.isEnabled = zoomable && scale < Self.zoomSteps.last! - 0.005
    }

    private func setZoomTitle(_ title: String) {
        zoomButton.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: Theme.uiFont(10.5), .foregroundColor: Theme.dimText,
        ])
    }

    // MARK: - Actions

    @objc private func previousPage() { pdfView.goToPreviousPage(nil) }
    @objc private func nextPage() { pdfView.goToNextPage(nil) }

    var thumbnailsVisible: Bool {
        get { showsThumbnails }
        set {
            showsThumbnails = newValue
            thumbnailWidth.constant = showsThumbnails ? Self.thumbnailColumnWidth : 0
            thumbnails.isHidden = !showsThumbnails || pdfView.isHidden
            needsLayout = true
        }
    }

    @objc private func toggleThumbnails() { thumbnailsVisible.toggle() }

    // MARK: - Appearance

    func refreshFonts() {
        fillColor = Theme.editorBackground
        header.fillColor = Theme.barBackground
        titleLabel.font = Theme.uiFont(11.5)
        titleLabel.textColor = Theme.foreground
        pageLabel.font = Theme.uiFont(10.5)
        pageLabel.textColor = Theme.dimText
        for button in [thumbnailsButton, zoomOutButton, zoomInButton, previousButton, nextButton] {
            button.contentTintColor = Theme.dimText
        }
        updateZoom()
        noticeLabel.font = Theme.uiFont(12)
        noticeLabel.textColor = Theme.dimText
        pdfView.backgroundColor = Theme.editorBackground
        thumbnails.backgroundColor = Theme.panelBackground
        needsLayout = true
        needsDisplay = true
    }

    // MARK: - Regression-test surface

    var pageCountForTesting: Int { pdfView.document?.pageCount ?? 0 }
    var pageIndexForTesting: Int { currentPageIndex }
    var pageLabelForTesting: String { pageLabel.stringValue }
    var noticeIsVisibleForTesting: Bool { !noticeLabel.isHidden }
    var showsThumbnailsForTesting: Bool { !thumbnails.isHidden }
    var thumbnailSizeForTesting: NSSize { thumbnails.bounds.size }
    func toggleThumbnailsForTesting() { toggleThumbnails() }
    func goToNextPageForTesting() { nextPage() }
    var zoomForTesting: CGFloat { pdfView.scaleFactor }
    var fitsPageForTesting: Bool { pdfView.autoScales }
    var zoomLabelForTesting: String { zoomButton.title }
    var headerForTesting: NSView { header }
    /// The page number and the arrow beside it, for checking that they line up.
    var pageLabelFrameForTesting: NSRect { pageLabel.frame }
    var previousButtonFrameForTesting: NSRect { previousButton.frame }
    var zoomControlFramesForTesting: [NSRect] {
        [zoomOutButton, zoomButton, zoomInButton].map(\.frame)
    }
    /// What a pinch does: the magnification of PDFKit's scroll view, with the
    /// live-magnify notifications a trackpad gesture brackets it with.
    func pinchForTesting(by factor: CGFloat) {
        guard let scroll = pagesScrollView else { return }
        NotificationCenter.default.post(name: NSScrollView.willStartLiveMagnifyNotification,
                                        object: scroll)
        scroll.setMagnification(scroll.magnification * factor,
                                centeredAt: NSPoint(x: scroll.documentVisibleRect.midX,
                                                    y: scroll.documentVisibleRect.midY))
        NotificationCenter.default.post(name: NSScrollView.didEndLiveMagnifyNotification,
                                        object: scroll)
    }
}

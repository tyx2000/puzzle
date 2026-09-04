import AppKit
import PDFKit

/// Shows a PDF: page thumbnails on the left, the pages on the right.
///
/// PDFKit does the rendering. Writing a PDF renderer would mean a font engine, a
/// PostScript-derived graphics model and a decade of malformed files, and the
/// system already ships one that the app links dynamically — so this file is the
/// chrome around it: the editor's own header, thumbnails, page stepping, and
/// remembering where the reader had got to.
///
/// Like media and books, the file is never read into a buffer: `PDFDocument`
/// maps it and renders the pages that are on screen.
final class PDFPreviewView: FlatView {
    private let header = FlatView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let pageLabel = NSTextField(labelWithString: "")
    private let thumbnailsButton = NSButton()
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
    private var pageObserver: NSObjectProtocol?

    private static let positionKey = "PuzzlePDFPages"
    private static let thumbnailColumnWidth: CGFloat = 150

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
        configure(previousButton, symbol: "chevron.left", label: "Previous page",
                  action: #selector(previousPage))
        configure(nextButton, symbol: "chevron.right", label: "Next page",
                  action: #selector(nextPage))

        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = Theme.editorBackground
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pdfView)

        thumbnails.pdfView = pdfView
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
        if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
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
        let pageWidth: CGFloat = 86
        titleLabel.frame = NSRect(x: left, y: y,
                                  width: max(0, right - left - pageWidth - 8), height: size.height)
        pageLabel.frame = NSRect(x: max(left, right - pageWidth), y: y,
                                 width: pageWidth, height: size.height)
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

        let savedIndex = min(max(0, Self.savedPage(for: url)), document.pageCount - 1)
        if let page = document.page(at: savedIndex) {
            pdfView.go(to: page)
        }
        observePageChanges()
        updatePageLabel()
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
    }

    /// Release the rendered pages. PDFKit caches page bitmaps, and a document
    /// left loaded in a tab nobody is looking at keeps all of them.
    func clear() {
        rememberPage()
        if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
        pageObserver = nil
        pdfView.document = nil
        loadedURL = nil
        titleLabel.stringValue = ""
        titleLabel.toolTip = nil
        pageLabel.stringValue = ""
        noticeLabel.isHidden = true
    }

    private func observePageChanges() {
        if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
        pageObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            self?.updatePageLabel()
            self?.rememberPage()
        }
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

    // MARK: - Actions

    @objc private func previousPage() { pdfView.goToPreviousPage(nil) }
    @objc private func nextPage() { pdfView.goToNextPage(nil) }

    @objc private func toggleThumbnails() {
        showsThumbnails.toggle()
        thumbnailWidth.constant = showsThumbnails ? Self.thumbnailColumnWidth : 0
        thumbnails.isHidden = !showsThumbnails || pdfView.isHidden
        needsLayout = true
    }

    // MARK: - Appearance

    func refreshFonts() {
        fillColor = Theme.editorBackground
        header.fillColor = Theme.barBackground
        titleLabel.font = Theme.uiFont(11.5)
        titleLabel.textColor = Theme.foreground
        pageLabel.font = Theme.uiFont(10.5)
        pageLabel.textColor = Theme.dimText
        for button in [thumbnailsButton, previousButton, nextButton] {
            button.contentTintColor = Theme.dimText
        }
        noticeLabel.font = Theme.uiFont(12)
        noticeLabel.textColor = Theme.dimText
        pdfView.backgroundColor = Theme.editorBackground
        thumbnails.backgroundColor = Theme.panelBackground
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
}

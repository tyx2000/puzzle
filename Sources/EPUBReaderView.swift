import AppKit

/// Reads an EPUB: contents on the left, the current chapter on the right.
///
/// Chapters are rendered one at a time and thrown away when the next one is
/// asked for. A book is hundreds of documents; laying all of them out at once
/// would cost more than every other buffer in the editor put together, and
/// nobody reads two chapters at the same time.
final class EPUBReaderView: FlatView, NSTableViewDataSource, NSTableViewDelegate,
                            NSTextViewDelegate {
    private let header = FlatView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let positionLabel = NSTextField(labelWithString: "")
    private let contentsButton = NSButton()
    private let previousButton = NSButton()
    private let nextButton = NSButton()

    private let contentsScroll = NSScrollView()
    private let contentsTable = NSTableView()
    private var contentsWidth: NSLayoutConstraint!

    private let textScroll = NSScrollView()
    private let textView = NSTextView()

    private var book: EPUBBook?
    private var bookURL: URL?
    private var chapterIndex = 0
    /// Offsets of the current chapter's anchors, for `#fragment` links.
    private var anchors: [String: Int] = [:]
    private var showsContents = true

    /// Where the reader was in each book, so reopening a tab does not start the
    /// book again. Keyed by path: a book is identified by where it lives.
    private static let positionKey = "PuzzleEPUBPositions"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        fillColor = Theme.editorBackground

        header.fillColor = Theme.barBackground
        header.bottomBorder = true
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        titleLabel.font = Theme.uiFont(11.5)
        titleLabel.textColor = Theme.foreground
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titleLabel)

        positionLabel.font = Theme.uiFont(10.5)
        positionLabel.textColor = Theme.dimText
        positionLabel.alignment = .right
        positionLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(positionLabel)

        configure(contentsButton, symbol: "list.bullet", label: "Contents",
                  action: #selector(toggleContents))
        configure(previousButton, symbol: "chevron.left", label: "Previous chapter",
                  action: #selector(previousChapter))
        configure(nextButton, symbol: "chevron.right", label: "Next chapter",
                  action: #selector(nextChapter))

        contentsTable.dataSource = self
        contentsTable.delegate = self
        contentsTable.headerView = nil
        contentsTable.backgroundColor = Theme.panelBackground
        contentsTable.usesAlternatingRowBackgroundColors = false
        contentsTable.selectionHighlightStyle = .regular
        contentsTable.rowHeight = max(24, Theme.treeRowHeight())
        contentsTable.intercellSpacing = NSSize(width: 0, height: 0)
        contentsTable.gridStyleMask = []
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        column.resizingMask = .autoresizingMask
        contentsTable.addTableColumn(column)
        contentsTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        contentsTable.target = self
        contentsTable.action = #selector(contentsRowClicked)

        PuzzleScroller.adopt(contentsScroll)
        contentsScroll.documentView = contentsTable
        contentsScroll.hasVerticalScroller = true
        contentsScroll.drawsBackground = true
        contentsScroll.backgroundColor = Theme.panelBackground
        contentsScroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentsScroll)

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = true
        textView.delegate = self
        textView.textContainerInset = NSSize(width: 28, height: 28)
        textView.linkTextAttributes = [
            .foregroundColor: Theme.blue,
            .cursor: NSCursor.pointingHand,
        ]
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        PuzzleScroller.adopt(textScroll)
        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.drawsBackground = true
        textScroll.backgroundColor = Theme.editorBackground
        textScroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textScroll)

        contentsWidth = contentsScroll.widthAnchor.constraint(equalToConstant: 240)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 30),

            contentsScroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            contentsScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentsScroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentsWidth,

            textScroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            textScroll.leadingAnchor.constraint(equalTo: contentsScroll.trailingAnchor),
            textScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            textScroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func configure(_ button: NSButton, symbol: String, label: String,
                           action: Selector) {
        button.image = Theme.symbol(symbol, accessibilityDescription: label,
                                    pointSize: 11, weight: .medium)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.bezelStyle = .inline
        button.isBordered = false
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(button)
    }

    override func layout() {
        super.layout()
        let size = NSSize(width: 28, height: 22)
        let y = floor((header.bounds.height - size.height) / 2)
        contentsButton.frame = NSRect(x: 6, y: y, width: size.width, height: size.height)
        nextButton.frame = NSRect(x: header.bounds.width - size.width - 6, y: y,
                                  width: size.width, height: size.height)
        previousButton.frame = NSRect(x: nextButton.frame.minX - size.width, y: y,
                                      width: size.width, height: size.height)
        let labelLeft = contentsButton.frame.maxX + 8
        let labelRight = previousButton.frame.minX - 8
        let positionWidth: CGFloat = 78
        titleLabel.frame = NSRect(x: labelLeft, y: y,
                                  width: max(0, labelRight - labelLeft - positionWidth - 8),
                                  height: size.height)
        positionLabel.frame = NSRect(x: max(labelLeft, labelRight - positionWidth), y: y,
                                     width: positionWidth, height: size.height)
        applyReadingInset()
    }

    /// Prose read across a full-width window is hard to track from the end of
    /// one line back to the start of the next, so the column stops growing and
    /// centres instead.
    private func applyReadingInset() {
        let available = textScroll.contentSize.width
        let measure = min(EPUBRenderer.readingWidth(), available - 56)
        let inset = max(28, (available - measure) / 2)
        guard abs(textView.textContainerInset.width - inset) > 0.5 else { return }
        textView.textContainerInset = NSSize(width: inset, height: 28)
        textView.textContainer?.containerSize = NSSize(
            width: max(1, available - inset * 2), height: .greatestFiniteMagnitude)
    }

    // MARK: - Loading

    /// Open a book. Returns false when the file is not a readable EPUB, so the
    /// caller can fall back to reporting it as an unsupported file.
    @discardableResult
    func show(url: URL) -> Bool {
        if bookURL == url, book != nil { return true }
        guard let book = EPUBBook(url: url) else { return false }
        self.book = book
        bookURL = url
        titleLabel.stringValue = [book.title, book.author]
            .compactMap { $0 }.joined(separator: "  ·  ")
        titleLabel.toolTip = titleLabel.stringValue
        contentsTable.reloadData()
        load(chapter: Self.savedPosition(for: url), restoringScroll: true)
        return true
    }

    /// Release the rendered chapter. The book's index is a few kilobytes and is
    /// kept; the laid-out text is not.
    func clear() {
        rememberPosition()
        textView.textStorage?.setAttributedString(NSAttributedString())
        anchors = [:]
        book = nil
        bookURL = nil
        chapterIndex = 0
        contentsTable.reloadData()
    }

    private func load(chapter index: Int, restoringScroll: Bool = false,
                      anchor: String? = nil) {
        guard let book, book.chapters.indices.contains(index) else { return }
        chapterIndex = index
        let chapter = book.chapters[index]
        let rendered = book.data(at: chapter.path).map {
            EPUBRenderer.render(xhtml: $0, chapterPath: chapter.path, book: book)
        }
        anchors = rendered?.anchors ?? [:]
        let text = rendered?.text ?? NSAttributedString(
            string: "This chapter could not be read from the book.",
            attributes: [.font: EPUBRenderer.bodyFont(),
                         .foregroundColor: Theme.dimText])
        textView.textStorage?.setAttributedString(text)
        applyReadingInset()

        positionLabel.stringValue = "\(index + 1) / \(book.chapters.count)"
        previousButton.isEnabled = index > 0
        nextButton.isEnabled = index + 1 < book.chapters.count
        if let row = book.contents.lastIndex(where: { $0.chapterIndex == index }) {
            contentsTable.selectRowIndexes([row], byExtendingSelection: false)
            contentsTable.scrollRowToVisible(row)
        } else {
            contentsTable.deselectAll(nil)
        }

        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        if let anchor, let offset = anchors[anchor] {
            textView.scrollRangeToVisible(NSRange(location: offset, length: 0))
        } else if restoringScroll, let url = bookURL {
            scroll(toFraction: Self.savedScroll(for: url))
        } else {
            textView.scroll(NSPoint(x: 0, y: 0))
        }
        rememberPosition()
    }

    private func scroll(toFraction fraction: CGFloat) {
        guard fraction > 0, let documentView = textScroll.documentView else { return }
        let span = max(0, documentView.bounds.height - textScroll.contentSize.height)
        textScroll.contentView.scroll(to: NSPoint(x: 0, y: span * fraction))
        textScroll.reflectScrolledClipView(textScroll.contentView)
    }

    private var scrollFraction: CGFloat {
        guard let documentView = textScroll.documentView else { return 0 }
        let span = max(0, documentView.bounds.height - textScroll.contentSize.height)
        guard span > 0 else { return 0 }
        return min(1, max(0, textScroll.contentView.bounds.origin.y / span))
    }

    // MARK: - Reading position

    private func rememberPosition() {
        guard let bookURL else { return }
        var positions = UserDefaults.standard
            .dictionary(forKey: Self.positionKey) as? [String: [String: Double]] ?? [:]
        positions[bookURL.path] = ["chapter": Double(chapterIndex),
                                   "scroll": Double(scrollFraction)]
        // A reader that has opened a thousand books should not carry all of
        // them forever; the oldest are the least likely to be resumed.
        if positions.count > 200 { positions.removeValue(forKey: positions.keys.first!) }
        UserDefaults.standard.set(positions, forKey: Self.positionKey)
    }

    private static func stored(for url: URL) -> [String: Double]? {
        (UserDefaults.standard.dictionary(forKey: positionKey)
            as? [String: [String: Double]])?[url.path]
    }

    static func savedPosition(for url: URL) -> Int {
        Int(stored(for: url)?["chapter"] ?? 0)
    }

    static func savedScroll(for url: URL) -> CGFloat {
        CGFloat(stored(for: url)?["scroll"] ?? 0)
    }

    // MARK: - Actions

    @objc private func previousChapter() {
        guard chapterIndex > 0 else { return }
        load(chapter: chapterIndex - 1)
    }

    @objc private func nextChapter() {
        guard let book, chapterIndex + 1 < book.chapters.count else { return }
        load(chapter: chapterIndex + 1)
    }

    @objc private func toggleContents() {
        showsContents.toggle()
        contentsWidth.constant = showsContents ? 240 : 0
        contentsScroll.isHidden = !showsContents
        needsLayout = true
    }

    @objc private func contentsRowClicked() {
        guard let book else { return }
        let row = contentsTable.clickedRow >= 0 ? contentsTable.clickedRow
            : contentsTable.selectedRow
        guard book.contents.indices.contains(row) else { return }
        load(chapter: book.contents[row].chapterIndex)
    }

    // MARK: - NSTextViewDelegate

    func textView(_ textView: NSTextView, clickedOnLink link: Any,
                  at charIndex: Int) -> Bool {
        guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:))
        else { return false }
        guard url.scheme == EPUBRenderer.linkScheme else {
            // An outward link is the browser's business, not the editor's.
            return false
        }
        let path = String(url.path.dropFirst())
        if path.isEmpty {
            // A bare fragment stays inside the chapter on screen.
            if let fragment = url.fragment, let offset = anchors[fragment] {
                textView.scrollRangeToVisible(NSRange(location: offset, length: 0))
            }
            return true
        }
        guard let book, let index = book.chapters.firstIndex(where: { $0.path == path })
        else { return true }
        load(chapter: index, anchor: url.fragment)
        return true
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { book?.contents.count ?? 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard let entry = book?.contents[row] else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("EPUBContentsCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self)
            as? NSTableCellView ?? {
                let made = NSTableCellView()
                made.identifier = identifier
                let label = NSTextField(labelWithString: "")
                label.translatesAutoresizingMaskIntoConstraints = false
                label.lineBreakMode = .byTruncatingTail
                made.addSubview(label)
                made.textField = label
                NSLayoutConstraint.activate([
                    label.centerYAnchor.constraint(equalTo: made.centerYAnchor),
                    label.trailingAnchor.constraint(equalTo: made.trailingAnchor, constant: -8),
                ])
                return made
            }()
        cell.textField?.stringValue = EPUBBook.displayTitle(entry.title)
        cell.textField?.font = Theme.uiFont(entry.level == 0 ? 11.5 : 11)
        cell.textField?.textColor = entry.level == 0 ? Theme.foreground : Theme.dimText
        cell.textField?.toolTip = EPUBBook.displayTitle(entry.title)
        // Rebuilt each time because a reused cell carries the previous row's
        // indent, and the contents nest arbitrarily deep.
        cell.leadingIndentConstraint?.isActive = false
        let indent = cell.textField!.leadingAnchor.constraint(
            equalTo: cell.leadingAnchor, constant: 10 + CGFloat(entry.level) * 14)
        indent.isActive = true
        cell.leadingIndentConstraint = indent
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard contentsTable.clickedRow < 0, let book else { return }
        let row = contentsTable.selectedRow
        guard book.contents.indices.contains(row),
              book.contents[row].chapterIndex != chapterIndex else { return }
        load(chapter: book.contents[row].chapterIndex)
    }

    // MARK: - Appearance

    func refreshFonts() {
        fillColor = Theme.editorBackground
        header.fillColor = Theme.barBackground
        titleLabel.font = Theme.uiFont(11.5)
        titleLabel.textColor = Theme.foreground
        positionLabel.font = Theme.uiFont(10.5)
        positionLabel.textColor = Theme.dimText
        contentsTable.backgroundColor = Theme.panelBackground
        contentsTable.rowHeight = max(24, Theme.treeRowHeight())
        contentsScroll.backgroundColor = Theme.panelBackground
        textScroll.backgroundColor = Theme.editorBackground
        contentsTable.reloadData()
        // Fonts and colours are baked into the rendered chapter, so it has to
        // be built again rather than restyled.
        if book != nil { load(chapter: chapterIndex, restoringScroll: true) }
        needsDisplay = true
    }

    // MARK: - Regression-test surface

    var chapterCountForTesting: Int { book?.chapters.count ?? 0 }
    var chapterIndexForTesting: Int { chapterIndex }
    var contentsRowCountForTesting: Int { book?.contents.count ?? 0 }
    var chapterTextForTesting: String { textView.string }
    var titleForTesting: String { titleLabel.stringValue }
    func goToNextChapterForTesting() { nextChapter() }
    func selectContentsRowForTesting(_ row: Int) {
        guard let book, book.contents.indices.contains(row) else { return }
        load(chapter: book.contents[row].chapterIndex)
    }
}

/// The contents indent changes per row, and a reused cell would otherwise keep
/// the constraint from whichever row it was last used for.
private var indentConstraintKey: UInt8 = 0
extension NSTableCellView {
    var leadingIndentConstraint: NSLayoutConstraint? {
        get { objc_getAssociatedObject(self, &indentConstraintKey) as? NSLayoutConstraint }
        set {
            objc_setAssociatedObject(self, &indentConstraintKey, newValue,
                                     .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}

import AppKit

/// Data shown by a file-history tab. The synthetic tab URL is owned by the
/// editor, while repository/path identify the local git query for row details.
struct FileHistoryModel {
    let tabURL: URL
    let repository: URL
    let relativePath: String
    let displayName: String
    let commits: [GitService.Commit]
}

/// Four-column file commit table with a resizable unified-diff detail pane.
final class FileHistoryView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private enum Column: String, CaseIterable {
        case message, time, author, commitID

        var title: String {
            switch self {
            case .message: return "Commit"
            case .time: return "Time"
            case .author: return "Author"
            case .commitID: return "Commit ID"
            }
        }
    }

    private let table = NSTableView()
    private let tableScroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No commits found for this file.")
    private let detailContainer = FlatView()
    private let detailResizeHandle = FileHistoryResizeHandle()
    private let detailTitle = NSTextField(labelWithString: "")
    private let detailScroll = NSScrollView()
    private let detailStorage: NSTextStorage
    private let detailLayoutManager: FoldingLayoutManager
    private let detailText: PuzzleTextView
    private var detailHeight: NSLayoutConstraint!
    private var preferredDetailHeight: CGFloat?
    private var model: FileHistoryModel?
    private var expandedRow: Int?
    private var detailGeneration = 0

    override init(frame frameRect: NSRect) {
        // Use the same explicit TextKit stack as the main editor. The detail
        // keeps horizontal scrolling, but its layout and decorations now share
        // one document coordinate system instead of the convenience text
        // view's implicit, effectively unbounded setup.
        let storage = NSTextStorage()
        let layoutManager = FoldingLayoutManager()
        storage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = false
        layoutManager.addTextContainer(textContainer)
        detailStorage = storage
        detailLayoutManager = layoutManager
        detailText = PuzzleTextView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 400),
            textContainer: textContainer)

        super.init(frame: frameRect)

        table.dataSource = self
        table.delegate = self
        table.headerView = NSTableHeaderView()
        table.backgroundColor = Theme.editorBackground
        table.usesAlternatingRowBackgroundColors = false
        table.selectionHighlightStyle = .regular
        table.rowHeight = max(28, Theme.treeRowHeight())
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.target = self
        table.action = #selector(rowClicked(_:))

        for columnKind in Column.allCases {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(columnKind.rawValue))
            column.title = columnKind.title
            column.headerCell.font = Theme.uiFont(11)
            switch columnKind {
            case .message:
                column.minWidth = 220
                column.width = 460
                column.resizingMask = [.autoresizingMask, .userResizingMask]
            case .time:
                column.minWidth = 130
                column.width = 160
                column.resizingMask = .userResizingMask
            case .author:
                column.minWidth = 100
                column.width = 140
                column.resizingMask = .userResizingMask
            case .commitID:
                column.minWidth = 80
                column.width = 100
                column.resizingMask = .userResizingMask
            }
            table.addTableColumn(column)
        }

        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.drawsBackground = true
        tableScroll.backgroundColor = Theme.editorBackground
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tableScroll)

        emptyLabel.font = Theme.uiFont(12)
        emptyLabel.textColor = Theme.dimText
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        addSubview(emptyLabel)

        detailContainer.fillColor = Theme.editorBackground
        detailContainer.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.isHidden = true
        addSubview(detailContainer)

        detailResizeHandle.translatesAutoresizingMaskIntoConstraints = false
        detailResizeHandle.onDrag = { [weak self] windowPoint in
            guard let self else { return }
            let requested = self.convert(windowPoint, from: nil).y
            self.preferredDetailHeight = self.applyDetailHeight(requested)
        }
        detailContainer.addSubview(detailResizeHandle)

        detailTitle.font = Theme.uiFont(12)
        detailTitle.textColor = Theme.foreground
        detailTitle.lineBreakMode = .byTruncatingMiddle
        detailTitle.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(detailTitle)

        detailText.isEditable = false
        detailText.isSelectable = true
        detailText.isRichText = false
        detailText.font = Theme.editorFont()
        detailText.textColor = Theme.foreground
        detailText.backgroundColor = Theme.editorBackground
        detailText.textContainerInset = NSSize(width: 10, height: 10)
        detailText.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        detailText.minSize = .zero
        detailText.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                    height: CGFloat.greatestFiniteMagnitude)
        detailText.isVerticallyResizable = true
        detailText.isHorizontallyResizable = true
        detailText.autoresizingMask = [.width]
        detailText.showsCurrentLineBand = false
        detailText.insertionPointColor = Theme.cursor
        detailText.selectedTextAttributes = [.backgroundColor: Theme.selection]
        detailScroll.documentView = detailText
        detailScroll.hasVerticalScroller = true
        detailScroll.hasHorizontalScroller = true
        detailScroll.autohidesScrollers = true
        detailScroll.hasVerticalRuler = true
        detailScroll.rulersVisible = true
        detailScroll.verticalRulerView = LineNumberRulerView(textView: detailText)
        detailScroll.drawsBackground = true
        detailScroll.backgroundColor = Theme.editorBackground
        detailScroll.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(detailScroll)

        detailHeight = detailContainer.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            tableScroll.topAnchor.constraint(equalTo: topAnchor),
            tableScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            tableScroll.bottomAnchor.constraint(equalTo: detailContainer.topAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: tableScroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: tableScroll.centerYAnchor),

            detailContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            detailContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            detailContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            detailHeight,

            detailResizeHandle.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            detailResizeHandle.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            detailResizeHandle.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            detailResizeHandle.heightAnchor.constraint(equalToConstant: 8),

            detailTitle.topAnchor.constraint(equalTo: detailResizeHandle.bottomAnchor, constant: 3),
            detailTitle.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant: 12),
            detailTitle.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor, constant: -12),
            detailTitle.heightAnchor.constraint(equalToConstant: 18),

            detailScroll.topAnchor.constraint(equalTo: detailTitle.bottomAnchor, constant: 6),
            detailScroll.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            detailScroll.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            detailScroll.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        Theme.editorBackground.setFill()
        dirtyRect.fill()
    }

    override func layout() {
        super.layout()
        if !detailContainer.isHidden {
            applyDetailHeight(preferredDetailHeight ?? defaultDetailHeight)
        }
    }

    private var defaultDetailHeight: CGFloat {
        max(180, floor(bounds.height * 0.38))
    }

    private var maximumDetailHeight: CGFloat {
        max(0, floor(bounds.height * 0.6))
    }

    @discardableResult
    private func applyDetailHeight(_ requested: CGFloat) -> CGFloat {
        let maximum = maximumDetailHeight
        let minimum = min(120, maximum)
        let resolved = min(maximum, max(minimum, requested))
        if detailHeight.constant != resolved { detailHeight.constant = resolved }
        return resolved
    }

    func configure(_ model: FileHistoryModel) {
        self.model = model
        detailGeneration += 1
        expandedRow = nil
        preferredDetailHeight = nil
        detailContainer.isHidden = true
        detailHeight.constant = 0
        detailTitle.stringValue = ""
        setDetailText("")
        emptyLabel.isHidden = !model.commits.isEmpty
        table.reloadData()
        table.deselectAll(nil)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        model?.commits.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard let model, model.commits.indices.contains(row),
              let tableColumn,
              let column = Column(rawValue: tableColumn.identifier.rawValue) else { return nil }
        let commit = model.commits[row]
        let id = NSUserInterfaceItemIdentifier("history-\(column.rawValue)")
        let cell = (tableView.makeView(withIdentifier: id, owner: self)
                    as? FileHistoryTableCell) ?? FileHistoryTableCell()
        cell.identifier = id
        let text: String
        switch column {
        case .message: text = commit.subject
        case .time: text = commit.absoluteDate
        case .author: text = commit.author
        case .commitID: text = commit.shortHash
        }
        cell.configure(text: text, monospaced: column == .commitID)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = FileHistoryRowView()
        // The header already owns the boundary above row zero. Drawing another
        // line there makes that edge look twice as dark.
        rowView.drawsTopBorder = row > 0
        return rowView
    }

    @objc private func rowClicked(_ sender: Any?) {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        toggleDetail(row: row)
    }

    private func toggleDetail(row: Int) {
        guard let model, model.commits.indices.contains(row) else { return }
        if expandedRow == row, !detailContainer.isHidden {
            collapseDetail()
            return
        }

        expandedRow = row
        detailGeneration += 1
        let generation = detailGeneration
        let commit = model.commits[row]
        detailTitle.stringValue = "Changes in \(commit.shortHash) — \(model.relativePath)"
        setDetailText("Loading…")
        detailContainer.isHidden = false
        applyDetailHeight(preferredDetailHeight ?? defaultDetailHeight)
        needsLayout = true

        let repository = model.repository
        let path = model.relativePath
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let diff = GitService.diff(inCommit: commit.shortHash,
                                       path: path, in: repository)
            DispatchQueue.main.async {
                guard let self, self.detailGeneration == generation,
                      self.expandedRow == row,
                      self.model?.tabURL == model.tabURL else { return }
                self.setDetailText(diff, highlightingDiff: true)
                self.detailText.scrollToBeginningOfDocument(nil)
            }
        }
    }

    private func collapseDetail() {
        guard expandedRow != nil else { return }
        detailGeneration += 1
        expandedRow = nil
        detailContainer.isHidden = true
        detailHeight.constant = 0
        setDetailText("")
    }

    // MARK: - Regression-test surface

    var columnTitlesForTesting: [String] { table.tableColumns.map(\.title) }
    var rowCountForTesting: Int { table.numberOfRows }
    var expandedRowForTesting: Int? { expandedRow }
    var detailTextForTesting: String { detailText.string }
    var detailDiffBandCountForTesting: Int { detailText.diffBands.count }
    func toggleRowForTesting(_ row: Int) { toggleDetail(row: row) }

    private func setDetailText(_ text: String, highlightingDiff: Bool = false) {
        guard let storage = detailText.textStorage else {
            detailText.string = text
            detailText.diffBands = []
            return
        }
        storage.setAttributedString(NSAttributedString(string: text))
        if highlightingDiff {
            // Exactly the same foreground colours and full-width added/removed
            // bands used by Changes diff tabs.
            detailText.diffBands = DiffHighlighter.apply(to: storage)
        } else {
            let full = NSRange(location: 0, length: storage.length)
            storage.setAttributes(Theme.textAttributes(color: Theme.foreground), range: full)
            detailText.diffBands = []
        }
        detailText.needsDisplay = true
        detailText.enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }
}

private final class FileHistoryTableCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.textColor = Theme.foreground
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        textField = label
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(text: String, monospaced: Bool) {
        label.stringValue = text
        label.font = monospaced ? Theme.editorFont() : Theme.uiFont(12)
        toolTip = text
        setAccessibilityElement(true)
        setAccessibilityLabel(text)
    }
}

private final class FileHistoryRowView: NSTableRowView {
    var drawsTopBorder = true

    override func drawBackground(in dirtyRect: NSRect) {
        Theme.editorBackground.setFill()
        bounds.fill()
        if drawsTopBorder {
            Theme.border.withAlphaComponent(0.35).setFill()
            NSRect(x: bounds.minX, y: bounds.minY,
                   width: bounds.width, height: 1).fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        Theme.activeRow.setFill()
        bounds.fill()
    }
}

/// Eight-point hit target over a one-point divider. Dragging reports window
/// coordinates so the owning history view can resolve its bottom-anchored
/// detail height without duplicating state in this presentation-only view.
private final class FileHistoryResizeHandle: NSView {
    var onDrag: ((NSPoint) -> Void)?

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        onDrag?(event.locationInWindow)
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.locationInWindow)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.border.setFill()
        NSRect(x: bounds.minX, y: floor(bounds.midY),
               width: bounds.width, height: 1).fill()
    }
}

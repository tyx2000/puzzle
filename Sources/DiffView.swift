import AppKit

/// A read-only diff, unified or side by side. Both are one table, so a long
/// diff costs only the rows on screen, and rows are drawn rather than built
/// from subviews, the same approach the Git lists take.
final class DiffView: FlatView {
    private let table = NSTableView()
    private let scroll = NSScrollView()
    /// Shown instead of the table when the diff has no hunks to draw — a
    /// binary file, or a file whose change is only its mode.
    private let note = NSTextField(labelWithString: "")
    private var diff = ""
    private(set) var mode: DiffHeaderView.Mode = .unified
    private var rows: [DiffRows.Row] = []
    /// Lines the budget left out of the model, said above the diff.
    private(set) var omittedLines = 0
    private var changeStarts: [Int] = []
    /// Unified rows only: which removed line each added line replaces.
    private var unifiedPairs: [Int: Int] = [:]
    /// The changed words of each row put on screen so far. Worked out when a
    /// row is first drawn, not when the diff is read: comparing every pair of
    /// a 50,000-line diff up front is work on the main thread for rows nobody
    /// may scroll to.
    private var wordMarks: [Int: DiffWords.Marks] = [:]
    /// Where the ↑↓ buttons currently are, so stepping continues from there.
    private var currentBlock = -1
    /// First row of that block, marked so the jump is visible even when the
    /// change was already on screen.
    private var currentRow: Int?

    static let gutterWidth: CGFloat = 44

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        fillColor = Theme.diffBackground

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        // `.automatic` insets every row by 10pt on each side.
        table.style = .plain
        table.rowSizeStyle = .custom
        table.backgroundColor = Theme.diffBackground
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.dataSource = self
        table.delegate = self

        GiftScroller.adopt(scroll)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.diffBackground
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        note.font = Theme.uiFont(12)
        note.textColor = Theme.dimText
        note.alignment = .center
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 0
        note.isHidden = true
        note.translatesAutoresizingMaskIntoConstraints = false
        addSubview(note)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            note.centerXAnchor.constraint(equalTo: centerXAnchor),
            note.centerYAnchor.constraint(equalTo: centerYAnchor),
            note.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Show a diff from the top. `keepingPosition` is for the same diff read
    /// again — a working-tree file that changed while it was open — where
    /// jumping back to the first line would lose the reader's place.
    func configure(diff: String, keepingPosition: Bool = false) {
        let offset = scroll.contentView.bounds.origin
        self.diff = diff
        rebuild()
        if keepingPosition {
            let maximum = max(0, table.bounds.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: offset.x, y: min(offset.y, maximum)))
        } else {
            // A clip view left to itself keeps its origin at the bottom, which
            // put a fresh diff on its last line with empty space above it.
            scroll.contentView.scroll(to: .zero)
        }
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func setMode(_ mode: DiffHeaderView.Mode) {
        guard mode != self.mode else { return }
        self.mode = mode
        rebuild()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func rebuild() {
        let parsed = mode == .unified ? DiffRows.unified(from: diff)
                                      : DiffRows.sideBySide(from: diff)
        rows = parsed.rows
        omittedLines = parsed.omittedLines
        changeStarts = DiffRows.changeBlockStarts(rows)
        unifiedPairs = mode == .unified ? DiffRows.unifiedPairs(rows) : [:]
        wordMarks = [:]
        currentBlock = -1
        currentRow = nil
        // Only built when there is nothing to draw: the note is one line, and
        // handing a whole 8 MiB diff to a hidden text field was work for
        // nobody, on every rebuild.
        note.stringValue = rows.isEmpty ? Self.note(for: diff) : ""
        note.isHidden = !rows.isEmpty
        scroll.isHidden = rows.isEmpty
        table.reloadData()
        table.layoutSubtreeIfNeeded()
    }

    /// How much of Git's own words the note repeats when it has nothing
    /// better to say. It is a line under a heading, not a second diff view.
    static let noteLimit = 400

    /// What to say when there are no lines to show.
    static func note(for diff: String) -> String {
        if diff.contains("Binary files") || diff.contains("GIT binary patch")
            || diff.contains("new file (binary") {
            return "Binary file — no text to compare"
        }
        if diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No changes"
        }
        if diff.contains("old mode") || diff.contains("new mode") {
            return "Only the file mode changed"
        }
        let text = diff.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count <= noteLimit ? text : String(text.prefix(noteLimit)) + "…"
    }

    var changeCount: Int { changeStarts.count }

    /// The words to mark on a row: a side-by-side row holding both lines of a
    /// pair, or a unified line and its twin, compared once and kept for both.
    private func marks(forRow row: Int) -> DiffWords.Marks {
        if let known = wordMarks[row] { return known }
        var removedRow = row, addedRow = row
        if let twin = unifiedPairs[row] {
            if rows[row].leftText != nil { addedRow = twin } else { removedRow = twin }
        }
        guard rows[row].isChange, let removed = rows[removedRow].leftText,
              let added = rows[addedRow].rightText,
              let words = DiffWords.changedWords(removed: removed, added: added) else {
            wordMarks[row] = DiffWords.Marks()
            return DiffWords.Marks()
        }
        if removedRow == addedRow {
            wordMarks[row] = DiffWords.Marks(removed: words.removed, added: words.added)
        } else {
            wordMarks[removedRow] = DiffWords.Marks(removed: words.removed)
            wordMarks[addedRow] = DiffWords.Marks(added: words.added)
        }
        return wordMarks[row] ?? DiffWords.Marks()
    }

    /// Step to the next (or previous) block of changed rows, wrapping round.
    func step(forward: Bool) {
        guard !changeStarts.isEmpty else { return }
        if forward {
            currentBlock = currentBlock + 1 >= changeStarts.count ? 0 : currentBlock + 1
        } else {
            currentBlock = currentBlock <= 0 ? changeStarts.count - 1 : currentBlock - 1
        }
        let row = changeStarts[currentBlock]
        currentRow = row
        // `scrollRowToVisible` does nothing when the row is already on screen,
        // which is why stepping looked like it was ignoring the buttons.
        // Centre it instead, and mark it so a jump inside the visible area is
        // still something you can see.
        centre(row: row)
        table.reloadData()
    }

    private func centre(row: Int) {
        guard rows.indices.contains(row) else { return }
        let rowRect = table.rect(ofRow: row)
        let visible = scroll.contentView.bounds
        let maximum = max(0, table.bounds.height - visible.height)
        let target = min(max(0, rowRect.midY - visible.height / 2), maximum)
        scroll.contentView.scroll(to: NSPoint(x: visible.origin.x, y: target))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: - Regression-test surface

    var currentRowForTesting: Int? { currentRow }
    var noteFieldIsEmptyForTesting: Bool { note.stringValue.isEmpty }
    var rowsForTesting: [DiffRows.Row] { rows }
    var noteForTesting: String? { note.isHidden ? nil : note.stringValue }
    /// Row count and scroll offset, so the table's own geometry stays checkable
    /// without a live window.
    var geometryForTesting: (rows: Int, contentHeight: CGFloat, scrollOffset: CGFloat) {
        (rows.count, table.frame.height, scroll.contentView.bounds.origin.y)
    }
    var currentBlockForTesting: Int { currentBlock }
    /// How many rows have had their changed words worked out.
    var markedRowCountForTesting: Int { wordMarks.count }
    var verticalScrollerForTesting: NSScroller? { scroll.verticalScroller }
    func cellForTesting(_ row: Int) -> DiffRowCell? {
        tableView(table, viewFor: nil, row: row) as? DiffRowCell
    }
}

extension DiffView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        Theme.diffRowHeight()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("diff-row")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? DiffRowCell)
            ?? DiffRowCell()
        cell.identifier = id
        guard rows.indices.contains(row) else { return cell }
        cell.configure(rows[row], mode: mode, isCurrent: row == currentRow,
                       marks: marks(forRow: row))
        return cell
    }
}

final class DiffRowCell: DrawnSidebarCell {
    private var row: DiffRows.Row?
    private var mode: DiffHeaderView.Mode = .unified
    private var isCurrent = false
    private var marks = DiffWords.Marks()

    func configure(_ row: DiffRows.Row, mode: DiffHeaderView.Mode, isCurrent: Bool,
                   marks: DiffWords.Marks = DiffWords.Marks()) {
        self.row = row
        self.mode = mode
        self.isCurrent = isCurrent
        self.marks = marks
        switch row.kind {
        case .hunk: exposeToAccessibility(row.header ?? "")
        case .context: exposeToAccessibility(row.leftText ?? "")
        case .change:
            let removed = row.leftText.map { "removed \($0)" } ?? ""
            let added = row.rightText.map { "added \($0)" } ?? ""
            exposeToAccessibility([removed, added].filter { !$0.isEmpty }.joined(separator: ", "))
        }
        needsDisplay = true
    }

    var modeForTesting: DiffHeaderView.Mode { mode }
    /// The text the row sets, styled as drawn: one string unified, the two
    /// sides (nil where a side is empty) side by side.
    var styledTextsForTesting: [NSAttributedString?] {
        guard let row, row.kind != .hunk else { return [] }
        let font = Theme.monoFont()
        if mode == .unified { return [unifiedText(row, font: font)] }
        return [sideText(row, onLeft: true, font: font), sideText(row, onLeft: false, font: font)]
    }

    /// A line's text in its ink, the changed words in a deeper shade of the
    /// line's own colour behind them. `offset` is where the line's own text
    /// starts in `text`, past any marker drawn before it.
    private static func styled(_ text: String, ink: NSColor, font: NSFont,
                               words: [NSRange], wordColor: NSColor,
                               offset: Int = 0) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let styled = NSMutableAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: ink, .paragraphStyle: paragraph])
        for range in words {
            let shifted = NSRange(location: range.location + offset, length: range.length)
            guard NSMaxRange(shifted) <= styled.length else { continue }
            styled.addAttribute(.backgroundColor, value: wordColor, range: shifted)
        }
        return styled
    }

    /// The unified line: its marker, a space, and the line as Git wrote it.
    private func unifiedText(_ row: DiffRows.Row, font: NSFont) -> NSAttributedString {
        let removed = row.kind == .change && row.leftText != nil
        let added = row.kind == .change && row.rightText != nil
        let sign = removed ? "-" : added ? "+" : " "
        let ink = removed ? Theme.diffRemovedText : added ? Theme.diffAddedText : Theme.foreground
        let text = (removed ? row.leftText : added ? row.rightText : row.leftText) ?? ""
        return Self.styled(sign + " " + text, ink: ink, font: font,
                           words: removed ? marks.removed : added ? marks.added : [],
                           wordColor: removed ? Theme.diffRemovedWordBackground
                                              : Theme.diffAddedWordBackground,
                           offset: 2)
    }

    /// One side of a side-by-side row; nil when that side has no line.
    private func sideText(_ row: DiffRows.Row, onLeft: Bool, font: NSFont) -> NSAttributedString? {
        guard let text = onLeft ? row.leftText : row.rightText else { return nil }
        let changed = row.kind == .change
        return Self.styled(text,
                           ink: !changed ? Theme.foreground
                               : onLeft ? Theme.diffRemovedText : Theme.diffAddedText,
                           font: font,
                           words: !changed ? [] : onLeft ? marks.removed : marks.added,
                           wordColor: onLeft ? Theme.diffRemovedWordBackground
                                             : Theme.diffAddedWordBackground)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let row else { return }
        let font = Theme.monoFont()
        let gutter = DiffView.gutterWidth

        if row.kind == .hunk {
            Theme.lineHighlight.setFill()
            bounds.fill()
            SidebarCellDrawing.text(row.header ?? "", font: font, color: Theme.blue,
                                    in: NSRect(x: 8, y: 0, width: bounds.width - 16,
                                               height: bounds.height))
            return
        }

        if mode == .unified {
            drawUnified(row, font: font, gutter: gutter)
        } else {
            drawSideBySide(row, font: font, gutter: gutter)
        }
    }

    /// Two number columns — the line as it was, and as it is — then the text.
    /// A removed line has only the first number, an added one only the second.
    private func drawUnified(_ row: DiffRows.Row, font: NSFont, gutter: CGFloat) {
        let removed = row.kind == .change && row.leftText != nil
        let added = row.kind == .change && row.rightText != nil
        if removed || added {
            (removed ? Theme.diffRemovedBackground : Theme.diffAddedBackground).setFill()
            bounds.fill()
        }
        let numbers: [(Int?, CGFloat)] = [
            (row.kind == .context || removed ? row.leftNumber : nil, 0),
            (row.kind == .context || added ? row.rightNumber : nil, gutter),
        ]
        for (number, x) in numbers {
            guard let number else { continue }
            SidebarCellDrawing.text("\(number)", font: font, color: Theme.gutter,
                                    in: NSRect(x: x, y: 0, width: gutter - 8,
                                               height: bounds.height),
                                    alignment: .right)
        }
        SidebarCellDrawing.attributedText(unifiedText(row, font: font), font: font,
                                          in: NSRect(x: gutter * 2, y: 0,
                                                     width: max(0, bounds.width - gutter * 2 - 6),
                                                     height: bounds.height))
        guard isCurrent else { return }
        Theme.accent.setFill()
        NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()
    }

    private func drawSideBySide(_ row: DiffRows.Row, font: NSFont, gutter: CGFloat) {
        let half = (bounds.width / 2).rounded()
        // Left = the file as it was, right = as it is. A missing side is left
        // empty rather than blank-filled, so the eye can see which side gained
        // or lost the line.
        drawSide(NSRect(x: 0, y: 0, width: half, height: bounds.height),
                 number: row.leftNumber, text: sideText(row, onLeft: true, font: font),
                 font: font, gutter: gutter,
                 background: row.kind == .change && row.leftText != nil
                     ? Theme.diffRemovedBackground : nil)
        drawSide(NSRect(x: half, y: 0, width: bounds.width - half, height: bounds.height),
                 number: row.rightNumber, text: sideText(row, onLeft: false, font: font),
                 font: font, gutter: gutter,
                 background: row.kind == .change && row.rightText != nil
                     ? Theme.diffAddedBackground : nil)

        Theme.border.setFill()
        NSRect(x: half, y: 0, width: 1, height: bounds.height).fill()

        // The change the ↑↓ buttons are on, marked down both columns.
        guard isCurrent else { return }
        Theme.accent.setFill()
        NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()
        NSRect(x: half + 1, y: 0, width: 3, height: bounds.height).fill()
    }

    private func drawSide(_ rect: NSRect, number: Int?, text: NSAttributedString?, font: NSFont,
                          gutter: CGFloat, background: NSColor?) {
        if let background {
            background.setFill()
            rect.fill()
        }
        if let number {
            SidebarCellDrawing.text("\(number)", font: font, color: Theme.gutter,
                                    in: NSRect(x: rect.minX, y: 0,
                                               width: gutter - 8, height: rect.height),
                                    alignment: .right)
        }
        guard let text else { return }
        SidebarCellDrawing.attributedText(text, font: font,
                                          in: NSRect(x: rect.minX + gutter, y: 0,
                                                     width: max(0, rect.width - gutter - 6),
                                                     height: rect.height))
    }
}

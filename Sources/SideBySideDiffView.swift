import AppKit

/// The side-by-side diff: old on the left, new on the right, one table so both
/// columns scroll as one. Rows are drawn rather than built from subviews, the
/// same approach the file tree and Git panel take for dense lists.
final class SideBySideDiffView: FlatView {
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var rows: [SideBySideDiff.Row] = []
    private var changeStarts: [Int] = []
    /// Where the ↑↓ buttons currently are, so stepping continues from there.
    private var currentBlock = -1
    /// First row of that block, marked so the jump is visible even when the
    /// change was already on screen.
    private var currentRow: Int?

    static let gutterWidth: CGFloat = 44

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        fillColor = Theme.editorBackground

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowSizeStyle = .custom
        table.backgroundColor = Theme.editorBackground
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.dataSource = self
        table.delegate = self

PuzzleScroller.adopt(scroll)
                scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.editorBackground
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(diff: String) {
        rows = SideBySideDiff.rows(from: diff)
        changeStarts = SideBySideDiff.changeBlockStarts(rows)
        currentBlock = -1
        currentRow = nil
        table.reloadData()
        table.layoutSubtreeIfNeeded()
        // A clip view left to itself keeps its origin at the bottom, which put
        // a fresh diff on its last line with empty space above it.
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func refreshAppearance() {
        fillColor = Theme.editorBackground
        table.backgroundColor = Theme.editorBackground
        scroll.backgroundColor = Theme.editorBackground
        table.reloadData()
    }

    var changeCount: Int { changeStarts.count }

    /// Step to the next (or previous) block of changed rows, wrapping like the
    /// unified view does.
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
    /// Row count and scroll offset, so the table's own geometry stays checkable
    /// without a live window.
    var geometryForTesting: (rows: Int, contentHeight: CGFloat, scrollOffset: CGFloat) {
        (rows.count, table.frame.height, scroll.contentView.bounds.origin.y)
    }
    var currentBlockForTesting: Int { currentBlock }
}

extension SideBySideDiffView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        Theme.lineMetrics().target
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("side-by-side-row")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? SideBySideRowCell)
            ?? SideBySideRowCell()
        cell.identifier = id
        guard rows.indices.contains(row) else { return cell }
        cell.configure(rows[row], isCurrent: row == currentRow)
        return cell
    }
}

private final class SideBySideRowCell: DrawnSidebarCell {
    private var row: SideBySideDiff.Row?
    private var isCurrent = false

    func configure(_ row: SideBySideDiff.Row, isCurrent: Bool) {
        self.row = row
        self.isCurrent = isCurrent
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

    override func draw(_ dirtyRect: NSRect) {
        guard let row else { return }
        let font = Theme.editorFont()
        let gutter = SideBySideDiffView.gutterWidth
        let half = (bounds.width / 2).rounded()

        if row.kind == .hunk {
            Theme.lineHighlight.setFill()
            bounds.fill()
            SidebarCellDrawing.text(row.header ?? "", font: font, color: Theme.blue,
                                    in: NSRect(x: 8, y: 0, width: bounds.width - 16,
                                               height: bounds.height))
            return
        }

        // Left = the file as it was, right = as it is. A missing side is left
        // empty rather than blank-filled, so the eye can see which side gained
        // or lost the line.
        drawSide(NSRect(x: 0, y: 0, width: half, height: bounds.height),
                 number: row.leftNumber, text: row.leftText, font: font, gutter: gutter,
                 background: row.kind == .change && row.leftText != nil
                     ? Theme.diffRemovedBackground : nil,
                 ink: row.kind == .change && row.leftText != nil
                     ? Theme.diffRemovedText : Theme.foreground)
        drawSide(NSRect(x: half, y: 0, width: bounds.width - half, height: bounds.height),
                 number: row.rightNumber, text: row.rightText, font: font, gutter: gutter,
                 background: row.kind == .change && row.rightText != nil
                     ? Theme.diffAddedBackground : nil,
                 ink: row.kind == .change && row.rightText != nil
                     ? Theme.diffAddedText : Theme.foreground)

        Theme.border.setFill()
        NSRect(x: half, y: 0, width: 1, height: bounds.height).fill()

        // The change the ↑↓ buttons are on, marked down both columns.
        guard isCurrent else { return }
        Theme.cursor.setFill()
        NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()
        NSRect(x: half + 1, y: 0, width: 3, height: bounds.height).fill()
    }

    private func drawSide(_ rect: NSRect, number: Int?, text: String?, font: NSFont,
                          gutter: CGFloat, background: NSColor?, ink: NSColor) {
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
        SidebarCellDrawing.text(text, font: font, color: ink,
                                in: NSRect(x: rect.minX + gutter, y: 0,
                                           width: max(0, rect.width - gutter - 6),
                                           height: rect.height))
    }
}

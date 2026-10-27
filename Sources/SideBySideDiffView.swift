import AppKit

/// The side-by-side diff: old on the left, new on the right, one table so both
/// columns scroll as one. Rows are drawn rather than built from subviews, the
/// same approach the file tree and Git panel take for dense lists.
final class SideBySideDiffView: FlatView {
    private let table = NSTableView()
    private let scroll = SideBySideScrollView()
    private let horizontalScroller = PuzzleScroller(
        frame: NSRect(x: 0, y: 0, width: 100, height: 15))
    private var horizontalScrollerHeight: NSLayoutConstraint!
    private var horizontalOffset: CGFloat = 0
    private var maximumTextWidth: CGFloat = 0
    private var textViewportWidth: CGFloat = 0
    private var measuredFont: NSFont?
    private var maximumHorizontalOffset: CGFloat {
        max(0, maximumTextWidth - textViewportWidth)
    }
    private var rows: [SideBySideDiff.Row] = []
    private var changeStarts: [Int] = []
    /// Where the ↑↓ buttons currently are, so stepping continues from there.
    private var currentBlock = -1
    /// The rows of that block, lit as the step lands — see `ChangeFlash` — so
    /// the jump is visible even when the change was already on screen.
    private var flash: (rows: Range<Int>, started: CFTimeInterval)?
    private var flashTimer: Timer?

    static let gutterWidth: CGFloat = 44

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        fillColor = Theme.editorBackground

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.autoresizingMask = [.width]
        table.headerView = nil
        table.rowSizeStyle = .custom
        table.backgroundColor = Theme.editorBackground
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.dataSource = self
        table.delegate = self

        PuzzleScroller.adopt(scroll, alongWindowEdge: true)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.editorBackground
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        // The table remains viewport-wide so gutters and the divider stay put.
        // Only the text inside the two columns follows this shared scroller.
        horizontalScroller.scrollerStyle = .legacy
        horizontalScroller.controlSize = .large
        horizontalScroller.target = self
        horizontalScroller.action = #selector(scrollHorizontally(_:))
        horizontalScroller.translatesAutoresizingMaskIntoConstraints = false
        horizontalScroller.isHidden = true
        addSubview(horizontalScroller)
        horizontalScrollerHeight = horizontalScroller.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: horizontalScroller.topAnchor),
            horizontalScroller.leadingAnchor.constraint(equalTo: leadingAnchor),
            horizontalScroller.trailingAnchor.constraint(equalTo: trailingAnchor),
            horizontalScroller.bottomAnchor.constraint(equalTo: bottomAnchor),
            horizontalScrollerHeight,
        ])
        scroll.onHorizontalScroll = { [weak self] delta in
            guard let self else { return }
            self.setHorizontalOffset(self.horizontalOffset - delta)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        if measuredFont != Theme.editorFont() { measureTextWidths() }
        updateHorizontalGeometry()
    }

    func configure(diff: String) {
        rows = SideBySideDiff.rows(from: diff)
        changeStarts = SideBySideDiff.changeBlockStarts(rows)
        currentBlock = -1
        flashTimer?.invalidate()
        flash = nil
        horizontalOffset = 0
        measureTextWidths()
        table.reloadData()
        table.layoutSubtreeIfNeeded()
        updateHorizontalGeometry()
        // A clip view left to itself keeps its origin at the bottom, which put
        // a fresh diff on its last line with empty space above it.
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func refreshAppearance() {
        fillColor = Theme.editorBackground
        table.backgroundColor = Theme.editorBackground
        scroll.backgroundColor = Theme.editorBackground
        measureTextWidths()
        updateHorizontalGeometry()
        table.reloadData()
    }

    private func measureTextWidths() {
        let font = Theme.editorFont()
        measuredFont = font
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .paragraphStyle: paragraph,
        ]
        maximumTextWidth = rows.reduce(CGFloat(0)) { maximum, row in
            max(maximum, [row.leftText, row.rightText].compactMap { text in
                text.map { ceil(($0 as NSString).size(withAttributes: attributes).width) }
            }.max() ?? 0)
        }
    }

    private func updateHorizontalGeometry() {
        // Use the narrower half when the viewport is an odd number of points.
        let width = scroll.contentView.bounds.width
        textViewportWidth = max(0, floor(width / 2) - Self.gutterWidth - 6)
        let visible = maximumHorizontalOffset > 0 && textViewportWidth > 0
        horizontalScroller.isHidden = !visible
        horizontalScroller.isEnabled = visible
        let height = visible ? PuzzleScroller.scrollerWidth(for: .large, scrollerStyle: .legacy) : 0
        if horizontalScrollerHeight.constant != height {
            horizontalScrollerHeight.constant = height
        }
        horizontalScroller.knobProportion = maximumTextWidth > 0
            ? min(1, textViewportWidth / maximumTextWidth) : 1
        setHorizontalOffset(horizontalOffset)
    }

    private func setHorizontalOffset(_ offset: CGFloat) {
        let clamped = min(max(0, offset), maximumHorizontalOffset)
        horizontalScroller.doubleValue = maximumHorizontalOffset > 0
            ? Double(clamped / maximumHorizontalOffset) : 0
        guard horizontalOffset != clamped else { return }
        horizontalOffset = clamped
        let visibleRows = table.rows(in: table.visibleRect)
        guard visibleRows.location != NSNotFound else { return }
        for row in visibleRows.location..<NSMaxRange(visibleRows) {
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? SideBySideRowCell)?
                .setHorizontalOffset(clamped)
        }
    }

    @objc private func scrollHorizontally(_ sender: NSScroller) {
        let line = Theme.editorFont().maximumAdvancement.width * 3
        switch sender.hitPart {
        case .decrementLine: setHorizontalOffset(horizontalOffset - line)
        case .incrementLine: setHorizontalOffset(horizontalOffset + line)
        case .decrementPage: setHorizontalOffset(horizontalOffset - textViewportWidth)
        case .incrementPage: setHorizontalOffset(horizontalOffset + textViewportWidth)
        default: setHorizontalOffset(CGFloat(sender.doubleValue) * maximumHorizontalOffset)
        }
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
        // `scrollRowToVisible` does nothing when the row is already on screen,
        // which is why stepping looked like it was ignoring the buttons.
        // Centre it instead, and light it so a jump inside the visible area is
        // still something you can see.
        centre(row: row)
        var end = row
        while end < rows.count, rows[end].kind == .change { end += 1 }
        flash(rows: row..<max(end, row + 1))
    }

    /// The code a scroll over the round buttons floating above it should move.
    var scrollingView: NSView { scroll }

    private func flash(rows lit: Range<Int>) {
        flashTimer?.invalidate()
        let previous = flash?.rows
        flash = (lit, CACurrentMediaTime())
        if let previous { setFlash(0, on: previous) }
        setFlash(ChangeFlash.strength(at: 0), on: lit)
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self, let flash = self.flash else {
                timer.invalidate()
                return
            }
            let elapsed = CACurrentMediaTime() - flash.started
            self.setFlash(ChangeFlash.strength(at: elapsed), on: flash.rows)
            if elapsed >= ChangeFlash.duration {
                timer.invalidate()
                self.flash = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        flashTimer = timer
    }

    private func setFlash(_ strength: CGFloat, on lit: Range<Int>) {
        for row in lit where row < table.numberOfRows {
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? SideBySideRowCell)?
                .flash = strength
        }
    }

    /// How strongly a row is lit now: a cell made while the flash runs starts
    /// where the others are.
    private func flashStrength(of row: Int) -> CGFloat {
        guard let flash, flash.rows.contains(row) else { return 0 }
        return ChangeFlash.strength(at: CACurrentMediaTime() - flash.started)
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

    var flashRowsForTesting: Range<Int>? { flash?.rows }
    /// Row count and scroll offset, so the table's own geometry stays checkable
    /// without a live window.
    var geometryForTesting: (rows: Int, contentHeight: CGFloat, scrollOffset: CGFloat) {
        (rows.count, table.frame.height, scroll.contentView.bounds.origin.y)
    }
    var currentBlockForTesting: Int { currentBlock }
    var horizontalGeometryForTesting: (offset: CGFloat, maximumOffset: CGFloat,
                                       textWidth: CGFloat, viewportWidth: CGFloat,
                                       scrollerVisible: Bool) {
        (horizontalOffset, maximumHorizontalOffset, maximumTextWidth, textViewportWidth,
         !horizontalScroller.isHidden)
    }
    func setHorizontalOffsetForTesting(_ offset: CGFloat) { setHorizontalOffset(offset) }
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
        cell.configure(rows[row], flash: flashStrength(of: row), horizontalOffset: horizontalOffset)
        return cell
    }
}

private final class SideBySideRowCell: DrawnSidebarCell {
    private var row: SideBySideDiff.Row?
    private var horizontalOffset: CGFloat = 0
    /// The change the ↑↓ buttons stepped to, lit while its flash runs.
    var flash: CGFloat = 0 {
        didSet { if flash != oldValue { needsDisplay = true } }
    }

    func configure(_ row: SideBySideDiff.Row, flash: CGFloat, horizontalOffset: CGFloat) {
        self.row = row
        self.flash = flash
        self.horizontalOffset = horizontalOffset
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

    func setHorizontalOffset(_ offset: CGFloat) {
        horizontalOffset = offset
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
                 number: row.leftNumber, text: row.attributedText(onLeft: true, font: font),
                 font: font, gutter: gutter,
                 background: row.kind == .change && row.leftText != nil
                     ? Theme.diffRemovedBackground : nil)
        drawSide(NSRect(x: half, y: 0, width: bounds.width - half, height: bounds.height),
                 number: row.rightNumber, text: row.attributedText(onLeft: false, font: font),
                 font: font, gutter: gutter,
                 background: row.kind == .change && row.rightText != nil
                     ? Theme.diffAddedBackground : nil)

        Theme.border.setFill()
        NSRect(x: half, y: 0, width: 1, height: bounds.height).fill()
    }

    private func drawSide(_ rect: NSRect, number: Int?, text: NSAttributedString?, font: NSFont,
                          gutter: CGFloat, background: NSColor?) {
        if let background {
            background.setFill()
            rect.fill()
        }
        if flash > 0 {
            ChangeFlash.fill(strength: flash).setFill()
            rect.fill(using: .sourceOver)
        }
        if let number {
            SidebarCellDrawing.text("\(number)", font: font, color: Theme.gutter,
                                    in: NSRect(x: rect.minX, y: 0,
                                               width: gutter - 8, height: rect.height),
                                    alignment: .right)
        }
        guard let text else { return }
        let textRect = NSRect(x: rect.minX + gutter, y: 0,
                              width: max(0, rect.width - gutter - 6), height: rect.height)
        guard textRect.width > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        textRect.clip()
        // Point drawing preserves the complete single line and its word-level
        // backgrounds; clipping bounds it to this side without an ellipsis.
        text.draw(at: NSPoint(x: textRect.minX - horizontalOffset,
                              y: floor(textRect.midY - text.size().height / 2)))
        NSGraphicsContext.restoreGraphicsState()
    }
}

private final class SideBySideScrollView: NSScrollView {
    var onHorizontalScroll: ((CGFloat) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        let shiftVertical = event.modifierFlags.contains(.shift) && event.scrollingDeltaX == 0
        let delta = shiftVertical ? event.scrollingDeltaY : event.scrollingDeltaX
        if delta != 0 {
            onHorizontalScroll?(delta * (event.hasPreciseScrollingDeltas ? 1 : 20))
        }
        if !shiftVertical { super.scrollWheel(with: event) }
    }
}

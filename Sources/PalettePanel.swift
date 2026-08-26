import AppKit

/// The floating input Puzzle uses for ⌘P and ⌘L: a query field with an optional
/// result list underneath, keyboard-driven and dismissed by Escape or by losing
/// key. Modelled on the panel Zed and VS Code put in the same place.
final class PalettePanel: NSPanel {
    /// One row: what to show, and what to hand back when it is chosen.
    struct Item {
        let title: String
        let detail: String
        let value: URL?
    }

    var onAccept: ((Item?) -> Void)?
    var onQueryChanged: ((String) -> Void)?

    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let hint = NSTextField(labelWithString: "")
    private var items: [Item] = []
    private var selection = 0

    static let rowHeight: CGFloat = 34
    static let maxVisibleRows = 8

    init(width: CGFloat = 560) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: 52),
                   styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isFloatingPanel = true
        level = .floating
        backgroundColor = Theme.panelBackground

        let container = FlatView()
        container.fillColor = Theme.panelBackground
        container.translatesAutoresizingMaskIntoConstraints = false

        field.font = Theme.uiFont(14)
        field.textColor = Theme.foreground
        field.backgroundColor = Theme.inputBackground
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = true
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        hint.font = Theme.uiFont(10.5)
        hint.textColor = Theme.dimText
        hint.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowSizeStyle = .custom
        table.backgroundColor = Theme.panelBackground
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(field)
        container.addSubview(hint)
        container.addSubview(scroll)
        contentView = container
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            field.heightAnchor.constraint(equalToConstant: 26),

            hint.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 6),
            hint.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: field.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    override var canBecomeKey: Bool { true }

    func configure(placeholder: String, hint hintText: String) {
        field.placeholderString = placeholder
        hint.stringValue = hintText
        hint.isHidden = hintText.isEmpty
    }

    var query: String { field.stringValue }

    func setQuery(_ text: String) {
        field.stringValue = text
        onQueryChanged?(text)
    }

    func setItems(_ items: [Item]) {
        self.items = items
        selection = items.isEmpty ? -1 : 0
        table.reloadData()
        resize()
    }

    /// Grow with the results instead of leaving an empty well under the field.
    private func resize() {
        let rows = min(items.count, Self.maxVisibleRows)
        let listHeight = CGFloat(rows) * Self.rowHeight
        let hintHeight: CGFloat = (hint.isHidden || !items.isEmpty) ? 0 : 22
        hint.isHidden = !items.isEmpty && !hint.stringValue.isEmpty ? true : hint.stringValue.isEmpty
        var frame = self.frame
        let height = 10 + 26 + 8 + listHeight + hintHeight + (listHeight > 0 ? 8 : 4)
        frame.origin.y += frame.height - height
        frame.size.height = height
        setFrame(frame, display: true)
        table.reloadData()
    }

    /// Centre near the top of the owning window, where a palette belongs.
    func present(over parent: NSWindow) {
        let parentFrame = parent.frame
        var frame = self.frame
        frame.origin.x = parentFrame.midX - frame.width / 2
        frame.origin.y = parentFrame.maxY - frame.height - 120
        setFrame(frame, display: true)
        parent.addChildWindow(self, ordered: .above)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
    }

    func dismiss() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }

    private func accept() {
        let item = items.indices.contains(selection) ? items[selection] : nil
        onAccept?(item)
    }

    private func move(by delta: Int) {
        guard !items.isEmpty else { return }
        selection = max(0, min(items.count - 1, selection + delta))
        table.reloadData()
        table.scrollRowToVisible(selection)
    }

    @objc private func rowClicked() {
        guard table.clickedRow >= 0 else { return }
        selection = table.clickedRow
        accept()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: dismiss()                  // Escape
        case 36, 76: accept()               // Return, Enter
        case 125: move(by: 1)               // Down
        case 126: move(by: -1)              // Up
        default: super.keyDown(with: event)
        }
    }

    // MARK: - Regression-test surface

    var itemsForTesting: [Item] { items }
    var selectedIndexForTesting: Int { selection }
    func moveSelectionForTesting(by delta: Int) { move(by: delta) }
    func acceptForTesting() { accept() }
}

extension PalettePanel: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        onQueryChanged?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)): dismiss(); return true
        case #selector(NSResponder.insertNewline(_:)): accept(); return true
        case #selector(NSResponder.moveDown(_:)): move(by: 1); return true
        case #selector(NSResponder.moveUp(_:)): move(by: -1); return true
        default: return false
        }
    }
}

extension PalettePanel: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        Self.rowHeight
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("palette-row")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? PaletteRowCell)
            ?? PaletteRowCell()
        cell.identifier = id
        cell.configure(items[row], selected: row == selection)
        return cell
    }
}

private final class PaletteRowCell: DrawnSidebarCell {
    private var item: PalettePanel.Item?
    private var selected = false

    func configure(_ item: PalettePanel.Item, selected: Bool) {
        self.item = item
        self.selected = selected
        exposeToAccessibility(item.title)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let item else { return }
        if selected {
            Theme.activeRow.setFill()
            bounds.fill()
        }
        let font = Theme.uiFont(12)
        let detailFont = Theme.uiFont(10)
        let baseline = SidebarCellDrawing.centeredBaseline(
            for: font, in: NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height / 2 + 6))
        SidebarCellDrawing.text(item.title, font: font, color: Theme.foreground,
                                baseline: baseline,
                                in: NSRect(x: 12, y: 0, width: bounds.width - 24,
                                           height: bounds.height))
        guard !item.detail.isEmpty else { return }
        SidebarCellDrawing.text(item.detail, font: detailFont, color: Theme.dimText,
                                baseline: baseline + 13,
                                in: NSRect(x: 12, y: 0, width: bounds.width - 24,
                                           height: bounds.height),
                                lineBreak: .byTruncatingHead)
    }
}

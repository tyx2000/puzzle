import AppKit

/// The changed files of one project, listed beside its file tree.
///
/// The Git panel shows the same list with everything that surrounds committing;
/// this is the list on its own, in the half of the Projects panel the branch
/// name heads. Clicking a row opens that file's diff, as it does there.
final class ProjectChangesViewController: NSViewController {
    /// A changed file was clicked: show its diff.
    var onOpenDiff: ((GitService.Status.Entry, URL) -> Void)?

    private let table = GitTableView()
    private var entries: [GitService.Status.Entry] = []
    private var directory: URL?

    override func loadView() {
        let root = FlatView()
        root.fillColor = Theme.panelBackground

        table.headerView = nil
        // `.automatic` insets the first row by 10pt, which would set this list
        // below the tree beside it; both start at the row under the heading.
        table.style = .plain
        table.rowSizeStyle = .custom
        table.backgroundColor = Theme.panelBackground
        table.gridStyleMask = []
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.usesAlternatingRowBackgroundColors = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("change"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        let scroll = NSScrollView()
        PuzzleScroller.adopt(scroll)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.panelBackground
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // No strip of its own: the branch in the row above heads this list, and
        // the two start level — a heading here would put back the gap that was
        // taken out from under the project row.
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    /// The project's changes, as the window's own Git refresh found them.
    func setEntries(_ entries: [GitService.Status.Entry], in directory: URL?) {
        guard self.entries != entries || self.directory != directory else { return }
        self.entries = entries
        self.directory = directory
        guard isViewLoaded else { return }
        table.reloadData()
    }

    @objc private func rowClicked() {
        guard let directory, entries.indices.contains(table.clickedRow) else { return }
        onOpenDiff?(entries[table.clickedRow], directory)
    }

    func refreshFonts() {
        guard isViewLoaded else { return }
        table.reloadData()
    }

    // MARK: - Regression-test surface

    var entriesForTesting: [GitService.Status.Entry] { entries }
    var rowCountForTesting: Int {
        _ = view
        return table.numberOfRows
    }
    /// Where the first row starts, measured from the window's top, so it can
    /// be held level with the tree in the column beside it.
    var firstRowTopInsetInWindowForTesting: CGFloat? {
        _ = view
        guard table.numberOfRows > 0, let window = view.window else { return nil }
        table.layoutSubtreeIfNeeded()
        let rect = table.convert(table.rect(ofRow: 0), to: nil)
        return window.frame.height - rect.maxY
    }
    /// The name a row draws, which is what the reader picks it out by.
    func rowNameForTesting(_ row: Int) -> String? {
        _ = view
        return (tableView(table, viewFor: nil, row: row) as? GitChangeCell)?.nameForTesting
    }
    /// A click on a row, through the same path a real one takes.
    func clickRowForTesting(_ row: Int) {
        guard let directory, entries.indices.contains(row) else { return }
        onOpenDiff?(entries[row], directory)
    }
}

extension ProjectChangesViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        // The same unit the tree beside it uses, so the two columns line up.
        Theme.treeRowHeight()
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("project-change-row")
        let view = (tableView.makeView(withIdentifier: id, owner: self) as? GitRowView)
            ?? GitRowView()
        view.identifier = id
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let id = NSUserInterfaceItemIdentifier("project-change-cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? GitChangeCell)
            ?? GitChangeCell()
        cell.identifier = id
        cell.configure(entry: entries[row])
        return cell
    }
}

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
    /// Drawn in place of the list when the project has nothing uncommitted,
    /// which is otherwise an empty half with no explanation.
    private let emptyLabel = NSTextField(labelWithString: "No changes")

    override func loadView() {
        let root = FlatView()
        root.fillColor = Theme.panelBackground

        table.headerView = nil
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

        emptyLabel.font = Theme.uiFont(10.5)
        emptyLabel.textColor = Theme.dimText
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(scroll)
        root.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            emptyLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
        ])
        view = root
        refreshEmptyState()
    }

    /// The project's changes, as the window's own Git refresh found them.
    func setEntries(_ entries: [GitService.Status.Entry], in directory: URL?) {
        guard self.entries != entries || self.directory != directory else { return }
        self.entries = entries
        self.directory = directory
        guard isViewLoaded else { return }
        table.reloadData()
        refreshEmptyState()
    }

    private func refreshEmptyState() {
        emptyLabel.isHidden = !entries.isEmpty
    }

    @objc private func rowClicked() {
        guard let directory, entries.indices.contains(table.clickedRow) else { return }
        onOpenDiff?(entries[table.clickedRow], directory)
    }

    func refreshFonts() {
        emptyLabel.font = Theme.uiFont(10.5)
        guard isViewLoaded else { return }
        table.reloadData()
    }

    // MARK: - Regression-test surface

    var entriesForTesting: [GitService.Status.Entry] { entries }
    var rowCountForTesting: Int {
        _ = view
        return table.numberOfRows
    }
    var emptyLabelIsVisibleForTesting: Bool {
        _ = view
        return !emptyLabel.isHidden
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

import AppKit

/// The current branch's commits, under the changes of the same project.
///
/// The Git panel's History tab shows the same list; this is that list in the
/// column the branch heads, in the same form — one line per commit, its files
/// underneath when it is opened.
final class ProjectHistoryViewController: NSViewController {
    /// A file inside a commit was clicked: show that commit's diff for it.
    var onOpenCommitDiff: ((GitService.Commit, GitService.CommitFile, URL) -> Void)?

    /// A commit, or one of its files while the commit is open.
    private enum Row {
        case commit(GitService.Commit)
        case file(GitService.CommitFile, commit: GitService.Commit)
    }

    private let table = GitTableView()
    private var directory: URL?
    /// What the list was built for: the commit it ends at and where the
    /// upstream sits behind it. Those are what the rows show — the commits
    /// themselves, and the ↑ on the ones not pushed yet — so the log is read
    /// again exactly when one of them moves, and left alone through the saves
    /// and refreshes that move neither.
    private var state = State()
    struct State: Equatable {
        var head = ""
        var ahead = 0
        var hasUpstream = false
    }
    private var commits: [GitService.Commit] = []
    /// Short hashes not yet on the upstream branch — drawn with an ↑, as in
    /// the Git panel.
    private var unpushed: Set<String> = []
    private var expanded: Set<String> = []
    private var files: [String: [GitService.CommitFile]] = [:]
    private var rows: [Row] = []
    private var loading = false

    override func loadView() {
        let root = FlatView()
        root.fillColor = Theme.panelBackground

        table.headerView = nil
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
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("commit"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        let scroll = NSScrollView()
        PuzzleScroller.adopt(scroll)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.panelBackground
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let header = SidebarSectionHeader(title: "History")
        header.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(header)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: SidebarSectionHeader.height),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    /// Point the list at a project and at where that project stands. Called
    /// with every Git refresh; the log is only re-read when something the
    /// rows show has actually moved — a commit, or a push.
    func setSource(directory: URL?, state: State) {
        guard directory != self.directory || state != self.state else { return }
        let switched = directory != self.directory
        self.directory = directory
        self.state = state
        if switched {
            // Another project's commits must not sit here while its own load
            // is still running.
            commits = []
            unpushed = []
            expanded = []
            files = [:]
            rebuildRows()
        }
        guard let directory else { return }
        load(directory)
    }

    private func load(_ directory: URL) {
        guard !loading else { return }
        loading = true
        GitService.workQueue.async { [weak self] in
            let log = GitService.log(in: directory, limit: Self.limit)
            let pending = GitService.unpushedHashes(in: directory)
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                guard self.directory == directory else { return }
                self.commits = log
                self.unpushed = pending
                // A commit that is no longer listed cannot stay open.
                let listed = Set(log.map(\.shortHash))
                self.expanded.formIntersection(listed)
                self.files = self.files.filter { listed.contains($0.key) }
                self.rebuildRows()
            }
        }
    }

    /// As many as the Git panel's own History tab reads.
    static let limit = 40

    private func rebuildRows() {
        var built: [Row] = []
        for commit in commits {
            built.append(.commit(commit))
            guard expanded.contains(commit.shortHash) else { continue }
            for file in files[commit.shortHash] ?? [] {
                built.append(.file(file, commit: commit))
            }
        }
        rows = built
        guard isViewLoaded else { return }
        table.reloadData()
    }

    private func isUnpushed(_ shortHash: String) -> Bool {
        // `git log` and `rev-list` can abbreviate to different lengths, so
        // match on prefix rather than requiring the strings to be equal.
        unpushed.contains { $0.hasPrefix(shortHash) || shortHash.hasPrefix($0) }
    }

    @objc private func rowClicked() { act(on: table.clickedRow) }

    private func act(on row: Int) {
        guard let directory, rows.indices.contains(row) else { return }
        switch rows[row] {
        case .commit(let commit):
            toggle(commit, in: directory)
        case .file(let file, let commit):
            onOpenCommitDiff?(commit, file, directory)
        }
    }

    private func toggle(_ commit: GitService.Commit, in directory: URL) {
        let hash = commit.shortHash
        if expanded.contains(hash) {
            expanded.remove(hash)
            rebuildRows()
            return
        }
        expanded.insert(hash)
        if files[hash] != nil {
            rebuildRows()
            return
        }
        // `git show` on a large commit is not instant.
        GitService.workQueue.async { [weak self] in
            let found = GitService.files(inCommit: hash, in: directory)
            DispatchQueue.main.async {
                guard let self, self.directory == directory,
                      self.expanded.contains(hash) else { return }
                self.files[hash] = found
                self.rebuildRows()
            }
        }
    }

    func refreshFonts() {
        guard isViewLoaded else { return }
        table.reloadData()
    }

    // MARK: - Regression-test surface

    /// The strip that names this list.
    var headerForTesting: SidebarSectionHeader? {
        _ = view
        return view.subviews.compactMap { $0 as? SidebarSectionHeader }.first
    }
    var rowCountForTesting: Int {
        _ = view
        return table.numberOfRows
    }
    var commitSubjectsForTesting: [String] {
        rows.compactMap { if case .commit(let c) = $0 { return c.subject } else { return nil } }
    }
    /// The commits drawn with the ↑ that says they are not pushed yet.
    var unpushedSubjectsForTesting: [String] {
        rows.compactMap {
            guard case .commit(let commit) = $0,
                  isUnpushed(commit.shortHash) else { return nil }
            return commit.subject
        }
    }
    var fileRowsForTesting: [String] {
        rows.compactMap { if case .file(let f, _) = $0 { return f.path } else { return nil } }
    }
    /// The subject a row draws, which is what the reader picks it out by.
    func rowSubjectForTesting(_ row: Int) -> String? {
        _ = view
        return (tableView(table, viewFor: nil, row: row) as? GitCommitCell)?.subjectForTesting
    }
    /// A click on a row, through the same path a real one takes.
    func clickRowForTesting(_ row: Int) { act(on: row) }
    /// Wait for a load already in flight, the way a test has to.
    func settleForTesting(timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while (loading || commits.isEmpty), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }
}

extension ProjectHistoryViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        // One `tree_line_height`, like every other list in the sidebar.
        Theme.treeRowHeight()
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("project-history-row")
        let view = (tableView.makeView(withIdentifier: id, owner: self) as? GitRowView)
            ?? GitRowView()
        view.identifier = id
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .commit(let commit):
            let id = NSUserInterfaceItemIdentifier("project-history-commit")
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? GitCommitCell)
                ?? GitCommitCell()
            cell.identifier = id
            cell.configure(commit: commit, pending: isUnpushed(commit.shortHash))
            return cell
        case .file(let file, _):
            let id = NSUserInterfaceItemIdentifier("project-history-file")
            let cell = (tableView.makeView(withIdentifier: id, owner: self)
                        as? GitHistoryFileCell) ?? GitHistoryFileCell()
            cell.identifier = id
            cell.configure(file: file)
            return cell
        }
    }
}

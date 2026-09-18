import AppKit

/// The current branch's commits, under the changes of the same project: one
/// line per commit — branch, id, message, author, how long ago — and its
/// files underneath when it is opened.
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
    /// Nil until a Git refresh has said where the project stands — which is
    /// what the first read waits for.
    private var state: State?
    struct State: Equatable {
        var head = ""
        var ahead = 0
        var hasUpstream = false
    }
    private var commits: [GitService.Commit] = []
    /// Short hashes not yet on the upstream branch — drawn with an ↑.
    private var unpushed: Set<String> = []
    /// The branch each commit sits on: the list holds everything behind HEAD,
    /// including commits made on a branch that was merged in.
    private var branches: [String: String] = [:]
    /// One width for the branch column down the whole list, so the ids and
    /// messages after it start at the same place on every row.
    private var branchColumnWidth: CGFloat = 0
    /// When the log was read: "3 hours ago" is measured from here, so every
    /// row agrees and a redraw does not change what a row says.
    private var readAt = Date()
    private var expanded: Set<String> = []
    private var files: [String: [GitService.CommitFile]] = [:]
    private var rows: [Row] = []
    private var loading = false
    /// Something moved while a read was already running. The reply in flight
    /// speaks for the state before it, so another read has to follow — without
    /// this the list sat one commit behind until the next thing moved.
    private var loadAgain = false

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
        table.contextMenuProvider = { [weak self] row in self?.contextMenu(forRow: row) }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("commit"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        let scroll = NSScrollView()
        GiftScroller.adopt(scroll)
        scroll.documentView = table
        // Reaching the end asks for the next page.
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.panelBackground
        scroll.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
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
        prepare(for: directory)
        self.state = state
        // No commit to read from: not a repository.
        guard let directory, !state.head.isEmpty else { return }
        load(directory)
    }

    /// Empty the list for a project whose state is not known yet, without
    /// reading anything: the refresh that follows says where it stands, and
    /// reading now only to read again then cost every project switch a
    /// second `git log`.
    func prepare(for directory: URL?) {
        guard directory != self.directory else { return }
        self.directory = directory
        state = nil
        // Another project's commits must not sit here while its own load is
        // still running, and its depth is not this one's.
        limit = Self.pageSize
        hasMore = true
        commits = []
        unpushed = []
        branches = [:]
        branchColumnWidth = 0
        expanded = []
        files = [:]
        rebuildRows()
    }

    /// How many times the log has been read, for a test to count them.
    private(set) var loadCountForTesting = 0

    private func load(_ directory: URL) {
        guard !loading else {
            loadAgain = true
            return
        }
        loading = true
        loadCountForTesting += 1
        // Read on the main thread, where it is set; the queue below only uses
        // the number.
        let wanted = limit
        GitService.workQueue.async { [weak self] in
            let log = GitService.log(in: directory, limit: wanted)
            let pending = GitService.unpushedHashes(in: directory)
            let named = GitService.branchNames(for: log.map(\.shortHash), in: directory)
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                defer {
                    if self.loadAgain, let current = self.directory {
                        self.loadAgain = false
                        self.load(current)
                    }
                }
                guard self.directory == directory else { return }
                self.commits = log
                self.hasMore = log.count >= wanted
                self.unpushed = pending
                self.branches = named
                self.branchColumnWidth = GitCommitCell.branchColumnWidth(for: named.values)
                self.readAt = Date()
                // A commit that is no longer listed cannot stay open.
                let listed = Set(log.map(\.shortHash))
                self.expanded.formIntersection(listed)
                self.files = self.files.filter { listed.contains($0.key) }
                self.rebuildRows()
            }
        }
    }

    /// Read in pages: a project's history is unbounded, and a list that holds
    /// the first forty commits and stops has no way to say so. Another page is
    /// read when the reader reaches the end of this one.
    static var pageSize = 200
    private var limit = pageSize
    /// False once Git has fewer commits left than the page asked for.
    private var hasMore = true

    /// Another page once the end of this one is in view. Re-read from the top
    /// rather than appended: one `git log` for the deeper list is simpler than
    /// stitching pages together, and it cannot disagree with itself.
    @objc private func scrolled() {
        guard hasMore, !loading, let directory,
              let clip = table.enclosingScrollView?.contentView else { return }
        let remaining = table.bounds.height - clip.bounds.maxY
        guard remaining < clip.bounds.height else { return }
        limit += Self.pageSize
        load(directory)
    }

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

    // MARK: - Context menu

    private func contextMenu(forRow row: Int) -> NSMenu? {
        guard let directory, rows.indices.contains(row) else { return nil }
        let menu = NSMenu()
        switch rows[row] {
        case .commit(let commit):
            add(to: menu, title: "Copy Commit ID") { Self.copy(commit.shortHash) }
            add(to: menu, title: "Copy Commit Message") { Self.copy(commit.subject) }
        case .file(let file, let commit):
            add(to: menu, title: "Show Changes in This Commit") { [weak self] in
                self?.onOpenCommitDiff?(commit, file, directory)
            }
            add(to: menu, title: "Copy Path") { Self.copy(file.path) }
        }
        return menu
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func add(to menu: NSMenu, title: String, action: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(runMenuAction(_:)),
                              keyEquivalent: "")
        item.target = self
        item.representedObject = MenuAction(run: action)
        menu.addItem(item)
    }

    /// Boxes a closure so it can ride on an `NSMenuItem`.
    private final class MenuAction {
        let run: () -> Void
        init(run: @escaping () -> Void) { self.run = run }
    }

    @objc private func runMenuAction(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuAction)?.run()
    }

    func contextMenuForTesting(row: Int) -> NSMenu? { contextMenu(forRow: row) }

    func refreshFonts() {
        guard isViewLoaded else { return }
        table.reloadData()
    }

    // MARK: - Regression-test surface

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
    /// The branch each commit row is labelled with.
    var branchLabelsForTesting: [String] {
        rows.compactMap {
            guard case .commit(let commit) = $0 else { return nil }
            return branches[commit.shortHash] ?? ""
        }
    }
    /// The subject a row draws, which is what the reader picks it out by.
    func rowSubjectForTesting(_ row: Int) -> String? {
        _ = view
        return (tableView(table, viewFor: nil, row: row) as? GitCommitCell)?.subjectForTesting
    }
    /// The cell a row builds, as it is drawn.
    func rowCellForTesting(_ row: Int) -> GitCommitCell? {
        _ = view
        return tableView(table, viewFor: nil, row: row) as? GitCommitCell
    }
    /// How deep the list has read so far.
    var limitForTesting: Int { limit }
    /// Put the end of the list in view, the way scrolling to the bottom does.
    func scrollToEndForTesting() {
        _ = view
        table.enclosingScrollView?.layoutSubtreeIfNeeded()
        table.scrollToEndOfDocument(nil)
        scrolled()
    }
    /// The room a row is given.
    func rowHeightForTesting(_ row: Int) -> CGFloat {
        _ = view
        return tableView(table, heightOfRow: row)
    }
    /// The branch a row draws before the subject.
    func rowBranchForTesting(_ row: Int) -> String? {
        rowCellForTesting(row)?.branchForTesting
    }
    /// A click on a row, through the same path a real one takes.
    func clickRowForTesting(_ row: Int) { act(on: row) }
    /// The row as the list draws it, laid out and ready to be rendered.
    func rowViewForTesting(_ row: Int) -> GitRowView? {
        _ = view
        table.layoutSubtreeIfNeeded()
        guard row >= 0, row < table.numberOfRows else { return nil }
        return table.rowView(atRow: row, makeIfNecessary: true) as? GitRowView
    }
    func setHoveredRowForTesting(_ row: Int) {
        _ = view
        table.setHoveredRowForTesting(row)
    }
    /// Wait for a load already in flight, the way a test has to.
    func settleForTesting(timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while loading || loadAgain || commits.isEmpty, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }
}

extension ProjectHistoryViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        Theme.treeRowHeight()
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("project-history-row")
        let view = (tableView.makeView(withIdentifier: id, owner: self) as? GitRowView)
            ?? GitRowView()
        view.identifier = id
        // A recycled row must not bring the pointer, or the stripe, of the
        // place it was last used.
        view.isHovered = table.hoveredRow == row
        view.isStriped = row % 2 == 1
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
            cell.configure(commit: commit, pending: isUnpushed(commit.shortHash),
                           branch: branches[commit.shortHash] ?? "",
                           branchColumnWidth: branchColumnWidth, now: readAt)
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

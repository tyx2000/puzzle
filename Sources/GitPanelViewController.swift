import AppKit

/// Git panel: flat Changes / Branch / History tabs, an automatically staged change list,
/// branch information, a commit message editor and commit controls.
final class GitPanelViewController: NSViewController {
    var onOpenFile: ((URL) -> Void)?
    /// Clicking a changed file asks the window to show its coloured diff.
    var onOpenDiff: ((GitService.Status.Entry, URL) -> Void)?
    /// Clicking a file inside an expanded commit shows that commit's diff for it.
    var onOpenCommitDiff: ((GitService.Commit, GitService.CommitFile, URL) -> Void)?
    var onChanged: (() -> Void)?

    /// History rows: a commit, or one of its files when the commit is expanded.
    private enum HistoryRow {
        case commit(GitService.Commit, expanded: Bool)
        case file(GitService.CommitFile, commit: GitService.Commit)
    }
    private var branches: [GitService.Branch] = []
    private var remotes: [GitService.Remote] = []
    private var historyRows: [HistoryRow] = []
    /// Short hashes of commits the user has expanded.
    private var expandedCommits: Set<String> = []
    /// The row whose diff is currently open on the right — painted like the
    /// active file in the tree.
    private var activeChangesPath: String?
    private var activeCommitFile: (commit: String, path: String)?
    /// Files per commit, fetched on first expand.
    private var commitFiles: [String: [GitService.CommitFile]] = [:]

    private var directory: URL?
    private var entries: [GitService.Status.Entry] = []
    private var history: [GitService.Commit] = []
    /// Short hashes not yet on the upstream branch — rendered with an ↑ badge.
    private var unpushed: Set<String> = []

    /// `git log --abbrev` and `git rev-list --abbrev-commit` both honour
    /// core.abbrev, but a repo can still hand back different lengths, so match
    /// on prefix rather than requiring the strings to be equal.
    private func isUnpushed(_ shortHash: String) -> Bool {
        unpushed.contains { $0.hasPrefix(shortHash) || shortHash.hasPrefix($0) }
    }
    private var showingHistory = false
    private var showingBranches = false

    private let segmented = FlatPanelTabBar(labels: ["Changes", "Branch", "History"])
    private let table = NSTableView()
    private let branchLabel = NSTextField(labelWithString: "")
    private let commitField = NSTextView()
    private var commitScroll: HorizontalBorderScrollView!
    private let commitButton = NSButton()
    private let pushButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let branchToolbar = FlatView()
    private let newBranchButton = NSButton()
    private let remoteButton = NSButton()
    private var branchToolbarHeight: NSLayoutConstraint!
    private var tableTopToTabs: NSLayoutConstraint!
    private var tableTopToBranchToolbar: NSLayoutConstraint!
    private var tableBottomToFooter: NSLayoutConstraint!
    private var tableBottomToContainer: NSLayoutConstraint!
    private var aheadCount = 0
    private var refreshInFlight = false
    private var refreshAgain = false

    func setDirectory(_ url: URL) {
        directory = url
        refresh()
    }

    func releaseTransientMemory() {
        historyRows.removeAll()
        expandedCommits.removeAll()
        commitFiles.removeAll()
        entries.removeAll()
        history.removeAll()
        unpushed.removeAll()
        branches.removeAll()
        remotes.removeAll()
        if isViewLoaded { table.reloadData() }
    }

    override func loadView() {
        let container = FlatView()
        container.fillColor = Theme.panelBackground

        segmented.selectedSegment = 0
        segmented.onChange = { [weak self] in self?.tabChanged() }
        segmented.translatesAutoresizingMaskIntoConstraints = false

        branchToolbar.fillColor = Theme.panelBackground
        branchToolbar.translatesAutoresizingMaskIntoConstraints = false
        branchToolbar.isHidden = true

        newBranchButton.title = "New Branch"
        newBranchButton.bezelStyle = .rounded
        newBranchButton.controlSize = .small
        newBranchButton.font = Theme.uiFont(10.5)
        newBranchButton.target = self
        newBranchButton.action = #selector(newBranchAction)
        newBranchButton.translatesAutoresizingMaskIntoConstraints = false

        remoteButton.title = "Remote"
        remoteButton.bezelStyle = .rounded
        remoteButton.controlSize = .small
        remoteButton.font = Theme.uiFont(10.5)
        remoteButton.target = self
        remoteButton.action = #selector(remoteAction)
        remoteButton.translatesAutoresizingMaskIntoConstraints = false
        branchToolbar.addSubview(newBranchButton)
        branchToolbar.addSubview(remoteButton)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowSizeStyle = .custom
        table.backgroundColor = Theme.panelBackground
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.usesAlternatingRowBackgroundColors = false

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.panelBackground
        scroll.translatesAutoresizingMaskIntoConstraints = false

        branchLabel.font = Theme.uiFont(10.5)
        branchLabel.textColor = Theme.dimText
        branchLabel.translatesAutoresizingMaskIntoConstraints = false

        // Commit message box.
        commitField.font = Theme.uiFont(11)
        commitField.isRichText = false
        commitField.backgroundColor = Theme.activeTab
        commitField.textColor = Theme.foreground
        commitField.textContainerInset = NSSize(width: 4, height: 4)
        commitScroll = HorizontalBorderScrollView()
        commitScroll.documentView = commitField
        commitScroll.borderType = .noBorder
        commitScroll.hasVerticalScroller = true
        commitScroll.drawsBackground = true
        commitScroll.backgroundColor = Theme.activeTab
        commitScroll.translatesAutoresizingMaskIntoConstraints = false

        commitButton.title = "Commit"
        commitButton.bezelStyle = .rounded
        commitButton.controlSize = .small
        commitButton.font = Theme.uiFont(10.5)
        commitButton.target = self
        commitButton.action = #selector(commit)
        commitButton.translatesAutoresizingMaskIntoConstraints = false

        // A pull-down, so the remote operations that belong together live in one
        // control: the title performs Push, the menu offers the rest.
        pushButton.bezelStyle = .rounded
        pushButton.controlSize = .small
        pushButton.font = Theme.uiFont(10.5)
        pushButton.translatesAutoresizingMaskIntoConstraints = false
        rebuildPushMenu()

        [segmented, branchToolbar, scroll, branchLabel, commitScroll,
         commitButton, pushButton].forEach { container.addSubview($0) }

        branchToolbarHeight = branchToolbar.heightAnchor.constraint(equalToConstant: 0)
        tableTopToTabs = scroll.topAnchor.constraint(equalTo: segmented.bottomAnchor)
        tableTopToBranchToolbar = scroll.topAnchor.constraint(equalTo: branchToolbar.bottomAnchor)
        tableBottomToFooter = scroll.bottomAnchor.constraint(equalTo: branchLabel.topAnchor, constant: -6)
        tableBottomToContainer = scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        NSLayoutConstraint.activate([
            segmented.topAnchor.constraint(equalTo: container.topAnchor),
            segmented.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            segmented.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            segmented.heightAnchor.constraint(equalToConstant: 36),

            branchToolbar.topAnchor.constraint(equalTo: segmented.bottomAnchor),
            branchToolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            branchToolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            branchToolbarHeight,
            newBranchButton.leadingAnchor.constraint(equalTo: branchToolbar.leadingAnchor, constant: 8),
            newBranchButton.centerYAnchor.constraint(equalTo: branchToolbar.centerYAnchor),
            remoteButton.leadingAnchor.constraint(equalTo: newBranchButton.trailingAnchor, constant: 20),
            remoteButton.trailingAnchor.constraint(equalTo: branchToolbar.trailingAnchor, constant: -8),
            remoteButton.centerYAnchor.constraint(equalTo: branchToolbar.centerYAnchor),
            remoteButton.widthAnchor.constraint(equalTo: newBranchButton.widthAnchor),

            tableTopToTabs,
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tableBottomToFooter,

            branchLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            branchLabel.bottomAnchor.constraint(equalTo: commitScroll.topAnchor, constant: -6),

            commitScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            commitScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            commitScroll.heightAnchor.constraint(equalToConstant: 200),
            commitScroll.bottomAnchor.constraint(equalTo: commitButton.topAnchor, constant: -6),

            // "Commit && Push" left, "Commit" right.
            pushButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            pushButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            commitButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            commitButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            commitButton.leadingAnchor.constraint(
                greaterThanOrEqualTo: pushButton.trailingAnchor, constant: 6),
        ])
        tableTopToBranchToolbar.isActive = false
        tableBottomToContainer.isActive = false
        self.view = container
    }

    // MARK: - Data

    /// Re-apply the UI font after a settings change.
    func refreshFonts() {
        segmented.refreshAppearance()
        branchLabel.font = Theme.uiFont(10.5)
        commitField.font = Theme.uiFont(11)
        commitButton.font = Theme.uiFont(10.5)
        pushButton.font = Theme.uiFont(10.5)
        newBranchButton.font = Theme.uiFont(10.5)
        remoteButton.font = Theme.uiFont(10.5)
        refresh()          // rebuilds the rows, which set their own fonts
    }

    func refresh() {
        guard let directory else { return }
        if refreshInFlight {
            refreshAgain = true
            return
        }
        refreshInFlight = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var status = GitService.status(in: directory)
            if status.isRepo,
               status.entries.contains(where: {
                   $0.isUntracked || $0.worktreeStatus != " "
               }) {
                GitService.stageAll(in: directory)
                status = GitService.status(in: directory)
            }
            let log = GitService.log(in: directory, limit: 40)
            let pending = GitService.unpushedHashes(in: directory)
            let branches = GitService.branches(in: directory)
            let remotes = GitService.remotes(in: directory)
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshInFlight = false
                // A project switch while Git was running makes this result
                // stale; immediately service the queued refresh instead.
                guard self.directory == directory else {
                    self.refreshAgain = false
                    self.refresh()
                    return
                }
                self.entries = status.entries
                self.history = log
                self.unpushed = pending
                self.branches = branches
                self.remotes = remotes
                self.rebuildHistoryRows()
                // Surface the ahead-count: without it there is no sign that
                // commits are sitting locally waiting to be pushed.
                var label = "\(directory.lastPathComponent) / \(status.branch)"
                if status.ahead > 0 { label += "  ↑\(status.ahead)" }
                else if status.isRepo && !status.hasUpstream { label += "  (no upstream)" }
                self.branchLabel.stringValue = status.isRepo ? label : "not a git repository"
                self.branchLabel.toolTip = status.ahead > 0
                    ? "\(status.ahead) commit\(status.ahead == 1 ? "" : "s") not pushed yet"
                    : nil
                self.segmented.setLabel("Changes (\(status.entries.count))", forSegment: 0)
                if self.aheadCount != status.ahead {
                    self.aheadCount = status.ahead
                    self.rebuildPushMenu()
                }
                self.rebuildPushMenu()
                self.table.reloadData()
                if self.refreshAgain {
                    self.refreshAgain = false
                    self.refresh()
                }
            }
        }
    }

    /// Colour for a commit file's status letter (A added, M modified, D deleted).
    static func statusColor(_ status: String) -> NSColor {
        switch status {
        case "A": return Theme.green
        case "D": return Theme.red
        case "R": return Theme.blue
        default:  return Theme.yellow     // M and friends
        }
    }

    /// Flatten commits (and the files of expanded ones) into display rows.
    private func rebuildHistoryRows() {
        var built: [HistoryRow] = []
        for commit in history {
            let isExpanded = expandedCommits.contains(commit.shortHash)
            built.append(.commit(commit, expanded: isExpanded))
            if isExpanded {
                for f in commitFiles[commit.shortHash] ?? [] {
                    built.append(.file(f, commit: commit))
                }
            }
        }
        historyRows = built
    }

    @objc func tabChanged() {
        showingBranches = segmented.selectedSegment == 1
        showingHistory = segmented.selectedSegment == 2
        updateTabLayout()
        table.reloadData()
    }

    private func updateTabLayout() {
        let branchTab = showingBranches
        branchToolbar.isHidden = !branchTab
        branchToolbarHeight.constant = branchTab ? 36 : 0
        tableTopToTabs.isActive = !branchTab
        tableTopToBranchToolbar.isActive = branchTab
        tableBottomToFooter.isActive = !branchTab
        tableBottomToContainer.isActive = branchTab
        branchLabel.isHidden = branchTab
        commitScroll.isHidden = branchTab
        commitButton.isHidden = branchTab
        pushButton.isHidden = branchTab
    }

    @objc private func commit() { performCommit(push: false) }

    /// The pull-down's first item is its title, so the menu is rebuilt whenever
    /// the ahead-count changes.
    private func rebuildPushMenu() {
        let menu = NSMenu()
        let title = aheadCount > 0 ? "Push ↑\(aheadCount)" : "Push"
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "")   // shown as the title
        menu.addItem(withTitle: title, action: #selector(pushAction), keyEquivalent: "")
        menu.addItem(withTitle: "Commit & Push", action: #selector(commitAndPushAction),
                     keyEquivalent: "")
        if !remotes.isEmpty {
            menu.addItem(.separator())
            for remote in remotes {
                let item = NSMenuItem(title: "Push to \(remote.name)",
                                      action: #selector(pushToRemoteAction(_:)),
                                      keyEquivalent: "")
                item.representedObject = remote.name
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Fetch", action: #selector(fetchAction), keyEquivalent: "")
        menu.addItem(withTitle: "Pull", action: #selector(pullAction), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Force Push…", action: #selector(forcePushAction), keyEquivalent: "")
        for item in menu.items { item.target = self }
        pushButton.menu = menu
        pushButton.toolTip = aheadCount > 0
            ? "\(aheadCount) commit\(aheadCount == 1 ? "" : "s") to push"
            : "Push"
    }

    /// Push whatever is already committed locally. A commit message in the
    /// editor must never change the meaning of the Push action.
    @objc private func pushAction() {
        guard let directory else { return }
        runRemote("Push") { GitService.push(in: directory) }
    }

    @objc private func commitAndPushAction() { performCommit(push: true) }

    @objc private func pushToRemoteAction(_ sender: NSMenuItem) {
        guard let directory, let name = sender.representedObject as? String else { return }
        runRemote("Push to \(name)") { GitService.push(to: name, in: directory) }
    }

    @objc private func fetchAction() {
        guard let directory else { return }
        runRemote("Fetch") { GitService.fetch(in: directory) }
    }

    @objc private func pullAction() {
        guard let directory else { return }
        runRemote("Pull") { GitService.pull(in: directory) }
    }

    @objc private func forcePushAction() {
        guard let directory else { return }
        // Destructive and hard to undo, so it asks first.
        let alert = NSAlert()
        alert.messageText = "Force push?"
        alert.informativeText = "This rewrites the remote branch. Uses --force-with-lease, "
            + "so it will refuse if the remote has commits you haven't fetched."
        alert.addButton(withTitle: "Force Push")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runRemote("Force push") { GitService.forcePush(in: directory) }
    }

    /// Run a remote operation off the main thread and report the outcome.
    private func runRemote(_ verb: String, _ work: @escaping () -> GitService.RemoteResult) {
        pushButton.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = work()
            DispatchQueue.main.async {
                guard let self else { return }
                self.pushButton.isEnabled = true
                if !result.ok {
                    let alert = NSAlert()
                    alert.messageText = "\(verb) failed"
                    alert.informativeText = result.message
                    alert.runModal()
                }
                self.refresh()
                self.onChanged?()
            }
        }
    }

    /// Commit, optionally pushing afterwards.
    ///
    /// Both run off the main thread: `git commit` touches the index and `git
    /// push` waits on the network, and doing either inline froze the whole
    /// window for the duration.
    private func performCommit(push: Bool) {
        guard let directory else { return }
        let message = commitField.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Commit message required"
            alert.runModal(); return
        }

        commitButton.isEnabled = false
        pushButton.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let commit = GitService.commit(message, in: directory)
            // A failed push still leaves the commit in place, so the two
            // outcomes are reported separately.
            var pushResult: GitService.RemoteResult?
            if commit.code == 0, push {
                pushResult = GitService.push(in: directory)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.commitButton.isEnabled = true
                self.pushButton.isEnabled = true

                if commit.code != 0 {
                    let alert = NSAlert()
                    alert.messageText = "Commit failed"
                    alert.informativeText = commit.err.isEmpty ? commit.out : commit.err
                    alert.runModal()
                } else {
                    self.commitField.string = ""
                    if let pushResult, !pushResult.ok {
                        let alert = NSAlert()
                        alert.messageText = "Committed, but push failed"
                        alert.informativeText = pushResult.message
                        alert.runModal()
                    }
                }
                self.refresh()
                self.onChanged?()
            }
        }
    }

    @objc private func rowClicked() {
        let row = table.clickedRow
        guard row >= 0, let directory else { return }

        if showingBranches {
            guard row < branches.count else { return }
            switchBranch(branches[row], in: directory)
            return
        }

        if showingHistory {
            guard row < historyRows.count else { return }
            switch historyRows[row] {
            case .commit(let commit, _):
                toggleCommit(commit, in: directory)
            case .file(let file, let commit):
                activeCommitFile = (commit.shortHash, file.path)
                activeChangesPath = nil
                table.reloadData()
                onOpenCommitDiff?(commit, file, directory)
            }
            return
        }

        guard row < entries.count else { return }
        let entry = entries[row]
        activeChangesPath = entry.path
        activeCommitFile = nil
        table.reloadData()
        // Clicking a changed file shows its diff, not the plain file.
        onOpenDiff?(entry, directory)
    }

    /// Expand or collapse a commit, loading its file list on first expand.
    /// Switch to the History tab programmatically.
    func showHistory() {
        segmented.selectedSegment = 2
        tabChanged()
    }

    /// Expand the Nth commit (scripting / screenshots).
    func expandCommit(at index: Int) {
        guard let directory, index >= 0, index < history.count else { return }
        toggleCommit(history[index], in: directory)
    }

    /// Open the Mth file of the Nth commit (scripting / screenshots).
    func openCommitFile(commitIndex: Int, fileIndex: Int) {
        guard let directory, commitIndex >= 0, commitIndex < history.count else { return }
        let commit = history[commitIndex]
        let files = commitFiles[commit.shortHash] ?? []
        guard fileIndex >= 0, fileIndex < files.count else { return }
        onOpenCommitDiff?(commit, files[fileIndex], directory)
    }

    @objc private func newBranchAction() {
        guard let directory else { return }
        let names = branches.map(\.name)
        guard !names.isEmpty else {
            presentGitError(title: "Cannot create branch", message: "No base branches are available.")
            return
        }

        let nameField = NSTextField(string: "")
        nameField.placeholderString = "Branch name"
        let basePopup = NSPopUpButton()
        basePopup.addItems(withTitles: names)
        if let current = branches.firstIndex(where: { $0.isCurrent }) {
            basePopup.selectItem(at: current)
        }
        let accessory = dialogStack([
            labeledField("Name", nameField),
            labeledField("Base", basePopup),
        ], width: 340)

        let alert = NSAlert()
        alert.messageText = "Create branch"
        alert.informativeText = "The new branch will be created and checked out immediately."
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            presentGitError(title: "Invalid branch name", message: "Enter a branch name.")
            return
        }
        let base = basePopup.titleOfSelectedItem ?? names[0]
        runRemote("Create branch") { GitService.createBranch(name, from: base, in: directory) }
    }

    @objc private func remoteAction() {
        guard let directory else { return }
        let currentRemotes = GitService.remotes(in: directory)
        let existing = currentRemotes.map {
            "\($0.name)\n  Fetch: \($0.fetchURL)\n  Push:  \($0.pushURL)"
        }.joined(separator: "\n\n")
        let summary = NSTextField(wrappingLabelWithString:
            existing.isEmpty ? "No remote repositories are configured." : existing)
        summary.textColor = Theme.dimText

        let nameField = NSTextField(string: currentRemotes.first?.name ?? "origin")
        nameField.placeholderString = "Remote name"
        let fetchField = NSTextField(string: currentRemotes.first?.fetchURL ?? "")
        fetchField.placeholderString = "https://… or git@…"
        let pushField = NSTextField(string: currentRemotes.first?.pushURL ?? "")
        pushField.placeholderString = "Optional push URL"
        let accessory = dialogStack([
            summary,
            labeledField("Name", nameField),
            labeledField("Fetch", fetchField),
            labeledField("Push", pushField),
        ], width: 420)

        let alert = NSAlert()
        alert.messageText = "Remote repositories"
        alert.informativeText = "Existing remotes are listed above. Save adds a new remote or updates the named remote."
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Save Remote")
        alert.addButton(withTitle: "Close")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let fetchURL = fetchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let pushURL = pushField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !fetchURL.isEmpty else {
            presentGitError(title: "Invalid remote", message: "Remote name and Fetch URL are required.")
            return
        }
        runRemote("Save remote") {
            GitService.saveRemote(name: name, fetchURL: fetchURL, pushURL: pushURL,
                                  in: directory)
        }
    }

    private func switchBranch(_ branch: GitService.Branch, in directory: URL) {
        guard !branch.isCurrent else { return }
        runRemote("Switch branch") { GitService.switchBranch(branch.name, in: directory) }
    }

    private func deleteBranch(_ branch: GitService.Branch, in directory: URL) {
        guard !branch.isCurrent else {
            presentGitError(title: "Cannot delete branch", message: "The current branch cannot be deleted.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete branch \(branch.name)?"
        alert.informativeText = "Only fully merged branches can be deleted."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runRemote("Delete branch") { GitService.deleteBranch(branch.name, in: directory) }
    }

    private func presentGitError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.runModal()
    }

    private func labeledField(_ label: String, _ field: NSView) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let labelField = NSTextField(labelWithString: label)
        labelField.font = Theme.uiFont(10.5)
        labelField.textColor = Theme.dimText
        labelField.translatesAutoresizingMaskIntoConstraints = false
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addSubview(labelField)
        row.addSubview(field)
        NSLayoutConstraint.activate([
            labelField.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            labelField.widthAnchor.constraint(equalToConstant: 48),
            labelField.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: labelField.trailingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            field.topAnchor.constraint(equalTo: row.topAnchor),
            field.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
        ])
        return row
    }

    private func dialogStack(_ views: [NSView], width: CGFloat) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .leading
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = true

        // NSAlert lays out its accessory view from its frame, not from a loose
        // width-only constraint. Give every row the same width, then materialize
        // the stack's fitting height into a concrete frame before presenting it.
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        stack.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        stack.layoutSubtreeIfNeeded()
        stack.frame.size.height = ceil(stack.fittingSize.height)
        stack.layoutSubtreeIfNeeded()
        return stack
    }

    private func toggleCommit(_ commit: GitService.Commit, in directory: URL) {
        let hash = commit.shortHash
        if expandedCommits.contains(hash) {
            expandedCommits.remove(hash)
            rebuildHistoryRows()
            table.reloadData()
            return
        }
        expandedCommits.insert(hash)
        if commitFiles[hash] != nil {
            rebuildHistoryRows(); table.reloadData(); return
        }
        // Fetch off the main thread; `git show` on a big commit isn't instant.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let files = GitService.files(inCommit: hash, in: directory)
            DispatchQueue.main.async {
                guard let self, self.directory == directory,
                      self.expandedCommits.contains(hash) else { return }
                self.commitFiles[hash] = files
                self.rebuildHistoryRows()
                self.table.reloadData()
            }
        }
    }

}

extension GitPanelViewController: NSTableViewDataSource {
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("git-row")
        let view = (tableView.makeView(withIdentifier: id, owner: self) as? GitRowView)
            ?? GitRowView()
        view.identifier = id
        view.isActiveFile = false
        if showingBranches {
            return view
        } else if showingHistory, row < historyRows.count {
            if case .file(let file, let commit) = historyRows[row] {
                view.isActiveFile = activeCommitFile?.commit == commit.shortHash
                    && activeCommitFile?.path == file.path
            }
        } else if row < entries.count {
            view.isActiveFile = activeChangesPath == entries[row].path
        }
        return view
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        if showingBranches { return branches.count }
        return showingHistory ? historyRows.count : entries.count
    }
}

extension GitPanelViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if showingBranches { return 58 }
        if showingHistory, row < historyRows.count,
           case .commit = historyRows[row] {
            let titleHeight = ceil(Theme.uiFont(11).boundingRectForFont.height)
            let infoHeight = ceil(Theme.uiFont(9.5).boundingRectForFont.height)
            return max(38, titleHeight + infoHeight + 7)
        }
        return 22
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if showingBranches {
            guard row < branches.count else { return nil }
            let id = NSUserInterfaceItemIdentifier("git-branch-cell")
            let cell = (tableView.makeView(withIdentifier: id, owner: self)
                        as? GitBranchCell) ?? GitBranchCell()
            cell.identifier = id
            let branch = branches[row]
            cell.configure(branch: branch,
                           onSwitch: { [weak self] in
                               guard let self, let directory = self.directory else { return }
                               self.switchBranch(branch, in: directory)
                           },
                           onDelete: { [weak self] in
                               guard let self, let directory = self.directory else { return }
                               self.deleteBranch(branch, in: directory)
                           })
            return cell
        }
        if showingHistory {
            guard row < historyRows.count else { return nil }
            switch historyRows[row] {
            case .commit(let commit, let expanded):
                let id = NSUserInterfaceItemIdentifier("git-commit-cell")
                let cell = (tableView.makeView(withIdentifier: id, owner: self)
                            as? GitCommitCell) ?? GitCommitCell()
                cell.identifier = id
                let pending = isUnpushed(commit.shortHash)
                cell.configure(commit: commit, expanded: expanded, pending: pending)
                return cell

            case .file(let file, _):
                let id = NSUserInterfaceItemIdentifier("git-history-file-cell")
                let cell = (tableView.makeView(withIdentifier: id, owner: self)
                            as? GitHistoryFileCell) ?? GitHistoryFileCell()
                cell.identifier = id
                cell.configure(file: file)
                return cell
            }
        }

        guard row < entries.count else { return nil }
        let id = NSUserInterfaceItemIdentifier("git-change-cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self)
                    as? GitChangeCell) ?? GitChangeCell()
        cell.identifier = id
        cell.configure(entry: entries[row])
        return cell
    }
}

private final class GitCommitCell: DrawnSidebarCell {
    private var chevron: NSImage?
    private var meta = ""
    private var subject = ""
    private var blame = ""
    private var metaColor = NSColor.clear
    func configure(commit: GitService.Commit, expanded: Bool, pending: Bool) {
        chevron = Theme.symbol(expanded ? "chevron.down" : "chevron.right",
                                pointSize: 8, weight: .semibold)
        meta = pending ? "↑ \(commit.shortHash)" : commit.shortHash
        metaColor = pending ? Theme.cursor : Theme.dimText
        subject = commit.subject
        blame = commit.blameSummary + (pending ? "  ·  not pushed" : "")
        // The metadata is always visible below the record, so a delayed hover
        // popup is both redundant and disruptive while scanning history.
        toolTip = nil
        exposeToAccessibility("\(pending ? "Unpushed " : "")commit \(commit.shortHash), \(commit.subject), \(commit.author), \(commit.absoluteDate)")
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let subjectFont = Theme.uiFont(11)
        let metaFont = Theme.uiFont(9.5)
        let titleBand = NSRect(x: 0, y: 2, width: bounds.width, height: 18)
        let titleBaseline = SidebarCellDrawing.centeredBaseline(for: subjectFont, in: titleBand)
        // Align the chevron's visual center with the subject's cap-height, not
        // merely the row center. Commit ID and subject share this exact baseline.
        let glyphCenterY = titleBaseline - subjectFont.capHeight / 2
        SidebarCellDrawing.image(chevron, tint: Theme.dimText,
                                 in: NSRect(x: 6, y: floor(glyphCenterY - 5),
                                            width: 10, height: 10))
        SidebarCellDrawing.text(meta, font: metaFont, color: metaColor,
                                baseline: titleBaseline,
                                in: NSRect(x: 20, y: titleBand.minY,
                                           width: 62, height: titleBand.height))
        SidebarCellDrawing.text(subject, font: subjectFont, color: Theme.foreground,
                                baseline: titleBaseline,
                                in: NSRect(x: 86, y: titleBand.minY,
                                           width: max(0, bounds.width - 92),
                                           height: titleBand.height))

        let blameFont = Theme.uiFont(9.5)
        let blameBand = NSRect(x: 20, y: 20,
                               width: max(0, bounds.width - 26),
                               height: max(0, bounds.height - 21))
        SidebarCellDrawing.text(blame, font: blameFont, color: Theme.dimText,
                                in: blameBand)
    }
}

private final class GitHistoryFileCell: DrawnSidebarCell {
    private var status = ""
    private var name = ""
    private var folder = ""
    private var statusColor = NSColor.clear
    func configure(file: GitService.CommitFile) {
        status = file.status
        statusColor = GitPanelViewController.statusColor(file.status)
        name = (file.path as NSString).lastPathComponent
        folder = (file.path as NSString).deletingLastPathComponent
        toolTip = file.path
        exposeToAccessibility("\(file.status), \(file.path)")
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        SidebarCellDrawing.text(status, font: Theme.uiFont(10), color: statusColor,
                                in: NSRect(x: 24, y: 0, width: 14, height: bounds.height),
                                alignment: .center)
        SidebarCellDrawing.primaryAndSecondary(
            primary: name, primaryFont: Theme.uiFont(11), primaryColor: Theme.foreground,
            secondary: folder, secondaryFont: Theme.uiFont(9.5), secondaryColor: Theme.dimText,
            in: NSRect(x: 44, y: 0, width: max(0, bounds.width - 50), height: bounds.height))
    }
}

private final class GitChangeCell: DrawnSidebarCell {
    private var status = ""
    private var icon: NSImage?
    private var name = ""
    private var folder = ""
    private var statusColor = NSColor.clear
    func configure(entry: GitService.Status.Entry) {
        status = entry.displayCode
        statusColor = entry.isUntracked ? Theme.green : Theme.yellow
        icon = Theme.symbol(FileTreeViewController.iconName(
            for: (entry.path as NSString).pathExtension))
        name = (entry.path as NSString).lastPathComponent
        folder = (entry.path as NSString).deletingLastPathComponent
        toolTip = entry.path
        exposeToAccessibility("Automatically staged \(entry.displayCode), \(entry.path)")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        SidebarCellDrawing.text(status, font: Theme.uiFont(10), color: statusColor,
                                in: NSRect(x: 6, y: 0, width: 18, height: bounds.height),
                                alignment: .center)
        SidebarCellDrawing.image(icon, tint: Theme.dimText,
                                 in: NSRect(x: 26, y: floor((bounds.height - 13) / 2),
                                            width: 13, height: 13))
        SidebarCellDrawing.primaryAndSecondary(
            primary: name, primaryFont: Theme.uiFont(11), primaryColor: Theme.foreground,
            secondary: folder, secondaryFont: Theme.uiFont(9.5), secondaryColor: Theme.dimText,
            in: NSRect(x: 44, y: 0,
                       width: max(0, bounds.width - 50), height: bounds.height),
            gap: 5, primaryLineBreak: .byTruncatingMiddle)
    }
}

private final class GitBranchCell: DrawnSidebarCell {
    private let switchButton = NSButton()
    private let deleteButton = NSButton()
    private var onSwitch: (() -> Void)?
    private var onDelete: (() -> Void)?
    private var name = ""
    private var metadata = ""
    private var isCurrent = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        switchButton.title = "Switch"
        switchButton.bezelStyle = .rounded
        switchButton.controlSize = .small
        switchButton.font = Theme.uiFont(9.5)
        switchButton.target = self
        switchButton.action = #selector(switchAction)
        switchButton.translatesAutoresizingMaskIntoConstraints = false

        deleteButton.title = "Delete"
        deleteButton.bezelStyle = .rounded
        deleteButton.controlSize = .small
        deleteButton.font = Theme.uiFont(9.5)
        deleteButton.target = self
        deleteButton.action = #selector(deleteAction)
        deleteButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(switchButton)
        addSubview(deleteButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(branch: GitService.Branch, onSwitch: @escaping () -> Void,
                   onDelete: @escaping () -> Void) {
        self.onSwitch = onSwitch
        self.onDelete = onDelete
        name = branch.isCurrent ? "\(branch.name)  · current" : branch.name
        metadata = "\(branch.author)  ·  \(branch.createdAt)"
        isCurrent = branch.isCurrent
        switchButton.isEnabled = !branch.isCurrent
        deleteButton.isEnabled = !branch.isCurrent
        toolTip = branch.name
        exposeToAccessibility("Branch \(branch.name), \(metadata)")
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        deleteButton.frame = NSRect(x: bounds.width - 72, y: 19, width: 64, height: 22)
        switchButton.frame = NSRect(x: bounds.width - 142, y: 19, width: 64, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        let content = NSRect(x: 8, y: 2, width: max(0, bounds.width - 154), height: bounds.height - 4)
        SidebarCellDrawing.primaryAndSecondary(
            primary: name, primaryFont: Theme.uiFont(11), primaryColor: isCurrent ? Theme.cursor : Theme.foreground,
            secondary: metadata, secondaryFont: Theme.uiFont(9.5), secondaryColor: Theme.dimText,
            in: content, gap: 5, primaryLineBreak: .byTruncatingMiddle)
    }

    @objc private func switchAction() { onSwitch?() }
    @objc private func deleteAction() { onDelete?() }
}

/// Two-state tab strip with the same full-height selection treatment as the
/// bottom action bar. Native buttons preserve keyboard and VoiceOver behavior.
private final class FlatPanelTabBar: NSView {
    var onChange: (() -> Void)?
    var selectedSegment = 0 { didSet { updateSelection() } }

    private var buttons: [FlatPanelTabButton] = []

    init(labels: [String]) {
        super.init(frame: .zero)
        buttons = labels.enumerated().map { index, label in
            let button = FlatPanelTabButton(title: label)
            button.setAccessibilityRole(.radioButton)
            button.onSelect = { [weak self] in self?.selectTab(index) }
            addSubview(button)
            return button
        }
        updateSelection()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        guard !buttons.isEmpty else { return }
        let width = bounds.width / CGFloat(buttons.count)
        for (index, button) in buttons.enumerated() {
            let minX = (CGFloat(index) * width).rounded()
            let maxX = (CGFloat(index + 1) * width).rounded()
            button.frame = NSRect(x: minX, y: 0, width: maxX - minX,
                                  height: bounds.height)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.barBackground.setFill()
        bounds.fill()
    }

    func setLabel(_ label: String, forSegment index: Int) {
        guard buttons.indices.contains(index) else { return }
        buttons[index].title = label
        buttons[index].setAccessibilityLabel(label)
        buttons[index].needsDisplay = true
    }

    func refreshAppearance() {
        needsDisplay = true
        buttons.forEach { $0.needsDisplay = true }
    }

    private func updateSelection() {
        for (index, button) in buttons.enumerated() {
            button.isSelected = index == selectedSegment
        }
    }

    private func selectTab(_ index: Int) {
        guard index != selectedSegment else { return }
        selectedSegment = index
        onChange?()
    }
}

private final class FlatPanelTabButton: NSView {
    var onSelect: (() -> Void)?
    var title: String {
        didSet { setAccessibilityLabel(title); needsDisplay = true }
    }
    var isSelected = false {
        didSet {
            setAccessibilityValue(isSelected)
            needsDisplay = true
        }
    }

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityLabel(title)
        setAccessibilityValue(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            Theme.activeTab.setFill()
            bounds.fill()
        }
        SidebarCellDrawing.text(title, font: Theme.uiFont(11),
                                color: isSelected ? Theme.foreground : Theme.dimText,
                                in: bounds, alignment: .center)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onSelect?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { // Return or Space
            onSelect?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onSelect?()
        return true
    }
}

/// Commit editor chrome with horizontal separators only; the content and hit
/// area run to both panel edges.
private final class HorizontalBorderScrollView: NSScrollView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Theme.border.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}


/// Git-panel row: flat background, with the same active-file tint the file tree
/// uses for the document currently shown on the right.
final class GitRowView: NSTableRowView {
    var isActiveFile = false

    override func drawBackground(in dirtyRect: NSRect) {
        Theme.panelBackground.setFill()
        bounds.fill()
        if isActiveFile {
            Theme.activeRow.setFill()
            bounds.fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard !isActiveFile, selectionHighlightStyle != .none else { return }
        Theme.hover.setFill()
        bounds.fill()
    }

    override var isEmphasized: Bool {
        get { false }        // never the blue system highlight
        set { }
    }
}

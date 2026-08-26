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
    private let progressShimmer = GitProgressShimmerView()
    private let commitButton = NSButton()
    /// Discards every change in the project — confirmed before it runs.
    private let discardAllButton = NSButton()
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
    private var refreshDirectory: URL?
    /// Serialize panel-owned Git commands so refresh staging cannot race a
    /// commit, checkout, pull, or other index/worktree mutation.
    private let gitQueue = DispatchQueue(label: "app.puzzle.git-panel", qos: .userInitiated)
    private var activeOperationID: UUID?
    private var operationLocksMessage = false

    func setDirectory(_ url: URL) {
        directory = url
        entries.removeAll()
        history.removeAll()
        historyRows.removeAll()
        unpushed.removeAll()
        branches.removeAll()
        remotes.removeAll()
        aheadCount = 0
        if isViewLoaded {
            branchLabel.stringValue = "Loading Git status…"
            segmented.setLabel("Changes", forSegment: 0)
            rebuildPushMenu()
            table.reloadData()
        }
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
        newBranchButton.bezelStyle = .regularSquare
        newBranchButton.controlSize = .small
        newBranchButton.font = Theme.uiFont(10.5)
        newBranchButton.target = self
        newBranchButton.action = #selector(newBranchAction)
        newBranchButton.translatesAutoresizingMaskIntoConstraints = false

        remoteButton.title = "Remote"
        remoteButton.bezelStyle = .regularSquare
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
        progressShimmer.translatesAutoresizingMaskIntoConstraints = false
        progressShimmer.isHidden = true

        discardAllButton.title = "Discard"
        discardAllButton.bezelStyle = .rounded
        discardAllButton.controlSize = .small
        discardAllButton.font = Theme.uiFont(10.5)
        discardAllButton.target = self
        discardAllButton.action = #selector(discardAllAction)
        discardAllButton.setAccessibilityLabel("Discard all changes")
        discardAllButton.translatesAutoresizingMaskIntoConstraints = false

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

        [segmented, branchToolbar, scroll, branchLabel, commitScroll, progressShimmer,
         commitButton, pushButton, discardAllButton].forEach { container.addSubview($0) }

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
            newBranchButton.heightAnchor.constraint(equalToConstant: 32),
            remoteButton.leadingAnchor.constraint(equalTo: newBranchButton.trailingAnchor, constant: 20),
            remoteButton.trailingAnchor.constraint(equalTo: branchToolbar.trailingAnchor, constant: -8),
            remoteButton.centerYAnchor.constraint(equalTo: branchToolbar.centerYAnchor),
            remoteButton.heightAnchor.constraint(equalToConstant: 32),
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
            progressShimmer.topAnchor.constraint(equalTo: commitScroll.topAnchor),
            progressShimmer.leadingAnchor.constraint(equalTo: commitScroll.leadingAnchor),
            progressShimmer.trailingAnchor.constraint(equalTo: commitScroll.trailingAnchor),
            progressShimmer.heightAnchor.constraint(equalToConstant: 3),

            // "Commit && Push" left, "Commit" right.
            pushButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            pushButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            commitButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            commitButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),

            // Discard sits just before Commit, both anchored to the right.
            discardAllButton.trailingAnchor.constraint(
                equalTo: commitButton.leadingAnchor, constant: -6),
            discardAllButton.bottomAnchor.constraint(
                equalTo: container.bottomAnchor, constant: -8),
            discardAllButton.leadingAnchor.constraint(
                greaterThanOrEqualTo: pushButton.trailingAnchor, constant: 6),
        ])
        tableTopToBranchToolbar.isActive = false
        tableBottomToContainer.isActive = false
        self.view = container
    }

    // MARK: - Data

    /// Re-apply the UI font after a settings change.
    func refreshFonts() {
        (view as? FlatView)?.fillColor = Theme.panelBackground
        branchToolbar.fillColor = Theme.panelBackground
        table.backgroundColor = Theme.panelBackground
        table.enclosingScrollView?.backgroundColor = Theme.panelBackground
        commitField.backgroundColor = Theme.activeTab
        commitScroll.backgroundColor = Theme.activeTab
        segmented.refreshAppearance()
        branchLabel.font = Theme.uiFont(10.5)
        commitField.font = Theme.uiFont(11)
        commitButton.font = Theme.uiFont(10.5)
        discardAllButton.font = Theme.uiFont(10.5)
        pushButton.font = Theme.uiFont(10.5)
        newBranchButton.font = Theme.uiFont(10.5)
        remoteButton.font = Theme.uiFont(10.5)
        table.reloadData()
        if table.numberOfRows > 0 {
            table.noteHeightOfRows(withIndexesChanged:
                IndexSet(integersIn: 0..<table.numberOfRows))
        }
    }

    func refresh() {
        requestRefresh(requireFollowUp: false)
    }

    /// External repository events and completed Git mutations must not be lost
    /// if they arrive while a snapshot is already being collected.
    func refreshExternal() {
        requestRefresh(requireFollowUp: true)
    }

    private enum RefreshPriority {
        case changes, branches, history
    }

    private func requestRefresh(requireFollowUp: Bool) {
        guard let directory else { return }
        if refreshInFlight {
            if refreshDirectory != directory || requireFollowUp {
                refreshAgain = true
            }
            return
        }
        refreshInFlight = true
        refreshDirectory = directory
        let priority: RefreshPriority = showingBranches
            ? .branches : (showingHistory ? .history : .changes)
        gitQueue.async { [weak self] in
            guard let self else { return }
            var status = GitService.status(in: directory)
            if status.isRepo,
               status.entries.contains(where: {
                   $0.isUntracked || $0.worktreeStatus != " " || $0.indexStatus == "A"
               }) {
                GitService.stageAll(in: directory)
                status = GitService.status(in: directory)
            }
            DispatchQueue.main.async {
                guard self.directory == directory else { return }
                self.applyStatus(status, in: directory)
                if !self.showingBranches && !self.showingHistory {
                    self.table.reloadData()
                }
            }

            let loadRemotes = {
                let remotes = GitService.remotes(in: directory)
                DispatchQueue.main.async {
                    guard self.directory == directory else { return }
                    self.remotes = remotes
                    self.rebuildPushMenu()
                }
            }
            let loadBranches = {
                let branches = GitService.branches(in: directory)
                DispatchQueue.main.async {
                    guard self.directory == directory else { return }
                    self.branches = branches
                    if self.showingBranches { self.table.reloadData() }
                }
            }
            let loadHistory = {
                let log = GitService.log(in: directory, limit: 40)
                let pending = GitService.unpushedHashes(in: directory)
                DispatchQueue.main.async {
                    guard self.directory == directory else { return }
                    self.history = log
                    self.unpushed = pending
                    self.rebuildHistoryRows()
                    if self.showingHistory { self.table.reloadData() }
                }
            }

            switch priority {
            case .changes:
                loadRemotes(); loadBranches(); loadHistory()
            case .branches:
                loadBranches(); loadRemotes(); loadHistory()
            case .history:
                loadHistory(); loadRemotes(); loadBranches()
            }

            DispatchQueue.main.async {
                self.refreshInFlight = false
                self.refreshDirectory = nil
                guard self.directory == directory else {
                    self.refreshAgain = false
                    self.refresh()
                    return
                }
                if self.refreshAgain {
                    self.refreshAgain = false
                    self.requestRefresh(requireFollowUp: false)
                }
            }
        }
    }

    /// Apply the cheap status snapshot independently of the slower history and
    /// remote refresh. Commit success uses this before a network push starts so
    /// Changes clears immediately even if that push later fails.
    private func applyStatus(_ status: GitService.Status, in directory: URL) {
        entries = status.entries
        var label = "\(directory.lastPathComponent) / \(status.branch)"
        // Who the next commit will be authored by, straight from git config.
        if !status.userName.isEmpty { label += " / \(status.userName)" }
        if status.ahead > 0 { label += "  ↑\(status.ahead)" }
        else if status.isRepo && !status.hasUpstream { label += "  (no upstream)" }
        branchLabel.stringValue = status.isRepo ? label : "not a git repository"
        branchLabel.toolTip = status.ahead > 0
            ? "\(status.ahead) commit\(status.ahead == 1 ? "" : "s") not pushed yet"
            : nil
        segmented.setLabel("Changes (\(status.entries.count))", forSegment: 0)
        discardAllButton.isEnabled = !status.entries.isEmpty
        aheadCount = status.ahead
        rebuildPushMenu()
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
        branchToolbarHeight.constant = branchTab ? 52 : 0
        tableTopToTabs.isActive = !branchTab
        tableTopToBranchToolbar.isActive = branchTab
        tableBottomToFooter.isActive = !branchTab
        tableBottomToContainer.isActive = branchTab
        branchLabel.isHidden = branchTab
        commitScroll.isHidden = branchTab
        progressShimmer.isHidden = branchTab || activeOperationID == nil
        commitButton.isHidden = branchTab
        discardAllButton.isHidden = branchTab
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
        alert.alertStyle = .warning
        alert.messageText = "Force-push the current branch?"
        alert.informativeText = "Repository:\n\(directory.path)\n\nThis can replace the remote branch history and make remote-only commits unreachable. Puzzle uses --force-with-lease, so Git will refuse if the remote changed since your last fetch."
        alert.addButton(withTitle: "Force Push")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runRemote("Force push") { GitService.forcePush(in: directory) }
    }

    /// Run a remote operation on the panel's serial Git queue and report the
    /// outcome without blocking subsequent UI refreshes behind a modal alert.
    private func runRemote(_ verb: String, _ work: @escaping () -> GitService.RemoteResult) {
        guard let operationDirectory = directory,
              let operationID = beginOperation(verb, lockCommitMessage: false) else { return }
        gitQueue.async { [weak self] in
            guard let self else { return }
            let result = work()
            DispatchQueue.main.async {
                guard self.activeOperationID == operationID else { return }
                self.finishOperation(operationID)
                guard self.directory == operationDirectory else { return }
                self.refreshExternal()
                self.onChanged?()
                if !result.ok {
                    self.presentOperationError(title: "\(verb) failed", message: result.message)
                }
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

        guard let operationID = beginOperation("Committing", lockCommitMessage: true) else { return }
        gitQueue.async { [weak self] in
            guard let self else { return }
            let commit = GitService.commit(message, in: directory)
            let postCommitStatus = commit.code == 0 ? GitService.status(in: directory) : nil
            DispatchQueue.main.async {
                guard self.activeOperationID == operationID else { return }
                guard self.directory == directory else {
                    self.finishOperation(operationID)
                    return
                }
                if commit.code != 0 {
                    self.finishOperation(operationID)
                    self.refreshExternal()
                    self.onChanged?()
                    self.presentOperationError(
                        title: "Commit failed",
                        message: commit.err.isEmpty ? commit.out : commit.err)
                    return
                }

                // Commit succeeded. Reflect the local repository state before
                // starting any network push, so Changes clears immediately.
                self.commitField.string = ""
                if let postCommitStatus {
                    self.applyStatus(postCommitStatus, in: directory)
                    self.table.reloadData()
                }
                self.onChanged?()
                if push {
                    self.continuePushAfterCommit(operationID: operationID,
                                                 directory: directory)
                } else {
                    self.finishOperation(operationID)
                    self.refreshExternal()
                }
            }
        }
    }

    private func continuePushAfterCommit(operationID: UUID, directory: URL) {
        transitionOperation(operationID, to: "Pushing")
        gitQueue.async { [weak self] in
            guard let self else { return }
            let result = GitService.push(in: directory)
            DispatchQueue.main.async {
                guard self.activeOperationID == operationID else { return }
                self.finishOperation(operationID)
                guard self.directory == directory else { return }
                self.refreshExternal()
                self.onChanged?()
                if !result.ok {
                    self.presentOperationError(title: "Committed, but push failed",
                                               message: result.message)
                }
            }
        }
    }

    private func beginOperation(_ label: String, lockCommitMessage: Bool) -> UUID? {
        guard activeOperationID == nil else {
            NSSound.beep()
            return nil
        }
        let id = UUID()
        activeOperationID = id
        operationLocksMessage = lockCommitMessage
        commitButton.isEnabled = false
        pushButton.isEnabled = false
        newBranchButton.isEnabled = false
        remoteButton.isEnabled = false
        table.isEnabled = false
        if lockCommitMessage { commitField.isEditable = false }
        progressShimmer.start(label: label)
        progressShimmer.isHidden = showingBranches
        return id
    }

    private func transitionOperation(_ id: UUID, to label: String) {
        guard activeOperationID == id else { return }
        progressShimmer.start(label: label)
    }

    private func finishOperation(_ id: UUID) {
        guard activeOperationID == id else { return }
        activeOperationID = nil
        commitButton.isEnabled = true
        pushButton.isEnabled = true
        newBranchButton.isEnabled = true
        remoteButton.isEnabled = true
        table.isEnabled = true
        if operationLocksMessage { commitField.isEditable = true }
        operationLocksMessage = false
        progressShimmer.stop()
    }

    private func presentOperationError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    @objc private func rowClicked() {
        let row = table.clickedRow
        guard row >= 0, let directory else { return }

        if showingBranches {
            // Only the explicit switch button may change branches. Selecting
            // or double-clicking the informational row is intentionally inert.
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
        let baseSelector = NSComboBox()
        baseSelector.isEditable = false
        baseSelector.completes = false
        baseSelector.usesDataSource = false
        baseSelector.addItems(withObjectValues: names)
        baseSelector.font = Theme.uiFont(10.5)
        baseSelector.itemHeight = max(
            20, ceil(Theme.uiFont(10.5).boundingRectForFont.height) + 6)
        // NSComboBox provides a scrolling list once the item count exceeds
        // numberOfVisibleItems. Reserve a few points for its list border so the
        // complete drop-down remains within the requested 300pt maximum.
        let maxVisibleItems = max(1, Int(floor((300 - 8) / baseSelector.itemHeight)))
        baseSelector.numberOfVisibleItems = min(names.count, maxVisibleItems)
        if let current = branches.firstIndex(where: { $0.isCurrent }) {
            baseSelector.selectItem(at: current)
        } else {
            baseSelector.selectItem(at: 0)
        }
        let accessory = dialogStack([
            labeledField("Name", nameField),
            labeledField("Base", baseSelector),
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
        let selectedBase = baseSelector.indexOfSelectedItem
        let base = names.indices.contains(selectedBase) ? names[selectedBase] : names[0]
        runRemote("Create branch") { GitService.createBranch(name, from: base, in: directory) }
    }

    @objc private func remoteAction() {
        guard let directory else { return }
        let currentRemotes = GitService.remotes(in: directory)
        let nameField = NSTextField(string: currentRemotes.first?.name ?? "origin")
        nameField.placeholderString = "Remote name"
        let fetchField = NSTextField(string: currentRemotes.first?.fetchURL ?? "")
        fetchField.placeholderString = "https://… or git@…"
        let pushField = NSTextField(string: currentRemotes.first?.pushURL ?? "")
        pushField.placeholderString = "Optional push URL"
        let accessory = dialogStack([
            labeledField("Name", nameField),
            labeledField("Fetch", fetchField),
            labeledField("Push", pushField),
        ], width: 420)

        let alert = NSAlert()
        alert.messageText = "Remote repositories"
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
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Switch to “\(branch.name)”?"
        let effect = branch.isRemote
            ? "A local tracking branch will be created, checked out, and the files in this working tree will be replaced with that branch's versions."
            : "The files in this working tree will be replaced with the versions from this branch. Git will refuse the switch if local changes cannot be preserved."
        alert.informativeText = "Project:\n\(directory.path)\n\n\(effect)"
        alert.addButton(withTitle: "Switch")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runRemote("Switch branch") { GitService.switchBranch(branch, in: directory) }
    }

    private func deleteBranch(_ branch: GitService.Branch, in directory: URL) {
        guard !branch.isCurrent else {
            presentGitError(title: "Cannot delete branch", message: "The current branch cannot be deleted.")
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete branch “\(branch.name)”?"
        alert.informativeText = branch.isRemote
            ? "Remote: \(branch.upstreamRemote ?? "unknown")\nProject: \(directory.path)\n\nThis deletes the branch from the remote repository for everyone. Commits reachable only from this branch may become difficult to recover."
            : "Project:\n\(directory.path)\n\nThis removes the local branch reference. Git permits this action only when the branch is fully merged; unmerged commits will not be deleted."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runRemote("Delete branch") { GitService.deleteBranch(branch, in: directory) }
    }

    private func presentGitError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.runModal()
    }

    @objc private func discardAllAction() {
        guard let directory else { return }
        discardAllChanges(in: directory)
    }

    /// Throw away every change in the project. Confirmed first, and the alert
    /// spells out what cannot be recovered: tracked files return to HEAD, and
    /// files Git has never seen are moved to the Trash.
    private func discardAllChanges(in directory: URL) {
        let entries = self.entries
        guard !entries.isEmpty else { return }
        let newFiles = entries.filter { GitService.discardRemovesFile($0, in: directory) }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = entries.count == 1
            ? "Discard the 1 change in this project?"
            : "Discard all \(entries.count) changes in this project?"
        var detail = "Project:\n\(directory.path)\n\n"
        detail += "Every uncommitted change, staged included, will be replaced with the "
            + "version in HEAD. Git cannot restore the discarded edits."
        if !newFiles.isEmpty {
            detail += "\n\n\(newFiles.count) file\(newFiles.count == 1 ? "" : "s") "
                + "never committed will be removed from Git and moved to Trash; "
                + "recovery is possible only while the item remains in Trash:\n"
            detail += newFiles.prefix(10).map { "• \($0.path)" }.joined(separator: "\n")
            if newFiles.count > 10 { detail += "\n• …and \(newFiles.count - 10) more" }
        }
        alert.informativeText = detail
        alert.addButton(withTitle: "Discard All Changes")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn,
              let operationID = beginOperation("Discarding all changes",
                                               lockCommitMessage: false) else { return }

        gitQueue.async { [weak self] in
            guard let self else { return }
            let result = GitService.discardAll(entries, in: directory)
            let status = GitService.status(in: directory)
            DispatchQueue.main.async {
                guard self.activeOperationID == operationID else { return }
                self.finishOperation(operationID)
                guard self.directory == directory else { return }
                self.applyStatus(status, in: directory)
                self.activeChangesPath = nil
                self.table.reloadData()
                self.onChanged?()
                self.refreshExternal()
                if let failure = result.failure {
                    self.presentOperationError(
                        title: "Discard all changes failed",
                        message: "\(result.discarded) of \(entries.count) discarded.\n\(failure)")
                }
            }
        }
    }

    private func discardChanges(_ entry: GitService.Status.Entry, in directory: URL) {
        let removesFile = GitService.discardRemovesFile(entry, in: directory)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard changes to “\(entry.path)”?"
        var affected = "File:\n\(directory.appendingPathComponent(entry.path).path)"
        if entry.code.contains("R"), let originalPath = entry.originalPath {
            affected += "\nOriginal path:\n\(directory.appendingPathComponent(originalPath).path)"
        }
        let consequence = removesFile
            ? "This file has no committed version. It will be removed from Git and moved to Trash. Puzzle cannot undo the action; recovery is possible only while the item remains in Trash."
            : "All uncommitted changes to this file, including staged changes, will be replaced with the version in HEAD. Git cannot restore the discarded edits."
        alert.informativeText = "\(affected)\n\n\(consequence)"
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn,
              let operationID = beginOperation("Discarding changes", lockCommitMessage: false) else {
            return
        }

        gitQueue.async { [weak self] in
            guard let self else { return }
            let result = GitService.discard(entry, in: directory)
            let status = result.ok ? GitService.status(in: directory) : nil
            DispatchQueue.main.async {
                guard self.activeOperationID == operationID else { return }
                self.finishOperation(operationID)
                guard self.directory == directory else { return }
                if let status {
                    self.applyStatus(status, in: directory)
                    if !status.entries.contains(where: { $0.path == entry.path }) {
                        self.activeChangesPath = nil
                    }
                    self.table.reloadData()
                    self.onChanged?()
                    self.refreshExternal()
                } else {
                    self.presentOperationError(title: "Discard changes failed",
                                               message: result.message)
                }
            }
        }
    }

    private func labeledField(_ label: String, _ field: NSView) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let labelField = NSTextField(labelWithString: label)
        labelField.font = Theme.uiFont(10.5)
        labelField.textColor = Theme.dimText
        labelField.translatesAutoresizingMaskIntoConstraints = false
        field.translatesAutoresizingMaskIntoConstraints = false
        (field as? NSControl)?.font = Theme.uiFont(10.5)
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

    // MARK: - Regression-test surface

    var discardAllEnabledForTesting: Bool {
        _ = view
        return discardAllButton.isEnabled
    }
    func discardAllForTesting(in directory: URL) { discardAllChanges(in: directory) }

    /// The line above the commit box: project, branch and commit author.
    var statusLabelForTesting: String {
        _ = view
        return branchLabel.stringValue
    }

    /// Distance from one file row to the next: its height plus the gap AppKit
    /// leaves between rows. Compared against the file tree's.
    var rowPitchForTesting: CGFloat {
        _ = view
        return Theme.treeRowHeight() + table.intercellSpacing.height
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
        if showingBranches { return GitBranchCell.preferredRowHeight }
        if showingHistory, row < historyRows.count,
           case .commit = historyRows[row] {
            let titleHeight = ceil(Theme.uiFont(11).boundingRectForFont.height)
            let infoHeight = ceil(Theme.uiFont(9.5).boundingRectForFont.height)
            return max(38, titleHeight + infoHeight + 7)
        }
        // File rows — Changes entries and the files inside an expanded commit —
        // are the same kind of row as the file tree's, so they take the same
        // `tree_line_height` instead of measuring their own font.
        return Theme.treeRowHeight()
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
        let entry = entries[row]
        cell.configure(entry: entry, onDiscard: { [weak self] in
            guard let self, let directory = self.directory else { return }
            self.discardChanges(entry, in: directory)
        })
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
        let detailFont = Theme.uiFont(9.5)
        let titleHeight = ceil(max(subjectFont.boundingRectForFont.height,
                                   metaFont.boundingRectForFont.height)) + 1
        let detailHeight = ceil(detailFont.boundingRectForFont.height) + 1
        let gap: CGFloat = 2
        let contentHeight = titleHeight + gap + detailHeight
        let top = floor((bounds.height - contentHeight) / 2)
        let titleBand = NSRect(x: 0, y: top, width: bounds.width, height: titleHeight)
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

        let blameBand = NSRect(x: 20, y: titleBand.maxY + gap,
                               width: max(0, bounds.width - 26),
                               height: detailHeight)
        SidebarCellDrawing.text(blame, font: detailFont, color: Theme.dimText,
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
    private let discardButton = NSButton()
    private var status = ""
    private var icon: SidebarIcon?
    private var name = ""
    private var folder = ""
    private var statusColor = NSColor.clear
    private var onDiscard: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        discardButton.title = ""
        discardButton.image = Theme.symbol(
            "arrow.uturn.backward", accessibilityDescription: "Discard file changes",
            pointSize: 11, weight: .medium)
        discardButton.imagePosition = .imageOnly
        discardButton.imageScaling = .scaleProportionallyDown
        discardButton.bezelStyle = .inline
        discardButton.isBordered = false
        discardButton.toolTip = "Discard file changes"
        discardButton.setAccessibilityLabel("Discard file changes")
        discardButton.target = self
        discardButton.action = #selector(discardAction)
        addSubview(discardButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(entry: GitService.Status.Entry, onDiscard: @escaping () -> Void) {
        self.onDiscard = onDiscard
        status = entry.displayCode
        statusColor = entry.isUntracked ? Theme.green : Theme.yellow
        icon = .file(URL(fileURLWithPath: entry.path))
        name = (entry.path as NSString).lastPathComponent
        folder = (entry.path as NSString).deletingLastPathComponent
        toolTip = entry.path
        exposeToAccessibility("Automatically staged \(entry.displayCode), \(entry.path)")
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        // A small tree_line_height can leave the row shorter than the button.
        let side = min(24, floor(bounds.height))
        discardButton.frame = NSRect(x: max(0, bounds.width - 6 - side),
                                     y: floor((bounds.height - side) / 2),
                                     width: side, height: side)
    }

    override func draw(_ dirtyRect: NSRect) {
        SidebarCellDrawing.text(status, font: Theme.uiFont(10), color: statusColor,
                                in: NSRect(x: 6, y: 0, width: 18, height: bounds.height),
                                alignment: .center)
        SidebarCellDrawing.icon(icon,
                                in: NSRect(x: 26, y: floor((bounds.height - 13) / 2),
                                           width: 13, height: 13))
        SidebarCellDrawing.primaryAndSecondary(
            primary: name, primaryFont: Theme.uiFont(11), primaryColor: Theme.foreground,
            secondary: folder, secondaryFont: Theme.uiFont(9.5), secondaryColor: Theme.dimText,
            in: NSRect(x: 44, y: 0,
                       width: max(0, bounds.width - 78), height: bounds.height),
            gap: 5, primaryLineBreak: .byTruncatingMiddle)
    }

    @objc private func discardAction() { onDiscard?() }
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
        switchButton.title = ""
        switchButton.image = Theme.symbol("arrow.right.circle", accessibilityDescription: "Switch branch",
                                          pointSize: 12)
        switchButton.imagePosition = .imageOnly
        switchButton.imageScaling = .scaleProportionallyDown
        switchButton.bezelStyle = .inline
        switchButton.isBordered = false
        switchButton.toolTip = "Switch branch"
        switchButton.setAccessibilityLabel("Switch branch")
        switchButton.target = self
        switchButton.action = #selector(switchAction)
        switchButton.translatesAutoresizingMaskIntoConstraints = false

        deleteButton.title = ""
        deleteButton.image = Theme.symbol("trash", accessibilityDescription: "Delete branch",
                                          pointSize: 12)
        deleteButton.imagePosition = .imageOnly
        deleteButton.imageScaling = .scaleProportionallyDown
        deleteButton.bezelStyle = .inline
        deleteButton.isBordered = false
        deleteButton.toolTip = "Delete branch"
        deleteButton.setAccessibilityLabel("Delete branch")
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
        let totalWidth = Self.actionButtonWidth * 2 + Self.actionButtonGap
        let x = max(8, bounds.width - totalWidth - 8)
        let y = floor((bounds.height - Self.actionButtonHeight) / 2)
        switchButton.frame = NSRect(x: x, y: y,
                                    width: Self.actionButtonWidth,
                                    height: Self.actionButtonHeight)
        deleteButton.frame = NSRect(x: x + Self.actionButtonWidth + Self.actionButtonGap,
                                    y: y,
                                    width: Self.actionButtonWidth,
                                    height: Self.actionButtonHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let primaryFont = Theme.uiFont(11)
        let secondaryFont = Theme.uiFont(9.5)
        let primaryHeight = ceil(primaryFont.boundingRectForFont.height) + 1
        let secondaryHeight = ceil(secondaryFont.boundingRectForFont.height) + 1
        let textHeight = primaryHeight + Self.textLineGap + secondaryHeight
        let top = floor((bounds.height - textHeight) / 2)
        let buttonX = max(8, bounds.width - (Self.actionButtonWidth * 2
                                             + Self.actionButtonGap) - 8)
        let width = max(0, buttonX - 16)
        SidebarCellDrawing.text(
            name, font: primaryFont,
            color: isCurrent ? Theme.cursor : Theme.foreground,
            in: NSRect(x: 8, y: top, width: width, height: primaryHeight),
            lineBreak: .byTruncatingMiddle)
        SidebarCellDrawing.text(
            metadata, font: secondaryFont, color: Theme.dimText,
            in: NSRect(x: 8, y: top + primaryHeight + Self.textLineGap,
                       width: width, height: secondaryHeight),
            lineBreak: .byTruncatingTail)
    }

    static var preferredRowHeight: CGFloat {
        let primaryHeight = ceil(Theme.uiFont(11).boundingRectForFont.height) + 1
        let secondaryHeight = ceil(Theme.uiFont(9.5).boundingRectForFont.height) + 1
        let textHeight = primaryHeight + textLineGap + secondaryHeight
        return max(44, max(textHeight, actionButtonHeight) + 8)
    }

    private static let actionButtonWidth: CGFloat = 26
    private static let actionButtonHeight: CGFloat = 26
    private static let actionButtonGap: CGFloat = 6
    private static let textLineGap: CGFloat = 0

    @objc private func switchAction() { onSwitch?() }
    @objc private func deleteAction() { onDelete?() }
}

/// Two-state tab strip with the same full-height selection treatment as the
/// bottom action bar. Native buttons preserve keyboard and VoiceOver behavior.
private final class FlatPanelTabBar: NSView {
    override var isFlipped: Bool { true }
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
    override var isFlipped: Bool { true }
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

/// Thin animated progress band pinned to the commit editor's top border. It is
/// deliberately indeterminate because hooks and network pushes expose no useful
/// percentage through the Git CLI.
private final class GitProgressShimmerView: NSView {
    private var timer: Timer?
    private var phase: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
    }

    required init?(coder: NSCoder) { fatalError() }

    func start(label: String) {
        setAccessibilityLabel(label)
        isHidden = false
        guard timer == nil else { return }
        phase = 0
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.phase = (self.phase + 0.015).truncatingRemainder(dividingBy: 1)
            self.needsDisplay = true
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isHidden = true
        needsDisplay = true
    }

    deinit { timer?.invalidate() }

    override func draw(_ dirtyRect: NSRect) {
        Theme.border.setFill()
        bounds.fill()
        let sweepWidth = max(48, bounds.width * 0.24)
        let travel = bounds.width + sweepWidth
        let x = -sweepWidth + travel * phase
        let colors = [
            Theme.cursor.withAlphaComponent(0),
            Theme.cursor.withAlphaComponent(0.95),
            Theme.cursor.withAlphaComponent(0),
        ]
        NSGradient(colors: colors)?.draw(
            in: NSRect(x: x, y: 0, width: sweepWidth, height: bounds.height), angle: 0)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
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

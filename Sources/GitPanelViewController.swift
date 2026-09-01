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
    /// False once everything local is on the remote, which is when Push has
    /// nothing left to do.
    private var pushIsPossible: Bool { aheadCount > 0 || !hasUpstream }
    private var hasUpstream = true
    /// A commit needs both something to commit and something to say about it.
    /// Either missing and the button says so by being unavailable, rather than
    /// accepting the click and answering with an alert.
    private var commitIsPossible: Bool { hasChanges && !trimmedCommitMessage.isEmpty }
    private var hasChanges = false
    private var trimmedCommitMessage: String {
        commitField.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// What the table was last built from, so a refresh that changes nothing
    /// does not rebuild the rows out from under a click.
    private var renderedEntries: [GitService.Status.Entry] = []
    private var renderedActiveChangesPath: String?
    private var renderedActiveCommitFile: String?
    private var reloadDeferred = false

    private let segmented = FlatPanelTabBar(labels: ["Changes", "Branch", "History"])
    private let table = GitTableView()
    private let branchLabel = NSTextField(labelWithString: "")
    private let commitField = CommitMessageTextView()
    private var commitScroll: HorizontalBorderScrollView!
    private let progressShimmer = GitProgressShimmerView()
    private let commitButton = NSButton()
    /// Discards every change in the project — confirmed before it runs.
    private let discardAllButton = NSButton()
    /// Push and its menu are one control with two targets: a segmented control
    /// draws them joined, and AppKit routes the label to the action and the
    /// chevron to the menu attached to that segment.
    private let pushControl = BadgeButton()
    /// The arrow beside Push: everything that is not the common case.
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
        hasChanges = false
        if isViewLoaded {
            branchLabel.stringValue = "Loading Git status…"
            segmented.setLabel("Changes", forSegment: 0)
            refreshPushButton()
            refreshCommitButton()
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
        // `.automatic` resolves to the inset style, which pads the top of the
        // list by 10pt and rounds its rows — so the first row sat further from
        // the toolbar above it than the toolbar sat from the tabs. The file
        // tree already uses the plain style; the panel now matches.
        table.style = .plain
        table.backgroundColor = Theme.panelBackground
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.contextMenuProvider = { [weak self] row in self?.contextMenu(forRow: row) }
        table.usesAlternatingRowBackgroundColors = false

        let scroll = NSScrollView()
        PuzzleScroller.adopt(scroll)
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
        commitField.placeholder = "Commit message  (⌘↩ to commit)"
        commitField.onCommitShortcut = { [weak self] in
            // ⌘↩ obeys the same rule the button does; there is nothing to
            // explain in an alert that the disabled button has not said.
            guard let self, self.commitIsPossible, self.activeOperationID == nil else {
                NSSound.beep()
                return
            }
            self.commit()
        }
        commitField.onTextChange = { [weak self] in self?.refreshCommitButton() }
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

        // Push is the common case, so it is one click on its own button; the
        // arrow beside it holds Commit & Push, Fetch, Pull and Force Push.
        pushControl.title = "Push"
        pushControl.toolTip = "Push the current branch"
        pushControl.setAccessibilityLabel("Push")
        pushControl.onClick = { [weak self] in self?.pushAction() }
        pushControl.translatesAutoresizingMaskIntoConstraints = false
        refreshPushButton()
        refreshCommitButton()

        [segmented, branchToolbar, scroll, branchLabel, commitScroll, progressShimmer,
         commitButton, pushControl,
         discardAllButton].forEach { container.addSubview($0) }

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

            // Push (with its menu) left, "Commit" right.
            pushControl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            pushControl.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            commitButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            commitButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),

            // Discard sits just before Commit, both anchored to the right.
            discardAllButton.trailingAnchor.constraint(
                equalTo: commitButton.leadingAnchor, constant: -6),
            discardAllButton.bottomAnchor.constraint(
                equalTo: container.bottomAnchor, constant: -8),
            discardAllButton.leadingAnchor.constraint(
                greaterThanOrEqualTo: pushControl.trailingAnchor, constant: 6),
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
        pushControl.invalidateIntrinsicContentSize()
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
                    self.reloadRows()
                }
            }

            let loadRemotes = {
                let remotes = GitService.remotes(in: directory)
                DispatchQueue.main.async {
                    guard self.directory == directory else { return }
                    self.remotes = remotes
                    self.refreshPushButton()
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

    /// Rebuild the rows only when they would come out different, and never
    /// while the mouse is down inside the panel.
    ///
    /// `reloadData` throws away the row views, and with them any button that is
    /// mid-click: a refresh landing between mouse-down and mouse-up swallowed
    /// the click. Git and file-system events fire constantly (a build alone
    /// produces a stream of them), which is why the row buttons worked only
    /// some of the time.
    private func reloadRows(force: Bool = false) {
        guard isViewLoaded else { return }
        guard force || rowsNeedReload else { return }
        guard NSEvent.pressedMouseButtons == 0 else {
            guard !reloadDeferred else { return }
            reloadDeferred = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self else { return }
                self.reloadDeferred = false
                self.reloadRows(force: true)
            }
            return
        }
        renderedEntries = entries
        renderedActiveChangesPath = activeChangesPath
        renderedActiveCommitFile = activeCommitFile.map { "\($0.commit):\($0.path)" }
        table.reloadData()
    }

    /// True when what is on screen no longer matches the model.
    private var rowsNeedReload: Bool {
        if showingBranches || showingHistory { return true }
        if renderedEntries != entries { return true }
        if renderedActiveChangesPath != activeChangesPath { return true }
        let commitKey = activeCommitFile.map { "\($0.commit):\($0.path)" }
        return renderedActiveCommitFile != commitKey
    }

    /// Apply the cheap status snapshot independently of the slower history and
    /// remote refresh. Commit success uses this before a network push starts so
    /// Changes clears immediately even if that push later fails.
    private func applyStatus(_ status: GitService.Status, in directory: URL) {
        entries = status.entries
        var label = "\(directory.lastPathComponent) / \(status.branch)"
        // Who the next commit will be authored by, straight from git config.
        if !status.userName.isEmpty { label += " / \(status.userName)" }
        // What is waiting to be pushed belongs on the Push button, not here.
        if status.isRepo, !status.hasUpstream { label += "  (no upstream)" }
        branchLabel.stringValue = status.isRepo ? label : "not a git repository"
        branchLabel.toolTip = status.ahead > 0
            ? "\(status.ahead) commit\(status.ahead == 1 ? "" : "s") not pushed yet"
            : nil
        segmented.setLabel("Changes",
                           badge: status.entries.isEmpty ? "" : "\(status.entries.count)",
                           forSegment: 0)
        discardAllButton.isEnabled = !status.entries.isEmpty
        hasChanges = !status.entries.isEmpty
        aheadCount = status.ahead
        hasUpstream = status.hasUpstream
        refreshCommitButton()
        refreshPushButton()
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
        // Committing belongs to Changes. Branch and History are lists to read,
        // so they give the whole panel to their list.
        let listOnly = showingBranches || showingHistory
        branchToolbar.isHidden = !branchTab
        branchToolbarHeight.constant = branchTab ? 52 : 0
        tableTopToTabs.isActive = !branchTab
        tableTopToBranchToolbar.isActive = branchTab
        tableBottomToFooter.isActive = !listOnly
        tableBottomToContainer.isActive = listOnly
        branchLabel.isHidden = listOnly
        commitScroll.isHidden = listOnly
        progressShimmer.isHidden = listOnly || activeOperationID == nil
        commitButton.isHidden = listOnly
        discardAllButton.isHidden = listOnly
        pushControl.isHidden = listOnly
    }

    @objc private func commit() { performCommit(push: false) }

    /// How much is waiting rides on the button as a badge, the same shape the
    /// Changes tab and the activity bar use for their counts.
    private func refreshCommitButton() {
        // Never enable anything while an operation owns the panel.
        commitButton.isEnabled = activeOperationID == nil && commitIsPossible
        commitButton.toolTip = commitIsPossible ? nil
            : (hasChanges ? "Describe the change to commit it"
                          : "Nothing to commit")
    }

    private func refreshPushButton() {
        pushControl.badge = aheadCount > 0 ? "\(aheadCount)" : ""
        // Nothing to push, nothing to do. A branch with no upstream is the
        // exception: pushing is what sets one up.
        pushControl.isEnabled = pushIsPossible
        pushControl.toolTip = aheadCount > 0
            ? "\(aheadCount) commit\(aheadCount == 1 ? "" : "s") to push"
            : "Push the current branch"
        pushControl.invalidateIntrinsicContentSize()
    }

    @objc private func pushAction() {
        guard let directory else { return }
        runRemote("Push") { GitService.push(in: directory) }
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
                self.refreshCommitButton()
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
        pushControl.isEnabled = false
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
        refreshCommitButton()
        pushControl.isEnabled = pushIsPossible
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

    /// Switch to the Branch tab programmatically.
    func showBranchTab() {
        _ = view
        segmented.selectedSegment = 1
        tabChanged()
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

    /// Right-click menu for a row. Replaces the buttons that used to sit at the
    /// end of each row: they crowded long names, and every row carried them
    /// whether or not the pointer was anywhere near.
    private func contextMenu(forRow row: Int) -> NSMenu? {
        guard let directory else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false

        if showingBranches {
            guard row < branches.count else { return nil }
            let branch = branches[row]
            add(to: menu, title: "Switch to “\(branch.name)”", enabled: !branch.isCurrent) {
                [weak self] in self?.switchBranch(branch, in: directory)
            }
            menu.addItem(.separator())
            add(to: menu, title: branch.isRemote ? "Delete Remote Branch…" : "Delete Branch…",
                enabled: !branch.isCurrent) {
                [weak self] in self?.deleteBranch(branch, in: directory)
            }
            return menu
        }

        if showingHistory {
            guard row < historyRows.count else { return nil }
            switch historyRows[row] {
            case .commit(let commit, _):
                add(to: menu, title: "Copy Commit Hash") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(commit.shortHash, forType: .string)
                }
                add(to: menu, title: "Copy Commit Message") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(commit.subject, forType: .string)
                }
            case .file(let file, let commit):
                add(to: menu, title: "Show Changes in This Commit") { [weak self] in
                    self?.onOpenCommitDiff?(commit, file, directory)
                }
                add(to: menu, title: "Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(file.path, forType: .string)
                }
            }
            return menu
        }

        guard row < entries.count else { return nil }
        let entry = entries[row]
        let fileURL = directory.appendingPathComponent(entry.path)
        add(to: menu, title: "Show Changes") { [weak self] in
            self?.onOpenDiff?(entry, directory)
        }
        add(to: menu, title: "Open File") { [weak self] in
            self?.onOpenFile?(fileURL)
        }
        menu.addItem(.separator())
        add(to: menu, title: "Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.path, forType: .string)
        }
        add(to: menu, title: "Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        }
        menu.addItem(.separator())
        add(to: menu, title: "Discard Changes…") { [weak self] in
            self?.discardChanges(entry, in: directory)
        }
        return menu
    }

    private func add(to menu: NSMenu, title: String, enabled: Bool = true,
                     action: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(runMenuAction(_:)),
                              keyEquivalent: "")
        item.target = self
        item.representedObject = MenuAction(run: action)
        item.isEnabled = enabled
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

    /// Rows rebuilt since the last check — the count a refresh must not raise
    /// when nothing changed.
    var reloadWouldRebuildForTesting: Bool { rowsNeedReload }
    var rowCountForTesting: Int { table.numberOfRows }
    /// What a row puts at each end of its single line, and what hovering it
    /// reveals.
    func rowTextForTesting(_ row: Int) -> (leading: String, trailing: String, hover: String) {
        guard let view = tableView(table, viewFor: nil, row: row) else { return ("", "", "") }
        if let cell = view as? GitCommitCell {
            return (cell.subjectForTesting, cell.metaForTesting, cell.toolTipForTesting)
        }
        if let cell = view as? GitBranchCell {
            return (cell.nameForTesting, cell.metadataForTesting, cell.toolTip ?? "")
        }
        return ("", "", "")
    }
    func applyStatusForTesting(_ status: GitService.Status, in directory: URL) {
        _ = view
        applyStatus(status, in: directory)
        reloadRows()
    }

    var discardAllEnabledForTesting: Bool {
        _ = view
        return discardAllButton.isEnabled
    }
    var commitEnabledForTesting: Bool {
        _ = view
        return commitButton.isEnabled
    }
    func setCommitMessageForTesting(_ message: String) {
        _ = view
        commitField.string = message
    }
    func discardAllForTesting(in directory: URL) { discardAllChanges(in: directory) }

    /// The line above the commit box: project, branch and commit author.
    /// Push's label, its menu, and the tab's own count — the three places a
    /// number is allowed to appear.
    var pushLabelForTesting: String {
        _ = view
        return pushControl.title
    }
    /// Point the panel at a directory without kicking off a refresh, so a test
    /// controls exactly what the model holds.
    func setDirectoryForTesting(_ url: URL) {
        _ = view
        directory = url
    }

    /// The commit box and its buttons, which only Changes shows.
    var footerVisibleForTesting: Bool {
        _ = view
        return !commitScroll.isHidden && !commitButton.isHidden && !pushControl.isHidden
    }
    func showChangesForTesting() {
        _ = view
        segmented.selectedSegment = 0
        tabChanged()
    }
    func showHistoryForTesting() {
        _ = view
        segmented.selectedSegment = 2
        tabChanged()
    }
    /// The lane diagram behind the History rows.
    var historyRefsForTesting: [String] { history.map(\.refs) }
    var historyRowIsCommitForTesting: [Bool] {
        historyRows.map { if case .commit = $0 { return true } else { return false } }
    }

    static var selectedTabColoursForTesting: (surface: NSColor, ink: NSColor) {
        (Theme.selectedControl, Theme.selectedControlText)
    }

    var listStyleForTesting: NSTableView.Style {
        _ = view
        return table.style
    }
    var firstRowRectForTesting: NSRect {
        _ = view
        table.layoutSubtreeIfNeeded()
        return table.numberOfRows > 0 ? table.rect(ofRow: 0) : .zero
    }

    var listScrollInsetsForTesting: NSEdgeInsets {
        _ = view
        return table.enclosingScrollView?.contentInsets ?? NSEdgeInsets()
    }
    var listAdjustsInsetsForTesting: Bool {
        _ = view
        return table.enclosingScrollView?.automaticallyAdjustsContentInsets ?? true
    }

    func rowHeightForTesting(_ row: Int) -> CGFloat {
        _ = view
        return tableView(table, heightOfRow: row)
    }

    func contextMenuForTesting(row: Int) -> NSMenu? {
        _ = view
        return contextMenu(forRow: row)
    }
    /// True when the row lights up under the pointer.
    func hoverForTesting(row: Int) -> Bool {
        _ = view
        table.layoutSubtreeIfNeeded()
        guard row >= 0, row < table.numberOfRows else { return false }
        table.setHoveredRowForTesting(row)
        return (table.rowView(atRow: row, makeIfNecessary: true) as? GitRowView)?
            .isHovered ?? false
    }

    var pushBadgeForTesting: String {
        _ = view
        return pushControl.badge
    }
    var pushEnabledForTesting: Bool {
        _ = view
        return pushControl.isEnabled
    }
    func clickPushForTesting() -> Bool {
        _ = view
        return pushControl.clickForTesting()
    }
    var changesTabLabelForTesting: String {
        _ = view
        return segmented.labelForTesting(at: 0)
    }
    var changesTabBadgeForTesting: String {
        _ = view
        return segmented.badgeForTesting(at: 0)
    }

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
        view.isHovered = table.hoveredRow == row
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
        // Every row in the panel is one `tree_line_height`, the unit the file
        // tree uses. Branches and commits used to stack their metadata on a
        // second line; it sits at the end of the same line instead, so a list
        // of them scans like every other list in the sidebar.
        Theme.treeRowHeight()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if showingBranches {
            guard row < branches.count else { return nil }
            let id = NSUserInterfaceItemIdentifier("git-branch-cell")
            let cell = (tableView.makeView(withIdentifier: id, owner: self)
                        as? GitBranchCell) ?? GitBranchCell()
            cell.identifier = id
            let branch = branches[row]
            cell.configure(branch: branch)
            return cell
        }
        if showingHistory {
            guard row < historyRows.count else { return nil }
            switch historyRows[row] {
            case .commit(let commit, _):
                let id = NSUserInterfaceItemIdentifier("git-commit-cell")
                let cell = (tableView.makeView(withIdentifier: id, owner: self)
                            as? GitCommitCell) ?? GitCommitCell()
                cell.identifier = id
                cell.configure(commit: commit, pending: isUnpushed(commit.shortHash))
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
        cell.configure(entry: entry)
        return cell
    }
}

private final class GitCommitCell: DrawnSidebarCell {
    private var subject = ""
    private var author = ""
    private var date = ""
    private var metaColor = NSColor.clear

    func configure(commit: GitService.Commit, pending: Bool) {
        subject = commit.subject
        // The name gives way before the timestamp does: a truncated name still
        // reads, a truncated date does not.
        author = pending ? "↑  " + commit.author : commit.author
        date = commit.absoluteDate
        // Unpushed commits are the reason Push is enabled, so they still have
        // to be tellable apart at a glance — the arrow rides with the metadata
        // rather than taking room from the subject.
        metaColor = pending ? Theme.cursor : Theme.dimText
        // One line can only carry so much. Everything the row had to drop —
        // the commit id, where a branch or tag points — is one hover away.
        var details = [commit.shortHash, commit.subject, commit.blameSummary]
        if !commit.refLabels.isEmpty { details.insert(commit.refLabels.joined(separator: ", "), at: 1) }
        if pending { details.append("not pushed") }
        toolTip = details.joined(separator: "\n")
        exposeToAccessibility("\(pending ? "Unpushed " : "")commit \(commit.shortHash), "
                                + "\(commit.subject), \(commit.author), \(commit.absoluteDate)")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        SidebarCellDrawing.leadingAndTrailing(
            leading: subject, leadingFont: Theme.uiFont(11), leadingColor: Theme.foreground,
            trailing: author, trailingFont: Theme.uiFont(9.5), trailingColor: metaColor,
            trailingPinned: date,
            in: NSRect(x: 8, y: 0, width: max(0, bounds.width - 16), height: bounds.height))
    }

    var subjectForTesting: String { subject }
    var metaForTesting: String { "\(author)  ·  \(date)" }
    var toolTipForTesting: String { toolTip ?? "" }
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
        // Indented under the commit it belongs to, which is what says these
        // rows are its files now that no lane is drawn behind them.
        SidebarCellDrawing.text(status, font: Theme.uiFont(10), color: statusColor,
                                in: NSRect(x: 18, y: 0, width: 14, height: bounds.height),
                                alignment: .center)
        let textX: CGFloat = 38
        SidebarCellDrawing.primaryAndSecondary(
            primary: name, primaryFont: Theme.uiFont(11), primaryColor: Theme.foreground,
            secondary: folder, secondaryFont: Theme.uiFont(9.5), secondaryColor: Theme.dimText,
            in: NSRect(x: textX, y: 0, width: max(0, bounds.width - textX - 6),
                       height: bounds.height))
    }
}

/// Test seam: the row type is private, so expose a probe that builds one.
final class GitChangeCellProbe: NSView {
    private let cell = GitChangeCell()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(cell)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        cell.frame = bounds
        cell.layoutSubtreeIfNeeded()
    }

    func configureProbe(path: String) {
        cell.configure(entry: GitService.Status.Entry(code: " M", path: path, originalPath: nil))
    }

    var nameForTesting: String { cell.nameForTesting }
}

private final class GitChangeCell: DrawnSidebarCell {
    private var status = ""
    private var icon: SidebarIcon?
    private var name = ""
    private var folder = ""
    private var statusColor = NSColor.clear

    func configure(entry: GitService.Status.Entry) {
        status = entry.displayCode
        statusColor = entry.isUntracked ? Theme.green : Theme.yellow
        icon = .file(URL(fileURLWithPath: entry.path))
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
        SidebarCellDrawing.icon(icon,
                                in: NSRect(x: 26, y: floor((bounds.height - 13) / 2),
                                           width: 13, height: 13))
        // The whole row is the name's now that the buttons have moved to the
        // context menu.
        SidebarCellDrawing.primaryAndSecondary(
            primary: name, primaryFont: Theme.uiFont(11), primaryColor: Theme.foreground,
            secondary: folder, secondaryFont: Theme.uiFont(9.5), secondaryColor: Theme.dimText,
            in: NSRect(x: 44, y: 0, width: max(0, bounds.width - 52), height: bounds.height),
            gap: 5, primaryLineBreak: .byTruncatingMiddle)
    }

    var nameForTesting: String { name }
}

private final class GitBranchCell: DrawnSidebarCell {
    private var name = ""
    private var author = ""
    private var date = ""
    private var metadata = ""
    private var isCurrent = false

    func configure(branch: GitService.Branch) {
        name = branch.isCurrent ? "\(branch.name)  · current" : branch.name
        author = branch.author
        date = branch.createdAt
        metadata = "\(branch.author)  ·  \(branch.createdAt)"
        isCurrent = branch.isCurrent
        // A name that had to be truncated is worth reading in full.
        toolTip = "\(branch.name)\n\(metadata)"
        exposeToAccessibility("Branch \(branch.name), \(metadata)")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Switch and delete moved to the row's context menu, so the name has
        // the full width up to its metadata.
        SidebarCellDrawing.leadingAndTrailing(
            leading: name, leadingFont: Theme.uiFont(11),
            leadingColor: isCurrent ? Theme.cursor : Theme.foreground,
            trailing: author, trailingFont: Theme.uiFont(9.5),
            trailingColor: Theme.dimText, trailingPinned: date,
            in: NSRect(x: 8, y: 0, width: max(0, bounds.width - 16), height: bounds.height),
            leadingLineBreak: .byTruncatingMiddle)
    }

    var nameForTesting: String { name }
    var metadataForTesting: String { metadata }
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

    func setLabel(_ label: String, badge: String = "", forSegment index: Int) {
        guard buttons.indices.contains(index) else { return }
        buttons[index].title = label
        buttons[index].badge = badge
        buttons[index].needsDisplay = true
    }

    func refreshAppearance() {
        needsDisplay = true
        buttons.forEach { $0.needsDisplay = true }
    }

    func labelForTesting(at index: Int) -> String {
        buttons.indices.contains(index) ? buttons[index].title : ""
    }
    func badgeForTesting(at index: Int) -> String {
        buttons.indices.contains(index) ? buttons[index].badge : ""
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
        didSet { setAccessibilityLabel(accessibilityText); needsDisplay = true }
    }
    /// Count shown as a pill after the title. Empty hides it.
    var badge = "" {
        didSet {
            guard badge != oldValue else { return }
            setAccessibilityLabel(accessibilityText)
            needsDisplay = true
        }
    }
    private var accessibilityText: String { badge.isEmpty ? title : "\(title), \(badge)" }
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
            Theme.selectedControl.setFill()
            bounds.fill()
        }
        let font = Theme.uiFont(11)
        let ink = isSelected ? Theme.selectedControlText : Theme.dimText
        SidebarCellDrawing.attributedText(
            SidebarCellDrawing.labelWithBadge(
                title, badge: badge, font: font, colour: ink,
                badgeBackground: Theme.activeRow, badgeForeground: Theme.foreground,
                alignment: .center),
            in: bounds)
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
/// The Git panel's list. Tracks the row under the pointer so rows can light up
/// like the file tree's, and hands right-clicks to the panel.
final class GitTableView: NSTableView {
    var contextMenuProvider: ((Int) -> NSMenu?)?
    private var hoverTrackingArea: NSTrackingArea?
    private(set) var hoveredRow = -1

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard hoverTrackingArea == nil else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { updateHoveredRow(with: event) }
    override func mouseMoved(with event: NSEvent) { updateHoveredRow(with: event) }
    override func mouseExited(with event: NSEvent) { setHoveredRow(-1) }

    override func layout() {
        super.layout()
        refreshHoverState()
    }

    func refreshHoverState() {
        guard let window else {
            setHoveredRow(-1)
            return
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setHoveredRow(bounds.contains(point) ? row(at: point) : -1)
    }

    private func updateHoveredRow(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setHoveredRow(bounds.contains(point) ? row(at: point) : -1)
    }

    func setHoveredRowForTesting(_ row: Int) { setHoveredRow(row) }

    private func setHoveredRow(_ row: Int) {
        let next = row >= 0 && row < numberOfRows ? row : -1
        guard next != hoveredRow else { return }
        let previous = hoveredRow
        hoveredRow = next
        for index in [previous, next] where index >= 0 {
            (rowView(atRow: index, makeIfNecessary: false) as? GitRowView)?
                .isHovered = index == next
        }
    }

    /// Right-click targets the row under the pointer without selecting it.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        guard row >= 0 else { return nil }
        return contextMenuProvider?(row)
    }
}

final class GitRowView: NSTableRowView {
    var isActiveFile = false
    var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            needsDisplay = true
        }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        Theme.panelBackground.setFill()
        bounds.fill()
        if isActiveFile {
            Theme.activeRow.setFill()
            bounds.fill()
        } else if isHovered {
            Theme.hover.setFill()
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

/// The commit box. Two things a plain NSTextView does not do: show a hint while
/// it is empty, and treat ⌘↩ as "commit" the way every Git client does.
final class CommitMessageTextView: NSTextView {
    var placeholder = "" { didSet { needsDisplay = true } }
    var onCommitShortcut: (() -> Void)?
    /// Typing changes whether there is anything to commit.
    var onTextChange: (() -> Void)?

    override func didChangeText() {
        super.didChangeText()
        onTextChange?()
    }

    /// Setting the text in code — clearing it after a commit — is not a user
    /// edit, so AppKit posts nothing. The panel still has to hear about it.
    override var string: String {
        get { super.string }
        set {
            super.string = newValue
            onTextChange?()
        }
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == [.command], event.keyCode == 36 || event.keyCode == 76 {
            onCommitShortcut?()
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? Theme.uiFont(11),
            .foregroundColor: Theme.dimText,
        ]
        let origin = NSPoint(x: textContainerInset.width + 5,
                             y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: attributes)
    }
}

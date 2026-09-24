import AppKit

/// One window: its projects down the side, and the diffs opened from them.
/// Several of these can exist at once (⌘N).
///
/// Menu items use `target: nil`, so AppKit routes each action down the responder
/// chain to the *key* window's controller — that's what makes the menus act on
/// whichever window is frontmost.
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate {
    let sidebar = SidebarViewController()
    let diffs = DiffPaneViewController()
    private let resizeHandles = WindowResizeHandleView()
    private var root: RootViewController!
    private(set) var projectURL: URL?
    private var gitRepositoryMonitor: GitRepositoryMonitor?
    private var workspaceFileMonitor: WorkspaceFileMonitor?
    private let gitSummaryQueue = DispatchQueue(
        label: "app.gift.workspace-git-summary", qos: .utility)
    private var gitRefreshGeneration = 0
    private var gitSummaryRefreshInFlight = false
    private var gitSummaryRefreshAgain = false
    private var gitSummaryDirectory: URL?
    /// The generation the refresh in flight was started under. Clearing the
    /// project moves `gitRefreshGeneration` on, which means that refresh's
    /// result will be thrown away when it lands.
    private var gitSummaryGeneration = 0
    /// Branch currently checked out, as last reported by the Git refresh.
    private var currentBranchName: String?
    /// Whether the project on screen is a repository. Nil until its first
    /// refresh has said.
    private var isRepository: Bool?
    private(set) var trafficLightTopInset = (DiffTabBar.defaultRowHeight - 14) / 2
    private(set) var trafficLightHeight: CGFloat = 14

    /// Called when the window closes, so the app can drop its reference.
    var onClose: ((WorkspaceWindowController) -> Void)?

    /// Initial outer-window frame: full usable display height, two-thirds of
    /// its usable width, centered. `visibleFrame` respects the menu bar and
    /// whichever edge currently contains the Dock.
    static func defaultWindowFrame(in visibleFrame: NSRect) -> NSRect {
        let width = floor(visibleFrame.width * 2 / 3)
        return NSRect(
            x: floor(visibleFrame.midX - width / 2),
            y: visibleFrame.minY,
            width: width,
            height: visibleFrame.height)
    }

    init() {
        let root = RootViewController(sidebar: sidebar, diffs: diffs)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init(window: window)
        self.root = root

        window.title = "Gift"
        // Gift only draws SDR sRGB colours. On wide-gamut/HDR displays the
        // default can otherwise promote large backing surfaces to 16-bit float.
        window.colorSpace = .sRGB
        // Do not retain both old and new full-size surfaces throughout a live
        // resize; redraw from the view tree instead.
        window.preservesContentDuringLiveResize = false
        // Tabs beside the traffic lights, transparent flat titlebar, no
        // toolbar.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = Theme.barBackground
        window.contentViewController = root
        resizeHandles.translatesAutoresizingMaskIntoConstraints = false
        root.view.addSubview(resizeHandles, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            resizeHandles.topAnchor.constraint(equalTo: root.view.topAnchor),
            resizeHandles.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            resizeHandles.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            resizeHandles.bottomAnchor.constraint(equalTo: root.view.bottomAnchor),
        ])
        window.delegate = self
        window.isReleasedWhenClosed = false

        if let visibleFrame = NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame {
            window.setFrame(Self.defaultWindowFrame(in: visibleFrame), display: false)
        } else {
            // Defensive fallback for the brief startup state where AppKit has
            // not published any displays yet.
            window.setContentSize(NSSize(width: 1080, height: 720))
            window.center()
        }

        wire()
        DispatchQueue.main.async { [weak self] in self?.updateTitlebarGeometry() }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func wire() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification, object: nil)
        sidebar.onAddProject = { [weak self] in self?.openFolder(nil) }
        sidebar.onOpenTerminal = { [weak self] in
            guard let directory = self?.projectURL else { return }
            TerminalLauncher.open(at: directory)
        }
        sidebar.onSelectProjectRow = { [weak self] index in
            guard let self, self.projects.indices.contains(index) else { return }
            let wanted = self.projects[index]
            // Clicking the project already showing collapses it, and the start
            // page comes back — which is where the others are chosen from.
            if self.projectURL == wanted {
                self.deactivateProject()
            } else {
                self.activateProject(wanted)
            }
        }
        sidebar.onReorderProjectRows = { [weak self] from, to in
            self?.moveProject(from: from, to: to)
        }
        sidebar.onCloseProjectRow = { [weak self] index in
            guard let self, self.projects.indices.contains(index) else { return }
            self.closeProject(self.projects[index])
        }
        onProjectsChanged = { [weak self] in self?.refreshProjectTabs() }
        sidebar.onGitDiff = { [weak self] entry, directory in
            self?.showDiff(for: entry, in: directory)
        }
        sidebar.onGitCommitDiff = { [weak self] commit, file, directory in
            self?.showCommitDiff(commit: commit, file: file, in: directory)
        }
        sidebar.onProjectGitChanged = { [weak self] directory in
            guard let self else { return }
            self.refreshGit(requireFollowUp: true)
            // Finished after the user moved to another project: the row of the
            // one it ran in still counts the changes it committed.
            if directory != self.projectURL { self.refreshProjectSummaries(all: true) }
        }
        // The branch in the title band drops the branch menu, anchored under it.
        sidebar.projectTitle.onBranchClick = { [weak self] rect in
            guard let self else { return }
            self.showBranchMenu(from: rect, in: self.sidebar.projectTitle)
        }
        // A tab reopened with ⇧⌘T, or shown after its body was released under
        // memory pressure, is read from Git again rather than from a copy kept
        // aside: what it showed then may not be true now.
        diffs.onReadAgain = { [weak self] directory, path, source in
            guard let self else { return }
            switch source {
            case .workingTree: self.showDiff(forPath: path, in: directory)
            case .commit(let hash): self.showCommitDiff(hash: hash, path: path, in: directory)
            }
        }
        diffs.onOpenFolder = { [weak self] in self?.openFolder(nil) }
        diffs.onOpenRecent = { [weak self] url in self?.openSelection([url]) }
        // Every ticked project joins this window, and the last one read becomes
        // the one on screen.
        diffs.onOpenChecked = { [weak self] urls in self?.openSelection(urls) }
    }

    /// The name Mission Control, the Dock's window list and the Window menu
    /// show for this window: the project on screen.
    private func refreshWindowTitle() {
        window?.title = Self.windowTitle(forProject: projectURL?.lastPathComponent)
    }

    /// The project first, because that is what tells two windows apart, then
    /// the app, because a name on its own in Mission Control says nothing
    /// about which app it belongs to. Nothing open is just the app.
    static func windowTitle(forProject name: String?) -> String {
        guard let name, !name.isEmpty else { return "Gift" }
        return "\(name) - Gift"
    }

    var windowTitleForTesting: String { window?.title ?? "" }

    func windowWillClose(_ notification: Notification) {
        gitRepositoryMonitor?.stop()
        gitRepositoryMonitor = nil
        workspaceFileMonitor?.stop()
        workspaceFileMonitor = nil
        onClose?(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        updateTitlebarGeometry()
        // Coming back from somewhere else — a terminal, most likely. Anything
        // resolved once for this project could have been changed out there
        // where no file inside .git would show it: `git config --global
        // user.name` is the case that started this.
        GitService.forgetRepositoryInfo()
        refreshGit(requireFollowUp: true)
    }

    /// The app came back from somewhere else. The rows behind the one on screen
    /// are read once, when their project joins the window; this is the moment
    /// they are most likely to be wrong — a commit, a checkout or a push in
    /// another project's own terminal shows nowhere else.
    ///
    /// Tied to the app becoming active rather than to this window becoming key:
    /// a window becomes key again after every alert and sheet, and each sweep
    /// is a full status walk of every other project.
    @objc func applicationDidBecomeActive(_ notification: Notification? = nil) {
        summarySweepCountForTesting += 1
        refreshProjectSummaries(all: true)
    }

    func windowDidResize(_ notification: Notification) {
        updateTitlebarGeometry()
    }

    private func updateTitlebarGeometry() {
        guard let window,
              let closeButton = window.standardWindowButton(.closeButton) else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        let buttonRect = closeButton.convert(closeButton.bounds, to: nil)
        let top = max(0, window.frame.height - buttonRect.maxY)
        let height = closeButton.bounds.height
        guard height > 0 else { return }

        trafficLightTopInset = top
        trafficLightHeight = height
        let tabHeight = top * 2 + height
        diffs.setTabRowHeight(tabHeight)
        sidebar.setTabRowHeight(tabHeight)
        // The project/branch strip starts after the last traffic light rather
        // than at a guessed offset — the buttons move with the system metrics.
        let lastButton = window.standardWindowButton(.zoomButton) ?? closeButton
        let trailing = lastButton.convert(lastButton.bounds, to: nil).maxX
        sidebar.setTitlebarLeadingInset(trailing + 10)
    }

    // MARK: - Project

    /// The projects this window holds, in the order their rows appear. A
    /// window shows one at a time; `projectURL` is whichever that is.
    private(set) var projects: [URL] = []
    /// Told when the list or the active project changes, so the rows redraw.
    var onProjectsChanged: (() -> Void)?

    /// Add a project to this window and switch to it. One already here just
    /// becomes the active one.
    func openProject(_ url: URL) {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        if !projects.contains(resolved) { projects.append(resolved) }
        activateProject(resolved)
    }

    /// Switch to a project this window already holds. The diffs of the one
    /// being left close: a tab always belongs to the project on screen.
    func activateProject(_ url: URL) {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard projects.contains(resolved) else { return }
        if projectURL != resolved { diffs.closeAll() }
        loadProject(resolved)
    }

    private func loadProject(_ url: URL) {
        // Where the repository root is and who commits from it are resolved
        // once per project and then reused; a new project resolves its own.
        GitService.forgetRepositoryInfo()
        // A batch of diff reads for the project being left stops where it is.
        openDiffReadToken?.cancel()
        lastChangedPaths = []
        gitRepositoryMonitor?.stop()
        gitRepositoryMonitor = nil
        workspaceFileMonitor?.stop()
        workspaceFileMonitor = nil
        projectURL = url
        isRepository = nil
        diffs.hasProject = true
        RecentProjects.shared.add(url)
        // Empty until this project's own refresh lands: the lists must not
        // keep showing what the project being left had changed.
        sidebar.clearChanges(for: url)
        // Show the name straight away; the branch follows the Git refresh.
        sidebar.setProjectTitle(project: url.lastPathComponent, branch: "")
        refreshWindowTitle()
        refreshGit()
        // Opened or switched to: find out what its remote has now. This
        // project only, and not again if it was fetched a moment ago.
        BackgroundFetch.fetchIfDue(url) { [weak self] in
            guard let self, self.projectURL == url else { return }
            self.remoteRefsMoved()
        }
        // Inside .git: commits, checkouts, fetches from anywhere.
        gitRepositoryMonitor = GitRepositoryMonitor(directory: url) { [weak self] in
            guard let self, self.projectURL == url else { return }
            self.refreshExternalGitState()
        }
        // The working tree: an edit in any editor is a change to list.
        workspaceFileMonitor = WorkspaceFileMonitor(directory: url) { [weak self] in
            guard let self, self.projectURL == url else { return }
            self.refreshGit(requireFollowUp: true)
        }
        onProjectsChanged?()
    }

    /// Synchronize every Git-derived surface after another process changes the
    /// repository, and when Gift becomes active after such a change.
    func refreshExternalGitState() {
        guard projectURL != nil else { return }
        // Something changed inside .git — possibly the repository's own
        // `user.name`, which is otherwise resolved once and reused.
        GitService.forgetRepositoryInfo()
        refreshGit(requireFollowUp: true)
    }

    // MARK: - Diffs

    /// Show a file's uncommitted change.
    func showDiff(for entry: GitService.Status.Entry, in directory: URL) {
        GitService.workQueue.async { [weak self] in
            let text = GitService.diff(for: entry, in: directory)
            DispatchQueue.main.async {
                guard let self, self.projectURL == directory else { return }
                self.diffs.open(.init(directory: directory, path: entry.path,
                                      source: .workingTree, diff: text))
            }
        }
    }

    /// The same, for a path alone: the status entry a tab was opened from is
    /// not kept, and the file may have changed since.
    func showDiff(forPath path: String, in directory: URL) {
        GitService.workQueue.async { [weak self] in
            let text = GitService.diff(forPath: path, in: directory)
            DispatchQueue.main.async {
                guard let self, self.projectURL == directory else { return }
                self.diffs.open(.init(directory: directory, path: path,
                                      source: .workingTree, diff: text ?? ""))
            }
        }
    }

    /// Show how one file changed in a specific commit.
    func showCommitDiff(commit: GitService.Commit, file: GitService.CommitFile,
                        in directory: URL) {
        showCommitDiff(hash: commit.shortHash, path: file.path, in: directory)
    }

    func showCommitDiff(hash: String, path: String, in directory: URL) {
        GitService.workQueue.async { [weak self] in
            let text = GitService.diff(inCommit: hash, path: path, in: directory)
            DispatchQueue.main.async {
                guard let self, self.projectURL == directory else { return }
                self.diffs.open(.init(directory: directory, path: path,
                                      source: .commit(hash), diff: text))
            }
        }
    }

    /// A flag the main thread raises and a read loop checks between files, so
    /// a batch started for a project that has since been left stops instead of
    /// reading the rest of it.
    private final class ReadToken {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }

    /// One batch of diff reads in flight per window, and at most one more
    /// waiting behind it. Saves during a build arrive faster than diffs can be
    /// read, and a queue of batches keeps every one of their results — and the
    /// versions they replace — alive at once.
    private var diffRefreshInFlight = false
    private var diffRefreshAgain = false
    private var openDiffReadToken: ReadToken?
    /// What the last status found changed, for the batch that follows one
    /// already running.
    private var lastChangedPaths: Set<String> = []
    private(set) var diffRefreshBatchesForTesting = 0

    /// The working-tree diff on screen read again after a refresh: the file
    /// moved under it, or was committed or discarded out from under it. The
    /// other working-tree tabs are marked and read when shown; a commit's diff
    /// never changes, so those are left alone.
    private func refreshOpenDiffs(changed: Set<String>, in directory: URL) {
        lastChangedPaths = changed
        // Only the tab on screen is read now. The others give up their bodies
        // and are read when they are next shown — reading every open tab here
        // cost a `git diff` per tab on every save, and put back each body that
        // memory pressure had released.
        let active = diffs.activeTab
        diffs.markWorkingTreeTabsStale(in: directory, except: active?.id)
        let wanted = [active].compactMap { $0 }
            .filter { $0.directory == directory && $0.source == .workingTree }
            .map { (id: $0.id, path: $0.path) }
        guard !wanted.isEmpty else { return }
        guard !diffRefreshInFlight else {
            diffRefreshAgain = true
            return
        }
        diffRefreshInFlight = true
        diffRefreshBatchesForTesting += 1
        let token = ReadToken()
        openDiffReadToken = token
        let generation = gitRefreshGeneration
        GitService.workQueue.async { [weak self] in
            for tab in wanted {
                guard !token.isCancelled else { break }
                // Not listed as changed: there is nothing left to show, and
                // nothing to ask Git about either.
                let text = changed.contains(tab.path)
                    ? (GitService.diff(forPath: tab.path, in: directory) ?? "") : ""
                DispatchQueue.main.async {
                    guard let self, self.projectURL == directory,
                          self.gitRefreshGeneration == generation else { return }
                    self.diffs.update(id: tab.id, diff: text)
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.diffRefreshInFlight = false
                guard self.diffRefreshAgain else { return }
                self.diffRefreshAgain = false
                guard let current = self.projectURL, !token.isCancelled else { return }
                self.refreshOpenDiffs(changed: self.lastChangedPaths, in: current)
            }
        }
    }

    // MARK: - Git refresh

    /// A fetch moved a remote-tracking branch. The history, which draws the
    /// remote branches, reads again, and so does the ↑ count, which is measured
    /// against one; the branch checked out and the working tree did not move.
    private func remoteRefsMoved() {
        guard let projectURL else { return }
        sidebar.projectsPanel.history.remoteRefsMoved(in: projectURL)
        refreshGit(requireFollowUp: true)
    }

    func refreshGit(requireFollowUp: Bool = false) {
        gitRefreshRequestCountForTesting += 1
        guard let projectURL else { return }
        if gitSummaryRefreshInFlight {
            // Coalesced into the one in flight — unless that one no longer
            // counts. A project collapsed and opened again while its refresh
            // was out gets that refresh discarded on arrival; dropping this
            // request as a duplicate of it left the reopened project with no
            // changes, no history and no branch until something else moved.
            if gitSummaryDirectory != projectURL || requireFollowUp
                || gitSummaryGeneration != gitRefreshGeneration {
                gitSummaryRefreshAgain = true
            }
            return
        }
        gitSummaryRefreshInFlight = true
        gitSummaryDirectory = projectURL
        gitRefreshGeneration += 1
        let generation = gitRefreshGeneration
        gitSummaryGeneration = generation
        gitSummaryQueue.async { [weak self] in
            let status = GitService.status(in: projectURL)
            DispatchQueue.main.async {
                guard let self else { return }
                self.gitSummaryRefreshInFlight = false
                self.gitSummaryDirectory = nil
                if self.projectURL == projectURL,
                   self.gitRefreshGeneration == generation {
                    self.apply(status, for: projectURL)
                }
                if self.gitSummaryRefreshAgain {
                    self.gitSummaryRefreshAgain = false
                    self.refreshGit()
                }
            }
        }
    }

    private func apply(_ status: GitService.Status, for projectURL: URL) {
        currentBranchName = status.isRepo ? status.branch : nil
        let wasRepository = isRepository
        isRepository = status.isRepo
        sidebar.setChanges(
            status.isRepo ? status.entries : [], in: projectURL,
            state: status.isRepo
                ? .init(head: status.head, ahead: status.ahead,
                        hasUpstream: status.hasUpstream)
                : .init())
        sidebar.setProjectTitle(project: projectURL.lastPathComponent,
                                branch: status.isRepo ? status.branch : "")
        // A folder that is not a repository has no branch to name, and must
        // not keep the last repository's.
        window?.subtitle = status.isRepo
            ? "\(projectURL.lastPathComponent) — \(status.branch)" : ""
        refreshOpenDiffs(changed: Set(status.isRepo ? status.entries.map(\.path) : []),
                         in: projectURL)
        // The row says the same thing the title strip does, and hears it at
        // the same moment.
        let changed = noteSummary(branch: status.isRepo ? status.branch : "",
                                  user: status.isRepo ? status.userName : "",
                                  changes: status.isRepo ? status.entries.count : 0,
                                  for: projectURL)
        if !changed, wasRepository != isRepository { refreshProjectTabs() }
    }

    // MARK: - Branch menu

    /// Puts the menu on screen. `popUp` runs its own tracking loop until the
    /// menu closes, so a test hands in something that keeps the menu instead.
    var presentBranchMenu: (NSMenu, NSPoint, NSView) -> Void = { menu, origin, anchor in
        menu.popUp(positioning: nil, at: origin, in: anchor)
    }

    /// The branches of the project on screen: the local ones to switch to,
    /// the remote ones in a submenu, then creating and deleting.
    private func showBranchMenu(from rect: NSRect, in anchor: NSView) {
        guard let directory = projectURL, isRepository != false else { return }
        gitSummaryQueue.async { [weak self] in
            let branches = GitService.branches(in: directory)
            DispatchQueue.main.async {
                guard let self, self.projectURL == directory else { return }
                let menu = self.branchMenu(branches, in: directory)
                // Just under the branch text, so the menu reads as its dropdown.
                let origin = NSPoint(x: rect.minX,
                                     y: anchor.isFlipped ? rect.maxY : rect.minY)
                self.presentBranchMenu(menu, origin, anchor)
            }
        }
    }

    func branchMenu(_ branches: [GitService.Branch], in directory: URL) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.font = Theme.uiFont(11)
        let local = Self.branchMenuEntries(branches.filter { !$0.isRemote })
        let remote = branches.filter(\.isRemote)
        if local.isEmpty {
            let item = NSMenuItem(title: "No branches", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        for branch in local {
            menu.addItem(branchItem(branch, in: directory))
        }
        if !remote.isEmpty {
            let item = NSMenuItem(title: "Remote Branches", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            remote.forEach { submenu.addItem(branchItem($0, in: directory)) }
            item.submenu = submenu
            menu.addItem(item)
        }
        menu.addItem(.separator())
        addAction(to: menu, title: "New Branch…") { [weak self] in
            self?.createBranch(from: branches, in: directory)
        }
        // Neither the branch this tree is on nor one another tree holds can be
        // deleted; Git refuses both.
        let deletable = local.filter { !$0.isCurrent && $0.heldByWorktree == nil }
        let delete = NSMenuItem(title: "Delete Branch", action: nil, keyEquivalent: "")
        let deleteMenu = NSMenu()
        deleteMenu.autoenablesItems = false
        for branch in deletable {
            addAction(to: deleteMenu, title: branch.name) { [weak self] in
                self?.deleteBranch(branch, in: directory)
            }
        }
        delete.submenu = deleteMenu
        delete.isEnabled = !deletable.isEmpty
        menu.addItem(delete)
        return menu
    }

    /// The current branch first so switching away from it is obvious, then
    /// the rest in the order Git lists them (most recently updated first).
    static func branchMenuEntries(_ branches: [GitService.Branch]) -> [GitService.Branch] {
        branches.filter(\.isCurrent) + branches.filter { !$0.isCurrent }
    }

    private func branchItem(_ branch: GitService.Branch, in directory: URL) -> NSMenuItem {
        let item = NSMenuItem(title: branch.name,
                              action: #selector(runMenuAction(_:)), keyEquivalent: "")
        item.attributedTitle = Self.branchMenuTitle(branch)
        item.target = self
        item.representedObject = MenuAction { [weak self] in
            self?.switchBranch(branch, in: directory)
        }
        item.state = branch.isCurrent ? .on : .off
        // A branch another working tree has checked out cannot be switched to
        // — Git refuses — so the menu says so rather than offering it.
        item.isEnabled = branch.heldByWorktree == nil
        return item
    }

    private func addAction(to menu: NSMenu, title: String, action: @escaping () -> Void) {
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

    /// Two lines per item: the branch, then who last touched it and when — or,
    /// for one another working tree holds, where it is instead.
    static func branchMenuTitle(_ branch: GitService.Branch) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 1
        let held = branch.heldByWorktree != nil
        let title = NSMutableAttributedString(
            string: branch.name,
            attributes: [.font: Theme.uiFont(11.5),
                         .foregroundColor: held ? Theme.dimText : Theme.foreground,
                         .paragraphStyle: paragraph])
        let detail: String
        if let worktree = branch.heldByWorktree {
            detail = "in use by \((worktree as NSString).lastPathComponent)"
        } else {
            detail = branch.author.isEmpty
                ? branch.createdAt
                : "\(branch.author) · \(branch.createdAt)"
        }
        title.append(NSAttributedString(
            string: "\n" + detail,
            attributes: [.font: Theme.uiFont(9.5),
                         .foregroundColor: Theme.dimText,
                         .paragraphStyle: paragraph]))
        return title
    }

    /// What clicking a branch in the menu should do. Kept separate from the
    /// alerts so the rule — refuse with a reason, or confirm naming both ends —
    /// is decided in one testable place.
    enum BranchSwitch: Equatable {
        case alreadyCurrent
        case unavailable(reason: String)
        case confirm(from: String, to: String)
    }

    static func branchSwitch(to branch: GitService.Branch,
                             from current: String?) -> BranchSwitch {
        if branch.isCurrent { return .alreadyCurrent }
        if let worktree = branch.heldByWorktree {
            // Git allows a branch in one working tree at a time. Said plainly,
            // with the place to look, rather than passed on as its fatal.
            return .unavailable(reason:
                "“\(branch.name)” is checked out in another working tree:\n\(worktree)\n\n"
                    + "Git keeps a branch in one working tree at a time. Switch that tree "
                    + "to something else, or remove it with `git worktree remove`, and "
                    + "“\(branch.name)” is free again.")
        }
        if branch.isRemote, branch.upstreamBranch == nil {
            return .unavailable(reason:
                "This remote-tracking ref has no branch name to check out locally.")
        }
        if let current, current == branch.name { return .alreadyCurrent }
        return .confirm(from: current ?? "the current branch", to: branch.name)
    }

    /// Answers the alerts the branch actions ask. A test answers in their
    /// place; the real one runs them modally.
    var confirmAlert: (NSAlert) -> Bool = { $0.runModal() == .alertFirstButtonReturn }

    /// Switch to `branch`, explaining first. A switch that cannot happen says
    /// why instead of asking; one that can names both ends before it runs.
    private func switchBranch(_ branch: GitService.Branch, in directory: URL) {
        let from: String
        switch Self.branchSwitch(to: branch, from: currentBranchName) {
        case .alreadyCurrent:
            return
        case .unavailable(let reason):
            presentBranchAlert(title: "Cannot switch to “\(branch.name)”", message: reason)
            return
        case .confirm(let source, _):
            from = source
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Switch from “\(from)” to “\(branch.name)”?"
        let effect = branch.isRemote
            ? "A local tracking branch will be created, checked out, and the files in this "
                + "working tree will be replaced with that branch's versions."
            : "The files in this working tree will be replaced with the versions from "
                + "“\(branch.name)”. Git will refuse the switch if local changes cannot be preserved."
        alert.informativeText = "Project:\n\(directory.path)\n\n\(effect)"
        alert.addButton(withTitle: "Switch")
        alert.addButton(withTitle: "Cancel")
        guard confirmAlert(alert) else { return }
        runBranchOperation("Could not switch to “\(branch.name)”", in: directory) {
            GitService.switchBranch(branch, in: directory)
        }
    }

    /// Ask for a name and a base, then create the branch and check it out.
    private func createBranch(from branches: [GitService.Branch], in directory: URL) {
        let names = branches.filter { !$0.isRemote }.map(\.name)
        guard !names.isEmpty else {
            presentBranchAlert(title: "Cannot create branch",
                               message: "No base branches are available.")
            return
        }
        let nameField = NSTextField(string: "")
        nameField.placeholderString = "Branch name"
        let base = NSPopUpButton()
        base.addItems(withTitles: names)
        if let current = branches.first(where: { $0.isCurrent && !$0.isRemote }) {
            base.selectItem(withTitle: current.name)
        }
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Name"), nameField],
            [NSTextField(labelWithString: "Base"), base],
        ])
        grid.rowSpacing = 8
        grid.column(at: 1).width = 240
        grid.frame = NSRect(x: 0, y: 0, width: 300, height: 56)

        let alert = NSAlert()
        alert.messageText = "Create branch"
        alert.informativeText = "The new branch will be created and checked out immediately."
        alert.accessoryView = grid
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = nameField
        guard createBranchPrompt(alert, nameField, base) else { return }

        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            presentBranchAlert(title: "Invalid branch name", message: "Enter a branch name.")
            return
        }
        let from = base.titleOfSelectedItem ?? names[0]
        runBranchOperation("Could not create “\(name)”", in: directory) {
            GitService.createBranch(name, from: from, in: directory)
        }
    }

    /// Fills in and answers the new-branch alert in a test; the real one runs
    /// it modally.
    var createBranchPrompt: (NSAlert, NSTextField, NSPopUpButton) -> Bool = { alert, _, _ in
        alert.runModal() == .alertFirstButtonReturn
    }

    private func deleteBranch(_ branch: GitService.Branch, in directory: URL) {
        guard !branch.isCurrent else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete branch “\(branch.name)”?"
        alert.informativeText = "Project:\n\(directory.path)\n\n"
            + "This removes the local branch reference. Git permits this only when the "
            + "branch is fully merged; unmerged commits will not be deleted."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard confirmAlert(alert) else { return }
        runBranchOperation("Could not delete “\(branch.name)”", in: directory) {
            GitService.deleteBranch(branch, in: directory)
        }
    }

    private func runBranchOperation(_ failureTitle: String, in directory: URL,
                                    _ work: @escaping () -> GitService.RemoteResult) {
        GitService.operationQueue.async { [weak self] in
            let result = work()
            DispatchQueue.main.async {
                guard let self else { return }
                if result.ok {
                    if self.projectURL == directory { self.refreshExternalGitState() }
                    self.refreshProjectSummaries(all: true)
                } else {
                    // Git refused it — a dirty tree it cannot preserve, a
                    // missing ref, an unmerged branch — so hand its own words
                    // to the user.
                    self.presentBranchAlert(title: failureTitle, message: result.message)
                }
                self.branchOperationsFinishedForTesting += 1
            }
        }
    }

    private(set) var branchOperationsFinishedForTesting = 0

    private func presentBranchAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message.trimmingCharacters(in: .whitespacesAndNewlines)
        presentAlert(alert)
    }

    /// Shows an alert that only informs. A test collects them instead.
    var presentAlert: (NSAlert) -> Void = { _ = $0.runModal() }

    // MARK: - Opening and closing projects

    /// Set when this window has no project yet (the start page) — then
    /// "Open…" fills this window instead of spawning another empty one.
    var hasProject: Bool { projectURL != nil }

    /// The app routes folders to an existing project first.
    var onOpenRequested: (([URL]) -> Void)?

    func openSelection(_ urls: [URL]) {
        if let handler = onOpenRequested {
            handler(urls)
            return
        }
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            openProject(url)
        }
    }

    /// Reorder the rows. Which project is showing does not change: the order
    /// is a convenience, not a switch.
    func moveProject(from: Int, to: Int) {
        guard projects.indices.contains(from), from != to else { return }
        let destination = max(0, min(to, projects.count - 1))
        let moved = projects.remove(at: from)
        projects.insert(moved, at: destination)
        refreshProjectTabs()
    }

    /// Take a project out of this window.
    ///
    /// Closing the one being shown moves to a neighbour. Closing the last one
    /// empties the window back to the start page rather than leaving lists
    /// pointing at a project that is no longer here.
    func closeProject(_ url: URL) {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard let index = projects.firstIndex(of: resolved) else { return }
        let wasShowing = projectURL == resolved
        projects.remove(at: index)
        diffs.closeTabs(in: resolved)
        guard wasShowing else {
            refreshProjectTabs()
            return
        }
        guard let next = projects.indices.contains(index)
                ? projects[index] : projects.last else {
            clearProject()
            refreshProjectTabs()
            return
        }
        activateProject(next)
    }

    /// Show no project, while keeping the window's list of them.
    ///
    /// The window is then what it is before any project is opened — the start
    /// page, and the recent projects on it — except that the rows are still
    /// there to come back to.
    func deactivateProject() {
        guard projectURL != nil else { return }
        clearProject()
        refreshProjectTabs()
    }

    /// Put the window back to having nothing open: no tabs, no monitors, no
    /// Git. Whether any projects remain in the list is the caller's business.
    private func clearProject() {
        diffs.closeAll()
        gitRepositoryMonitor?.stop()
        gitRepositoryMonitor = nil
        workspaceFileMonitor?.stop()
        workspaceFileMonitor = nil
        GitService.forgetRepositoryInfo()
        openDiffReadToken?.cancel()
        lastChangedPaths = []
        projectURL = nil
        isRepository = nil
        diffs.hasProject = false
        sidebar.clearChanges(for: nil)
        sidebar.setProjectTitle(project: "", branch: "")
        // Bumping the generation discards a refresh that is already in flight,
        // which would otherwise arrive and speak for a project that is no
        // longer on screen.
        gitRefreshGeneration += 1
        currentBranchName = nil
        window?.subtitle = ""
        refreshWindowTitle()
    }

    /// What each row says after the project's name: the branch it is on, who
    /// commits there, and how many files it has changed. The project on screen
    /// keeps its entry current from every Git refresh; the others are read
    /// once, when they join the window.
    private var projectSummaries: [URL: ProjectSummary] = [:]
    /// Summaries of the projects behind the one on screen are read here, off
    /// the queue that project's own history and commit files are read on, so
    /// a sweep over several large repositories does not hold those up.
    private static let summaryQueue = DispatchQueue(label: "app.gift.git-summaries",
                                                    qos: .utility)
    struct ProjectSummary: Equatable {
        var branch: String
        var user: String
        var changes: Int
    }

    private func refreshProjectTabs() {
        sidebar.setProjects(
            projects.map { (name: $0.lastPathComponent,
                            branch: projectSummaries[$0]?.branch ?? "",
                            user: projectSummaries[$0]?.user ?? "",
                            changes: projectSummaries[$0]?.changes ?? 0,
                            path: $0.path) },
            active: projectURL.flatMap { projects.firstIndex(of: $0) },
            isRepository: isRepository)
        refreshProjectSummaries()
    }

    /// `all` re-reads every project rather than only the ones never read. The
    /// project on screen is never in that sweep: its own refresh has just run
    /// and knows more than a summary does.
    private func refreshProjectSummaries(all: Bool = false) {
        let wanted = all
            ? projects.filter { $0 != projectURL }
            : projects.filter { projectSummaries[$0] == nil }
        guard !wanted.isEmpty else { return }
        Self.summaryQueue.async { [weak self] in
            // One status walk each, giving both the branch and the count. The
            // count is the same number the project on screen reports from its
            // own refresh, so a row does not change meaning when it is opened.
            let found = wanted.map { url -> (URL, ProjectSummary) in
                let status = GitService.status(in: url)
                return (url, ProjectSummary(branch: status.isRepo ? status.branch : "",
                                            user: status.isRepo ? status.userName : "",
                                            changes: status.isRepo ? status.entries.count : 0))
            }
            DispatchQueue.main.async { self?.applySummaries(found) }
        }
    }

    private func applySummaries(_ found: [(URL, ProjectSummary)]) {
        var changed = false
        // The project on screen may have been opened while the sweep was
        // reading it; its own refresh is newer than this snapshot and must not
        // be replaced by it.
        for (url, summary) in found
        where url != projectURL && projectSummaries[url] != summary {
            projectSummaries[url] = summary
            changed = true
        }
        if changed { refreshProjectTabs() }
    }

    /// Hand the window a summary as a sweep would, for a project by URL.
    func applySummaryForTesting(branch: String, changes: Int, for url: URL) {
        applySummaries([(url.standardizedFileURL.resolvingSymlinksInPath(),
                         ProjectSummary(branch: branch, user: "", changes: changes))])
    }
    /// How many sweeps over the other projects have started.
    private(set) var summarySweepCountForTesting = 0
    /// How many times the project on screen has been asked to re-read Git.
    private(set) var gitRefreshRequestCountForTesting = 0

    /// What the refresh reports for the project on screen, which is fresher
    /// than anything cached. True when the rows were redrawn for it.
    @discardableResult
    private func noteSummary(branch: String, user: String, changes: Int, for url: URL) -> Bool {
        let summary = ProjectSummary(branch: branch, user: user, changes: changes)
        guard projectSummaries[url] != summary else { return false }
        projectSummaries[url] = summary
        refreshProjectTabs()
        return true
    }

    // MARK: - Menu actions (reached via the responder chain)

    @objc func openFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Open"
        panel.message = "Choose one or more repositories"
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.openSelection(panel.urls)
        }
    }

    /// ⌘W. With no diff open the window itself closes, so the shortcut never
    /// feels dead.
    @objc func closeTab(_ sender: Any?) {
        guard diffs.closeActive() else {
            window?.performClose(sender)
            return
        }
    }
    @objc func selectNextTab(_ sender: Any?) { diffs.step(by: 1) }
    @objc func selectPreviousTab(_ sender: Any?) { diffs.step(by: -1) }
    @objc func reopenClosedTab(_ sender: Any?) {
        guard !diffs.reopenLastClosed() else { return }
        NSSound.beep()
    }
    /// Under memory pressure: let go of every diff not being read. Each is
    /// read again when its tab is next shown.
    func releaseTransientMemory() {
        diffs.releaseInactiveBodies()
    }

    /// ⌘C, when nothing nearer has claimed it — typing in the commit message
    /// keeps its own copy — puts the diff on screen on the pasteboard. The
    /// diff's rows are drawn rather than laid out as text, so there is no
    /// selection for the editing commands to work from.
    @objc func copy(_ sender: Any?) {
        guard diffs.copyActiveDiff() else {
            NSSound.beep()
            return
        }
    }

    /// ⌘R: read the project again, as returning to the app does.
    @objc func refreshRepository(_ sender: Any?) {
        refreshExternalGitState()
        refreshProjectSummaries(all: true)
    }
}

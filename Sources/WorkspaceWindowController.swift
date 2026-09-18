import AppKit

/// One editor window: its own project folder, sidebar, tabs and editor panes.
/// Several of these can exist at once (⌘N).
///
/// Menu items use `target: nil`, so AppKit routes each action down the responder
/// chain to the *key* window's controller — that's what makes the menus act on
/// whichever window is frontmost.
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate {
    let sidebar = SidebarViewController()
    let editor = EditorViewController()
    private let resizeHandles = WindowResizeHandleView()
    private var root: RootViewController!
    private(set) var projectURL: URL?
    private var gitRepositoryMonitor: GitRepositoryMonitor?
    private var workspaceFileMonitor: WorkspaceFileMonitor?
    private let gitSummaryQueue = DispatchQueue(
        label: "app.puzzle.workspace-git-summary", qos: .utility)
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
    /// ⌘P's panel and the file list behind it.
    private var palette: PalettePanel?
    private var quickOpenIndex: [String] = []
    private var quickOpenIndexInFlight = false
    /// One replaceable Git preview buffer per window. Giving every path/commit a
    /// permanent synthetic URL made an inspection session grow without bound.
    private let diffPreviewID = UUID().uuidString
    private(set) var trafficLightTopInset = (EditorTabBar.defaultRowHeight - 14) / 2
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
        let root = RootViewController(sidebar: sidebar, editor: editor)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init(window: window)
        self.root = root

        window.title = "Puzzle"
        // Puzzle only draws SDR sRGB colours. On wide-gamut/HDR displays the
        // default can otherwise promote large backing surfaces to 16-bit float.
        window.colorSpace = .sRGB
        // Do not retain both old and new full-size surfaces throughout a live
        // resize; redraw from the view tree instead.
        window.preservesContentDuringLiveResize = false
        // Zed-style header: full-size content with the tabs beside the traffic
        // lights, transparent flat titlebar, no toolbar.
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
        sidebar.onSelectProjectRow = { [weak self] index in
            guard let self, self.projects.indices.contains(index) else { return }
            let wanted = self.projects[index]
            // Clicking the project already showing collapses it: the tree
            // folds away and the start page comes back, which is where the
            // other projects are chosen from.
            if self.projectURL == wanted {
                self.deactivateProject()
            } else {
                self.activateProject(wanted)
            }
        }
        // The branch is a shortcut into that project's Git panel: it brings the
        // project forward if it is not the one showing, and never collapses the
        // one that is — collapsing would take the panel it just asked for away.
        sidebar.onSelectProjectBranchRow = { [weak self] index in
            guard let self, self.projects.indices.contains(index) else { return }
            let wanted = self.projects[index]
            if self.projectURL != wanted { self.activateProject(wanted) }
            self.sidebar.showGit()
        }
        sidebar.onReorderProjectRows = { [weak self] from, to in
            self?.moveProject(from: from, to: to)
        }
        sidebar.onCloseProjectRow = { [weak self] index in
            guard let self, self.projects.indices.contains(index) else { return }
            self.closeProject(self.projects[index])
        }
        onProjectsChanged = { [weak self] in self?.refreshProjectTabs() }
        sidebar.fileTree.onOpenFile = { [weak self] url in self?.editor.open(url: url) }
        sidebar.fileTree.onGitHistory = { [weak self] url in self?.showFileHistory(for: url) }
        sidebar.fileTree.onOpenInTerminal = { url in Self.openTerminal(at: url) }
        sidebar.fileTree.onFileSystemChanged = { [weak self] in
            self?.sidebar.refreshGitPanelIfLoaded()
            self?.refreshGit(requireFollowUp: true)
        }
        sidebar.fileTree.canMutatePath = { [weak self] url in
            self?.editor.canMutatePath(url) ?? true
        }
        sidebar.fileTree.onPathRenamed = { [weak self] oldURL, newURL in
            self?.editor.pathRenamed(from: oldURL, to: newURL)
        }
        sidebar.fileTree.onPathDeleted = { [weak self] url in
            self?.editor.pathDeleted(url)
        }
        sidebar.onSearchResult = { [weak self] url, line in
            self?.editor.open(url: url)
            self?.editor.jumpToLine(line)
        }
        sidebar.onSearchFile = { [weak self] url in self?.editor.open(url: url) }
        sidebar.onGitFile = { [weak self] url in self?.editor.open(url: url) }
        sidebar.onGitDiff = { [weak self] entry, directory in
            self?.showDiff(for: entry, in: directory)
        }
        sidebar.onGitCommitDiff = { [weak self] commit, file, directory in
            self?.showCommitDiff(commit: commit, file: file, in: directory)
        }
        sidebar.onGitChanged = { [weak self] in self?.gitChanged() }
        sidebar.onProjectGitChanged = { [weak self] directory in
            guard let self else { return }
            self.gitChanged()
            // The Git panel did not run this one, so it has not read it yet.
            self.sidebar.refreshGitPanelIfLoaded()
            // Finished after the user moved to another project: the row of the
            // one it ran in still counts the changes it committed.
            if directory != self.projectURL { self.refreshProjectSummaries(all: true) }
        }
        sidebar.activityBar.onAction = { [weak self] action in self?.handleActivity(action) }
        // The name goes back to the list it was chosen from; the terminal has
        // its own button at the end of the band.
        sidebar.projectTitle.onProjectClick = { [weak self] in self?.sidebar.showFiles() }
        sidebar.onOpenTerminal = { [weak self] in self?.openProjectInTerminal() }
        // The branch in the title band drops the list of branches to switch
        // to, anchored under the name. (The branch on a project row is the
        // one that goes to the Git panel.)
        sidebar.projectTitle.onBranchClick = { [weak self] rect in
            self?.showBranchMenu(from: rect)
        }
        editor.onOpenFolder = { [weak self] in self?.openFolder(nil) }
        editor.onOpenSettings = { [weak self] in self?.openSettings() }
        editor.onOpenRecent = { [weak self] url in self?.openSelection([url]) }
        // Every ticked project joins this window, and the last one read becomes
        // the one on screen.
        editor.onOpenChecked = { [weak self] urls in self?.openSelection(urls) }
        editor.onDocumentSaved = { [weak self] url in
            guard let self else { return }
            // The file changed on disk, so its cached blame is stale.
            self.editor.invalidateBlame(for: url)
            // Saving settings.json applies the new display config immediately.
            if url.standardizedFileURL == Settings.fileURL.standardizedFileURL {
                Settings.shared.reload()
            }
            self.scheduleGitRefreshAfterSave()
        }
        // Keep the file tree's active-file highlight in sync with the active tab.
        editor.onActiveDocumentChanged = { [weak self] url in
            guard let self, let url else { return }
            self.sidebar.fileTree.selectFile(url)
            self.refreshWindowTitle(activeFile: url)
        }
    }

    /// The name Mission Control, the Dock's window list and the Window menu
    /// show for this window.
    ///
    /// A window *is* a project, so it keeps the project's name as tabs come and
    /// go: hovering a window in the switcher should say which project it holds,
    /// not which file happened to be open in it. A window opened on a single
    /// file has only that file to be named after.
    private func refreshWindowTitle(activeFile: URL?) {
        let name = projectURL?.lastPathComponent
            ?? activeFile?.lastPathComponent
        window?.title = name.map { $0.isEmpty ? "Puzzle" : $0 } ?? "Puzzle"
    }

    var windowTitleForTesting: String { window?.title ?? "" }

    func windowWillClose(_ notification: Notification) {
        gitRepositoryMonitor?.stop()
        gitRepositoryMonitor = nil
        workspaceFileMonitor?.stop()
        workspaceFileMonitor = nil
        // Release this window's buffers rather than leaving its layout
        // managers attached to them.
        editor.detachAllPanes()
        onClose?(self)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        editor.confirmClose()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        quickOpenIndex = []
        sidebar.releaseHiddenPanels()
        editor.releaseTransientMemory()
        DocumentStore.shared.releaseTransientMemory()
        // Nothing is drawing file rows while the window is in the Dock.
        FileIcons.releaseTransientMemory()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        updateTitlebarGeometry()
        // Coming back from somewhere else — a terminal, most likely. Anything
        // resolved once for this project could have been changed out there
        // where no file inside .git would show it: `git config --global
        // user.name` is the case that started this.
        GitService.forgetRepositoryInfo()
        sidebar.refreshGitPanelIfLoaded()
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

    /// Clicking another window, or switching apps, is a focus change: the
    /// buffers are written before attention moves on.
    func windowDidResignKey(_ notification: Notification) {
        editor.autosaveAll()
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
        let fileTabHeight = top * 2 + height
        editor.setTabRowHeight(fileTabHeight)
        sidebar.setFileTabHeight(fileTabHeight)
        // The project/branch strip starts after the last traffic light rather
        // than at a guessed offset — the buttons move with the system metrics.
        let lastButton = window.standardWindowButton(.zoomButton) ?? closeButton
        let trailing = lastButton.convert(lastButton.bounds, to: nil).maxX
        sidebar.setTitlebarLeadingInset(trailing + 10)
    }

    func releaseTransientMemory() {
        // Rebuilt in well under a second the next time ⌘P is used, and on a
        // large checkout it is the biggest thing this window holds.
        quickOpenIndex = []
        palette?.dismiss()
        sidebar.releaseHiddenPanels()
        editor.releaseTransientMemory()
    }

    // MARK: - Project

    /// The projects this window holds, in the order their tabs appear. A window
    /// shows one at a time; `projectURL` is whichever that is.
    private(set) var projects: [URL] = []
    /// Told when the list or the active project changes, so the strip redraws.
    var onProjectsChanged: (() -> Void)?

    /// Add a project to this window and switch to it. One already here just
    /// becomes the active one.
    func openProject(_ url: URL) {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        if !projects.contains(resolved) { projects.append(resolved) }
        activateProject(resolved)
    }

    /// Switch to a project this window already holds.
    ///
    /// The editor is emptied first: nothing of the previous project is carried
    /// across, and nothing about it is remembered — coming back loads it as if
    /// it had just been opened. That is deliberate; keeping per-project tab
    /// state would mean a bundle of caret positions, folds and find state that
    /// every future per-tab feature would have to remember to join.
    func activateProject(_ url: URL) {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard projects.contains(resolved) else { return }
        if projectURL != resolved { editor.closeAllTabs() }
        loadProject(resolved)
    }

    private func loadProject(_ url: URL) {
        // Where the repository root is and who commits from it are resolved
        // once per project and then reused; a new project resolves its own.
        GitService.forgetRepositoryInfo()
        gitRepositoryMonitor?.stop()
        gitRepositoryMonitor = nil
        workspaceFileMonitor?.stop()
        workspaceFileMonitor = nil
        projectURL = url
        quickOpenIndex = []
        palette?.dismiss()
        editor.hasProject = true
        editor.repositoryRoot = url
        RecentProjects.shared.add(url)
        sidebar.fileTree.setRoot(url)
        // Empty until this project's own refresh lands: the column must not
        // keep showing what the project being left had changed.
        sidebar.clearChanges(for: url)
        sidebar.setDirectory(url)
        // Show the name straight away; the branch follows the Git refresh.
        sidebar.setProjectTitle(project: url.lastPathComponent, branch: "")
        refreshWindowTitle(activeFile: nil)
        refreshGit()
        gitRepositoryMonitor = GitRepositoryMonitor(directory: url) { [weak self] in
            guard let self, self.projectURL == url else { return }
            self.refreshExternalGitState()
        }
        workspaceFileMonitor = WorkspaceFileMonitor(directory: url) { [weak self] paths, date in
            guard let self, self.projectURL == url else { return }
            let reloaded = DocumentStore.shared.reloadExternalChanges(
                at: paths, observedAt: date)
            // New/deleted files are not cached Documents, but still need an
            // immediate tree refresh. Previously this happened only when an
            // already-open buffer was reloaded, while Git Changes refreshed
            // independently and appeared ahead of the tree.
            self.sidebar.fileTree.refresh(changedURLs: paths)
            self.sidebar.refreshGitPanelIfLoaded()
            self.refreshGit(requireFollowUp: true)
            reloaded.forEach { self.editor.invalidateBlame(for: $0) }
        }
        onProjectsChanged?()
    }

    /// Synchronize every Git-derived surface after another process changes the
    /// repository, and when Puzzle becomes active after such a change.
    func refreshExternalGitState() {
        guard let projectURL else { return }
        // Something changed inside .git — possibly the repository's own
        // `user.name`, which is otherwise resolved once and reused.
        GitService.forgetRepositoryInfo()
        let reloaded = DocumentStore.shared.reloadExternalChanges(at: [projectURL])
        sidebar.fileTree.refresh(changedURLs: [projectURL])
        sidebar.refreshGitPanelIfLoaded()
        refreshGit(requireFollowUp: true)
        if reloaded.isEmpty {
            editor.invalidateBlame()
        } else {
            reloaded.forEach { editor.invalidateBlame(for: $0) }
        }
        editor.refreshGitLineChanges()
    }

    /// Show a file's git diff in the editor, coloured by DiffHighlighter.
    /// The diff is a virtual document, so it opens as a normal (read-only) tab.
    /// True when a path is a picture we can preview. `git diff` on a binary just
    /// says "Binary files differ", so showing the image itself is far more useful.
    private static func isImage(_ path: String) -> Bool {
        Document.imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Media is the same case: `git diff` on a video says "Binary files
    /// differ", and the player is what anyone clicking the row wanted.
    private static func isPlayable(_ path: String) -> Bool {
        Document.mediaExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    func showDiff(for entry: GitService.Status.Entry, in directory: URL) {
        // Images and media preview instead of diffing — the same view the file
        // tree gives.
        if Self.isImage(entry.path) || Self.isPlayable(entry.path) {
            let fileURL = directory.appendingPathComponent(entry.path)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                editor.open(url: fileURL)
                return
            }
            // Deleted image: nothing on disk to show, fall through to the diff.
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let text = GitService.diff(for: entry, in: directory)
            // A picture that is also source: the diff tab shows both versions
            // above the diff itself.
            let sides = GitService.svgDiffSides(for: entry.path, in: directory)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.projectURL == directory else { return }
                let url = self.diffPreviewURL(in: directory, path: entry.path)
                // Replace any previous diff for this file so re-clicking refreshes.
                let document = DocumentStore.shared.setVirtualDocument(
                    url: url, text: text,
                    displayName: "\((entry.path as NSString).lastPathComponent) (diff)")
                document.svgDiffSides = sides
                self.editor.open(url: url, replacingContent: true)
            }
        }
    }

    /// Show how one file changed in a specific commit (History tab).
    func showCommitDiff(commit: GitService.Commit, file: GitService.CommitFile, in directory: URL) {
        // For an image, show the picture as it looked in THAT commit: extract the
        // blob to a temp file so the normal image preview can decode it.
        if Self.isImage(file.path), file.status != "D" {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let blob = GitService.blob(inCommit: commit.shortHash,
                                           path: file.path, in: directory)
                guard case .data(let data) = blob, !data.isEmpty else {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.projectURL == directory else { return }
                        let alert = NSAlert()
                        alert.messageText = "Unable to open history image"
                        switch blob {
                        case .tooLarge(let bytes):
                            alert.informativeText = "The image is "
                                + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
                                + ", which exceeds Puzzle's preview limit."
                        case .unavailable(let message):
                            alert.informativeText = message.trimmingCharacters(in: .whitespacesAndNewlines)
                        case .data:
                            alert.informativeText = "The image blob is empty."
                        }
                        alert.runModal()
                    }
                    return
                }
                let temp = WorkspaceWindowController.commitBlobURL(
                    repository: directory, commit: commit.shortHash, path: file.path)
                do {
                    try FileManager.default.createDirectory(
                        at: temp.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: temp, options: .atomic)
                } catch {
                    return
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.projectURL == directory else { return }
                    self.editor.open(url: temp)
                }
            }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Built the same way the rebuild-from-URL path builds it, so a
            // History tab that is evicted and reopened comes back identical.
            let content = Self.commitDiffContent(commit: commit.shortHash,
                                                 path: file.path, in: directory)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.projectURL == directory else { return }
                let url = self.diffPreviewURL(in: directory,
                                              path: file.path, commit: commit.shortHash)
                let document = DocumentStore.shared.setVirtualDocument(
                    url: url, text: content.text, displayName: content.displayName)
                document.svgDiffSides = content.svgSides
                self.editor.open(url: url, replacingContent: true)
            }
        }
    }

    private func showFileHistory(for file: URL) {
        guard let directory = projectURL else { return }
        let rootPath = directory.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard filePath.hasPrefix(prefix) else { return }
        let relative = String(filePath.dropFirst(prefix.count))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let commits = GitService.log(file: file, in: directory)
            DispatchQueue.main.async {
                guard let self, self.projectURL == directory else { return }
                let previewURL = self.diffPreviewURL(
                    in: directory, path: relative, commit: "file-history-table")
                self.editor.showFileHistory(FileHistoryModel(
                    tabURL: previewURL,
                    repository: directory,
                    relativePath: relative,
                    displayName: "\(file.lastPathComponent) History",
                    commits: commits))
            }
        }
    }

    /// Synthetic URL for a Git preview tab. The path identifies a Changes diff;
    /// adding a commit identifies a History diff. Reopening the same identity
    /// refreshes that tab, while different files/commits stay separate.
    private func diffPreviewURL(in directory: URL, path: String,
                                commit: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = DocumentStore.diffScheme
        components.host = ""
        components.path = "/" + directory.path + "/.puzzle-diff-preview"
        components.queryItems = [
            URLQueryItem(name: "window", value: diffPreviewID),
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "commit", value: commit),
        ]
        return components.url ?? directory.appendingPathComponent(".puzzle-diff-preview")
    }

    /// Teach the store how to rebuild a diff buffer from its URL, so those
    /// buffers can be evicted under memory pressure like any other.
    ///
    /// Registered once, at launch. History rebuilds byte for byte — a commit
    /// and a path name an immutable diff. A working-tree diff rebuilds as the
    /// diff *now*, which is the same thing clicking its row again would show.
    static func registerDiffContentProvider() {
        DocumentStore.shared.virtualContentProvider = { url in
            guard url.scheme == DocumentStore.diffScheme,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let path = components.queryItems?
                    .first(where: { $0.name == "path" })?.value,
                  !path.isEmpty else { return nil }
            let directory = URL(fileURLWithPath:
                (url.path as NSString).deletingLastPathComponent)
            let name = (path as NSString).lastPathComponent
            let commit = components.queryItems?
                .first(where: { $0.name == "commit" })?.value
            if let commit, !commit.isEmpty {
                return commitDiffContent(commit: commit, path: path, in: directory)
            }
            guard let text = GitService.diff(forPath: path, in: directory) else { return nil }
            return DocumentStore.VirtualContent(
                text: text, displayName: "\(name) (diff)",
                svgSides: GitService.svgDiffSides(for: path, in: directory))
        }
    }

    /// What a History row opens: the commit's diff for the file, or — for an
    /// SVG the commit *added* — the file itself with its picture above it.
    ///
    /// A diff that adds a file is every line with a `+` in front of it. For a
    /// picture that is worth nothing: the file as it stands reads better, and
    /// the preview has one version to show rather than two.
    static func commitDiffContent(commit: String, path: String,
                                  in directory: URL) -> DocumentStore.VirtualContent {
        let name = (path as NSString).lastPathComponent
        let sides = GitService.svgDiffSides(inCommit: commit, path: path, in: directory)
        if let sides, sides.before == nil, let after = sides.after,
           let text = String(data: after, encoding: .utf8) {
            return DocumentStore.VirtualContent(
                text: text, displayName: "\(name) @ \(commit)", svgSides: sides)
        }
        return DocumentStore.VirtualContent(
            text: GitService.diff(inCommit: commit, path: path, in: directory),
            displayName: "\(name) @ \(commit)", svgSides: sides)
    }

    /// Preserve the repository path below the per-commit temp directory. Using
    /// only `lastPathComponent` made `assets/icon.png` collide with
    /// `docs/icon.png`, so opening one could show the other's cached image.
    static func commitBlobURL(repository: URL, commit: String, path: String) -> URL {
        let repositoryKey = Data(
            repository.standardizedFileURL.resolvingSymlinksInPath().path.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("puzzle-blobs", isDirectory: true)
            .appendingPathComponent(repositoryKey, isDirectory: true)
            .appendingPathComponent(commit, isDirectory: true)
            .appendingPathComponent(path)
    }

    /// Saves arrive in bursts now that leaving a buffer writes it — switching
    /// tabs, clicking into the tree, leaving the window. Each git refresh is a
    /// subprocess and a repository walk, so a burst is collapsed into one.
    private func scheduleGitRefreshAfterSave() {
        gitRefreshAfterSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.gitRefreshAfterSave = nil
            self.sidebar.refreshGitPanelIfLoaded()
            self.refreshGit(requireFollowUp: true)
        }
        gitRefreshAfterSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.gitRefreshAfterSaveDelay,
                                      execute: work)
    }
    /// Long enough to swallow a burst of focus changes, short enough that the
    /// panel is current before the user can look at it.
    static let gitRefreshAfterSaveDelay: TimeInterval = 0.4
    private var gitRefreshAfterSave: DispatchWorkItem?

    /// Something committed, pushed or otherwise moved the repository.
    private func gitChanged() {
        refreshGit(requireFollowUp: true)
        // Committing rewrites authorship for the committed lines, and clears
        // the gutter marks for everything it took.
        editor.invalidateBlame()
        editor.refreshGitLineChanges()
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
            let split = GitService.trackedAndUntracked(in: status)
            DispatchQueue.main.async {
                guard let self else { return }
                self.gitSummaryRefreshInFlight = false
                self.gitSummaryDirectory = nil
                if self.projectURL == projectURL,
                   self.gitRefreshGeneration == generation {
                    self.sidebar.fileTree.setStatus(modified: split.modified,
                                                    untracked: split.untracked)
                    self.currentBranchName = status.isRepo ? status.branch : nil
                    self.sidebar.setChanges(
                        status.isRepo ? status.entries : [], in: projectURL,
                        state: status.isRepo
                            ? .init(head: status.head, ahead: status.ahead,
                                    hasUpstream: status.hasUpstream)
                            : .init())
                    self.sidebar.setProjectTitle(
                        project: projectURL.lastPathComponent,
                        branch: status.isRepo ? status.branch : "")
                    // The row beside the tree says the same thing the title
                    // strip does, and hears it at the same moment.
                    self.noteSummary(branch: status.isRepo ? status.branch : "",
                                     user: status.isRepo ? status.userName : "",
                                     changes: status.isRepo ? status.entries.count : 0,
                                     for: projectURL)
                    // A folder that is not a repository has no branch to name,
                    // and must not keep the last repository's.
                    self.window?.subtitle = status.isRepo
                        ? "\(projectURL.lastPathComponent) — \(status.branch)" : ""
                }
                if self.gitSummaryRefreshAgain {
                    self.gitSummaryRefreshAgain = false
                    self.refreshGit()
                }
            }
        }
    }

    /// Terminals tried, in order, when the project/branch strip beside the
    /// traffic lights is clicked.
    static let terminalBundleIDs = ["com.googlecode.iterm2", "com.apple.Terminal"]

    /// The first of those that is installed. Injectable so the preference order
    /// stays testable on a machine with or without iTerm.
    static func terminalApplication(
        lookup: (String) -> URL? = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }
    ) -> URL? {
        terminalBundleIDs.lazy.compactMap(lookup).first
    }

    /// Open the project folder in iTerm in a window of its own. Opening a folder
    /// through `NSWorkspace` lets iTerm reuse whatever window it already has, so
    /// ask it for a new one by script, and keep the plain open as the fallback
    /// (no iTerm, or automation not permitted).
    private func openProjectInTerminal() {
        guard let projectURL else { return }
        Self.openTerminal(at: projectURL)
    }

    /// Open a terminal window at `directory` — the title strip and the file
    /// tree's context menu both land here.
    static func openTerminal(at directory: URL) {
        let command = "cd " + shellQuoted(directory.path)
        // Launching iTerm already opens a window; asking for another on top of
        // that is what produced two. Only create one when it was running.
        let reuseLaunchWindow = !isITermRunning
        DispatchQueue.global(qos: .userInitiated).async {
            guard !runITermScript(command: command,
                                  reusingLaunchWindow: reuseLaunchWindow) else { return }
            DispatchQueue.main.async {
                guard let terminal = terminalApplication() else { return }
                NSWorkspace.shared.open([directory], withApplicationAt: terminal,
                                        configuration: NSWorkspace.OpenConfiguration(),
                                        completionHandler: nil)
            }
        }
    }

    static var isITermRunning: Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.googlecode.iterm2").isEmpty
    }

    /// Runs off the main thread: the reuse path waits for the launch window, and
    /// AppleScript execution blocks its caller.
    @discardableResult
    static func runITermScript(command: String, reusingLaunchWindow: Bool) -> Bool {
        guard NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.googlecode.iterm2") != nil else { return false }
        var error: NSDictionary?
        NSAppleScript(source: iTermScript(command: command,
                                          reusingLaunchWindow: reusingLaunchWindow))?
            .executeAndReturnError(&error)
        return error == nil
    }

    /// `reusingLaunchWindow` means iTerm is not running yet: the window its
    /// launch opens is the one to use, so wait for it instead of adding a second.
    static func iTermScript(command: String, reusingLaunchWindow: Bool) -> String {
        let reuse = """
              repeat 50 times
                if (count of windows) > 0 then exit repeat
                delay 0.1
              end repeat
              if (count of windows) > 0 then set targetWindow to current window
            """
        return """
            tell application "iTerm"
              activate
              set targetWindow to missing value
            \(reusingLaunchWindow ? reuse : "")
              if targetWindow is missing value then
                set targetWindow to (create window with default profile)
              end if
              tell current session of targetWindow
                write text "\(appleScriptQuoted(command))"
              end tell
            end tell
            """
    }

    /// Single-quote for the shell: everything inside is literal, and an embedded
    /// quote is closed, escaped and reopened.
    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escape for an AppleScript string literal.
    static func appleScriptQuoted(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Quick Open / Go to Line

    /// ⌘P. The file index is built off the main thread on first use and reused
    /// until the project changes, so typing stays responsive on a big checkout.
    @objc func quickOpen(_ sender: Any?) {
        guard let directory = projectURL, let window else { return }
        let panel = ensurePalette()
        panel.configure(placeholder: "Search files by name",
                        hint: "Type to filter · ↑↓ to choose · ↩ to open · esc to dismiss")
        panel.onQueryChanged = { [weak self, weak panel] query in
            guard let self, let panel else { return }
            panel.setItems(self.quickOpenItems(matching: query))
        }
        panel.onAccept = { [weak self, weak panel] item in
            panel?.dismiss()
            guard let self, let url = item?.value else { return }
            self.editor.open(url: url)
        }
        panel.setQuery("")
        panel.setItems(quickOpenItems(matching: ""))
        panel.present(over: window)
        refreshQuickOpenIndex(for: directory)
    }

    /// ⌘L. Same panel, no list: a line (or `line:column`) to jump to.
    @objc func goToLine(_ sender: Any?) {
        guard let window, editor.hasOpenDocument else { return }
        let panel = ensurePalette()
        panel.configure(placeholder: "Line number",
                        hint: "Type a line, or line:column · ↩ to jump · esc to dismiss")
        panel.onQueryChanged = { [weak panel] _ in panel?.setItems([]) }
        panel.onAccept = { [weak self, weak panel] _ in
            guard let self, let panel else { return }
            guard let target = QuickOpen.lineTarget(panel.query) else { return }
            panel.dismiss()
            self.editor.jumpToLine(target.line, column: target.column)
        }
        panel.setQuery("")
        panel.setItems([])
        panel.present(over: window)
    }

    private func ensurePalette() -> PalettePanel {
        if let palette { return palette }
        let made = PalettePanel()
        palette = made
        return made
    }

    private func quickOpenItems(matching query: String) -> [PalettePanel.Item] {
        guard let directory = projectURL else { return [] }
        return QuickOpen.matches(quickOpenIndex, query: query).map { path in
            PalettePanel.Item(title: (path as NSString).lastPathComponent,
                              detail: (path as NSString).deletingLastPathComponent,
                              value: directory.appendingPathComponent(path))
        }
    }

    private func refreshQuickOpenIndex(for directory: URL) {
        guard !quickOpenIndexInFlight else { return }
        quickOpenIndexInFlight = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let paths = QuickOpen.index(in: directory)
            DispatchQueue.main.async {
                guard let self, self.projectURL == directory else { return }
                self.quickOpenIndexInFlight = false
                self.quickOpenIndex = paths
                guard let palette = self.palette, palette.isVisible else { return }
                palette.setItems(self.quickOpenItems(matching: palette.query))
            }
        }
    }

    // MARK: - Branch menu

    /// How many branches the title-strip menu lists. Beyond this the Git panel's
    /// Branch tab is the place to look.
    static let branchMenuLimit = 10

    /// Branches for the menu: the current one first so switching away from it is
    /// obvious, then the most recently updated, capped at `branchMenuLimit`.
    static func branchMenuEntries(_ branches: [GitService.Branch]) -> [GitService.Branch] {
        let current = branches.filter(\.isCurrent)
        let rest = branches.filter { !$0.isCurrent }
        return Array((current + rest).prefix(branchMenuLimit))
    }

    /// Puts the menu on screen. `popUp` runs its own tracking loop until the
    /// menu closes, so a test hands in something that keeps the menu instead.
    var presentBranchMenu: (NSMenu, NSPoint, NSView) -> Void = { menu, origin, anchor in
        menu.popUp(positioning: nil, at: origin, in: anchor)
    }

    private func showBranchMenu(from rect: NSRect) {
        guard let directory = projectURL else { return }
        let anchor = sidebar.projectTitle
        gitSummaryQueue.async { [weak self] in
            let branches = GitService.branches(in: directory)
            DispatchQueue.main.async {
                guard let self, self.projectURL == directory else { return }
                let menu = NSMenu()
                menu.font = Theme.uiFont(11)
                let entries = Self.branchMenuEntries(branches)
                if entries.isEmpty {
                    let item = NSMenuItem(title: "No branches", action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    menu.addItem(item)
                }
                for branch in entries {
                    let item = NSMenuItem(title: branch.name,
                                          action: #selector(self.branchMenuItemSelected(_:)),
                                          keyEquivalent: "")
                    item.attributedTitle = Self.branchMenuTitle(branch)
                    item.target = self
                    item.representedObject = branch
                    item.state = branch.isCurrent ? .on : .off
                    menu.addItem(item)
                }
                if branches.count > entries.count {
                    menu.addItem(.separator())
                    let more = NSMenuItem(
                        title: "\(branches.count - entries.count) more in the Git panel…",
                        action: #selector(self.showBranchPanel), keyEquivalent: "")
                    more.target = self
                    menu.addItem(more)
                }
                // Just under the branch text, so the menu reads as its dropdown.
                let origin = NSPoint(x: rect.minX, y: rect.maxY)
                self.presentBranchMenu(menu, origin, anchor)
            }
        }
    }

    /// Two lines per item: the branch, then who last touched it and when.
    static func branchMenuTitle(_ branch: GitService.Branch) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 1
        let title = NSMutableAttributedString(
            string: branch.name,
            attributes: [.font: Theme.uiFont(11.5),
                         .foregroundColor: Theme.foreground,
                         .paragraphStyle: paragraph])
        let detail = branch.author.isEmpty
            ? branch.createdAt
            : "\(branch.author) · \(branch.createdAt)"
        title.append(NSAttributedString(
            string: "\n" + detail,
            attributes: [.font: Theme.uiFont(9.5),
                         .foregroundColor: Theme.dimText,
                         .paragraphStyle: paragraph]))
        return title
    }

    @objc private func showBranchPanel() {
        sidebar.showGit()
        sidebar.showGitBranches()
    }

    @objc private func branchMenuItemSelected(_ sender: NSMenuItem) {
        guard let branch = sender.representedObject as? GitService.Branch,
              let directory = projectURL else { return }
        switchBranch(branch, in: directory)
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
        if branch.isRemote, branch.upstreamBranch == nil {
            return .unavailable(reason:
                "This remote-tracking ref has no branch name to check out locally. "
                    + "Create a local branch from it in the Git panel's Branch tab.")
        }
        if let current, current == branch.name { return .alreadyCurrent }
        return .confirm(from: current ?? "the current branch", to: branch.name)
    }

    /// Switch to `branch`, explaining first. A switch that cannot happen says
    /// why instead of asking; one that can names both ends before it runs.
    private func switchBranch(_ branch: GitService.Branch, in directory: URL) {
        let from: String
        switch Self.branchSwitch(to: branch, from: currentBranchName) {
        case .alreadyCurrent:
            presentBranchAlert(
                title: "Already on “\(branch.name)”",
                message: "This is the branch the working tree is already checked out to.")
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
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        gitSummaryQueue.async { [weak self] in
            let result = GitService.switchBranch(branch, in: directory)
            DispatchQueue.main.async {
                guard let self, self.projectURL == directory else { return }
                if result.ok {
                    self.refreshExternalGitState()
                } else {
                    // Git refused it — a dirty tree it cannot preserve, a
                    // missing ref — so hand its own words to the user.
                    self.presentBranchAlert(
                        title: "Could not switch to “\(branch.name)”",
                        message: result.message)
                }
            }
        }
    }

    private func presentBranchAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.runModal()
    }

    /// Re-apply fonts/metrics after settings.json changes.
    func refreshDisplay() {
        editor.refreshDisplay()
        sidebar.refreshFonts()
        root.refreshAppearance()
    }

    // MARK: - Menu actions (reached via the responder chain)

    /// Set when this window has no project yet (the welcome screen) — then
    /// "Open Folder" fills this window instead of spawning another empty one.
    var hasProject: Bool { projectURL != nil }

    /// The app routes both files and folders to an existing project first.
    var onOpenRequested: (([URL]) -> Void)?

    func openSelection(_ urls: [URL]) {
        if let handler = onOpenRequested {
            handler(urls)
            return
        }
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                openProject(url)
            } else {
                if !hasProject { openProject(url.deletingLastPathComponent()) }
                editor.open(url: url)
            }
        }
    }

    /// Reorder the strip. Which project is showing does not change: the order
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
    /// Closing the one being shown moves to a neighbour — the tabs of the
    /// project being left close either way. Closing the last one empties the
    /// window back to the welcome screen rather than leaving a tree and a Git
    /// panel pointing at a project that is no longer here.
    func closeProject(_ url: URL) {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard let index = projects.firstIndex(of: resolved) else { return }
        let wasShowing = projectURL == resolved
        projects.remove(at: index)
        guard wasShowing else {
            refreshProjectTabs()
            return
        }
        guard let next = projects.indices.contains(index)
                ? projects[index] : projects.last else {
            closeLastProject()
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

    private func closeLastProject() {
        clearProject()
        refreshProjectTabs()
    }

    /// Put the window back to having nothing open: no tabs, no monitors, no
    /// tree, no Git. Whether any projects remain in the list is the caller's
    /// business.
    private func clearProject() {
        editor.closeAllTabs()
        gitRepositoryMonitor?.stop()
        gitRepositoryMonitor = nil
        workspaceFileMonitor?.stop()
        workspaceFileMonitor = nil
        GitService.forgetRepositoryInfo()
        projectURL = nil
        quickOpenIndex = []
        palette?.dismiss()
        editor.hasProject = false
        editor.repositoryRoot = nil
        sidebar.fileTree.clearRoot()
        sidebar.clearChanges(for: nil)
        sidebar.setDirectory(nil)
        sidebar.setProjectTitle(project: "", branch: "")
        // Bumping the generation discards a refresh that is already in flight,
        // which would otherwise arrive and speak for a project that is no
        // longer on screen.
        gitRefreshGeneration += 1
        currentBranchName = nil
        window?.subtitle = ""
        refreshWindowTitle(activeFile: nil)
    }

    /// What each row says after the project's name: the branch it is on, who
    /// commits there, and how many files it has changed. The project on screen
    /// keeps its entry current from every Git refresh; the others are read
    /// once, when they join the window.
    private var projectSummaries: [URL: ProjectSummary] = [:]
    /// Summaries of the projects behind the one on screen are read here, off
    /// the queue that project's own history and commit files are read on, so
    /// a sweep over several large repositories does not hold those up.
    private static let summaryQueue = DispatchQueue(label: "app.puzzle.git-summaries",
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
            active: projectURL.flatMap { projects.firstIndex(of: $0) })
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

    /// What the panel reports for the project on screen, which is fresher than
    /// anything cached — it arrives with every Git refresh.
    private func noteSummary(branch: String, user: String, changes: Int, for url: URL) {
        let summary = ProjectSummary(branch: branch, user: user, changes: changes)
        guard projectSummaries[url] != summary else { return }
        projectSummaries[url] = summary
        refreshProjectTabs()
    }

    @objc func openFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Open"
        panel.message = "Choose files or a project folder"
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.openSelection(panel.urls)
        }
    }

    @objc func saveDocument(_ sender: Any?) { editor.save() }
    @objc func findInFile(_ sender: Any?) { editor.showFindBar() }
    @objc func findAndReplace(_ sender: Any?) { editor.showFindBar(replacing: true) }
    @objc func showSidebar(_ sender: Any?) { root.showSidebar() }

    @objc func showSettings(_ sender: Any?) { openSettings() }

    /// ⌘W. With nothing open the window itself closes, so the shortcut never
    /// feels dead.
    @objc func closeTab(_ sender: Any?) {
        guard editor.closeActiveTab() else {
            window?.performClose(sender)
            return
        }
    }
    @objc func selectNextTab(_ sender: Any?) { editor.stepTab(by: 1) }
    @objc func selectPreviousTab(_ sender: Any?) { editor.stepTab(by: -1) }
    @objc func reopenClosedTab(_ sender: Any?) {
        guard !editor.reopenLastClosedTab() else { return }
        NSSound.beep()
    }
    @objc func showFiles(_ sender: Any?) {
        root.showSidebar(); sidebar.showFiles(); root.preserveSidebarWidth()
    }

    @objc func findInFolder(_ sender: Any?) {
        root.showSidebar(); sidebar.showSearch(); root.preserveSidebarWidth()
    }

    @objc func showGit(_ sender: Any?) {
        root.showSidebar(); sidebar.showGit(); root.preserveSidebarWidth()
    }

    /// Open settings.json in this window's editor (creating it if needed).
    func openSettings() {
        editor.open(url: Settings.shared.ensureFileExists())
    }

    /// Activity-bar routing: the sidebar is always visible; tapping an action
    /// selects the requested panel.
    private func handleActivity(_ action: ActivityBarView.Action) {
        // Tapping an action selects its panel; the sidebar remains visible.
        root.showSidebar()
        switch action {
        case .project:  sidebar.showFiles()
        case .search:   sidebar.showSearch()
        case .git:      sidebar.showGit()
        }
        root.preserveSidebarWidth()
    }
}

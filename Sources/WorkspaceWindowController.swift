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
        // Follow the system appearance (light/dark) exactly like Zed does when no
        // theme is pinned. Zed-style header: full-size content with the tabs
        // beside the traffic lights, transparent flat titlebar, no toolbar.
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
        sidebar.onGitChanged = { [weak self] in
            self?.refreshGit(requireFollowUp: true)
            // Committing rewrites authorship for the committed lines.
            self?.editor.invalidateBlame()
        }
        sidebar.activityBar.onAction = { [weak self] action in self?.handleActivity(action) }
        sidebar.projectTitle.onProjectClick = { [weak self] in self?.openProjectInTerminal() }
        sidebar.projectTitle.onBranchClick = { [weak self] rect in
            self?.showBranchMenu(from: rect)
        }
        editor.onOpenFolder = { [weak self] in self?.openFolder(nil) }
        editor.onOpenRecent = { [weak self] url in self?.openProject(url) }
        editor.onDocumentSaved = { [weak self] url in
            self?.sidebar.refreshGitPanelIfLoaded()
            self?.refreshGit(requireFollowUp: true)
            // The file changed on disk, so its cached blame is stale.
            self?.editor.invalidateBlame(for: url)
            // Saving settings.json applies the new display config immediately.
            if url.standardizedFileURL == Settings.fileURL.standardizedFileURL {
                Settings.shared.reload()
            }
        }
        // Keep the file tree's active-file highlight in sync with the active tab.
        editor.onActiveDocumentChanged = { [weak self] url in
            guard let self, let url else { return }
            self.sidebar.fileTree.selectFile(url)
            self.window?.title = url.lastPathComponent
        }
    }

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
        sidebar.releaseHiddenPanels()
        editor.releaseTransientMemory()
        DocumentStore.shared.releaseTransientMemory()
        // Nothing is drawing file rows while the window is in the Dock.
        FileIcons.releaseTransientMemory()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        updateTitlebarGeometry()
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
        sidebar.releaseHiddenPanels()
        editor.releaseTransientMemory()
    }

    // MARK: - Project

    func openProject(_ url: URL) {
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
        sidebar.setDirectory(url)
        // Show the name straight away; the branch follows the Git refresh.
        sidebar.setProjectTitle(project: url.lastPathComponent, branch: "")
        window?.title = url.lastPathComponent
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
    }

    /// Synchronize every Git-derived surface after another process changes the
    /// repository, and when Puzzle becomes active after such a change.
    func refreshExternalGitState() {
        guard let projectURL else { return }
        let reloaded = DocumentStore.shared.reloadExternalChanges(at: [projectURL])
        sidebar.fileTree.refresh(changedURLs: [projectURL])
        sidebar.refreshGitPanelIfLoaded()
        refreshGit(requireFollowUp: true)
        if reloaded.isEmpty {
            editor.invalidateBlame()
        } else {
            reloaded.forEach { editor.invalidateBlame(for: $0) }
        }
    }

    /// Show a file's git diff in the editor, coloured by DiffHighlighter.
    /// The diff is a virtual document, so it opens as a normal (read-only) tab.
    /// True when a path is a picture we can preview. `git diff` on a binary just
    /// says "Binary files differ", so showing the image itself is far more useful.
    private static func isImage(_ path: String) -> Bool {
        Document.imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    func showDiff(for entry: GitService.Status.Entry, in directory: URL) {
        // Images preview instead of diffing — same view the file tree gives.
        if Self.isImage(entry.path) {
            let fileURL = directory.appendingPathComponent(entry.path)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                editor.open(url: fileURL)
                return
            }
            // Deleted image: nothing on disk to show, fall through to the diff.
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let text = GitService.diff(for: entry, in: directory)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.projectURL == directory else { return }
                let url = self.diffPreviewURL(in: directory, path: entry.path)
                // Replace any previous diff for this file so re-clicking refreshes.
                DocumentStore.shared.setVirtualDocument(
                    url: url, text: text,
                    displayName: "\((entry.path as NSString).lastPathComponent) (diff)")
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
            let text = GitService.diff(inCommit: commit.shortHash, path: file.path, in: directory)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.projectURL == directory else { return }
                let url = self.diffPreviewURL(in: directory,
                                              path: file.path, commit: commit.shortHash)
                let name = (file.path as NSString).lastPathComponent
                DocumentStore.shared.setVirtualDocument(
                    url: url, text: text, displayName: "\(name) @ \(commit.shortHash)")
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

    func refreshGit(requireFollowUp: Bool = false) {
        guard let projectURL else { return }
        if gitSummaryRefreshInFlight {
            if gitSummaryDirectory != projectURL || requireFollowUp {
                gitSummaryRefreshAgain = true
            }
            return
        }
        gitSummaryRefreshInFlight = true
        gitSummaryDirectory = projectURL
        gitRefreshGeneration += 1
        let generation = gitRefreshGeneration
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
                    self.sidebar.activityBar.setChangeCount(
                        status.isRepo ? status.entries.count : 0)
                    self.sidebar.setProjectTitle(
                        project: projectURL.lastPathComponent,
                        branch: status.isRepo ? status.branch : "")
                    if status.isRepo {
                        self.window?.subtitle = "\(projectURL.lastPathComponent) — \(status.branch)"
                    }
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
                menu.popUp(positioning: nil, at: origin, in: anchor)
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

    /// Asked to open a folder; the app decides which window receives it.
    var onOpenFolderRequested: ((URL) -> Void)?

    @objc func openFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a project folder"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            if let handler = self.onOpenFolderRequested {
                handler(url)
            } else {
                self.openProject(url)
            }
        }
    }

    @objc func saveDocument(_ sender: Any?) { editor.save() }
    @objc func findInFile(_ sender: Any?) { editor.showFindBar() }
    @objc func findAndReplace(_ sender: Any?) { editor.showFindBar(replacing: true) }
    @objc func showSidebar(_ sender: Any?) { root.showSidebar() }
    @objc func splitEditor(_ sender: Any?) { editor.splitEditor() }

    @objc func showSettings(_ sender: Any?) { openSettings() }

    /// ⌘W. With nothing open the window itself closes, so the shortcut never
    /// feels dead.
    @objc func closeTab(_ sender: Any?) {
        guard editor.closeActiveTab() else {
            window?.performClose(sender)
            return
        }
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
        if action == .settings {
            openSettings()
            return
        }
        // Tapping an action selects its panel; the sidebar remains visible.
        root.showSidebar()
        switch action {
        case .project:  sidebar.showFiles()
        case .search:   sidebar.showSearch()
        case .git:      sidebar.showGit()
        case .settings: break
        }
        root.preserveSidebarWidth()
    }
}

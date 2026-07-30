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

    /// Called when the window closes, so the app can drop its reference.
    var onClose: ((WorkspaceWindowController) -> Void)?

    /// Windows are staggered so a new one doesn't hide the previous.
    private static var cascadePoint = NSPoint(x: 0, y: 0)

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
        window.setContentSize(NSSize(width: 1080, height: 720))
        window.delegate = self
        window.isReleasedWhenClosed = false

        window.center()
        Self.cascadePoint = window.cascadeTopLeft(from: Self.cascadePoint)

        wire()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func wire() {
        sidebar.fileTree.onOpenFile = { [weak self] url in self?.editor.open(url: url) }
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
            self?.refreshGit()
            // Committing rewrites authorship for the committed lines.
            self?.editor.invalidateBlame()
        }
        sidebar.activityBar.onAction = { [weak self] action in self?.handleActivity(action) }

        editor.onOpenFolder = { [weak self] in self?.openFolder(nil) }
        editor.onOpenRecent = { [weak self] url in self?.openProject(url) }
        editor.onDocumentSaved = { [weak self] url in
            self?.refreshGit()
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
        // Release this window's buffers rather than leaving its layout
        // managers attached to them.
        editor.detachAllPanes()
        onClose?(self)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        sidebar.releaseHiddenPanels()
        DocumentStore.shared.releaseTransientMemory()
    }

    func releaseTransientMemory() {
        sidebar.releaseHiddenPanels()
    }

    // MARK: - Project

    func openProject(_ url: URL) {
        projectURL = url
        editor.hasProject = true
        editor.repositoryRoot = url
        RecentProjects.shared.add(url)
        sidebar.fileTree.setRoot(url)
        sidebar.setDirectory(url)
        window?.title = url.lastPathComponent
        refreshGit()
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
        DispatchQueue.global(qos: .userInitiated).async {
            let text = GitService.diff(for: entry, in: directory)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let url = Self.diffURL(for: entry.path, in: directory)
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
            DispatchQueue.global(qos: .userInitiated).async {
                guard let data = GitService.blob(inCommit: commit.shortHash,
                                                 path: file.path, in: directory),
                      !data.isEmpty else { return }
                let name = (file.path as NSString).lastPathComponent
                let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("puzzle-blobs/\(commit.shortHash)")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let temp = dir.appendingPathComponent(name)
                try? data.write(to: temp)
                DispatchQueue.main.async { [weak self] in
                    self?.editor.open(url: temp)
                }
            }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let text = GitService.diff(inCommit: commit.shortHash, path: file.path, in: directory)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let url = Self.diffURL(for: file.path, in: directory, commit: commit.shortHash)
                let name = (file.path as NSString).lastPathComponent
                DocumentStore.shared.setVirtualDocument(
                    url: url, text: text, displayName: "\(name) @ \(commit.shortHash)")
                self.editor.open(url: url, replacingContent: true)
            }
        }
    }

    /// Synthetic URL identifying a diff tab, under a `puzzle-diff` scheme so it
    /// can't collide with a real file on disk. A commit hash (when present)
    /// keeps each commit's diff of the same file in its own tab.
    static func diffURL(for path: String, in directory: URL, commit: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = DocumentStore.diffScheme
        components.host = ""
        components.path = "/" + directory.path + "/" + path
        if let commit { components.query = "commit=\(commit)" }
        return components.url ?? directory.appendingPathComponent(path + ".diff")
    }

    func refreshGit() {
        guard let projectURL else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let split = GitService.trackedAndUntracked(in: projectURL)
            let status = GitService.status(in: projectURL)
            DispatchQueue.main.async {
                self?.sidebar.fileTree.setStatus(modified: split.modified,
                                                 untracked: split.untracked)
                if status.isRepo {
                    self?.window?.subtitle = "\(projectURL.lastPathComponent) — \(status.branch)"
                }
            }
        }
    }

    /// Re-apply fonts/metrics after settings.json changes.
    func refreshDisplay() {
        editor.refreshDisplay()
        sidebar.refreshFonts()
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
    @objc func toggleSidebar(_ sender: Any?) { root.toggleSidebar() }
    @objc func splitEditor(_ sender: Any?) { editor.splitEditor() }
    @objc func toggleMarkdownPreview(_ sender: Any?) { editor.toggleMarkdownPreview() }

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

    /// Activity-bar routing: tapping the visible panel's button collapses the
    /// sidebar; tapping another switches to it (revealing the sidebar if hidden).
    private func handleActivity(_ action: ActivityBarView.Action) {
        if action == .settings {
            openSettings()
            return
        }
        // Tapping the button of the panel already showing used to collapse the
        // sidebar; it now simply keeps that panel visible.
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

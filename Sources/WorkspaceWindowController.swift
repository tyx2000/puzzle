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
        // Follow the system appearance (light/dark) exactly like Zed does when no
        // theme is pinned. Zed-style header: full-size content with the tabs
        // beside the traffic lights, transparent flat titlebar, no toolbar.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = Theme.barBackground
        window.contentViewController = root
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
        sidebar.search.onOpenResult = { [weak self] url, line in
            self?.editor.open(url: url)
            self?.editor.jumpToLine(line)
        }
        sidebar.search.onOpenFile = { [weak self] url in self?.editor.open(url: url) }
        sidebar.gitPanel.onOpenFile = { [weak self] url in self?.editor.open(url: url) }
        sidebar.gitPanel.onOpenDiff = { [weak self] entry, directory in
            self?.showDiff(for: entry, in: directory)
        }
        sidebar.gitPanel.onChanged = { [weak self] in self?.refreshGit() }
        sidebar.activityBar.onAction = { [weak self] action in self?.handleActivity(action) }

        editor.onOpenFolder = { [weak self] in self?.openFolder(nil) }
        editor.onOpenRecent = { [weak self] url in self?.openProject(url) }
        editor.onDocumentSaved = { [weak self] url in
            self?.refreshGit()
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
        onClose?(self)
    }

    // MARK: - Project

    func openProject(_ url: URL) {
        projectURL = url
        RecentProjects.shared.add(url)
        sidebar.fileTree.setRoot(url)
        sidebar.search.setDirectory(url)
        sidebar.gitPanel.setDirectory(url)
        window?.title = url.lastPathComponent
        refreshGit()
    }

    /// Show a file's git diff in the editor, coloured by DiffHighlighter.
    /// The diff is a virtual document, so it opens as a normal (read-only) tab.
    func showDiff(for entry: GitService.Status.Entry, in directory: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            let text = GitService.diff(for: entry, in: directory)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let url = Self.diffURL(for: entry.path, in: directory)
                // Replace any previous diff for this file so re-clicking refreshes.
                DocumentStore.shared.setVirtualDocument(url: url, text: text)
                self.editor.open(url: url, replacingContent: true)
            }
        }
    }

    /// Synthetic URL identifying a diff tab: `<file>.diff` under a `puzzle-diff`
    /// scheme so it can't collide with a real file on disk.
    static func diffURL(for path: String, in directory: URL) -> URL {
        var components = URLComponents()
        components.scheme = DocumentStore.diffScheme
        components.host = ""
        components.path = "/" + directory.path + "/" + path
        return components.url ?? directory.appendingPathComponent(path + ".diff")
    }

    func refreshGit() {
        guard let projectURL else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let dirty = GitService.dirtyPaths(in: projectURL)
            let status = GitService.status(in: projectURL)
            DispatchQueue.main.async {
                self?.sidebar.fileTree.setDirtyPaths(dirty)
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

    @objc func openFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a project folder"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.openProject(url)
        }
    }

    @objc func saveDocument(_ sender: Any?) { editor.save() }
    @objc func findInFile(_ sender: Any?) { editor.showFindBar() }
    @objc func toggleSidebar(_ sender: Any?) { root.toggleSidebar() }
    @objc func splitEditor(_ sender: Any?) { editor.splitEditor() }

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
        if sidebar.visiblePanel == action {
            root.toggleSidebar()
            return
        }
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

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
    /// One replaceable Git preview buffer per window. Giving every path/commit a
    /// permanent synthetic URL made an inspection session grow without bound.
    private let diffPreviewID = UUID().uuidString

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

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        editor.confirmClose()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        sidebar.releaseHiddenPanels()
        editor.releaseTransientMemory()
        DocumentStore.shared.releaseTransientMemory()
    }

    func releaseTransientMemory() {
        sidebar.releaseHiddenPanels()
        editor.releaseTransientMemory()
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

    func refreshGit() {
        guard let projectURL else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let split = GitService.trackedAndUntracked(in: projectURL)
            let status = GitService.status(in: projectURL)
            DispatchQueue.main.async {
                guard let self, self.projectURL == projectURL else { return }
                self.sidebar.fileTree.setStatus(modified: split.modified,
                                                untracked: split.untracked)
                if status.isRepo {
                    self.window?.subtitle = "\(projectURL.lastPathComponent) — \(status.branch)"
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
    @objc func showSidebar(_ sender: Any?) { root.showSidebar() }
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

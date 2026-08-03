import AppKit

/// Left panel: file tree or search, with Zed's 40pt action bar pinned at the
/// bottom (its width is the panel's width). Swapping panels never changes the
/// panel width.
final class SidebarViewController: NSViewController {
    let fileTree = FileTreeViewController()
    let activityBar = ActivityBarView()

    // Search and Git each own an outline/table view, scroll view, controls and
    // (for Git) another NSTextView. Most windows never show both panels, so do
    // not build those view trees until the user asks for them.
    private var searchController: SearchViewController?
    private var gitController: GitPanelViewController?
    private var mountedControllers: [NSViewController] = []
    private var directory: URL?

    var onSearchResult: ((URL, Int) -> Void)?
    var onSearchFile: ((URL) -> Void)?
    var onGitFile: ((URL) -> Void)?
    var onGitDiff: ((GitService.Status.Entry, URL) -> Void)?
    var onGitCommitDiff: ((GitService.Commit, GitService.CommitFile, URL) -> Void)?
    var onGitChanged: (() -> Void)?

    private let containerView = NSView()
    /// Which panel is currently visible.
    private(set) var visiblePanel: ActivityBarView.Action = .project

    override func loadView() {
        let root = FlatView()
        root.fillColor = Theme.panelBackground

        containerView.translatesAutoresizingMaskIntoConstraints = false
        activityBar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(containerView)
        root.addSubview(activityBar)

        NSLayoutConstraint.activate([
            // Match the editor's first tab row while clearing the traffic lights.
            containerView.topAnchor.constraint(equalTo: root.topAnchor,
                                               constant: EditorTabBar.rowHeight),
            containerView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: activityBar.topAnchor),

            activityBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            activityBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            activityBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        self.view = root

        mount(fileTree)
        showFiles()
    }

    func setDirectory(_ url: URL) {
        directory = url
        searchController?.setDirectory(url)
        gitController?.setDirectory(url)
    }

    func showFiles() {
        visiblePanel = .project
        reveal(fileTree)
        activityBar.setSelected(.project)
    }
    func showSearch() {
        let search = ensureSearch()
        visiblePanel = .search
        reveal(search)
        activityBar.setSelected(.search)
        search.focusSearchField()
    }
    func showGit() {
        let gitPanel = ensureGit()
        visiblePanel = .git
        reveal(gitPanel)
        activityBar.setSelected(.git)
    }

    /// Re-apply the UI font (`ui_font_*`) across every panel in the sidebar.
    func refreshFonts() {
        fileTree.refreshAppearance()
        searchController?.refreshFonts()
        gitController?.refreshFonts()
    }

    /// External Git tools can update an already-visible panel without routing
    /// through one of the panel's own actions. Do not instantiate a hidden Git
    /// panel just for this; its first reveal already performs a full refresh.
    func refreshGitPanelIfLoaded() {
        gitController?.refreshExternal()
    }

    private func reveal(_ vc: NSViewController) {
        for other in mountedControllers {
            other.view.isHidden = (other !== vc)
        }
    }

    private func mount(_ controller: NSViewController) {
        guard !mountedControllers.contains(where: { $0 === controller }) else { return }
        addChild(controller)
        let panel = controller.view
        panel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: containerView.topAnchor),
            panel.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
        ])
        mountedControllers.append(controller)
    }

    private func unmount(_ controller: NSViewController) {
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        mountedControllers.removeAll { $0 === controller }
    }

    /// Drop heavy hidden view trees under memory pressure or when the window is
    /// miniaturized. Reopening a panel recreates it and refreshes its data.
    func releaseHiddenPanels() {
        if visiblePanel != .search, let search = searchController {
            search.releaseTransientMemory()
            unmount(search)
            searchController = nil
        }
        if visiblePanel != .git, let git = gitController {
            git.releaseTransientMemory()
            unmount(git)
            gitController = nil
        }
    }

    private func ensureSearch() -> SearchViewController {
        if let searchController { return searchController }
        let search = SearchViewController()
        search.onOpenResult = { [weak self] url, line in self?.onSearchResult?(url, line) }
        search.onOpenFile = { [weak self] url in self?.onSearchFile?(url) }
        if let directory { search.setDirectory(directory) }
        searchController = search
        mount(search)
        return search
    }

    private func ensureGit() -> GitPanelViewController {
        if let gitController { return gitController }
        let git = GitPanelViewController()
        git.onOpenFile = { [weak self] url in self?.onGitFile?(url) }
        git.onOpenDiff = { [weak self] entry, directory in self?.onGitDiff?(entry, directory) }
        git.onOpenCommitDiff = { [weak self] commit, file, directory in
            self?.onGitCommitDiff?(commit, file, directory)
        }
        git.onChanged = { [weak self] in self?.onGitChanged?() }
        if let directory { git.setDirectory(directory) }
        gitController = git
        mount(git)
        return git
    }

    func performSearch(_ query: String) { ensureSearch().performSearch(query) }
    func showHistory() { ensureGit().showHistory() }
    func expandCommit(at index: Int) { ensureGit().expandCommit(at: index) }
    func openCommitFile(commitIndex: Int, fileIndex: Int) {
        ensureGit().openCommitFile(commitIndex: commitIndex, fileIndex: fileIndex)
    }

}

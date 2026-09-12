import AppKit

/// Left panel: file tree or search, with Zed's 40pt action bar pinned at the
/// bottom (its width is the panel's width). Swapping panels never changes the
/// panel width.
final class SidebarViewController: NSViewController {
    let fileTree = FileTreeViewController()
    let activityBar = ActivityBarView()
    /// Project name + branch beside the traffic lights (the panel owns that
    /// strip of the titlebar because it is the view underneath it).
    let projectTitle = ProjectTitleView()
    /// The Projects panel: the window's projects, with the selected one's tree
    /// expanded under its row.
    private(set) lazy var projectsPanel = ProjectsPanelViewController(fileTree: fileTree)
    /// A project row was chosen, or its ✕ was clicked.
    var onSelectProjectRow: ((Int) -> Void)?
    var onCloseProjectRow: ((Int) -> Void)?
    var onReorderProjectRows: ((Int, Int) -> Void)?
    /// The button at the end of the title band. Listing the open projects is
    /// the Projects panel's job now; this opens another one.
    private let addProjectButton = NSButton()
    var onAddProject: (() -> Void)?

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
    /// The 1pt line under the traffic-light band — the same boundary the
    /// activity bar draws at the bottom of the panel.
    private let titleSeparator = FlatView()
    private var containerTopConstraint: NSLayoutConstraint!
    private var projectTitleLeadingConstraint: NSLayoutConstraint!
    /// Which panel is currently visible.
    private(set) var visiblePanel: ActivityBarView.Action = .project

    override func loadView() {
        let root = FlatView()
        root.fillColor = Theme.panelBackground

        containerView.translatesAutoresizingMaskIntoConstraints = false
        activityBar.translatesAutoresizingMaskIntoConstraints = false
        projectTitle.translatesAutoresizingMaskIntoConstraints = false
        titleSeparator.translatesAutoresizingMaskIntoConstraints = false
        titleSeparator.fillColor = Theme.border
        root.addSubview(containerView)
        root.addSubview(activityBar)
        root.addSubview(projectTitle)
        configure(addProjectButton, symbol: "plus",
                  label: "Open project",
                  tip: "Open another project",
                  action: #selector(addProjectAction))
        root.addSubview(addProjectButton)
        root.addSubview(titleSeparator)

        containerTopConstraint = containerView.topAnchor.constraint(
            equalTo: root.topAnchor, constant: EditorTabBar.defaultRowHeight)
        // Sits in the band the panel leaves empty for the traffic lights; the
        // window controller supplies the real inset once AppKit has laid the
        // buttons out.
        projectTitleLeadingConstraint = projectTitle.leadingAnchor.constraint(
            equalTo: root.leadingAnchor, constant: 78)
        NSLayoutConstraint.activate([
            // Match the editor's first tab row while clearing the traffic lights.
            containerTopConstraint,
            projectTitleLeadingConstraint,
            // The strip is exactly the file-tab band, so its text sits on the
            // traffic lights' centre line.
            projectTitle.topAnchor.constraint(equalTo: root.topAnchor),
            projectTitle.bottomAnchor.constraint(equalTo: containerView.topAnchor),
            // The name truncates rather than pushing the button off the end.
            projectTitle.trailingAnchor.constraint(
                lessThanOrEqualTo: addProjectButton.leadingAnchor, constant: -6),
            addProjectButton.trailingAnchor.constraint(
                equalTo: root.trailingAnchor, constant: -8),
            addProjectButton.centerYAnchor.constraint(equalTo: projectTitle.centerYAnchor),
            addProjectButton.widthAnchor.constraint(equalToConstant: 22),
            addProjectButton.heightAnchor.constraint(equalToConstant: 20),
            titleSeparator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            titleSeparator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            titleSeparator.bottomAnchor.constraint(equalTo: containerView.topAnchor),
            titleSeparator.heightAnchor.constraint(equalToConstant: 1),

            containerView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: activityBar.topAnchor),

            activityBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            activityBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            activityBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        self.view = root

        projectsPanel.onSelect = { [weak self] in self?.onSelectProjectRow?($0) }
        projectsPanel.onClose = { [weak self] in self?.onCloseProjectRow?($0) }
        projectsPanel.onReorder = { [weak self] from, to in
            self?.onReorderProjectRows?(from, to)
        }
        mount(projectsPanel)
        showFiles()
    }

    /// The title band's buttons, drawn like the editor's settings gear.
    private func configure(_ button: NSButton, symbol: String, label: String,
                           tip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = Theme.dimText
        button.toolTip = tip
        button.setAccessibilityLabel(label)
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    @objc private func addProjectAction() { onAddProject?() }

    var addProjectButtonForTesting: NSButton { addProjectButton }

    func setFileTabHeight(_ height: CGFloat) {
        containerTopConstraint.constant = height
    }

    /// Start the project/branch strip after the actual traffic lights.
    func setTitlebarLeadingInset(_ inset: CGFloat) {
        projectTitleLeadingConstraint.constant = inset
    }

    func setProjectTitle(project: String, branch: String) {
        projectTitle.configure(project: project, branch: branch)
    }

    var fileTreeTopInsetForTesting: CGFloat { containerTopConstraint.constant }
    var titleSeparatorForTesting: FlatView { titleSeparator }

    /// `nil` when the window has no project left: the panels empty rather than
    /// keep answering for a project that is no longer here.
    func setDirectory(_ url: URL?) {
        directory = url
        searchController?.setDirectory(url)
        gitController?.setDirectory(url)
    }

    func showFiles() {
        visiblePanel = .project
        reveal(projectsPanel)
        activityBar.setSelected(.project)
    }

    /// The window's projects, newest last, and which one is showing.
    func setProjects(_ projects: [(name: String, branch: String, path: String)],
                     active: Int?) {
        projectsPanel.configure(projects: projects, active: active)
    }
    func showSearch() {
        let search = ensureSearch()
        visiblePanel = .search
        reveal(search)
        activityBar.setSelected(.search)
        search.focusSearchField()
    }
    /// Reveal the Git panel already switched to its Branch tab.
    func showGitBranches() {
        showGit()
        gitController?.showBranchTab()
    }

    func showGit() {
        let gitPanel = ensureGit()
        visiblePanel = .git
        reveal(gitPanel)
        activityBar.setSelected(.git)
    }

    /// Re-apply the UI font (`ui_font_*`) across every panel in the sidebar.
    func refreshFonts() {
        (view as? FlatView)?.fillColor = Theme.panelBackground
        titleSeparator.fillColor = Theme.border
        activityBar.refreshAppearance()
        projectTitle.refreshAppearance()
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

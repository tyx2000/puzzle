import AppKit

/// Left panel: file tree or search, with Zed's 40pt action bar pinned at the
/// bottom (its width is the panel's width). Swapping panels never changes the
/// panel width.
final class SidebarViewController: NSViewController {
    let fileTree = FileTreeViewController()
    let search = SearchViewController()
    let gitPanel = GitPanelViewController()
    let activityBar = ActivityBarView()

    private let containerView = NSView()
    /// Which panel is currently visible.
    private(set) var visiblePanel: ActivityBarView.Action = .project

    override func loadView() {
        let root = FlatView()
        root.fillColor = Theme.panelBackground
        root.rightBorder = true

        containerView.translatesAutoresizingMaskIntoConstraints = false
        activityBar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(containerView)
        root.addSubview(activityBar)

        NSLayoutConstraint.activate([
            // Room at the top for the traffic lights (full-size content window).
            containerView.topAnchor.constraint(equalTo: root.topAnchor, constant: 30),
            containerView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: activityBar.topAnchor),

            activityBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            activityBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            activityBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        self.view = root

        // Mount all three panels once and switch with `isHidden`. Adding/removing
        // views made the split view re-resolve the divider, which changed the
        // panel width when switching panels.
        addChild(fileTree)
        addChild(search)
        addChild(gitPanel)
        for vc in [fileTree, search, gitPanel] as [NSViewController] {
            let v = vc.view
            v.translatesAutoresizingMaskIntoConstraints = false
            containerView.addSubview(v)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: containerView.topAnchor),
                v.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
                v.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            ])
        }
        showFiles()
    }

    func showFiles() {
        visiblePanel = .project
        reveal(fileTree)
        activityBar.setSelected(.project)
    }
    func showSearch() {
        visiblePanel = .search
        reveal(search)
        activityBar.setSelected(.search)
        search.focusSearchField()
    }
    func showGit() {
        visiblePanel = .git
        reveal(gitPanel)
        activityBar.setSelected(.git)
        gitPanel.refresh()
    }

    /// Re-apply the UI font (`ui_font_*`) across every panel in the sidebar.
    func refreshFonts() {
        fileTree.refreshAppearance()
        search.refreshFonts()
        gitPanel.refreshFonts()
    }

    private func reveal(_ vc: NSViewController) {
        for other in [fileTree, search, gitPanel] as [NSViewController] {
            other.view.isHidden = (other !== vc)
        }
    }

}

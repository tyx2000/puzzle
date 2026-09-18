import AppKit

/// Left panel: the project/branch band beside the traffic lights, and under
/// it the window's projects, the one being shown expanded to its changes and
/// history.
final class SidebarViewController: NSViewController {
    /// Project name + branch beside the traffic lights (the panel owns that
    /// strip of the titlebar because it is the view underneath it).
    let projectTitle = ProjectTitleView()
    /// The window's projects, with the selected one's Git lists expanded under
    /// its row.
    let projectsPanel = ProjectsPanelViewController()
    /// A project row was chosen, or its ✕ was clicked.
    var onSelectProjectRow: ((Int) -> Void)?
    var onCloseProjectRow: ((Int) -> Void)?
    /// The branch on a project row was clicked: the row, and where its branch
    /// sits in this panel's view, for the branch menu to hang from.
    var onSelectProjectBranchRow: ((Int, NSRect) -> Void)?
    var onReorderProjectRows: ((Int, Int) -> Void)?
    /// The button at the end of the title band opens another project.
    private let addProjectButton = NSButton()
    var onAddProject: (() -> Void)?

    var onGitDiff: ((GitService.Status.Entry, URL) -> Void)?
    var onGitCommitDiff: ((GitService.Commit, GitService.CommitFile, URL) -> Void)?
    /// The commit line over a project's changes committed, pushed or
    /// discarded in this repository — the project on screen, or one the user
    /// has since left.
    var onProjectGitChanged: ((URL) -> Void)?

    /// The 1pt line under the traffic-light band.
    private let titleSeparator = FlatView()
    private var containerTopConstraint: NSLayoutConstraint!
    private var projectTitleLeadingConstraint: NSLayoutConstraint!

    override func loadView() {
        let root = FlatView()
        root.fillColor = Theme.panelBackground

        let panel = projectsPanel.view
        addChild(projectsPanel)
        panel.translatesAutoresizingMaskIntoConstraints = false
        projectTitle.translatesAutoresizingMaskIntoConstraints = false
        titleSeparator.translatesAutoresizingMaskIntoConstraints = false
        titleSeparator.fillColor = Theme.border
        root.addSubview(panel)
        root.addSubview(projectTitle)
        addProjectButton.image = Theme.symbol("plus", accessibilityDescription: "Open project",
                                              pointSize: 12)
        addProjectButton.isBordered = false
        addProjectButton.bezelStyle = .regularSquare
        addProjectButton.imageScaling = .scaleProportionallyDown
        addProjectButton.contentTintColor = Theme.dimText
        addProjectButton.toolTip = "Open another project"
        addProjectButton.setAccessibilityLabel("Open project")
        addProjectButton.target = self
        addProjectButton.action = #selector(addProjectAction)
        addProjectButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(addProjectButton)
        root.addSubview(titleSeparator)

        containerTopConstraint = panel.topAnchor.constraint(
            equalTo: root.topAnchor, constant: DiffTabBar.defaultRowHeight)
        // Sits in the band the panel leaves empty for the traffic lights; the
        // window controller supplies the real inset once AppKit has laid the
        // buttons out.
        projectTitleLeadingConstraint = projectTitle.leadingAnchor.constraint(
            equalTo: root.leadingAnchor, constant: 78)
        NSLayoutConstraint.activate([
            containerTopConstraint,
            projectTitleLeadingConstraint,
            // The strip is exactly the tab band, so its text sits on the
            // traffic lights' centre line.
            projectTitle.topAnchor.constraint(equalTo: root.topAnchor),
            projectTitle.bottomAnchor.constraint(equalTo: panel.topAnchor),
            // The name truncates rather than pushing the button off the end.
            projectTitle.trailingAnchor.constraint(
                lessThanOrEqualTo: addProjectButton.leadingAnchor, constant: -6),
            addProjectButton.trailingAnchor.constraint(equalTo: root.trailingAnchor,
                                                       constant: -8),
            addProjectButton.centerYAnchor.constraint(equalTo: projectTitle.centerYAnchor),
            addProjectButton.widthAnchor.constraint(equalToConstant: 22),
            addProjectButton.heightAnchor.constraint(equalToConstant: 20),
            titleSeparator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            titleSeparator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            titleSeparator.bottomAnchor.constraint(equalTo: panel.topAnchor),
            titleSeparator.heightAnchor.constraint(equalToConstant: 1),

            panel.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        self.view = root

        projectsPanel.onSelect = { [weak self] in self?.onSelectProjectRow?($0) }
        projectsPanel.onClose = { [weak self] in self?.onCloseProjectRow?($0) }
        projectsPanel.onSelectBranch = { [weak self] index, rect in
            guard let self else { return }
            self.onSelectProjectBranchRow?(index, self.projectsPanel.view.convert(rect, to: root))
        }
        projectsPanel.changes.onOpenDiff = { [weak self] entry, directory in
            self?.onGitDiff?(entry, directory)
        }
        // A commit, push or discard from the changes moves everything that
        // reads the repository.
        projectsPanel.changes.onChanged = { [weak self] directory in
            self?.onProjectGitChanged?(directory)
        }
        // A file inside a commit opens that commit's diff for it.
        projectsPanel.history.onOpenCommitDiff = { [weak self] commit, file, directory in
            self?.onGitCommitDiff?(commit, file, directory)
        }
        projectsPanel.onReorder = { [weak self] from, to in
            self?.onReorderProjectRows?(from, to)
        }
    }

    @objc private func addProjectAction() { onAddProject?() }

    var addProjectButtonForTesting: NSButton { addProjectButton }

    func setTabRowHeight(_ height: CGFloat) {
        containerTopConstraint.constant = height
    }

    /// Start the project/branch strip after the actual traffic lights.
    func setTitlebarLeadingInset(_ inset: CGFloat) {
        projectTitleLeadingConstraint.constant = inset
    }

    func setProjectTitle(project: String, branch: String) {
        projectTitle.configure(project: project, branch: branch)
    }

    var panelTopInsetForTesting: CGFloat { containerTopConstraint.constant }
    var titleSeparatorForTesting: FlatView { titleSeparator }

    /// The window's projects, and which one is showing. `isRepository` speaks
    /// for that one: nil while its first Git read is still out.
    func setProjects(_ projects: [(name: String, branch: String, user: String,
                                   changes: Int, path: String)],
                     active: Int?, isRepository: Bool? = nil) {
        projectsPanel.configure(projects: projects, active: active,
                                isRepository: isRepository)
    }

    /// What the project on screen has changed, and where that project stands —
    /// the history under the changes is re-read only when something it shows
    /// has moved.
    func setChanges(_ entries: [GitService.Status.Entry], in directory: URL?,
                    state: ProjectHistoryViewController.State) {
        // Push on the commit line is live when something is ahead, or when
        // there is no upstream yet.
        projectsPanel.changes.setEntries(entries, in: directory,
                                         ahead: state.ahead, hasUpstream: state.hasUpstream)
        projectsPanel.history.setSource(directory: directory, state: state)
    }

    /// Empty both lists for a project whose Git state is not known yet. Nothing
    /// is read: the refresh that follows fills them.
    func clearChanges(for directory: URL?) {
        projectsPanel.changes.setEntries([], in: directory)
        projectsPanel.history.prepare(for: directory)
    }
}

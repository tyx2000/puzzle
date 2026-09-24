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
    var onReorderProjectRows: ((Int, Int) -> Void)?
    /// The Git mark on a project row was clicked: pull that project.
    var onPullProjectRow: ((Int) -> Void)?
    /// The buttons at the end of the title band: one opens another project,
    /// the one past it opens a terminal on the project showing.
    private let addProjectButton = NSButton()
    private let terminalButton = NSButton()
    var onAddProject: (() -> Void)?
    var onOpenTerminal: (() -> Void)?

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
        configure(addProjectButton,
                  image: Theme.symbol("plus", accessibilityDescription: "Open project",
                                      pointSize: 12),
                  label: "Open project", tip: "Open another project",
                  action: #selector(addProjectAction))
        root.addSubview(addProjectButton)
        configure(terminalButton, image: Self.promptImage(),
                  label: "Open terminal", tip: "Open this project in a terminal",
                  action: #selector(openTerminalAction))
        root.addSubview(terminalButton)
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
            addProjectButton.trailingAnchor.constraint(
                equalTo: terminalButton.leadingAnchor, constant: -2),
            addProjectButton.centerYAnchor.constraint(equalTo: projectTitle.centerYAnchor),
            addProjectButton.widthAnchor.constraint(equalToConstant: 22),
            addProjectButton.heightAnchor.constraint(equalToConstant: 20),
            terminalButton.trailingAnchor.constraint(equalTo: root.trailingAnchor,
                                                     constant: -8),
            terminalButton.centerYAnchor.constraint(equalTo: projectTitle.centerYAnchor),
            terminalButton.widthAnchor.constraint(equalToConstant: 22),
            terminalButton.heightAnchor.constraint(equalToConstant: 20),
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
        projectsPanel.onPull = { [weak self] in self?.onPullProjectRow?($0) }
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

    /// The title band's buttons, drawn alike.
    private func configure(_ button: NSButton, image: NSImage?, label: String,
                           tip: String, action: Selector) {
        button.image = image
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

    /// A shell prompt: one chevron and the cursor's underscore, drawn at the
    /// weight of the SF Symbol beside it. The `terminal` symbol puts a window
    /// frame around the same two marks, which at this size reads as a filled
    /// box next to the bare `+`.
    private static func promptImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { _ in
            let path = NSBezierPath()
            path.lineWidth = 1.3
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: NSPoint(x: 3, y: 10.25))
            path.line(to: NSPoint(x: 6.5, y: 7))
            path.line(to: NSPoint(x: 3, y: 3.75))
            path.move(to: NSPoint(x: 8, y: 3.75))
            path.line(to: NSPoint(x: 11.5, y: 3.75))
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        // Tinted by the button, like every other mark in the band.
        image.isTemplate = true
        return image
    }

    @objc private func addProjectAction() { onAddProject?() }
    @objc private func openTerminalAction() { onOpenTerminal?() }

    var addProjectButtonForTesting: NSButton { addProjectButton }
    var terminalButtonForTesting: NSButton { terminalButton }

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

    /// The projects, by path, with a fetch or a pull running: their rows'
    /// Git marks show it.
    func setSyncingProjects(_ paths: Set<String>) {
        projectsPanel.setSyncing(paths)
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

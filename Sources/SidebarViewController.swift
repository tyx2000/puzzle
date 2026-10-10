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
    /// The branch on a project row was clicked, which goes to its Git panel.
    var onSelectProjectBranchRow: ((Int) -> Void)?
    var onReorderProjectRows: ((Int, Int) -> Void)?
    /// The Git mark on a project row was clicked: pull that project.
    var onPullProjectRow: ((Int) -> Void)?
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
    /// A Git panel operation finished in the given project.
    var onGitChanged: ((URL) -> Void)?
    /// The commit line over a project's changes committed or pushed in this
    /// repository — the project on screen, or one the user has since left.
    var onProjectGitChanged: ((URL) -> Void)?

    /// The three errands that start a session, at the end of the title band:
    /// open a project, go back to a recent one, get a shell in this one. They
    /// were on the menu bar, where macOS would not let them act on one click —
    /// a top-level item with no submenu is never drawn at all.
    private let openButton = TitleLetterButton(letter: "O", word: "Open")
    private let recentButton = TitleLetterButton(letter: "R", word: "Recent")
    private let terminalButton = TitleLetterButton(letter: "T", word: "Terminal")
    private let windowButton = TitleLetterButton(letter: "W", word: "Window")
    private var titleButtons: [TitleLetterButton] {
        [openButton, recentButton, terminalButton, windowButton]
    }
    var onOpenProject: (() -> Void)?
    var onNewWindow: (() -> Void)?
    /// Carries the button's rect in this view's coordinates, so the window can
    /// drop the recents menu directly under it.
    var onShowRecent: ((NSRect) -> Void)?
    var onOpenTerminal: (() -> Void)?

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
        for (button, action) in [(openButton, #selector(openProjectAction)),
                                 (recentButton, #selector(showRecentAction)),
                                 (terminalButton, #selector(openTerminalAction)),
                                 (windowButton, #selector(newWindowAction))] {
            button.target = self
            button.action = action
            root.addSubview(button)
        }
        // No tooltips: hovering already spells the letter out, and a tooltip
        // would arrive a second later on top of the word it duplicates. The
        // accessibility label carries the name for VoiceOver instead.
        // Nothing to open a shell in until a project is showing.
        terminalButton.isEnabled = false
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
            // The name truncates against the buttons rather than pushing them
            // off the end of the band.
            projectTitle.trailingAnchor.constraint(
                lessThanOrEqualTo: openButton.leadingAnchor, constant: -6),
            openButton.trailingAnchor.constraint(equalTo: recentButton.leadingAnchor),
            recentButton.trailingAnchor.constraint(equalTo: terminalButton.leadingAnchor),
            terminalButton.trailingAnchor.constraint(equalTo: windowButton.leadingAnchor),
            windowButton.trailingAnchor.constraint(
                equalTo: root.trailingAnchor, constant: -6),
            openButton.centerYAnchor.constraint(equalTo: projectTitle.centerYAnchor),
            openButton.heightAnchor.constraint(equalToConstant: TitleLetterButton.side),
            recentButton.centerYAnchor.constraint(equalTo: projectTitle.centerYAnchor),
            recentButton.heightAnchor.constraint(equalToConstant: TitleLetterButton.side),
            terminalButton.centerYAnchor.constraint(equalTo: projectTitle.centerYAnchor),
            terminalButton.heightAnchor.constraint(equalToConstant: TitleLetterButton.side),
            windowButton.centerYAnchor.constraint(equalTo: projectTitle.centerYAnchor),
            windowButton.heightAnchor.constraint(equalToConstant: TitleLetterButton.side),
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
        projectsPanel.onSelectBranch = { [weak self] in self?.onSelectProjectBranchRow?($0) }
        projectsPanel.onPull = { [weak self] in self?.onPullProjectRow?($0) }
        // The changes column opens a diff the same way the Git panel's list
        // does — it is the same list, beside the tree instead of instead of it.
        projectsPanel.changes.onOpenDiff = { [weak self] entry, directory in
            self?.onGitDiff?(entry, directory)
        }
        // A commit or push from the line over the changes moves everything
        // that reads the repository, the Git panel included.
        projectsPanel.changes.onChanged = { [weak self] directory in
            self?.onProjectGitChanged?(directory)
        }
        // The open button on a change row asks for the file itself, which is
        // the errand the Git panel's own list runs with `onOpenFile`.
        projectsPanel.changes.onOpenFile = { [weak self] url in self?.onGitFile?(url) }
        projectsPanel.history.onOpenFile = { [weak self] url in self?.onGitFile?(url) }
        // A file inside a commit opens that commit's diff, as it does in the
        // Git panel's own History tab.
        projectsPanel.history.onOpenCommitDiff = { [weak self] commit, file, directory in
            self?.onGitCommitDiff?(commit, file, directory)
        }
        projectsPanel.onReorder = { [weak self] from, to in
            self?.onReorderProjectRows?(from, to)
        }
        mount(projectsPanel)
        showFiles()
    }

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

    /// A terminal needs a directory to open in.
    func setHasProject(_ hasProject: Bool) {
        terminalButton.isEnabled = hasProject
    }

    @objc private func openProjectAction() { onOpenProject?() }
    @objc private func newWindowAction() { onNewWindow?() }
    @objc private func openTerminalAction() { onOpenTerminal?() }
    @objc private func showRecentAction() {
        onShowRecent?(recentButton.convert(recentButton.bounds, to: view))
    }

    var titleButtonsForTesting: [TitleLetterButton] { titleButtons }

    var fileTreeTopInsetForTesting: CGFloat { containerTopConstraint.constant }
    /// The Git panel, if it has been built.
    var gitPanelForTesting: GitPanelViewController? { gitController }
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
    func setProjects(_ projects: [(name: String, branch: String, user: String,
                                   changes: Int, path: String)],
                     active: Int?) {
        projectsPanel.configure(projects: projects, active: active)
    }

    /// The projects, by path, with a fetch or a pull running: their rows'
    /// Git marks show it.
    func setSyncingProjects(_ paths: Set<String>) {
        projectsPanel.setSyncing(paths)
    }

    /// What the project on screen has changed, for the column beside its tree,
    /// and where that project stands — the history under the changes is re-read
    /// only when something it shows has moved.
    func setChanges(_ entries: [GitService.Status.Entry], in directory: URL?,
                    state: ProjectHistoryViewController.State) {
        // Push on the commit line is live on the same terms as the Git panel's:
        // something ahead, or no upstream yet. A folder that is not a
        // repository has neither, and no column to show them in.
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
        titleButtons.forEach { $0.refreshFonts() }
        fileTree.refreshAppearance()
        searchController?.refreshFonts()
        gitController?.refreshFonts()
        projectsPanel.changes.refreshFonts()
        projectsPanel.history.refreshFonts()
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
        git.onChanged = { [weak self] directory in self?.onGitChanged?(directory) }
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

/// A single-letter button for the title band that unrolls into its word on
/// hover: O → Open, R → Recent, T → Terminal, W → Window.
///
/// Letters rather than glyphs because these four are not obviously pictureable
/// — opening a project, the recents, a terminal and a new window all reach for
/// the same folder-ish and window-ish symbols, and the unlabelled pair that
/// used to sit here said so little that the errands were moved to the menu bar
/// instead. A letter says even less on its own, so hovering spells it out.
///
/// The button owns its width constraint, because that constant is what the
/// animation drives. Which text is drawn follows the width it has right now
/// rather than the hover flag, so the word reveals as the button opens and is
/// still whole while it closes, instead of snapping at either end.
final class TitleLetterButton: NSButton {
    static let side: CGFloat = 22
    /// Breathing room either side of the spelled-out word.
    private static let wordPadding: CGFloat = 9
    private static let unrollDuration: TimeInterval = 0.16

    private let letter: String
    private let word: String
    private var isHovered = false
    private var hoverTracking: NSTrackingArea?
    private var widthConstraint: NSLayoutConstraint!

    init(letter: String, word: String) {
        self.letter = letter
        self.word = word
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        setAccessibilityRole(.button)
        setAccessibilityLabel(word)
        translatesAutoresizingMaskIntoConstraints = false
        widthConstraint = widthAnchor.constraint(equalToConstant: Self.side)
        widthConstraint.isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isEnabled: Bool { didSet { needsDisplay = true } }

    /// Width the button opens to, measured in the font it draws with.
    private var expandedWidth: CGFloat {
        (word as NSString).size(withAttributes: [.font: font()]).width.rounded(.up)
            + Self.wordPadding * 2
    }

    private func font() -> NSFont { Theme.uiFont(11.5) }

    private func setUnrolled(_ unrolled: Bool) {
        let target = unrolled ? expandedWidth : Self.side
        guard abs(widthConstraint.constant - target) > 0.5 else { return }
        // The constant is set directly rather than through `animator()`, and
        // the layout pass inside the group is what animates it. The animator
        // proxy does not write the model value straight away, which leaves the
        // constraint reading as its old width until the animation has run.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.unrollDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            widthConstraint.constant = target
            superview?.layoutSubtreeIfNeeded()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        isHovered = true
        setUnrolled(true)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        setUnrolled(false)
        needsDisplay = true
    }

    /// The frame changes every frame of the unroll, and a view is not redrawn
    /// for that on its own.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered, isEnabled {
            Theme.hover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        let colour: NSColor = !isEnabled ? Theme.gutter
            : (isHovered ? Theme.foreground : Theme.dimText)
        let attributes: [NSAttributedString.Key: Any] = [.font: font(),
                                                         .foregroundColor: colour]
        // Past halfway open the word is what is drawn, clipped by the bounds
        // until there is room for all of it.
        let open = bounds.width > (Self.side + expandedWidth) / 2
        let text = (open ? word : letter) as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                              y: (bounds.height - size.height) / 2),
                  withAttributes: attributes)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Settings can change the UI font, which changes how wide the word is.
    func refreshFonts() {
        if isHovered { widthConstraint.constant = expandedWidth }
        needsDisplay = true
    }

    var isHoveredForTesting: Bool { isHovered }
    func setHoveredForTesting(_ hovered: Bool) {
        isHovered = hovered
        setUnrolled(hovered)
        needsDisplay = true
    }
    var letterForTesting: String { letter }
    var wordForTesting: String { word }
    var widthForTesting: CGFloat { widthConstraint.constant }
    var expandedWidthForTesting: CGFloat { expandedWidth }
}

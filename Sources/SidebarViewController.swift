import AppKit

/// What the sidebar can be showing: the window's projects, a search across
/// the one on show, or its Git panel.
enum SidebarPanel: CaseIterable { case project, search, git }

/// Left panel: the projects, a search or Git, running the whole height under
/// the title band, whose buttons switch between them. Swapping panels never
/// changes the panel width.
final class SidebarViewController: NSViewController {
    let fileTree = FileTreeViewController()
    /// Project name + branch beside the traffic lights (the panel owns that
    /// strip of the titlebar because it is the view underneath it).
    let projectTitle = ProjectTitleView()
    /// The Projects panel: the project on show's heading, tree and changes.
    private(set) lazy var projectsPanel = ProjectsPanelViewController(fileTree: fileTree)
    /// The ✕ in the heading of the project on show was clicked.
    var onCloseProjectRow: ((Int) -> Void)?
    /// The branch in the heading was clicked, which goes to its Git panel.
    var onSelectProjectBranchRow: ((Int) -> Void)?
    /// The Git mark in the heading: pull that project.
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
    var onSearchReplaced: (([URL]) -> Void)?
    var onGitFile: ((URL) -> Void)?
    var onGitDiff: ((GitService.Status.Entry, URL) -> Void)?
    var onGitCommitDiff: ((GitService.Commit, GitService.CommitFile, URL) -> Void)?
    /// A Git panel operation finished in the given project.
    var onGitChanged: ((URL) -> Void)?
    /// The commit line over a project's changes committed or pushed in this
    /// repository — the project on screen, or one the user has since left.
    var onProjectGitChanged: ((URL) -> Void)?

    /// At the end of the title band, the two panels other than the projects:
    /// switches, each marked while its panel is open, and a second click on
    /// one goes back to the projects. The errands that start a session are in
    /// the project bar along the window's foot.
    private let searchButton = TitleLetterButton(letter: "S", word: "Search", hint: "Search Project",
                                                 shortcut: "⌘2", icon: "search")
    private let gitButton = TitleLetterButton(letter: "G", word: "Git", hint: "Git",
                                              shortcut: "⌘3", icon: "git")
    private var titleButtons: [TitleLetterButton] { [searchButton, gitButton] }

    private let containerView = NSView()
    /// The 1pt line under the traffic-light band.
    private let titleSeparator = FlatView()
    private var containerTopConstraint: NSLayoutConstraint!
    private var projectTitleLeadingConstraint: NSLayoutConstraint!
    /// Which panel is currently visible.
    private(set) var visiblePanel: SidebarPanel = .project

    override func loadView() {
        let root = FlatView()
        root.fillColor = Theme.panelBackground

        containerView.translatesAutoresizingMaskIntoConstraints = false
        projectTitle.translatesAutoresizingMaskIntoConstraints = false
        titleSeparator.translatesAutoresizingMaskIntoConstraints = false
        titleSeparator.fillColor = Theme.border
        root.addSubview(containerView)
        root.addSubview(projectTitle)
        for (button, action) in [(searchButton, #selector(searchAction)),
                                 (gitButton, #selector(gitAction))] {
            button.target = self
            button.action = action
            root.addSubview(button)
        }
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
                lessThanOrEqualTo: searchButton.leadingAnchor, constant: -6),
            searchButton.trailingAnchor.constraint(equalTo: gitButton.leadingAnchor,
                                                   constant: -TitleLetterButton.gap),
            gitButton.trailingAnchor.constraint(
                equalTo: root.trailingAnchor, constant: -6),
            searchButton.centerYAnchor.constraint(equalTo: projectTitle.centerYAnchor),
            searchButton.heightAnchor.constraint(equalToConstant: TitleLetterButton.side),
            searchButton.widthAnchor.constraint(equalToConstant: TitleLetterButton.side),
            gitButton.centerYAnchor.constraint(equalTo: projectTitle.centerYAnchor),
            gitButton.heightAnchor.constraint(equalToConstant: TitleLetterButton.side),
            gitButton.widthAnchor.constraint(equalToConstant: TitleLetterButton.side),
            titleSeparator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            titleSeparator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            titleSeparator.bottomAnchor.constraint(equalTo: containerView.topAnchor),
            titleSeparator.heightAnchor.constraint(equalToConstant: 1),

            containerView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            // Down to the window's foot: the panels have nothing under them.
            containerView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        // Back to the projects, from either switch while it is on.
        for button in [searchButton, gitButton] {
            button.onHint = (text: "Back to Projects", shortcut: "⌘1")
        }
        self.view = root

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
    var titlebarLeadingInsetForTesting: CGFloat { projectTitleLeadingConstraint.constant }

    func setProjectTitle(project: String, branch: String) {
        projectTitle.configure(project: project, branch: branch)
    }

    /// A switch: its panel, or back to the projects if that is what is open.
    @objc private func searchAction() {
        if visiblePanel == .search { showFiles() } else { showSearch() }
    }
    @objc private func gitAction() {
        if visiblePanel == .git { showFiles() } else { showGit() }
    }

    /// The switch for the panel on show is marked; the projects have none.
    private func markVisiblePanel() {
        searchButton.isOn = visiblePanel == .search
        gitButton.isOn = visiblePanel == .git
    }

    var titleButtonsForTesting: [TitleLetterButton] { titleButtons }

    var fileTreeTopInsetForTesting: CGFloat { containerTopConstraint.constant }
    /// The Git panel, if it has been built.
    var gitPanelForTesting: GitPanelViewController? { gitController }
    var searchPanelForTesting: SearchViewController? { searchController }
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
        markVisiblePanel()
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
        markVisiblePanel()
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
        markVisiblePanel()
    }

    /// Re-apply the UI font (`ui_font_*`) across every panel in the sidebar.
    func refreshFonts() {
        (view as? FlatView)?.fillColor = Theme.panelBackground
        titleSeparator.fillColor = Theme.border
        projectTitle.refreshAppearance()
        titleButtons.forEach { $0.refreshFonts() }
        fileTree.refreshAppearance()
        searchController?.refreshFonts()
        gitController?.refreshFonts()
        projectsPanel.refreshFonts()
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
        search.onFilesReplaced = { [weak self] urls in self?.onSearchReplaced?(urls) }
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

/// A small button drawn as one of the coloured icons the file tree uses: the
/// Search and Git switches in the title band, and the errands at the end of
/// the project bar — open a project, the recents, a terminal, a new window.
/// Each keeps a letter as its short name.
///
/// No edge of its own: the icon's colour is enough to read as a target. Under
/// the pointer a ground comes up behind it; a switch keeps that ground while
/// its panel is open. Resting on one names it, with its shortcut, in a card
/// under it: the icon alone did not say what it does.
final class TitleLetterButton: NSButton {
    /// The hit area, which is deliberately wider than the icon.
    static let side: CGFloat = 26
    /// Gap between neighbours, so they read as separate targets instead of
    /// one strip of icons.
    static let gap: CGFloat = 3
    /// The ground inside the hit area.
    static let capInset: CGFloat = 2
    static let iconSide: CGFloat = 16
    /// How long the pointer rests before the name shows: long enough that
    /// passing over the band shows nothing.
    static let hintDelay: TimeInterval = 0.4

    private let letter: String
    /// The Material icon it is drawn as.
    private let icon: String
    /// What it does, said in full, and its shortcut.
    let hint: String
    let shortcut: String?
    /// A switch whose panel is open: marked with the ground, and its card says
    /// what a click on it now does.
    var isOn = false {
        didSet {
            guard isOn != oldValue else { return }
            setAccessibilityValue(isOn ? "on" : "off")
            needsDisplay = true
        }
    }
    var onHint: (text: String, shortcut: String?)?
    /// Name it in a card above rather than under: for a button along the
    /// window's foot.
    var hintAbove = false
    private var isHovered = false
    private var hoverTracking: NSTrackingArea?
    private var hintWork: DispatchWorkItem?
    /// One card for all of them, and the sidebar's toggle: only one is ever
    /// under the pointer.
    private static var hintCard: TitleButtonHintCard { .shared }

    init(letter: String, word: String, hint: String, shortcut: String? = nil, icon: String) {
        self.letter = letter
        self.icon = icon
        self.hint = hint
        self.shortcut = shortcut
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        setAccessibilityRole(.button)
        // No tooltip: the card under the button names it, sooner and in the
        // app's own look. The accessibility label carries the name for
        // VoiceOver.
        setAccessibilityLabel(word)
        setAccessibilityHelp(hint)
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isEnabled: Bool {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
            if !isEnabled { setHovered(false) }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: PointerCursor.trackingOptions,
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    var trackingOptionsForTesting: NSTrackingArea.Options? { hoverTracking?.options }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        setHovered(true)
        PointerCursor.enter()
    }

    override func mouseMoved(with event: NSEvent) {
        if isEnabled { PointerCursor.enter() }
    }

    override func cursorUpdate(with event: NSEvent) {
        if isEnabled { PointerCursor.enter() } else { NSCursor.arrow.set() }
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
        PointerCursor.leave(self, event: event)
    }

    /// Clicking is past needing the name.
    override func mouseDown(with event: NSEvent) {
        hideHint()
        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }

    private func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        needsDisplay = true
        hintWork?.cancel()
        hintWork = nil
        guard hovered else {
            hideHint()
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.showHint() }
        hintWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hintDelay, execute: work)
    }

    private func showHint() {
        guard isHovered, isEnabled, let window else { return }
        let onScreen = window.convertToScreen(convert(bounds, to: nil))
        let said = isOn ? onHint ?? (hint, shortcut) : (hint, shortcut)
        if hintAbove {
            Self.hintCard.show(said.0, detail: said.1, icon: nil, above: onScreen,
                               in: window, owner: self)
        } else {
            Self.hintCard.show(said.0, shortcut: said.1, below: onScreen, in: window, owner: self)
        }
    }

    private func hideHint() {
        hintWork?.cancel()
        hintWork = nil
        Self.hintCard.hide(owner: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { setHovered(false) }
    }

    override func draw(_ dirtyRect: NSRect) {
        if isEnabled, isHovered || isOn {
            Theme.selectedControl.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: Self.capInset, dy: Self.capInset),
                         xRadius: 5, yRadius: 5).fill()
        }
        let side = Self.iconSide
        // A dead one keeps its icon, faded: a terminal with nowhere to open.
        SidebarCellDrawing.icon(.material(icon), in: NSRect(
            x: (bounds.width - side) / 2, y: (bounds.height - side) / 2,
            width: side, height: side), opacity: isEnabled ? 1 : 0.35)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func refreshFonts() { needsDisplay = true }

    var isHoveredForTesting: Bool { isHovered }
    /// The pointer arriving or leaving, as the tracking area reports it.
    func setHoveredForTesting(_ hovered: Bool) { setHovered(hovered) }
    var letterForTesting: String { letter }
    var iconForTesting: String { icon }
    var wordForTesting: String { accessibilityLabel() ?? "" }
    static var hintCardForTesting: TitleButtonHintCard { hintCard }
}

/// The card under a title-band button that names it: what it does, and its
/// shortcut, dimmer, after it; over a button in the project bar, since that
/// is at the window's foot. A window of its own so the band's edge does not cut
/// it off, and one the pointer passes through. Not a child of the window it
/// names a button in: it is gone as soon as the pointer leaves the button, so
/// it never has to move with the window.
final class TitleButtonHintCard {
    static let shared = TitleButtonHintCard()

    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
    private let label = HintLabelView()
    private weak var owner: NSView?
    static let gap: CGFloat = 6
    /// How far a card shown above rises as it fades in.
    static let rise: CGFloat = 3
    static let riseDuration: TimeInterval = 0.12

    init() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        panel.contentView = label
    }

    var isVisible: Bool { panel.isVisible }
    var screenFrame: NSRect { panel.frame }
    var textForTesting: String { label.text + (label.shortcut.map { "  " + $0 } ?? "") }
    var hasIconForTesting: Bool { label.icon != nil }
    /// The card itself, to be drawn off screen.
    var contentForTesting: NSView { label }

    /// Centred under `anchor`, in screen coordinates — and kept inside the
    /// window, which W, at the band's end, would otherwise run out of.
    func show(_ text: String, shortcut: String?, below anchor: NSRect, in parent: NSWindow,
              owner: NSView) {
        place(text, detail: shortcut, icon: nil, owner: owner)
        let size = label.fittingCardSize
        let origin = NSPoint(x: Self.centred(size, on: anchor, in: parent),
                             y: anchor.minY - Self.gap - size.height)
        panel.alphaValue = 1
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        panel.orderFront(nil)
    }

    /// Centred over `anchor`, with an optional mark before the text: the card
    /// a button in the project bar names itself in. It fades in rising a few
    /// points, so it reads as coming off the button rather than appearing
    /// over it.
    func show(_ text: String, detail: String?, icon: NSImage?, above anchor: NSRect,
              in parent: NSWindow, owner: NSView) {
        place(text, detail: detail, icon: icon, owner: owner)
        let size = label.fittingCardSize
        let frame = NSRect(origin: NSPoint(x: Self.centred(size, on: anchor, in: parent),
                                           y: anchor.maxY + Self.gap),
                           size: size)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.alphaValue = 1
            panel.setFrame(frame, display: false)
            panel.orderFront(nil)
            return
        }
        panel.alphaValue = 0
        panel.setFrame(frame.offsetBy(dx: 0, dy: -Self.rise), display: false)
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.riseDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func place(_ text: String, detail: String?, icon: NSImage?, owner: NSView) {
        self.owner = owner
        label.text = text
        label.shortcut = detail
        label.icon = icon
        label.needsDisplay = true
    }

    private static func centred(_ size: NSSize, on anchor: NSRect, in parent: NSWindow) -> CGFloat {
        let bounds = parent.frame.insetBy(dx: 6, dy: 0)
        let x = (anchor.midX - size.width / 2).rounded()
        return min(max(bounds.minX, x), bounds.maxX - size.width)
    }

    /// Only the button that showed it takes it down: the next one along may
    /// already have put its own name up.
    func hide(owner: NSView) {
        guard self.owner === owner else { return }
        self.owner = nil
        panel.orderOut(nil)
    }
}

private final class HintLabelView: NSView {
    var text = ""
    var shortcut: String?
    /// A mark before the text, in the dimmer ink.
    var icon: NSImage?
    static let padding = NSSize(width: 8, height: 4)
    static let iconSide: CGFloat = 10
    static let iconGap: CGFloat = 4

    override var isFlipped: Bool { true }

    private var textAttributes: [NSAttributedString.Key: Any] {
        [.font: Theme.uiFont(11), .foregroundColor: Theme.foreground]
    }
    private var shortcutAttributes: [NSAttributedString.Key: Any] {
        [.font: Theme.uiFont(11), .foregroundColor: Theme.dimText]
    }
    private var shortcutText: String? { shortcut.map { "  " + $0 } }
    private var iconRoom: CGFloat { icon == nil ? 0 : Self.iconSide + Self.iconGap }

    var fittingCardSize: NSSize {
        let main = (text as NSString).size(withAttributes: textAttributes)
        let extra = shortcutText.map { ($0 as NSString).size(withAttributes: shortcutAttributes) }
        return NSSize(width: ceil(iconRoom + main.width + (extra?.width ?? 0)) + Self.padding.width * 2,
                      height: ceil(main.height) + Self.padding.height * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: 5, yRadius: 5)
        Theme.panelBackground.setFill()
        body.fill()
        Theme.border.setStroke()
        body.lineWidth = 1
        body.stroke()
        if let icon {
            SidebarCellDrawing.image(icon, tint: Theme.dimText, in: NSRect(
                x: Self.padding.width, y: (bounds.height - Self.iconSide) / 2,
                width: Self.iconSide, height: Self.iconSide))
        }
        let main = text as NSString
        let origin = NSPoint(x: Self.padding.width + iconRoom, y: Self.padding.height)
        main.draw(at: origin, withAttributes: textAttributes)
        if let shortcutText {
            let width = main.size(withAttributes: textAttributes).width
            (shortcutText as NSString).draw(at: NSPoint(x: origin.x + width, y: origin.y),
                                            withAttributes: shortcutAttributes)
        }
    }
}

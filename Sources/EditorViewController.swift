import AppKit

/// Container for the editor's single pane and the welcome screen behind it.
/// The pane owns the tab strip; buffers come from DocumentStore.
final class EditorViewController: NSViewController {
    var onDocumentSaved: ((URL) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onActiveDocumentChanged: ((URL?) -> Void)?
    /// Welcome-screen actions, forwarded to the window controller.
    var onOpenFolder: (() -> Void)?
    /// True once this window has a project. The welcome screen invites you to
    /// open a folder, which is misleading once one is already open — then the
    /// editor area should simply be empty until a file is picked.
    var hasProject = false { didSet { updatePlaceholder() } }
    var onOpenRecent: ((URL) -> Void)?
    /// Several recent projects at once, from the start page's tick boxes.
    var onOpenChecked: (([URL]) -> Void)?

    private var pane: EditorPaneViewController!
    /// Made when it is shown and let go when it is not: a window with a
    /// project never shows it, yet kept a page of rows that it rebuilt on
    /// every change to the recent projects.
    private var welcome: WelcomeView?
    /// A project open and no file: a few faint shortcuts where the text goes.
    let emptyHints = EmptyEditorHintView()
    /// Settings opens a file, so it belongs with the editor's actions rather
    /// than with the panel switcher. It sits over the tab strip's reserved
    /// right edge — in the container, not in the strip, so an empty window
    /// with no tabs still offers it.
    private let settingsButton = NSButton()
    private var settingsButtonTop: NSLayoutConstraint!
    private var tabRowHeight = EditorTabBar.defaultRowHeight
    private var fileHistories: [URL: FileHistoryModel] = [:]

    var currentURL: URL? { pane?.currentURL }
    var openURLs: [URL] { pane?.openURLs ?? [] }

    func setTabRowHeight(_ height: CGFloat) {
        tabRowHeight = height
        settingsButtonTop?.constant = (height - 20) / 2
        pane?.setTabRowHeight(height)
    }

    override func loadView() {
        let container = FlatView()
        container.fillColor = Theme.editorBackground

        let pane = makePane()
        pane.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pane.view)

        emptyHints.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyHints)

        settingsButton.image = NSImage(systemSymbolName: "gearshape",
                                       accessibilityDescription: "Settings")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        settingsButton.isBordered = false
        settingsButton.bezelStyle = .regularSquare
        settingsButton.imageScaling = .scaleProportionallyDown
        settingsButton.contentTintColor = Theme.dimText
        settingsButton.toolTip = "Settings"
        settingsButton.setAccessibilityLabel("Settings")
        settingsButton.target = self
        settingsButton.action = #selector(settingsAction)
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(settingsButton)
        settingsButtonTop = settingsButton.topAnchor.constraint(
            equalTo: container.topAnchor, constant: (tabRowHeight - 20) / 2)

        NSLayoutConstraint.activate([
            pane.view.topAnchor.constraint(equalTo: container.topAnchor),
            pane.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pane.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pane.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            emptyHints.topAnchor.constraint(equalTo: container.topAnchor),
            emptyHints.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            emptyHints.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            emptyHints.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            settingsButton.trailingAnchor.constraint(equalTo: container.trailingAnchor,
                                                     constant: -10),
            settingsButtonTop,
            settingsButton.widthAnchor.constraint(equalToConstant: 22),
            settingsButton.heightAnchor.constraint(equalToConstant: 20),
        ])
        self.view = container
        updatePlaceholder()
    }

    /// Read-only access for the test harnesses.
    var activePaneForTesting: EditorPaneViewController? { pane }
    func clickSettingsGearForTesting() { settingsAction() }
    var settingsGearVisibleForTesting: Bool {
        _ = view
        return !settingsButton.isHidden && settingsButton.window != nil
    }

    @objc private func settingsAction() { onOpenSettings?() }

    // MARK: - The pane

    /// Project root, forwarded to the pane so inline blame knows which repo to
    /// ask.
    var repositoryRoot: URL? {
        didSet { pane?.repositoryRoot = repositoryRoot }
    }

    /// Blame is keyed by file and line; a commit or checkout invalidates it.
    func refreshGitLineChanges() { pane?.refreshGitLineChanges() }

    func invalidateBlame(for url: URL? = nil) {
        pane?.invalidateBlame(for: url)
    }

    private func makePane() -> EditorPaneViewController {
        let pane = EditorPaneViewController()
        pane.setTabRowHeight(tabRowHeight)
        pane.repositoryRoot = repositoryRoot
        pane.fileHistoryProvider = { [weak self] url in self?.fileHistories[url] }
        pane.onDocumentSaved = { [weak self] url in
            guard let self else { return }
            self.pane?.reloadTabs()
            self.onDocumentSaved?(url)
        }
        pane.onDocumentEdited = { [weak self] in
            self?.pane?.reloadTabs()
        }
        pane.onActiveDocumentChanged = { [weak self] url in
            guard let self else { return }
            self.onActiveDocumentChanged?(url)
            self.updatePlaceholder()
        }
        pane.onEmptied = { [weak self] _ in self?.updatePlaceholder() }
        pane.onTabOpened = { [weak pane] url in
            guard let pane else { return }
            DocumentStore.shared.registerOpen(url, owner: pane)
        }
        pane.onTabClosed = { [weak self, weak pane] url in
            guard let pane else { return }
            DocumentStore.shared.unregisterOpen(url, owner: pane)
            self?.fileHistories.removeValue(forKey: url)
        }
        addChild(pane)
        pane.isActivePane = true
        self.pane = pane
        return pane
    }

    /// Confirm all modified documents before a window close.
    func confirmClose() -> Bool {
        guard let pane else { return true }
        return pane.confirmClose(urls: pane.openURLs)
    }

    /// Detach the pane's layout manager — called after confirmClose().
    func detachAllPanes() {
        pane?.prepareForClose()
    }

    func releaseTransientMemory() {
        pane?.releaseTransientMemory()
    }

    /// The start page came up, or went away. The window hides the sidebar
    /// while it is showing: with no project there is nothing in the panel.
    ///
    /// Subscribing delivers the state immediately. The view is loaded while the
    /// window is still being assembled, so the first change happens before the
    /// window has anything wired to hear it; without this the panel stayed up
    /// on the very start page the callback exists for.
    var onWelcomeVisibilityChanged: ((Bool) -> Void)? {
        didSet {
            reportedWelcome = wantsWelcome
            onWelcomeVisibilityChanged?(wantsWelcome)
        }
    }
    /// Last value handed to that callback, so it only fires on a change.
    private var reportedWelcome: Bool?

    private var hasOpenFiles: Bool { !(pane?.openURLs.isEmpty ?? true) }
    /// The start page is for a window with no project and nothing open.
    private var wantsWelcome: Bool { !hasOpenFiles && !hasProject }
    /// Whether the start page is the thing on screen.
    var showsWelcome: Bool { wantsWelcome }

    private func updatePlaceholder() {
        let hasOpenFiles = self.hasOpenFiles
        updateWelcome()
        // Reported from the condition rather than from whether the view has
        // been built: the page is created one turn late on purpose, and the
        // sidebar must not flash in and out across that turn.
        if reportedWelcome != wantsWelcome {
            reportedWelcome = wantsWelcome
            onWelcomeVisibilityChanged?(wantsWelcome)
        }
        emptyHints.isHidden = hasOpenFiles || !hasProject
        // The pane (and its blank text view) must not cover the welcome screen.
        if let pane, pane.view.isHidden == hasOpenFiles {
            if hasOpenFiles {
                // Coming back from the start page: fade in rather than
                // appearing whole under a page that is fading out.
                pane.view.alphaValue = 0
                pane.view.isHidden = false
                Self.fade(pane.view, to: 1)
            } else {
                pane.view.isHidden = true
            }
        }
    }

    /// How long the editor area takes to change what it is showing. Short
    /// enough to read as the view settling rather than as a transition being
    /// performed at you.
    static let crossfadeDuration: TimeInterval = 0.14

    static func fade(_ view: NSView, to alpha: CGFloat,
                     then finish: (() -> Void)? = nil) {
        // Off screen there is no run loop to carry the animation, and the view
        // would sit at whatever alpha it started from — for the start page,
        // built one turn after it is asked for, that meant a page faded to
        // nothing and left there.
        guard view.window != nil else {
            view.alphaValue = alpha
            finish?()
            return
        }
        // Composited rather than redrawn, so nothing behind it has to repaint
        // in step and no stale pixels are left where it used to be.
        view.wantsLayer = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = crossfadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.animator().alphaValue = alpha
        } completionHandler: { finish?() }
    }

    private var welcomePending = false

    private func updateWelcome() {
        guard wantsWelcome else {
            guard let leaving = welcome else { return }
            welcome = nil
            // Faded out and then removed, so opening a project does not snap
            // the page away under the file that is arriving.
            Self.fade(leaving, to: 0) { leaving.removeFromSuperview() }
            return
        }
        guard welcome == nil, isViewLoaded, !welcomePending else { return }
        // A window opened for a project — `pz`, Finder, a launch argument — is
        // handed it straight after it is made. Waiting one turn means such a
        // window never builds a page only to drop it.
        welcomePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.welcomePending = false
            self.makeWelcomeIfStillWanted()
        }
    }

    private func makeWelcomeIfStillWanted() {
        guard welcome == nil, wantsWelcome else { return }
        let welcome = WelcomeView()
        welcome.translatesAutoresizingMaskIntoConstraints = false
        welcome.onOpenFolder = { [weak self] in self?.onOpenFolder?() }
        welcome.onOpenRecent = { [weak self] url in self?.onOpenRecent?(url) }
        welcome.onOpenChecked = { [weak self] urls in self?.onOpenChecked?(urls) }
        // Over the pane, under the hints and the settings gear.
        welcome.alphaValue = 0
        view.addSubview(welcome, positioned: .below, relativeTo: emptyHints)
        NSLayoutConstraint.activate([
            welcome.topAnchor.constraint(equalTo: view.topAnchor),
            welcome.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            welcome.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            welcome.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        // After the constraints, and after a layout pass: a view still at zero
        // size when the fade starts has nothing to fade, and the page appeared
        // without one.
        view.layoutSubtreeIfNeeded()
        Self.fade(welcome, to: 1)
        self.welcome = welcome
    }

    var welcomeShownForTesting: Bool { welcome?.superview != nil }

    func stepTab(by offset: Int) { pane?.stepTab(by: offset) }
    /// Every tab, as a project switch requires. False when one would not
    /// close — the user kept a file whose disk version changed under an edit.
    @discardableResult
    func closeAllTabs() -> Bool { pane?.closeAllTabs() ?? true }

    @discardableResult
    func reopenLastClosedTab() -> Bool {
        let reopened = pane?.reopenLastClosedTab() ?? false
        updatePlaceholder()
        return reopened
    }

    /// Close the current tab. False when there was none to close.
    @discardableResult
    func closeActiveTab() -> Bool {
        guard let pane, let index = pane.activeTabIndex else { return false }
        pane.close(index: index)
        return true
    }

    // MARK: - Forwarded to the pane

    func open(url: URL, replacingContent: Bool = false) {
        pane?.open(url: url, replacingContent: replacingContent)
        updatePlaceholder()
    }

    func showFileHistory(_ model: FileHistoryModel) {
        fileHistories[model.tabURL] = model
        // A tiny virtual document gives the existing tab/document lifecycle a
        // stable identity; the pane replaces its text area with FileHistoryView.
        DocumentStore.shared.setVirtualDocument(
            url: model.tabURL, text: "", displayName: model.displayName)
        open(url: model.tabURL, replacingContent: true)
    }

    func canMutatePath(_ base: URL) -> Bool {
        let path = base.standardizedFileURL.path
        let prefix = path.hasSuffix("/") ? path : path + "/"
        for url in pane?.openURLs ?? [] {
            let candidate = url.standardizedFileURL.path
            guard candidate == path || candidate.hasPrefix(prefix) else { continue }
            if DocumentStore.shared.cachedDocument(for: url)?.isModified == true {
                return false
            }
        }
        return true
    }

    func pathRenamed(from oldURL: URL, to newURL: URL) {
        pane?.pathRenamed(from: oldURL, to: newURL)
        onActiveDocumentChanged?(pane?.currentURL)
    }

    func pathDeleted(_ url: URL) {
        pane?.pathDeleted(url)
        updatePlaceholder()
        onActiveDocumentChanged?(pane?.currentURL)
    }
    func save() { pane?.save() }
    /// The open buffer, for the window going inactive.
    func autosaveAll() { pane?.autosaveIfNeeded() }

    /// Show the in-file find bar, optionally pre-filled.
    func showFindBar(seed: String? = nil, replacing: Bool = false) {
        pane?.showFindBar(seed: seed, replacing: replacing)
    }
    func jumpToLine(_ line: Int, column: Int? = nil) {
        pane?.jumpToLine(line, column: column)
    }

    /// Whether there is a document to act on (⌘L has nothing to do without).
    var hasOpenDocument: Bool { pane?.currentURL != nil }

    /// Re-apply font / line-height settings.
    func refreshDisplay() {
        pane?.refreshDisplay()
        welcome?.refreshFonts()
    }
}

/// What the editor area says with a project open and no file in it: a few
/// shortcuts, faint and centred, the way Zed's empty pane lists them. Text,
/// not buttons — the keys are the point.
///
/// Each shortcut is read from the menu item it belongs to, so the hint cannot
/// drift from what the key does.
final class EmptyEditorHintView: NSView {
    /// The menu items listed, by title, in order.
    static let titles = ["Quick Open…", "Find in Folder…", "Show Git",
                         "Reopen Closed Tab", "Open…"]
    /// Where the shortcuts are read from; the application's menu unless a
    /// test hands it one.
    var shortcutSource: NSMenu?

    override var isFlipped: Bool { true }
    /// Drawn over the editor area, never in the way of a click.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The lines are drawn by a view just their size, centred in this one.
    /// Drawn here, they cost a bitmap the size of the whole editor area.
    private let block = HintBlockView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(block)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Each listed item that has a key, as its title and the key.
    var lines: [(title: String, keys: String)] {
        let source = shortcutSource ?? NSApp.mainMenu
        return Self.titles.compactMap { title in
            guard let item = Self.item(titled: title, in: source),
                  let keys = Self.shortcut(of: item) else { return nil }
            return (title.hasSuffix("…") ? String(title.dropLast()) : title, keys)
        }
    }

    private static func item(titled title: String, in menu: NSMenu?) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if item.title == title { return item }
            if let found = self.item(titled: title, in: item.submenu) { return found }
        }
        return nil
    }

    /// `⇧⌘F`, in the order the menu bar writes modifiers.
    static func shortcut(of item: NSMenuItem) -> String? {
        let key = item.keyEquivalent
        guard !key.isEmpty else { return nil }
        var modifiers = item.keyEquivalentModifierMask
        // An upper-case key equivalent carries the shift with it.
        if key != key.lowercased() { modifiers.insert(.shift) }
        var glyphs = ""
        if modifiers.contains(.control) { glyphs += "⌃" }
        if modifiers.contains(.option) { glyphs += "⌥" }
        if modifiers.contains(.shift) { glyphs += "⇧" }
        if modifiers.contains(.command) { glyphs += "⌘" }
        return glyphs + key.uppercased()
    }

    // The menu is read again whenever the hints are placed: on coming into a
    // window, on being shown, and on every change of size.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let lines = self.lines
        let font = Theme.uiFont(12)
        let rowHeight: CGFloat = 28
        func width(_ text: String) -> CGFloat {
            ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2
        }
        let titleWidth = lines.map { width($0.title) }.max() ?? 0
        let keysWidth = lines.map { width($0.keys) }.max() ?? 0
        let gap: CGFloat = 40
        let blockWidth = min(titleWidth + gap + keysWidth, bounds.width - 32)
        guard !lines.isEmpty, blockWidth > 0 else {
            block.frame = .zero
            return
        }
        let height = CGFloat(lines.count) * rowHeight
        block.frame = NSRect(x: floor(bounds.midX - blockWidth / 2),
                             y: floor(bounds.midY - height / 2),
                             width: blockWidth, height: height)
        block.set(lines: lines, font: font, rowHeight: rowHeight,
                  keysWidth: keysWidth, gap: gap)
    }
}

/// The shortcut lines themselves, set out by `EmptyEditorHintView`.
private final class HintBlockView: NSView {
    private var lines: [(title: String, keys: String)] = []
    private var font = Theme.uiFont(12)
    private var rowHeight: CGFloat = 28
    private var keysWidth: CGFloat = 0
    private var gap: CGFloat = 0

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func set(lines: [(title: String, keys: String)], font: NSFont, rowHeight: CGFloat,
             keysWidth: CGFloat, gap: CGFloat) {
        self.lines = lines
        self.font = font
        self.rowHeight = rowHeight
        self.keysWidth = keysWidth
        self.gap = gap
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, line) in lines.enumerated() {
            let row = NSRect(x: 0, y: CGFloat(index) * rowHeight,
                             width: bounds.width, height: rowHeight)
            SidebarCellDrawing.text(line.title, font: font, color: Theme.dimText,
                                    in: NSRect(x: row.minX, y: row.minY,
                                               width: max(0, row.width - keysWidth - gap / 2),
                                               height: row.height))
            SidebarCellDrawing.text(line.keys, font: font, color: Theme.gutterActive,
                                    in: NSRect(x: row.maxX - keysWidth, y: row.minY,
                                               width: keysWidth, height: row.height),
                                    alignment: .right)
        }
    }
}

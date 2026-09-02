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
    var onTabBarHeightChanged: ((CGFloat) -> Void)?

    private var pane: EditorPaneViewController!
    private let welcome = WelcomeView()
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
        onTabBarHeightChanged?(pane?.tabBarHeight ?? height)
    }

    override func loadView() {
        let container = FlatView()
        container.fillColor = Theme.editorBackground

        let pane = makePane()
        pane.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pane.view)

        welcome.translatesAutoresizingMaskIntoConstraints = false
        welcome.onOpenFolder = { [weak self] in self?.onOpenFolder?() }
        welcome.onOpenRecent = { [weak self] url in self?.onOpenRecent?(url) }
        container.addSubview(welcome)

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
            welcome.topAnchor.constraint(equalTo: container.topAnchor),
            welcome.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            welcome.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            welcome.bottomAnchor.constraint(equalTo: container.bottomAnchor),
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
        pane.onTabBarHeightChanged = { [weak self] height in
            self?.onTabBarHeightChanged?(height)
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

    private func updatePlaceholder() {
        let hasOpenFiles = !(pane?.openURLs.isEmpty ?? true)
        welcome.isHidden = hasOpenFiles || hasProject
        // The pane (and its blank text view) must not cover the welcome screen.
        pane?.view.isHidden = !hasOpenFiles
    }

    func stepTab(by offset: Int) { pane?.stepTab(by: offset) }

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
        welcome.refreshFonts()
    }
}

import AppKit

/// Container for one or more editor panes arranged in a vertical split. Each
/// pane has its own tab strip; buffers are shared via DocumentStore.
final class EditorViewController: NSViewController {
    var onDocumentSaved: ((URL) -> Void)?
    var onActiveDocumentChanged: ((URL?) -> Void)?
    /// Welcome-screen actions, forwarded to the window controller.
    var onOpenFolder: (() -> Void)?
    var onOpenRecent: ((URL) -> Void)?

    private var panes: [EditorPaneViewController] = []
    private weak var activePane: EditorPaneViewController?
    private var editorSplit: NSSplitView!
    private let welcome = WelcomeView()

    var currentURL: URL? { activePane?.currentURL }

    /// Number of editor panes (1, or 2 when split).
    var paneCount: Int { panes.count }
    /// Tabs open in a given pane — panes are independent.
    func openURLs(inPane index: Int) -> [URL] {
        panes.indices.contains(index) ? panes[index].openURLs : []
    }
    /// Index of the focused pane.
    var activePaneIndex: Int? { activePane.flatMap { panes.firstIndex(of: $0) } }

    override func loadView() {
        let container = FlatView()
        container.fillColor = Theme.editorBackground

        editorSplit = NSSplitView()
        editorSplit.isVertical = true
        editorSplit.dividerStyle = .thin
        editorSplit.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(editorSplit)

        welcome.translatesAutoresizingMaskIntoConstraints = false
        welcome.onOpenFolder = { [weak self] in self?.onOpenFolder?() }
        welcome.onOpenRecent = { [weak self] url in self?.onOpenRecent?(url) }
        container.addSubview(welcome)

        NSLayoutConstraint.activate([
            editorSplit.topAnchor.constraint(equalTo: container.topAnchor),
            editorSplit.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            editorSplit.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            editorSplit.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            welcome.topAnchor.constraint(equalTo: container.topAnchor),
            welcome.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            welcome.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            welcome.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        self.view = container

        addPane()  // first pane
    }

    // MARK: - Panes

    @discardableResult
    private func addPane() -> EditorPaneViewController {
        let pane = EditorPaneViewController()
        pane.onRequestSplit = { [weak self] in self?.splitEditor() }
        pane.onBecameActive = { [weak self] p in self?.setActivePane(p) }
        pane.onDocumentSaved = { [weak self] url in self?.onDocumentSaved?(url) }
        pane.onDocumentEdited = { [weak self] in
            self?.panes.forEach { $0.reloadTabs() }
        }
        pane.onActiveDocumentChanged = { [weak self] url in
            guard let self, self.activePane === pane else { return }
            self.onActiveDocumentChanged?(url)
            self.updatePlaceholder()
        }
        pane.onEmptied = { [weak self] p in self?.closePane(p) }

        addChild(pane)
        panes.append(pane)
        editorSplit.addArrangedSubview(pane.view)
        setActivePane(pane)
        updatePlaceholder()
        return pane
    }

    private func closePane(_ pane: EditorPaneViewController) {
        // Keep at least one pane alive.
        guard panes.count > 1, let index = panes.firstIndex(of: pane) else {
            updatePlaceholder(); return
        }
        pane.view.removeFromSuperview()
        pane.removeFromParent()
        panes.remove(at: index)
        setActivePane(panes[max(0, index - 1)])
        updatePlaceholder()
    }

    private func setActivePane(_ pane: EditorPaneViewController) {
        guard activePane !== pane else { return }
        activePane = pane
        for p in panes { p.isActivePane = (p === pane) }
        onActiveDocumentChanged?(pane.currentURL)
    }

    private func updatePlaceholder() {
        let hasOpenFiles = panes.contains { !$0.openURLs.isEmpty }
        welcome.isHidden = hasOpenFiles
        // The split (and its blank text view) must not cover the welcome screen.
        editorSplit.isHidden = !hasOpenFiles
    }

    /// Split the active file into a second vertical pane with its own tabs.
    func splitEditor() {
        if panes.count > 1 {
            // Already split: collapse back to a single pane.
            if let last = panes.last { closePane(last) }
            return
        }
        let source = activePane
        let pane = addPane()
        if let url = source?.currentURL { pane.open(url: url) }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.editorSplit.setPosition(self.editorSplit.bounds.width / 2, ofDividerAt: 0)
        }
    }

    // MARK: - Forwarded to the active pane

    func open(url: URL, replacingContent: Bool = false) {
        (activePane ?? panes.first)?.open(url: url, replacingContent: replacingContent)
        updatePlaceholder()
    }
    func save() { activePane?.save() }

    /// Show the in-file find bar in the focused pane, optionally pre-filled.
    func showFindBar(seed: String? = nil) {
        (activePane ?? panes.first)?.showFindBar(seed: seed)
    }
    func jumpToLine(_ line: Int) { activePane?.jumpToLine(line) }

    /// Re-apply font / line-height settings to every pane.
    func refreshDisplay() {
        panes.forEach { $0.refreshDisplay() }
        welcome.refreshFonts()
    }
}

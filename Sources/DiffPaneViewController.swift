import AppKit

/// The right side of the window: one tab per diff that has been opened, the
/// strip naming the file over it, and the diff itself. Nothing here edits —
/// a tab holds the text Git gave for one file, in the working tree or in one
/// commit.
final class DiffPaneViewController: NSViewController {
    /// What a tab shows.
    struct Tab: Equatable {
        enum Source: Equatable {
            /// A file's uncommitted change.
            case workingTree
            /// A file as one commit changed it.
            case commit(String)
        }
        let directory: URL
        /// Repository-relative path.
        let path: String
        let source: Source
        var diff: String

        /// One tab per file and source: opening the same one again refreshes
        /// it rather than adding another.
        var id: String {
            switch source {
            case .workingTree: return "\(directory.path)|\(path)"
            case .commit(let hash): return "\(directory.path)|\(path)|\(hash)"
            }
        }

        var title: String {
            let name = (path as NSString).lastPathComponent
            switch source {
            case .workingTree: return name
            case .commit(let hash): return "\(name) @ \(hash)"
            }
        }
    }

    /// Start-page actions, forwarded to the window controller.
    var onOpenFolder: (() -> Void)?
    var onOpenRecent: ((URL) -> Void)?
    var onOpenChecked: (([URL]) -> Void)?

    /// True once this window has a project. The start page invites you to
    /// open a folder, which is misleading once one is already open — then the
    /// area says what to click instead.
    var hasProject = false { didSet { updatePlaceholder() } }

    private let tabBar = DiffTabBar()
    private let header = DiffHeaderView()
    private let diffView = DiffView()
    private let welcome = WelcomeView()
    private let hint = NSTextField(labelWithString: "Select a change or a commit's file to see its diff")
    private var tabHeight: NSLayoutConstraint!

    private(set) var tabs: [Tab] = []
    private(set) var activeIndex: Int?
    /// What ⇧⌘T brings back, newest last.
    private var closed: [Tab] = []
    private static let closedLimit = 20
    /// The layout sticks for the session, so switching files does not switch
    /// back.
    private static var mode: DiffHeaderView.Mode = .unified

    override func loadView() {
        let container = FlatView()
        container.fillColor = Theme.diffBackground

        for subview in [tabBar, header, diffView, welcome, hint] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(subview)
        }
        tabBar.onSelect = { [weak self] in self?.select($0) }
        tabBar.onClose = { [weak self] in self?.close(index: $0) }
        tabBar.onCloseOthers = { [weak self] in self?.closeOthers(keeping: $0) }
        tabBar.onCloseRight = { [weak self] in self?.closeRight(of: $0) }
        header.onPrevious = { [weak self] in self?.diffView.step(forward: false) }
        header.onNext = { [weak self] in self?.diffView.step(forward: true) }
        header.onToggleMode = { [weak self] in self?.toggleMode() }
        header.setMode(Self.mode)
        diffView.setMode(Self.mode)

        welcome.onOpenFolder = { [weak self] in self?.onOpenFolder?() }
        welcome.onOpenRecent = { [weak self] url in self?.onOpenRecent?(url) }
        welcome.onOpenChecked = { [weak self] urls in self?.onOpenChecked?(urls) }

        hint.font = Theme.uiFont(12)
        hint.textColor = Theme.dimText
        hint.alignment = .center

        tabHeight = tabBar.heightAnchor.constraint(equalToConstant: DiffTabBar.defaultRowHeight)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: container.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tabHeight,
            header.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: DiffHeaderView.height),
            diffView.topAnchor.constraint(equalTo: header.bottomAnchor),
            diffView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            diffView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            diffView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            welcome.topAnchor.constraint(equalTo: container.topAnchor),
            welcome.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            welcome.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            welcome.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hint.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            hint.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            hint.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40),
        ])
        view = container
        reload()
    }

    /// The tab strip sits beside the traffic lights, so its rows are as tall
    /// as the band they sit in.
    func setTabRowHeight(_ height: CGFloat) {
        _ = view
        tabBar.setRowHeight(height)
        updateTabHeight()
    }

    private func updateTabHeight() {
        tabHeight.constant = tabBar.currentHeight
    }

    // MARK: - Tabs

    /// Show a diff, in its existing tab when it already has one.
    func open(_ tab: Tab) {
        _ = view
        if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
            let unchanged = tabs[index].diff == tab.diff && activeIndex == index
            tabs[index] = tab
            activeIndex = index
            if unchanged { return }
        } else {
            // Next to the one being read, the way a browser opens a link.
            let at = activeIndex.map { $0 + 1 } ?? tabs.count
            tabs.insert(tab, at: at)
            activeIndex = at
        }
        reload()
    }

    /// A working-tree diff read again. The tab keeps its place in the diff:
    /// the file moving under the reader must not throw them back to the top.
    func update(id: String, diff: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }),
              tabs[index].diff != diff else { return }
        tabs[index].diff = diff
        guard index == activeIndex else { return }
        showActive(keepingPosition: true)
    }

    func select(_ index: Int) {
        guard tabs.indices.contains(index), index != activeIndex else { return }
        activeIndex = index
        reload()
    }

    func close(index: Int) {
        guard tabs.indices.contains(index) else { return }
        remember(tabs.remove(at: index))
        if let active = activeIndex {
            if tabs.isEmpty {
                activeIndex = nil
            } else if index < active || active >= tabs.count {
                activeIndex = active - 1
            }
        }
        reload()
    }

    /// ⌘W. False when there was nothing to close.
    @discardableResult
    func closeActive() -> Bool {
        guard let activeIndex else { return false }
        close(index: activeIndex)
        return true
    }

    func closeOthers(keeping index: Int) {
        guard tabs.indices.contains(index) else { return }
        let kept = tabs[index]
        tabs.filter { $0.id != kept.id }.forEach(remember)
        tabs = [kept]
        activeIndex = 0
        reload()
    }

    func closeRight(of index: Int) {
        guard tabs.indices.contains(index), index < tabs.count - 1 else { return }
        tabs[(index + 1)...].forEach(remember)
        tabs.removeSubrange((index + 1)...)
        if let active = activeIndex, active > index { activeIndex = index }
        reload()
    }

    /// Every tab — a project switch, or the project closing.
    func closeAll() {
        tabs.forEach(remember)
        tabs = []
        activeIndex = nil
        reload()
    }

    /// Tabs of one project only: closing a project leaves the others' alone.
    func closeTabs(in directory: URL) {
        let kept = tabs.filter { $0.directory != directory }
        guard kept.count != tabs.count else { return }
        let activeID = activeIndex.map { tabs[$0].id }
        tabs.filter { $0.directory == directory }.forEach(remember)
        tabs = kept
        activeIndex = activeID.flatMap { id in tabs.firstIndex { $0.id == id } }
            ?? (tabs.isEmpty ? nil : 0)
        reload()
    }

    func step(by offset: Int) {
        guard !tabs.isEmpty else { return }
        let current = activeIndex ?? 0
        activeIndex = (current + offset + tabs.count) % tabs.count
        reload()
    }

    /// ⇧⌘T. False when nothing has been closed.
    @discardableResult
    func reopenLastClosed() -> Bool {
        guard let tab = closed.popLast() else { return false }
        open(tab)
        return true
    }

    private func remember(_ tab: Tab) {
        closed.removeAll { $0.id == tab.id }
        closed.append(tab)
        if closed.count > Self.closedLimit { closed.removeFirst() }
    }

    var activeTab: Tab? { activeIndex.map { tabs[$0] } }

    private func reload() {
        guard isViewLoaded else { return }
        tabBar.reload(tabs: tabs.map { .init(title: $0.title, path: tooltip(for: $0)) },
                      active: activeIndex ?? -1)
        tabBar.layoutSubtreeIfNeeded()
        updateTabHeight()
        showActive(keepingPosition: false)
        updatePlaceholder()
    }

    private func tooltip(for tab: Tab) -> String {
        switch tab.source {
        case .workingTree: return tab.path
        case .commit(let hash): return "\(tab.path) @ \(hash)"
        }
    }

    private func showActive(keepingPosition: Bool) {
        guard let tab = activeTab else {
            diffView.configure(diff: "")
            return
        }
        diffView.configure(diff: tab.diff, keepingPosition: keepingPosition)
        header.configure(path: tab.path, changes: diffView.changeCount)
    }

    private func toggleMode() {
        Self.mode = Self.mode.next
        header.setMode(Self.mode)
        diffView.setMode(Self.mode)
        if let tab = activeTab {
            header.configure(path: tab.path, changes: diffView.changeCount)
        }
    }

    private func updatePlaceholder() {
        let hasTabs = !tabs.isEmpty
        for view in [tabBar, header, diffView] as [NSView] { view.isHidden = !hasTabs }
        welcome.isHidden = hasTabs || hasProject
        hint.isHidden = hasTabs || !hasProject
    }

    // MARK: - Regression-test surface

    var diffViewForTesting: DiffView { _ = view; return diffView }
    var headerForTesting: DiffHeaderView { _ = view; return header }
    var tabTitlesForTesting: [String] { tabs.map(\.title) }
    var tabRowHeightForTesting: CGFloat { _ = view; return tabBar.rowHeight }
    var welcomeVisibleForTesting: Bool { _ = view; return !welcome.isHidden }
    var hintVisibleForTesting: Bool { _ = view; return !hint.isHidden }
    func toggleModeForTesting() { toggleMode() }
}

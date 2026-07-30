import AppKit

/// Window content: sidebar | editor split. There is no status bar — the panel
/// buttons live in the sidebar's bottom action bar (Zed layout).
final class RootViewController: NSViewController {
    let split = PuzzleSplitViewController()
    let sidebar: SidebarViewController
    let editor: EditorViewController

    /// Panel width is preserved across panel switches / collapses.
    private let minimumSidebarWidth: CGFloat = 150
    private var lastSidebarWidth: CGFloat = 280
    /// Owns the panel width so switching panels can never change it. Dragging the
    /// divider updates its constant, so the divider still works.
    private var sidebarWidthConstraint: NSLayoutConstraint!
    private var sidebarItem: NSSplitViewItem!
    private let dividerHandle = SplitDividerHandleView()
    private var dividerDragStartWidth: CGFloat = 280

    init(sidebar: SidebarViewController, editor: EditorViewController) {
        self.sidebar = sidebar
        self.editor = editor
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = FlatView()
        root.fillColor = Theme.editorBackground

        sidebarItem = NSSplitViewItem(viewController: sidebar)
        sidebarItem.minimumThickness = minimumSidebarWidth
        // Upper bound is 80% of the window (applied live in onDividerDrag);
        // this static cap is just a sane ceiling before the window exists.
        sidebarItem.maximumThickness = 2000
        // The panel is always visible — clicking the active action button (or
        // ⌘B) must not hide it.
        sidebarItem.canCollapse = false
        // The panel holds its width; the editor absorbs window resizing. With
        // `.defaultLow` the panel is the pane that yields, so it snapped back to
        // its content minimum and could not be widened.
        sidebarItem.holdingPriority = .defaultHigh
        let editorItem = NSSplitViewItem(viewController: editor)
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(editorItem)
        addChild(split)

        // The panel's width is owned by this constraint, so switching panels can
        // never change it. Dragging the divider updates the constant (below), so
        // the divider still works normally.
        sidebarWidthConstraint = sidebar.view.widthAnchor.constraint(equalToConstant: lastSidebarWidth)
        sidebarWidthConstraint.priority = .init(999)
        sidebarWidthConstraint.isActive = true

        split.onDividerDrag = { [weak self] proposed in
            self?.resizeSidebar(to: proposed)
        }

        let splitView = split.view
        splitView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(splitView)
        dividerHandle.translatesAutoresizingMaskIntoConstraints = false
        dividerHandle.onDragBegan = { [weak self] in
            guard let self else { return }
            self.dividerDragStartWidth = self.lastSidebarWidth
        }
        dividerHandle.onDrag = { [weak self] deltaX in
            guard let self else { return }
            self.resizeSidebar(to: self.dividerDragStartWidth + deltaX)
        }
        root.addSubview(dividerHandle, positioned: .above, relativeTo: splitView)
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: root.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            dividerHandle.centerXAnchor.constraint(equalTo: sidebar.view.trailingAnchor),
            dividerHandle.topAnchor.constraint(equalTo: root.topAnchor),
            dividerHandle.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            dividerHandle.widthAnchor.constraint(equalToConstant: SplitDividerHandleView.hitWidth),
        ])
        self.view = root

    }


    /// The width constraint already makes every panel identical; this simply
    /// re-asserts it (also used after collapse/expand).
    func preserveSidebarWidth() { applyWidth(lastSidebarWidth) }

    private func applyWidth(_ target: CGFloat) {
        guard !sidebarItem.isCollapsed else { return }
        lastSidebarWidth = target
        sidebarWidthConstraint.constant = target
    }

    private func resizeSidebar(to proposedWidth: CGFloat) {
        // Never let the panel take more than 80% of the window.
        let limit = max(minimumSidebarWidth, (view.bounds.width * 0.8).rounded())
        let width = min(max(proposedWidth, minimumSidebarWidth), limit)
        sidebarWidthConstraint.constant = width
        lastSidebarWidth = width
    }

    var isSidebarCollapsed: Bool { sidebarItem.isCollapsed }

    /// The panel no longer collapses; this just guarantees it is visible at its
    /// remembered width (kept so existing callers/menu items stay valid).
    func toggleSidebar() { showSidebar() }

    func showSidebar() {
        if sidebarItem.isCollapsed { sidebarItem.isCollapsed = false }
        applyWidth(max(lastSidebarWidth, minimumSidebarWidth))
    }
}

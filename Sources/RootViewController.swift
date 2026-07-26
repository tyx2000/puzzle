import AppKit

/// Window content: sidebar | editor split. There is no status bar — the panel
/// buttons live in the sidebar's bottom action bar (Zed layout).
final class RootViewController: NSViewController {
    let split = PuzzleSplitViewController()
    let sidebar: SidebarViewController
    let editor: EditorViewController

    /// Panel width is preserved across panel switches / collapses.
    private let minimumSidebarWidth: CGFloat = 180
    private var lastSidebarWidth: CGFloat = 260
    /// Owns the panel width so switching panels can never change it. Dragging the
    /// divider updates its constant, so the divider still works.
    private var sidebarWidthConstraint: NSLayoutConstraint!
    private var sidebarItem: NSSplitViewItem!

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
        sidebarItem.maximumThickness = 520
        sidebarItem.canCollapse = true
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
            guard let self else { return }
            let width = min(max(proposed, self.minimumSidebarWidth), 520)
            self.sidebarWidthConstraint.constant = width
            self.lastSidebarWidth = width
        }

        let splitView = split.view
        splitView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(splitView)
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: root.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
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

    var isSidebarCollapsed: Bool { sidebarItem.isCollapsed }

    /// Collapse / expand the left panel. Uses a direct assignment — the
    /// `animator()` proxy did not reliably toggle the item.
    func toggleSidebar() {
        if sidebarItem.isCollapsed {
            let target = lastSidebarWidth
            sidebarItem.isCollapsed = false
            applyWidth(target)
        } else {
            // `lastSidebarWidth` already tracks the constraint (updated on drag),
            // so don't read the frame here — mid-collapse it reports the minimum.
            sidebarItem.isCollapsed = true
        }
    }

    func showSidebar() {
        guard sidebarItem.isCollapsed else { return }
        let target = lastSidebarWidth
        sidebarItem.isCollapsed = false
        applyWidth(target)
    }
}

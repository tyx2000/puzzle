import AppKit

/// Window content: sidebar | editor split. There is no status bar — the panel
/// buttons live in the sidebar's bottom action bar (Zed layout).
final class RootViewController: NSViewController {
    let split = PuzzleSplitViewController()
    let sidebar: SidebarViewController
    let editor: EditorViewController

    /// Panel width is preserved across panel switches. The floor is what the
    /// Git panel's rows need before names start truncating.
    static let minimumSidebarWidth: CGFloat = 300
    /// What a window opens at.
    static let defaultSidebarWidth: CGFloat = 500
    private var minimumSidebarWidth: CGFloat { Self.minimumSidebarWidth }
    private var lastSidebarWidth: CGFloat = RootViewController.defaultSidebarWidth
    /// Owns the panel width so switching panels can never change it. Dragging the
    /// divider updates its constant, so the divider still works.
    private var sidebarWidthConstraint: NSLayoutConstraint!
    private var sidebarItem: NSSplitViewItem!
    private let dividerHandle = SplitDividerHandleView()
    private var dividerDragStartWidth: CGFloat = 400

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
        // The panel is always visible; all sidebar commands select a panel.
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
        dividerHandle.dividerThickness = split.splitView.dividerThickness
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


    /// Repaint the themed divider after a theme change.
    func refreshAppearance() {
        dividerHandle.dividerThickness = split.splitView.dividerThickness
        dividerHandle.needsDisplay = true
    }

    func resizeSidebarForTesting(to width: CGFloat) { resizeSidebar(to: width) }
    var sidebarWidthForTesting: CGFloat { sidebarWidthConstraint.constant }

    /// Re-assert the remembered width after switching panels.
    func preserveSidebarWidth() { applyWidth(lastSidebarWidth) }

    private func applyWidth(_ target: CGFloat) {
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

    func showSidebar() {
        applyWidth(max(lastSidebarWidth, minimumSidebarWidth))
    }
}

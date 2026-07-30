import AppKit

/// Sidebar showing the project directory as a lazy NSOutlineView tree.
final class FileTreeViewController: NSViewController {
    var onOpenFile: ((URL) -> Void)?

    private var outlineView: NSOutlineView!
    private var root: FileNode?
    /// Relative paths (from root) that git reports as modified/untracked.
    private var dirtyPaths: Set<String> = []
    private var untrackedPaths: Set<String> = []
    /// Directories containing a change, so a collapsed folder still shows that
    /// something under it differs — git reports files, never their folders.
    private var dirtyDirectories: Set<String> = []
    private var untrackedDirectories: Set<String> = []
    /// The file open in the active editor pane — gets a persistent background.
    private var activeURL: URL?

    override func loadView() {
        outlineView = NSOutlineView()
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .custom
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.backgroundColor = Theme.panelBackground
        outlineView.indentationPerLevel = 14
        outlineView.selectionHighlightStyle = .regular
        outlineView.target = self
        outlineView.doubleAction = #selector(handleDoubleClick)
        outlineView.action = #selector(handleClick)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.panelBackground
        scrollView.scrollerKnobStyle = .light

        self.view = scrollView
    }

    func setRoot(_ url: URL) {
        root = FileNode(url: url, isDirectory: true)
        outlineView.reloadData()
        if let root {
            outlineView.expandItem(root)
        }
    }

    /// Refresh from disk, keeping expansion where possible.
    func refresh() {
        root?.invalidate()
        outlineView.reloadData()
    }

    /// Row index currently painted as the active file (nil if none on screen).
    var activeHighlightedRow: Int? {
        var found: Int?
        outlineView.enumerateAvailableRowViews { view, index in
            if (view as? TreeRowView)?.isActiveFile == true { found = index }
        }
        return found
    }

    /// Row index for a URL, or nil if not currently displayed.
    func row(for url: URL) -> Int? {
        for index in 0..<outlineView.numberOfRows {
            if let node = outlineView.item(atRow: index) as? FileNode, node.url == url {
                return index
            }
        }
        return nil
    }

    /// Whether `row` is inside the scrolled visible area.
    func isRowVisible(_ row: Int) -> Bool {
        guard let scroll = view as? NSScrollView else { return false }
        return scroll.contentView.bounds.intersects(outlineView.rect(ofRow: row))
    }

    /// Redraw after a theme / settings change.
    func refreshAppearance() {
        outlineView.backgroundColor = Theme.panelBackground
        outlineView.reloadData()
        // Row heights are cached, so `ui_line_height` / `ui_font_size` changes
        // need an explicit invalidation to take effect.
        if outlineView.numberOfRows > 0 {
            outlineView.noteHeightOfRows(withIndexesChanged:
                IndexSet(integersIn: 0..<outlineView.numberOfRows))
        }
    }

    func setDirtyPaths(_ paths: Set<String>) {
        setStatus(modified: paths, untracked: [])
    }

    func setStatus(modified: Set<String>, untracked: Set<String>) {
        dirtyPaths = modified
        untrackedPaths = untracked
        dirtyDirectories = Self.ancestors(of: modified)
        untrackedDirectories = Self.ancestors(of: untracked)
        outlineView.reloadData()
    }

    /// Every directory prefix of the given paths.
    private static func ancestors(of paths: Set<String>) -> Set<String> {
        var out: Set<String> = []
        for path in paths {
            var components = path.split(separator: "/").map(String.init)
            guard components.count > 1 else { continue }
            components.removeLast()
            var prefix = ""
            for component in components {
                prefix = prefix.isEmpty ? component : prefix + "/" + component
                out.insert(prefix)
            }
        }
        return out
    }

    /// Colour for a row: untracked reads as "new", modified as "changed", and a
    /// folder inherits from whatever is inside it.
    private func statusColor(for node: FileNode) -> NSColor? {
        guard let path = relativePath(for: node) else { return nil }
        if node.isDirectory {
            if untrackedDirectories.contains(path) { return Theme.green }
            if dirtyDirectories.contains(path) { return Theme.yellow }
            return nil
        }
        if untrackedPaths.contains(path) { return Theme.green }
        if dirtyPaths.contains(path) { return Theme.yellow }
        return nil
    }

    /// Expand ancestors and select the row for `url` (keeps the tree in sync
    /// with the active editor tab). Does not trigger onOpenFile.
    func selectFile(_ url: URL) {
        activeURL = url
        guard let root else { return }
        let rootPath = root.url.path
        // Files outside the project (e.g. settings.json) just clear the highlight.
        guard url.path.hasPrefix(rootPath) else { refreshActiveRowBackgrounds(); return }
        outlineView.expandItem(root)
        var current = root
        let relative = url.path.dropFirst(rootPath.count)
        for comp in relative.split(separator: "/") {
            guard let child = current.children.first(where: { $0.name == String(comp) }) else {
                refreshActiveRowBackgrounds(); return
            }
            if child.isDirectory { outlineView.expandItem(child) }
            current = child
        }
        let row = outlineView.row(forItem: current)
        guard row >= 0 else { outlineView.reloadData(); return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        refreshActiveRowBackgrounds()
        // Bring the active file into view (it may be far down / newly expanded).
        outlineView.scrollRowToVisible(row)
    }

    /// `rowViewForItem:` only runs when a row view is created, so rows that are
    /// already on screen keep a stale `isActiveFile`. Update them in place.
    private func refreshActiveRowBackgrounds() {
        outlineView.enumerateAvailableRowViews { view, rowIndex in
            guard let rowView = view as? TreeRowView else { return }
            let node = self.outlineView.item(atRow: rowIndex) as? FileNode
            let isActive = node != nil && node!.url == self.activeURL
            if rowView.isActiveFile != isActive {
                rowView.isActiveFile = isActive
            }
            rowView.needsDisplay = true
        }
    }

    private func relativePath(for node: FileNode) -> String? {
        guard let root else { return nil }
        let rootPath = root.url.path
        let nodePath = node.url.path
        guard nodePath.hasPrefix(rootPath) else { return nil }
        var rel = String(nodePath.dropFirst(rootPath.count))
        if rel.hasPrefix("/") { rel.removeFirst() }
        return rel
    }

    @objc private func handleDoubleClick() {
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? FileNode else { return }
        if node.isDirectory {
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else {
                outlineView.expandItem(node)
            }
        } else {
            onOpenFile?(node.url)
        }
    }

    @objc private func handleClick() {
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? FileNode else { return }
        if node.isDirectory {
            // Single click toggles a directory (and repaints its icon).
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else {
                outlineView.expandItem(node)
            }
        } else {
            onOpenFile?(node.url)
        }
    }
}

extension FileTreeViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return root == nil ? 0 : 1 }
        guard let node = item as? FileNode, node.isDirectory else { return 0 }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return root! }
        let node = item as! FileNode
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory ?? false
    }
}

extension FileTreeViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell: FileTreeCell
        if let reused = outlineView.makeView(withIdentifier: id, owner: self) as? FileTreeCell {
            cell = reused
        } else {
            cell = FileTreeCell()
            cell.identifier = id
        }

        // Directories show open/closed state through both icon and colour.
        let icon: NSImage?
        let iconColor: NSColor
        if node.isDirectory {
            let expanded = outlineView.isItemExpanded(node)
            icon = Theme.symbol(expanded ? "folder.fill" : "folder")
            iconColor = expanded ? Theme.blue : Theme.folderClosed
        } else {
            icon = Theme.symbol(Self.iconName(for: node.url.pathExtension))
            iconColor = Theme.dimText
        }

        cell.configure(title: node.name, icon: icon, iconColor: iconColor,
                       titleColor: statusColor(for: node) ?? Theme.foreground)
        return cell
    }

    /// Driven by `ui_font_size` × `ui_line_height` in settings.json.
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        Theme.treeRowHeight()
    }

    // Repaint the folder row so its icon reflects the new open/closed state.
    func outlineViewItemDidExpand(_ notification: Notification) {
        reloadRow(from: notification)
    }
    func outlineViewItemDidCollapse(_ notification: Notification) {
        reloadRow(from: notification)
    }
    private func reloadRow(from notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] else { return }
        // Collapsing frees the subtree's cached nodes.
        if let node = item as? FileNode, !outlineView.isItemExpanded(node) {
            node.releaseChildren()
        }
        outlineView.reloadItem(item)
        refreshActiveRowBackgrounds()
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("tree-row")
        let row = (outlineView.makeView(withIdentifier: id, owner: self) as? TreeRowView)
            ?? TreeRowView()
        row.identifier = id
        row.isActiveFile = (item as? FileNode)?.url == activeURL
        return row
    }

    static func iconName(for ext: String) -> String {
        switch ext.lowercased() {
        case "json", "yaml", "yml": return "curlybraces"
        case "ts", "tsx", "js", "jsx", "mjs", "cjs": return "chevron.left.forwardslash.chevron.right"
        case "sh", "bash", "zsh": return "terminal"
        case "md", "markdown": return "doc.richtext"
        case "swift": return "swift"
        case "png", "jpg", "jpeg", "gif", "svg": return "photo"
        default: return "doc.text"
        }
    }
}

private final class FileTreeCell: DrawnSidebarCell {
    private var title = ""
    private var icon: NSImage?
    private var iconColor = NSColor.clear
    private var titleColor = NSColor.clear

    func configure(title: String, icon: NSImage?, iconColor: NSColor,
                   titleColor: NSColor) {
        self.title = title
        self.icon = icon
        self.iconColor = iconColor
        self.titleColor = titleColor
        toolTip = title
        exposeToAccessibility(title)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let font = Theme.uiFont(12)
        let baseline = SidebarCellDrawing.centeredBaseline(for: font, in: bounds)
        SidebarCellDrawing.image(icon, tint: iconColor,
                                 in: NSRect(x: 3, y: floor(bounds.midY - 7),
                                            width: 14, height: 14))
        SidebarCellDrawing.text(title, font: font, color: titleColor,
                                baseline: baseline,
                                in: NSRect(x: 22, y: 0,
                                           width: max(0, bounds.width - 27),
                                           height: bounds.height),
                                lineBreak: .byTruncatingMiddle)
    }
}

/// Tree row with a persistent background for the file open in the active pane.
final class TreeRowView: NSTableRowView {
    var isActiveFile = false

    override func drawBackground(in dirtyRect: NSRect) {
        Theme.panelBackground.setFill()
        bounds.fill()
        if isActiveFile {
            Theme.activeRow.setFill()
            bounds.fill()
        }
    }

    // Selection is conveyed by the active-file background; keep rows flat.
    override func drawSelection(in dirtyRect: NSRect) {
        if !isActiveFile {
            Theme.hover.setFill()
            bounds.fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

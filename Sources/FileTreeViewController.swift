import AppKit

/// Sidebar showing the project directory as a lazy NSOutlineView tree.
final class FileTreeViewController: NSViewController {
    var onOpenFile: ((URL) -> Void)?

    private var outlineView: NSOutlineView!
    private var root: FileNode?
    /// Relative paths (from root) that git reports as modified/untracked.
    private var dirtyPaths: Set<String> = []
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
        dirtyPaths = paths
        outlineView.reloadData()
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
        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            let imageView = NSImageView()
            let textField = NSTextField(labelWithString: "")
            textField.lineBreakMode = .byTruncatingMiddle
            imageView.translatesAutoresizingMaskIntoConstraints = false
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(imageView)
            cell.addSubview(textField)
            cell.imageView = imageView
            cell.textField = textField
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 5),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        // Directories show open/closed state through both icon and colour.
        if node.isDirectory {
            let expanded = outlineView.isItemExpanded(node)
            cell.imageView?.image = NSImage(
                systemSymbolName: expanded ? "folder.fill" : "folder",
                accessibilityDescription: nil)
            cell.imageView?.contentTintColor = expanded ? Theme.blue : Theme.folderClosed
        } else {
            cell.imageView?.image = NSImage(
                systemSymbolName: Self.iconName(for: node.url.pathExtension),
                accessibilityDescription: nil)
            cell.imageView?.contentTintColor = Theme.dimText
        }

        let isDirty = relativePath(for: node).map { dirtyPaths.contains($0) } ?? false
        cell.textField?.stringValue = node.name
        cell.textField?.textColor = isDirty ? Theme.yellow : Theme.foreground
        // Set on every pass, not just on creation — cells are reused, so a
        // settings change must re-apply the font to already-built cells.
        cell.textField?.font = Theme.uiFont(12)
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
        let row = TreeRowView()
        row.depth = outlineView.level(forItem: item)
        row.indentPerLevel = outlineView.indentationPerLevel
        if let node = item as? FileNode, let active = activeURL {
            row.isActiveFile = (node.url == active)
        }
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

/// Tree row that draws Zed-style indent guides and a persistent background for
/// the file open in the active editor pane.
final class TreeRowView: NSTableRowView {
    var depth = 0
    var indentPerLevel: CGFloat = 14
    var isActiveFile = false

    override func drawBackground(in dirtyRect: NSRect) {
        Theme.panelBackground.setFill()
        bounds.fill()
        if isActiveFile {
            Theme.activeRow.setFill()
            bounds.fill()
        }
        // Indent guides for each ancestor level.
        guard depth > 0 else { return }
        Theme.indentGuide.setFill()
        for level in 0..<depth {
            let x = 10 + indentPerLevel * CGFloat(level)
            NSRect(x: x, y: 0, width: 1, height: bounds.height).fill()
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

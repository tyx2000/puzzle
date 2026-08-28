import AppKit

private final class PendingTreePlaceholder {}

private enum FileTreeRowLayout {
    /// Keep the original slot width so shrinking the chevron does not shift the
    /// folder icon or title. Only the visible disclosure glyph becomes smaller.
    static let disclosureSlotSize: CGFloat = 12
    static let disclosureSize: CGFloat = 10
    static let iconSize: CGFloat = 14
    static let gap: CGFloat = 4
    static let disclosureX = (disclosureSlotSize - disclosureSize) / 2
    static let iconX = disclosureSlotSize + gap
    static let titleX = iconX + iconSize + gap

    static func centeredRect(x: CGFloat, size: CGFloat, in bounds: NSRect) -> NSRect {
        NSRect(x: x, y: bounds.midY - size / 2, width: size, height: size)
    }
}

private final class PendingTreeEdit {
    enum Kind { case file, folder, rename }
    let kind: Kind
    let parent: FileNode?
    let original: FileNode?
    let initialName: String
    let insertionIndex: Int
    let placeholder = PendingTreePlaceholder()
    var didFocus = false

    init(kind: Kind, parent: FileNode?, original: FileNode?, initialName: String,
         insertionIndex: Int = 0) {
        self.kind = kind
        self.parent = parent
        self.original = original
        self.initialName = initialName
        self.insertionIndex = insertionIndex
    }
}

private final class FileTreeOutlineView: NSOutlineView {
    var contextMenuProvider: ((Int) -> NSMenu?)?
    private var hoverTrackingArea: NSTrackingArea?
    private(set) var hoverTrackingAreaInstallCountForTesting = 0
    private(set) var hoveredRow = -1

    /// The disclosure symbol is drawn with the file icon and title by the cell,
    /// giving all three elements one coordinate system and one spacing rule.
    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard hoverTrackingArea == nil else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved,
                      .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
        hoverTrackingAreaInstallCountForTesting += 1
    }

    override func mouseEntered(with event: NSEvent) { updateHoveredRow(with: event) }
    override func mouseMoved(with event: NSEvent) { updateHoveredRow(with: event) }
    override func mouseExited(with event: NSEvent) { setHoveredRow(-1) }

    override func layout() {
        super.layout()
        refreshHoverState()
    }

    func refreshHoverState() {
        guard let window else {
            setHoveredRow(-1)
            return
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setHoveredRow(bounds.contains(point) ? row(at: point) : -1)
    }

    private func updateHoveredRow(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setHoveredRow(bounds.contains(point) ? row(at: point) : -1)
    }

    func setHoveredRowForTesting(_ row: Int) { setHoveredRow(row) }

    private func setHoveredRow(_ row: Int) {
        let next = row >= 0 && row < numberOfRows ? row : -1
        guard next != hoveredRow else { return }
        let previous = hoveredRow
        hoveredRow = next
        if previous >= 0 {
            (rowView(atRow: previous, makeIfNecessary: false) as? TreeRowView)?.isHovered = false
        }
        if next >= 0 {
            (rowView(atRow: next, makeIfNecessary: false) as? TreeRowView)?.isHovered = true
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return contextMenuProvider?(row(at: point))
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        if clickedRow >= 0,
           let editor = view(atColumn: 0, row: clickedRow,
                             makeIfNecessary: false) as? InlineTreeNameCell {
            editor.focus(selectAll: false)
            return
        }
        super.mouseDown(with: event)
    }

}

/// Sidebar showing the project directory as a lazy NSOutlineView tree.
final class FileTreeViewController: NSViewController {
    var onOpenFile: ((URL) -> Void)?
    var onGitHistory: ((URL) -> Void)?
    /// Open a terminal at this folder (the window owns which terminal).
    var onOpenInTerminal: ((URL) -> Void)?
    var onFileSystemChanged: (() -> Void)?
    var canMutatePath: ((URL) -> Bool)?
    var onPathRenamed: ((URL, URL) -> Void)?
    var onPathDeleted: ((URL) -> Void)?

    private var outlineView: FileTreeOutlineView!
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
    private var pendingEdit: PendingTreeEdit?
    private var deferredTreeReload = false
    private var treeResyncScheduled = false
    /// Stands in for a child that has gone away between AppKit asking how many
    /// there are and which one. Never part of the tree, so it cannot recurse.
    private let staleChild = PendingTreePlaceholder()
    private var deferredDiskRefresh = false

    override func loadView() {
        outlineView = FileTreeOutlineView()
        outlineView.contextMenuProvider = { [weak self] row in
            self?.contextMenu(forRow: row)
        }
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.headerView = nil
        outlineView.style = .plain
        outlineView.rowSizeStyle = .custom
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.backgroundColor = Theme.panelBackground
        outlineView.indentationPerLevel = 14
        // Active/hover backgrounds are drawn by TreeRowView. AppKit's native
        // selection layer raced that tracking state and visibly flashed.
        outlineView.selectionHighlightStyle = .none
        outlineView.target = self
        outlineView.doubleAction = #selector(handleDoubleClick)
        outlineView.action = #selector(handleClick)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        let scrollView = NSScrollView()
        PuzzleScroller.adopt(scrollView)
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.panelBackground
        scrollView.scrollerKnobStyle = .light
        // Full-size windows otherwise let NSScrollView apply titlebar safe-area
        // insets of its own, pulling the first tree row back above our 32pt gap.
        // Insets and scrollers both come from `PuzzleScroller.adopt` above.

        self.view = scrollView
    }

    func setRoot(_ url: URL) {
        cancelPendingEdit()
        deferredTreeReload = false
        deferredDiskRefresh = false
        root = FileNode(url: url, isDirectory: true)
        outlineView.reloadData()
        if let root {
            outlineView.expandItem(root)
        }
    }

    /// Refresh from disk, keeping expansion where possible.
    func refresh() {
        guard pendingEdit == nil else {
            deferredTreeReload = true
            deferredDiskRefresh = true
            return
        }
        root?.invalidate()
        outlineView.reloadData()
    }

    /// Refresh only directories touched by external filesystem events. Existing
    /// nodes keep their identity, so expanded folders and hover state survive.
    func refresh(changedURLs: [URL]) {
        guard let root, !changedURLs.isEmpty else { return }
        guard pendingEdit == nil else {
            deferredTreeReload = true
            deferredDiskRefresh = true
            return
        }

        let rootPath = root.url.standardizedFileURL.path
        let rootPrefix = rootPath + "/"
        var affected: [FileNode] = []
        var seen = Set<ObjectIdentifier>()
        for changedURL in changedURLs {
            let changed = changedURL.standardizedFileURL
            guard changed.path == rootPath || changed.path.hasPrefix(rootPrefix) else { continue }
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: changed.path,
                                                        isDirectory: &isDirectory)
            var candidate = exists && isDirectory.boolValue
                ? changed : changed.deletingLastPathComponent()
            while candidate.path == rootPath || candidate.path.hasPrefix(rootPrefix) {
                if let node = node(for: candidate), node.isDirectory {
                    let id = ObjectIdentifier(node)
                    if seen.insert(id).inserted { affected.append(node) }
                    break
                }
                guard candidate.path != rootPath else { break }
                candidate.deleteLastPathComponent()
            }
        }
        guard !affected.isEmpty else { return }
        affected.forEach { $0.refreshChildren() }
        affected.forEach { outlineView.reloadItem($0, reloadChildren: true) }
        refreshActiveRowBackgrounds()
    }

    /// Row index currently painted as the active file (nil if none on screen).
    var activeHighlightedRow: Int? {
        var found: Int?
        outlineView.enumerateAvailableRowViews { view, index in
            if (view as? TreeRowView)?.isActiveFile == true { found = index }
        }
        return found
    }
    var activeURLForTesting: URL? { activeURL }
    func activeStateForTesting(at row: Int) -> Bool? {
        (outlineView.rowView(atRow: row, makeIfNecessary: true) as? TreeRowView)?.isActiveFile
    }

    /// Row index for a URL, or nil if not currently displayed.
    func row(for url: URL) -> Int? {
        let target = url.standardizedFileURL
        for index in 0..<outlineView.numberOfRows {
            if let node = outlineView.item(atRow: index) as? FileNode,
               node.url.standardizedFileURL == target {
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

    // MARK: - Regression-test surface

    /// Distance from one file row to the next: its height plus the gap AppKit
    /// leaves between rows. Compared against the git panel's.
    var rowPitchForTesting: CGFloat {
        _ = view
        return Theme.treeRowHeight() + outlineView.intercellSpacing.height
    }
    func contextMenuForTesting(row: Int) -> NSMenu? { contextMenu(forRow: row) }
    var rowCountForTesting: Int { outlineView.numberOfRows }
    var outlineViewForTesting: NSOutlineView { outlineView }
    var verticalScrollerForTesting: NSScroller? { outlineView.enclosingScrollView?.verticalScroller }
    func nodeForTesting(at row: Int) -> FileNode? { outlineView.item(atRow: row) as? FileNode }
    func expandRowForTesting(_ row: Int) {
        guard let item = outlineView.item(atRow: row) else { return }
        outlineView.expandItem(item)
    }
    /// Counts `reloadItem` calls, so a test can tell a deferred reload from one
    /// that happened inside AppKit's own.
    private(set) var reloadCountForTesting = 0
    var pendingEditRowForTesting: Int? {
        guard let edit = pendingEdit else { return nil }
        let item: Any = edit.original ?? edit.placeholder
        let row = outlineView.row(forItem: item)
        return row >= 0 ? row : nil
    }
    var pendingEditorVerticalCenterErrorForTesting: CGFloat? {
        guard let row = pendingEditRowForTesting,
              let cell = outlineView.view(atColumn: 0, row: row,
                                          makeIfNecessary: true) as? InlineTreeNameCell else {
            return nil
        }
        return cell.verticalCenterErrorForTesting
    }
    var pendingEditorHasIconForTesting: Bool? {
        guard let row = pendingEditRowForTesting,
              let cell = outlineView.view(atColumn: 0, row: row,
                                          makeIfNecessary: true) as? InlineTreeNameCell else {
            return nil
        }
        return cell.hasIconForTesting
    }
    var pendingEditorBackgroundForTesting: NSColor? {
        guard let row = pendingEditRowForTesting,
              let cell = outlineView.view(atColumn: 0, row: row,
                                          makeIfNecessary: true) as? InlineTreeNameCell else {
            return nil
        }
        return cell.backgroundColorForTesting
    }
    var automaticallyAdjustsInsetsForTesting: Bool {
        (view as? NSScrollView)?.automaticallyAdjustsContentInsets ?? true
    }
    var hoverTrackingAreaInstallCountForTesting: Int {
        outlineView.updateTrackingAreas()
        return outlineView.hoverTrackingAreaInstallCountForTesting
    }
    var hoveredRowForTesting: Int { outlineView.hoveredRow }
    func setHoveredRowForTesting(_ row: Int) { outlineView.setHoveredRowForTesting(row) }
    var firstRowTopInsetInWindowForTesting: CGFloat? {
        guard outlineView.numberOfRows > 0, let window = view.window else { return nil }
        outlineView.layoutSubtreeIfNeeded()
        let rect = outlineView.convert(outlineView.rect(ofRow: 0), to: nil)
        return window.frame.height - rect.maxY
    }
    func titleColorForTesting(at url: URL) -> NSColor? {
        guard let row = row(for: url) else { return nil }
        return (outlineView.view(atColumn: 0, row: row,
                                 makeIfNecessary: true) as? FileTreeCell)?.titleColorForTesting
    }

    /// Redraw after a theme / settings change.
    func refreshAppearance() {
        guard pendingEdit == nil else {
            deferredTreeReload = true
            return
        }
        outlineView.backgroundColor = Theme.panelBackground
        outlineView.reloadData()
        // Row heights are cached, so `tree_line_height` / `ui_font_size` changes
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
        guard pendingEdit == nil else {
            deferredTreeReload = true
            return
        }
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
        let previousURL = activeURL
        activeURL = url.standardizedFileURL
        defer { refreshActiveFilePresentation(previousURL: previousURL) }
        guard let root else { return }
        let rootPath = root.url.standardizedFileURL.path
        let target = url.standardizedFileURL
        let prefix = rootPath + "/"
        // Files outside the project (e.g. settings.json) just clear the highlight.
        guard target.path.hasPrefix(prefix) else { refreshActiveRowBackgrounds(); return }
        _ = revealAndSelect(target, below: root, rootPath: rootPath)
    }

    @discardableResult
    private func revealAndSelect(_ url: URL, below root: FileNode,
                                 rootPath: String) -> Bool {
        outlineView.expandItem(root)
        var current = root
        let relative = url.path.dropFirst(rootPath.count)
        for comp in relative.split(separator: "/") {
            let name = String(comp)
            var child = current.children.first(where: { $0.name == name })
            if child == nil {
                // The open request can beat the FSEvent for a newly created
                // file. Refresh only the missing item's parent, preserving all
                // other node identities and expansion state.
                current.refreshChildren()
                outlineView.reloadItem(current, reloadChildren: true)
                child = current.children.first(where: { $0.name == name })
            }
            guard let child else { return false }
            if child.isDirectory { outlineView.expandItem(child) }
            current = child
        }
        let row = outlineView.row(forItem: current)
        guard row >= 0 else { return false }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        refreshActiveRowBackgrounds()
        // Bring the active file into view (it may be far down / newly expanded).
        outlineView.scrollRowToVisible(row)
        return true
    }

    private func refreshActiveFilePresentation(previousURL: URL?) {
        var rows = IndexSet()
        if let previousURL, let row = row(for: previousURL) { rows.insert(row) }
        if let activeURL, let row = row(for: activeURL) { rows.insert(row) }
        if !rows.isEmpty {
            outlineView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
        }
        refreshActiveRowBackgrounds()
    }

    /// `rowViewForItem:` only runs when a row view is created, so rows that are
    /// already on screen keep a stale `isActiveFile`. Update them in place.
    private func refreshActiveRowBackgrounds() {
        outlineView.enumerateAvailableRowViews { view, rowIndex in
            guard let rowView = view as? TreeRowView else { return }
            let node = self.outlineView.item(atRow: rowIndex) as? FileNode
            let isActive = node != nil
                && node!.url.standardizedFileURL == self.activeURL
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

    private func contextMenu(forRow row: Int) -> NSMenu? {
        guard let node = row >= 0 ? outlineView.item(atRow: row) as? FileNode : root else {
            return nil
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let actions: [(String, Selector)] = [
            ("New File", #selector(newFileAction(_:))),
            ("New Folder", #selector(newFolderAction(_:))),
            ("Rename", #selector(renameAction(_:))),
            ("Duplicate", #selector(duplicateAction(_:))),
            ("Reveal in Finder", #selector(revealInFinderAction(_:))),
            ("Copy Path", #selector(copyPathAction(_:))),
            ("Copy Relative Path", #selector(copyRelativePathAction(_:))),
            ("Open in Terminal", #selector(openInTerminalAction(_:))),
            ("Git History", #selector(gitHistoryAction(_:))),
            ("Delete", #selector(deleteAction(_:))),
        ]
        for (index, action) in actions.enumerated() {
            if index == 2 || index == 4 || index == 8 || index == 9 {
                menu.addItem(.separator())
            }
            let item = NSMenuItem(title: action.0, action: action.1, keyEquivalent: "")
            item.target = self
            // Keep a stable path, not the node object. A git/file refresh can
            // rebuild the whole node tree while the menu is open.
            item.representedObject = node.url as NSURL
            if action.0 == "Rename" || action.0 == "Delete" {
                item.isEnabled = node !== root
            } else if action.0 == "Git History" {
                item.isEnabled = !node.isDirectory
            }
            menu.addItem(item)
        }
        return menu
    }

    private func menuNode(_ sender: Any?) -> FileNode? {
        guard let url = (sender as? NSMenuItem)?.representedObject as? URL else { return nil }
        return node(for: url)
    }

    private func node(for url: URL) -> FileNode? {
        guard let root else { return nil }
        let rootPath = root.url.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == rootPath { return root }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        var current = root
        for component in path.dropFirst(prefix.count).split(separator: "/") {
            guard let child = current.children.first(where: { $0.name == String(component) }) else {
                return nil
            }
            current = child
        }
        return current
    }

    @objc private func newFileAction(_ sender: Any?) {
        guard let node = menuNode(sender) else { return }
        let parent = node.isDirectory ? node : node.parent
        guard let parent else { return }
        beginCreate(kind: .file, parent: parent, after: node.isDirectory ? nil : node)
    }

    @objc private func newFolderAction(_ sender: Any?) {
        guard let node = menuNode(sender) else { return }
        let parent = node.isDirectory ? node : node.parent
        guard let parent else { return }
        beginCreate(kind: .folder, parent: parent, after: node.isDirectory ? nil : node)
    }

    @objc private func renameAction(_ sender: Any?) {
        guard let node = menuNode(sender), node !== root else { return }
        guard canMutate(node.url, verb: "rename") else { return }
        cancelPendingEdit()
        pendingEdit = PendingTreeEdit(kind: .rename, parent: node.parent,
                                      original: node, initialName: node.name)
        outlineView.reloadItem(node)
        focusPendingEditor()
    }

    @objc private func revealInFinderAction(_ sender: Any?) {
        guard let node = menuNode(sender) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    @objc private func copyPathAction(_ sender: Any?) {
        guard let node = menuNode(sender) else { return }
        copyToPasteboard(node.url.path)
    }

    @objc private func copyRelativePathAction(_ sender: Any?) {
        guard let node = menuNode(sender), let root else { return }
        let rootPath = root.url.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let path = node.url.standardizedFileURL.resolvingSymlinksInPath().path
        copyToPasteboard(path.hasPrefix(prefix)
                         ? String(path.dropFirst(prefix.count)) : path)
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// A file opens a terminal in its folder — nobody wants to cd afterwards.
    @objc private func openInTerminalAction(_ sender: Any?) {
        guard let node = menuNode(sender) else { return }
        let directory = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
        onOpenInTerminal?(directory)
    }

    /// `name copy.swift`, then `name copy 2.swift`, so repeating it never fails.
    @objc private func duplicateAction(_ sender: Any?) {
        guard let node = menuNode(sender), node !== root else { return }
        let base = (node.name as NSString).deletingPathExtension
        let ext = (node.name as NSString).pathExtension
        let parent = node.url.deletingLastPathComponent()
        var candidate = "\(base) copy"
        var counter = 2
        while FileManager.default.fileExists(
            atPath: parent.appendingPathComponent(ext.isEmpty ? candidate
                                                  : candidate + "." + ext).path) {
            candidate = "\(base) copy \(counter)"
            counter += 1
        }
        let destination = parent.appendingPathComponent(
            ext.isEmpty ? candidate : candidate + "." + ext)
        do {
            try FileManager.default.copyItem(at: node.url, to: destination)
            reloadAfterMutation(parent: node.parent, selecting: destination)
        } catch {
            presentFileError(title: "Duplicate failed", error: error)
        }
    }

    @objc private func gitHistoryAction(_ sender: Any?) {
        guard let node = menuNode(sender), !node.isDirectory else { return }
        onGitHistory?(node.url)
    }

    @objc private func deleteAction(_ sender: Any?) {
        guard let node = menuNode(sender), node !== root else { return }
        guard canMutate(node.url, verb: "delete") else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(node.name)”?"
        let kind = node.isDirectory ? "folder and everything inside it" : "file"
        alert.informativeText = "\(node.url.path)\n\nThe \(kind) will be moved to Trash and removed from the project. Open tabs at this path will close. Recovery is possible only while the item remains in Trash."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
            onPathDeleted?(node.url)
            reloadAfterMutation(parent: node.parent, selecting: nil)
        } catch {
            presentFileError(title: "Delete failed", error: error)
        }
    }

    private func canMutate(_ url: URL, verb: String) -> Bool {
        guard canMutatePath?(url) != false else {
            let alert = NSAlert()
            alert.messageText = "Cannot \(verb) \(url.lastPathComponent)"
            alert.informativeText = "Save or close modified files at this location first."
            alert.runModal()
            return false
        }
        return true
    }

    private func beginCreate(kind: PendingTreeEdit.Kind, parent: FileNode,
                             after anchor: FileNode?) {
        cancelPendingEdit()
        // Load and expose the parent before adding the synthetic child. Using
        // insertItems makes the edit row appear deterministically instead of
        // relying on reloadItem to notice a changed child count.
        outlineView.expandItem(parent)
        var insertionIndex = 0
        if let anchor, anchor.parent === parent,
           let index = parent.children.firstIndex(where: { $0 === anchor }) {
            insertionIndex = index + 1
        }
        pendingEdit = PendingTreeEdit(kind: kind, parent: parent,
                                      original: nil, initialName: "",
                                      insertionIndex: insertionIndex)
        outlineView.insertItems(at: IndexSet(integer: insertionIndex),
                                inParent: parent, withAnimation: [])
        focusPendingEditor()
    }

    private func focusPendingEditor() {
        guard let pendingEdit else { return }
        // A context-menu action can run while AppKit is still unwinding menu
        // tracking. Retry after menu tracking has fully restored the key view.
        focusPendingEditor(pendingEdit, after: 0.05)
        focusPendingEditor(pendingEdit, after: 0.25)
    }

    private func focusPendingEditor(_ pendingEdit: PendingTreeEdit,
                                    after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak pendingEdit] in
            guard let self, let pendingEdit, self.pendingEdit === pendingEdit,
                  !pendingEdit.didFocus else { return }
            self.outlineView.layoutSubtreeIfNeeded()
            let item: Any = pendingEdit.original ?? pendingEdit.placeholder
            let row = self.outlineView.row(forItem: item)
            guard row >= 0 else { return }
            self.outlineView.scrollRowToVisible(row)
            self.outlineView.layoutSubtreeIfNeeded()
            guard let cell = self.outlineView.view(atColumn: 0, row: row,
                                                   makeIfNecessary: true)
                    as? InlineTreeNameCell else { return }
            if cell.focus(selectAll: pendingEdit.kind == .rename) {
                pendingEdit.didFocus = true
            }
        }
    }

    private func cancelPendingEdit() {
        guard let edit = pendingEdit else { return }
        pendingEdit = nil
        if let original = edit.original {
            outlineView.reloadItem(original)
        } else if let parent = edit.parent {
            outlineView.removeItems(at: IndexSet(integer: edit.insertionIndex),
                                    inParent: parent, withAnimation: [])
        }
        applyDeferredTreeReloadIfNeeded()
    }

    @discardableResult
    private func completePendingEdit(_ rawName: String) -> Bool {
        guard let edit = pendingEdit, let parent = edit.parent else { return false }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validFileName(name) else {
            presentFileError(title: "Invalid name",
                             message: "Enter a name that does not contain ‘/’.")
            focusPendingEditor()
            return false
        }

        let destination = parent.url.appendingPathComponent(name,
                                                             isDirectory: edit.kind == .folder)
        // On a case-insensitive volume `fileExists` matches the item being
        // renamed, so compare file identity rather than paths: otherwise
        // Readme.md -> README.md reports a clash with itself.
        if FileManager.default.fileExists(atPath: destination.path),
           !Self.isSameFile(destination, edit.original?.url) {
            presentFileError(title: "Name already exists",
                             message: "An item named \(name) already exists here.")
            focusPendingEditor()
            return false
        }

        do {
            switch edit.kind {
            case .file:
                guard FileManager.default.createFile(atPath: destination.path,
                                                     contents: Data()) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            case .folder:
                try FileManager.default.createDirectory(at: destination,
                                                        withIntermediateDirectories: false)
            case .rename:
                guard let original = edit.original else { return false }
                if original.url.standardizedFileURL != destination.standardizedFileURL {
                    try Self.move(original.url, to: destination)
                    onPathRenamed?(original.url, destination)
                }
            }
            pendingEdit = nil
            reloadAfterMutation(parent: parent, selecting: destination)
            applyDeferredTreeReloadIfNeeded()
            if edit.kind == .file { onOpenFile?(destination) }
            return true
        } catch {
            presentFileError(title: "File operation failed", error: error)
            focusPendingEditor()
            return false
        }
    }

    /// Same item on disk, whatever the path spelling — the only reliable test
    /// on a case-insensitive volume.
    private static func isSameFile(_ lhs: URL, _ rhs: URL?) -> Bool {
        guard let rhs else { return false }
        if lhs.standardizedFileURL == rhs.standardizedFileURL { return true }
        guard let left = try? lhs.resourceValues(forKeys: [.fileResourceIdentifierKey])
                .fileResourceIdentifier,
              let right = try? rhs.resourceValues(forKeys: [.fileResourceIdentifierKey])
                .fileResourceIdentifier else { return false }
        return left.isEqual(right)
    }

    /// `moveItem` refuses a rename that only changes case on a case-insensitive
    /// volume, because the destination "already exists" — it is the same file.
    /// Go through a temporary name in that case.
    private static func move(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: destination.path), isSameFile(destination, source) else {
            try fm.moveItem(at: source, to: destination)
            return
        }
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".puzzle-rename-\(UUID().uuidString)")
        try fm.moveItem(at: source, to: staging)
        do {
            try fm.moveItem(at: staging, to: destination)
        } catch {
            // Put it back rather than leaving the file under a hidden name.
            try? fm.moveItem(at: staging, to: source)
            throw error
        }
    }

    /// Rename through the same path the inline editor uses.
    @discardableResult
    func renameForTesting(_ url: URL, to name: String) -> Bool {
        _ = view
        guard let node = self.node(for: url) else { return false }
        cancelPendingEdit()
        pendingEdit = PendingTreeEdit(kind: .rename, parent: node.parent,
                                      original: node, initialName: node.name)
        return completePendingEdit(name)
    }

    private static func validFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
            && !name.contains("\0")
    }

    private func reloadAfterMutation(parent: FileNode?, selecting url: URL?) {
        parent?.invalidate()
        if let parent {
            outlineView.reloadItem(parent, reloadChildren: true)
            outlineView.expandItem(parent)
        } else {
            refresh()
        }
        if let url, let row = row(for: url) {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
        }
        onFileSystemChanged?()
    }

    private func applyDeferredTreeReloadIfNeeded() {
        guard deferredTreeReload else { return }
        let refreshDisk = deferredDiskRefresh
        deferredTreeReload = false
        deferredDiskRefresh = false
        if refreshDisk { root?.invalidate() }
        outlineView.backgroundColor = Theme.panelBackground
        outlineView.reloadData()
        if let root { outlineView.expandItem(root) }
    }

    private func presentFileError(title: String, error: Error) {
        presentFileError(title: title, message: error.localizedDescription)
    }

    private func presentFileError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

extension FileTreeViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return root == nil ? 0 : 1 }
        guard let node = item as? FileNode, node.isDirectory else { return 0 }
        let extra = pendingEdit?.original == nil && pendingEdit?.parent === node ? 1 : 0
        return node.children.count + extra
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return root ?? staleChild }
        guard let node = item as? FileNode else { return staleChild }
        var wanted = index
        if let pending = pendingEdit, pending.original == nil, pending.parent === node {
            let insertion = min(pending.insertionIndex, node.children.count)
            if index == insertion { return pending.placeholder }
            wanted = index < insertion ? index : index - 1
        }
        // A data source must never trap. AppKit can ask for a child the model
        // has already dropped — a file-system refresh landing mid-reload — and
        // dying on the subscript is the worst possible answer. Hand back a
        // placeholder and put the tree back in step on the next turn.
        guard node.children.indices.contains(wanted) else {
            scheduleTreeResync()
            return staleChild
        }
        return node.children[wanted]
    }

    /// Rebuild once the current AppKit traversal is over.
    private func scheduleTreeResync() {
        guard !treeResyncScheduled else { return }
        treeResyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.treeResyncScheduled = false
            guard self.isViewLoaded, self.pendingEdit == nil else { return }
            self.outlineView.reloadData()
            self.refreshActiveRowBackgrounds()
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory ?? false
    }
}

extension FileTreeViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let pending = pendingEdit,
           item as AnyObject === pending.placeholder
            || pending.original.map({ item as AnyObject === $0 }) == true {
            let id = NSUserInterfaceItemIdentifier("inline-name")
            let cell = (outlineView.makeView(withIdentifier: id, owner: self)
                        as? InlineTreeNameCell) ?? InlineTreeNameCell()
            cell.identifier = id
            let icon: SidebarIcon
            switch pending.kind {
            case .file:
                icon = .newItem(folder: false)
            case .folder:
                icon = .newItem(folder: true)
            case .rename:
                // A rename keeps the row's own icon, so the file being renamed
                // stays recognisable while its name is being typed over.
                if let original = pending.original {
                    let expanded = outlineView.isItemExpanded(original)
                    icon = original.isDirectory
                        ? .folder(original.url, expanded: expanded)
                        : .file(original.url)
                } else {
                    icon = .newItem(folder: false)
                }
            }
            let isDirectory = pending.kind == .folder || pending.original?.isDirectory == true
            let expanded = pending.original.map { outlineView.isItemExpanded($0) } ?? false
            let disclosure = isDirectory
                ? Theme.symbol(expanded ? "chevron.down" : "chevron.right", pointSize: 9)
                : nil
            cell.configure(value: pending.initialName,
                           disclosure: disclosure,
                           icon: icon,
                           onSubmit: { [weak self] in
                               self?.completePendingEdit($0) ?? false
                           },
                           onCancel: { [weak self] in self?.cancelPendingEdit() })
            return cell
        }
        guard let node = item as? FileNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell: FileTreeCell
        if let reused = outlineView.makeView(withIdentifier: id, owner: self) as? FileTreeCell {
            cell = reused
        } else {
            cell = FileTreeCell()
            cell.identifier = id
        }

        // Directories show open/closed state through the icon as well as the
        // disclosure triangle.
        let icon: SidebarIcon = node.isDirectory
            ? .folder(node.url, expanded: outlineView.isItemExpanded(node))
            : .file(node.url)

        let expanded = node.isDirectory && outlineView.isItemExpanded(node)
        let disclosure = node.isDirectory
            ? Theme.symbol(expanded ? "chevron.down" : "chevron.right", pointSize: 9)
            : nil
        let titleColor = statusColor(for: node) ?? Theme.foreground
        cell.configure(title: node.name, disclosure: disclosure,
                       icon: icon,
                       titleColor: titleColor)
        return cell
    }

    /// Driven by the exact `tree_line_height` point value in settings.json.
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        return Theme.treeRowHeight()
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
        // AppKit posts expand/collapse from *inside* `reloadItem(_:reloadChildren:)`.
        // Reloading again here re-enters that call while its row bookkeeping is
        // half built, and the data source is then asked for children the model
        // no longer has — an index-out-of-range crash, reproduced from a file
        // system event arriving while a folder was being re-expanded. Freeing
        // the collapsed subtree has the same problem: it mutates the model
        // AppKit is walking. Both wait until AppKit has finished.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isViewLoaded else { return }
            if let node = item as? FileNode, !self.outlineView.isItemExpanded(node) {
                node.releaseChildren()
            }
            self.reloadCountForTesting += 1
            self.outlineView.reloadItem(item)
            self.refreshActiveRowBackgrounds()
        }
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("tree-row")
        let row = (outlineView.makeView(withIdentifier: id, owner: self) as? TreeRowView)
            ?? TreeRowView()
        row.identifier = id
        row.isActiveFile = (item as? FileNode)?.url.standardizedFileURL == activeURL
        row.isHovered = self.outlineView.hoveredRow == outlineView.row(forItem: item)
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
    private var disclosure: NSImage?
    private var icon: SidebarIcon?
    private var titleColor = NSColor.clear
    var titleColorForTesting: NSColor { titleColor }
    var iconForTesting: SidebarIcon? { icon }

    func configure(title: String, disclosure: NSImage?,
                   icon: SidebarIcon?,
                   titleColor: NSColor) {
        self.title = title
        self.disclosure = disclosure
        self.icon = icon
        self.titleColor = titleColor
        toolTip = title
        exposeToAccessibility(title)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let font = Theme.uiFont(12)
        let baseline = SidebarCellDrawing.centeredBaseline(for: font, in: bounds)
        SidebarCellDrawing.image(disclosure, tint: Theme.dimText,
                                 in: FileTreeRowLayout.centeredRect(
                                    x: FileTreeRowLayout.disclosureX,
                                    size: FileTreeRowLayout.disclosureSize,
                                    in: bounds))
        SidebarCellDrawing.icon(icon,
                                in: FileTreeRowLayout.centeredRect(
                                    x: FileTreeRowLayout.iconX,
                                    size: FileTreeRowLayout.iconSize,
                                    in: bounds))
        SidebarCellDrawing.text(title, font: font, color: titleColor,
                                baseline: baseline,
                                in: NSRect(x: FileTreeRowLayout.titleX, y: 0,
                                           width: max(0, bounds.width - FileTreeRowLayout.titleX - 5),
                                           height: bounds.height),
                                lineBreak: .byTruncatingMiddle)
    }
}

private final class InlineTreeTextView: NSTextView {
    var onResign: (() -> Void)?

    override func layout() {
        super.layout()
        guard let font else { return }
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        textContainerInset = NSSize(
            width: 0,
            height: max(0, floor((bounds.height - lineHeight) / 2)))
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onResign?() }
        return resigned
    }

    var verticalCenterError: CGFloat? {
        guard let font else { return nil }
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        return abs((textContainerInset.height + lineHeight / 2) - bounds.midY)
    }
}

private final class InlineTreeNameCell: NSTableCellView, NSTextViewDelegate {
    private let editor = InlineTreeTextView(frame: .zero)
    private var onSubmit: ((String) -> Bool)?
    private var onCancel: (() -> Void)?
    private var submitting = false
    private var cancelling = false
    private var editingSessionStarted = false
    private var disclosure: NSImage?
    private var icon: SidebarIcon?

    override var isOpaque: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        editor.isEditable = true
        editor.isSelectable = true
        editor.drawsBackground = false
        editor.isRichText = false
        editor.isVerticallyResizable = false
        editor.isHorizontallyResizable = false
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.lineFragmentPadding = 0
        editor.font = Theme.uiFont(12)
        editor.textColor = .black
        editor.insertionPointColor = .black
        editor.delegate = self
        editor.onResign = { [weak self] in self?.editorDidResign() }
        editor.setAccessibilityLabel("File name")
        editor.translatesAutoresizingMaskIntoConstraints = false
        addSubview(editor)
        NSLayoutConstraint.activate([
            editor.leadingAnchor.constraint(equalTo: leadingAnchor,
                                             constant: FileTreeRowLayout.titleX),
            editor.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            editor.topAnchor.constraint(equalTo: topAnchor),
            editor.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(value: String,
                   disclosure: NSImage?,
                   icon: SidebarIcon?,
                   onSubmit: @escaping (String) -> Bool,
                   onCancel: @escaping () -> Void) {
        editingSessionStarted = false
        editor.string = value
        editor.font = Theme.uiFont(12)
        editor.textColor = .black
        editor.insertionPointColor = .black
        self.disclosure = disclosure
        self.icon = icon
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        submitting = false
        cancelling = false
        editor.needsLayout = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        SidebarCellDrawing.image(disclosure, tint: Theme.dimText,
                                 in: FileTreeRowLayout.centeredRect(
                                    x: FileTreeRowLayout.disclosureX,
                                    size: FileTreeRowLayout.disclosureSize,
                                    in: bounds))
        SidebarCellDrawing.icon(icon,
                                in: FileTreeRowLayout.centeredRect(
                                    x: FileTreeRowLayout.iconX,
                                    size: FileTreeRowLayout.iconSize,
                                    in: bounds))
    }

    @discardableResult
    func focus(selectAll: Bool) -> Bool {
        guard let window, window.makeFirstResponder(editor) else { return false }
        editingSessionStarted = window.firstResponder === editor
        let length = (editor.string as NSString).length
        editor.setSelectedRange(selectAll
            ? NSRange(location: 0, length: length)
            : NSRange(location: length, length: 0))
        return editingSessionStarted
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            submitting = true
            if onSubmit?(editor.string) != true { submitting = false }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancelling = true
            onCancel?()
            return true
        default:
            return false
        }
    }

    private func editorDidResign() {
        if editingSessionStarted && !submitting && !cancelling { onCancel?() }
        editingSessionStarted = false
    }

    var verticalCenterErrorForTesting: CGFloat? {
        editor.layoutSubtreeIfNeeded()
        return editor.verticalCenterError
    }
    var hasIconForTesting: Bool { icon != nil }
    var backgroundColorForTesting: NSColor { .white }
}

/// Tree row with a persistent background for the file open in the active pane.
final class TreeRowView: NSTableRowView {
    var isActiveFile = false
    var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        Theme.panelBackground.setFill()
        bounds.fill()
        if isActiveFile {
            Theme.activeRow.setFill()
            bounds.fill()
        } else if isHovered {
            Theme.hover.setFill()
            bounds.fill()
        }
    }

    // Selection is conveyed by active-file/hover state; keep rows flat.
    override func drawSelection(in dirtyRect: NSRect) {}

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

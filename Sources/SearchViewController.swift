import AppKit

/// Project-wide content search, grouped by file like Zed: each file is a header
/// row (name + folder) with its matching lines beneath. Clicking a file opens it;
/// clicking a line opens it at that line.
final class SearchViewController: NSViewController {
    var onOpenResult: ((URL, Int) -> Void)?
    var onOpenFile: ((URL) -> Void)?

    private var directory: URL?
    private let searchField = SearchInputView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let outline = NSOutlineView()
    private var searchWork: DispatchWorkItem?

    struct Hit {
        let line: Int
        let preview: String
        let matchRange: NSRange?   // range of the needle inside `preview`
    }
    final class FileGroup {
        let url: URL
        let relative: String
        var hits: [Hit]
        init(url: URL, relative: String, hits: [Hit]) {
            self.url = url; self.relative = relative; self.hits = hits
        }
        var folder: String {
            let dir = (relative as NSString).deletingLastPathComponent
            return dir.isEmpty ? "" : dir
        }
        var name: String { (relative as NSString).lastPathComponent }
    }
    private var groups: [FileGroup] = []

    func setDirectory(_ url: URL) { directory = url }

    override func loadView() {
        let container = FlatView()
        container.fillColor = Theme.panelBackground

        searchField.placeholder = "Search project…"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.onChange = { [weak self] _, _ in self?.searchChanged() }
        searchField.onSubmit = { [weak self] _, _ in self?.searchChanged() }

        summaryLabel.font = Theme.uiFont(10.5)
        summaryLabel.textColor = Theme.dimText
        summaryLabel.alignment = .center
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("hit"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowSizeStyle = .custom
        outline.backgroundColor = Theme.panelBackground
        outline.indentationPerLevel = 12
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
        outline.usesAlternatingRowBackgroundColors = false

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.panelBackground
        scroll.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(searchField)
        container.addSubview(summaryLabel)
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            summaryLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            summaryLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            summaryLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        self.view = container
    }

    func focusSearchField() { searchField.focus() }

    func refreshFonts() { searchField.refreshFonts() }

    func releaseTransientMemory() {
        searchWork?.cancel()
        searchWork = nil
        groups.removeAll()
        hitRowCache.removeAll()
        if isViewLoaded { outline.reloadData() }
    }

    /// Run a query programmatically (used by the `--search` launch flag).
    func performSearch(_ query: String) {
        searchField.stringValue = query
        searchChanged()
    }

    @objc private func searchChanged() {
        let query = searchField.stringValue
        let options = searchField.options
        searchWork?.cancel()
        guard query.count >= 2, let directory else {
            groups = []; hitRowCache.removeAll(); outline.reloadData()
            summaryLabel.stringValue = query.isEmpty ? "" : "Type at least 2 characters"
            return
        }
        // Release the previous result tree before the replacement is built, so
        // two large searches never coexist during the debounce/backend work.
        groups.removeAll()
        hitRowCache.removeAll()
        outline.reloadData()
        summaryLabel.stringValue = "Searching…"
        let work = DispatchWorkItem { [weak self] in
            let found = Self.search(query: query, in: directory, options: options)
            DispatchQueue.main.async {
                guard let self, !(self.searchWork?.isCancelled ?? true) else { return }
                self.hitRowCache.removeAll()   // stale rows from the previous query
                self.groups = found
                self.outline.reloadData()
                for g in found { self.outline.expandItem(g) }
                let matches = found.reduce(0) { $0 + $1.hits.count }
                self.summaryLabel.stringValue = matches == 0
                    ? "No results"
                    : "\(matches) result\(matches == 1 ? "" : "s") in \(found.count) file\(found.count == 1 ? "" : "s")"
            }
        }
        searchWork = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    @objc private func rowClicked() {
        let row = outline.clickedRow
        guard row >= 0, let item = outline.item(atRow: row) else { return }
        if let group = item as? FileGroup {
            onOpenFile?(group.url)
        } else if let hit = item as? HitRow {
            onOpenResult?(hit.group.url, hit.hit.line)
        }
    }

    /// Boxed hit so the outline can map a row back to its file.
    final class HitRow {
        let group: FileGroup, hit: Hit
        init(group: FileGroup, hit: Hit) { self.group = group; self.hit = hit }
    }
    private var hitRowCache: [ObjectIdentifier: [HitRow]] = [:]
    private func rows(for group: FileGroup) -> [HitRow] {
        let key = ObjectIdentifier(group)
        if let cached = hitRowCache[key] { return cached }
        let made = group.hits.map { HitRow(group: group, hit: $0) }
        hitRowCache[key] = made
        return made
    }

    // MARK: - Search backends

    private static let ripgrepPath: String? = {
        ["/opt/homebrew/bin/rg", "/usr/local/bin/rg", "/usr/bin/rg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    static func search(query: String, in directory: URL,
                       options: SearchOptions = SearchOptions()) -> [FileGroup] {
        let raw = ripgrepPath.map { ripgrep(rg: $0, query: query, in: directory, options: options) }
            ?? nativeSearch(query: query, in: directory)
        // Preserve file order, group hits.
        var order: [String] = []
        var byFile: [String: FileGroup] = [:]
        let highlightOptions: NSString.CompareOptions =
            options.caseSensitive ? [] : [.caseInsensitive]
        for (rel, line, text) in raw {
            let url = directory.appendingPathComponent(rel)
            let range = (text as NSString).range(of: query, options: highlightOptions)
            let hit = Hit(line: line, preview: text,
                          matchRange: range.location == NSNotFound ? nil : range)
            if let g = byFile[rel] {
                g.hits.append(hit)
            } else {
                order.append(rel)
                byFile[rel] = FileGroup(url: url, relative: rel, hits: [hit])
            }
        }
        return order.compactMap { byFile[$0] }
    }

    private static func ripgrep(rg: String, query: String, in directory: URL,
                                options: SearchOptions) -> [(String, Int, String)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: rg)
        var args = ["--line-number", "--no-heading", "--color", "never", "--max-count", "80"]
        if !options.regex { args.append("--fixed-strings") }   // regex is rg's default
        args.append(options.caseSensitive ? "--case-sensitive" : "--ignore-case")
        if options.wholeWord { args.append("--word-regexp") }
        args += ["--", query, "."]
        process.arguments = args
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nativeSearch(query: query, in: directory) }

        // Read incrementally and stop once we have enough. `readDataToEndOfFile`
        // buffered ripgrep's ENTIRE output first — a common word in a big repo
        // could be tens of MB of matches we then threw away.
        var out: [(String, Int, String)] = []
        var buffer = Data()
        let handle = pipe.fileHandleForReading
        var done = false
        while !done {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            // Consume whole lines; keep the trailing partial line in `buffer`.
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                let line = String(decoding: lineData, as: UTF8.self)
                let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3, let no = Int(parts[1]) else { continue }
                var rel = String(parts[0])
                if rel.hasPrefix("./") { rel.removeFirst(2) }
                let text = String(parts[2]).trimmingCharacters(in: .whitespaces)
                out.append((rel, no, String(text.prefix(maxPreviewChars))))
                if out.count >= maxHits { done = true; break }
            }
        }
        if done { process.terminate() }        // stop ripgrep early
        process.waitUntilExit()
        return out
    }

    /// Result caps — the panel can't usefully show more than this, and holding
    /// every hit of a common word was the single largest memory spike measured.
    private static let maxHits = 500
    private static let maxPreviewChars = 160

    private static let skipDirs: Set<String> = [".git", "node_modules", ".build", "build",
                                                "DerivedData", ".svn", "Pods", ".obj"]

    private static func nativeSearch(query: String, in directory: URL) -> [(String, Int, String)] {
        var out: [(String, Int, String)] = []
        let fm = FileManager.default
        guard let e = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey],
                                    options: [.skipsHiddenFiles]) else { return [] }
        let needle = query.lowercased()
        for case let url as URL in e {
            if skipDirs.contains(url.lastPathComponent) { e.skipDescendants(); continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let data = try? Data(contentsOf: url), data.count < 2_000_000,
                  !data.prefix(1024).contains(0) else { continue }
            let rel = url.path.replacingOccurrences(of: directory.path + "/", with: "")
            var no = 0
            for raw in String(decoding: data, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: false) {
                no += 1
                if raw.lowercased().contains(needle) {
                    out.append((rel, no, String(raw.trimmingCharacters(in: .whitespaces).prefix(300))))
                    if out.count >= maxHits { return out }
                }
            }
        }
        return out
    }
}

extension SearchViewController: NSOutlineViewDataSource {
    func outlineView(_ ov: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return groups.count }
        if let g = item as? FileGroup { return g.hits.count }
        return 0
    }
    func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return groups[index] }
        return rows(for: item as! FileGroup)[index]
    }
    func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileGroup) != nil
    }
}

extension SearchViewController: NSOutlineViewDelegate {
    func outlineView(_ ov: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        // Scale with the UI font so larger `ui_font_size` isn't clipped.
        let base = ceil(Theme.uiFont(11.5).boundingRectForFont.height)
        return item is FileGroup ? max(24, base + 9) : max(20, base + 5)
    }

    /// Flat selection matching the file tree's active row — the system blue
    /// made the result text unreadable.
    func outlineView(_ ov: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("search-row")
        let row = (ov.makeView(withIdentifier: id, owner: self) as? SearchRowView)
            ?? SearchRowView()
        row.identifier = id
        return row
    }

    func outlineView(_ ov: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? FileGroup {
            let id = NSUserInterfaceItemIdentifier("search-group-cell")
            let cell = (ov.makeView(withIdentifier: id, owner: self)
                        as? SearchGroupCell) ?? SearchGroupCell()
            cell.identifier = id
            cell.configure(group: group)
            return cell
        }

        guard let row = item as? HitRow else { return nil }
        let id = NSUserInterfaceItemIdentifier("search-hit-cell")
        let cell = (ov.makeView(withIdentifier: id, owner: self)
                    as? SearchHitCell) ?? SearchHitCell()
        cell.identifier = id
        cell.configure(hit: row.hit)
        return cell
    }
}

private final class SearchGroupCell: DrawnSidebarCell {
    private var icon: NSImage?
    private var name = ""
    private var folder = ""

    func configure(group: SearchViewController.FileGroup) {
        icon = Theme.symbol(FileTreeViewController.iconName(for: group.url.pathExtension))
        name = group.name
        folder = group.folder
        toolTip = group.relative
        exposeToAccessibility(group.relative)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        SidebarCellDrawing.image(icon, tint: Theme.dimText,
                                 in: NSRect(x: 2, y: floor((bounds.height - 13) / 2),
                                            width: 13, height: 13))
        SidebarCellDrawing.primaryAndSecondary(
            primary: name, primaryFont: Theme.uiFont(11.5), primaryColor: Theme.foreground,
            secondary: folder, secondaryFont: Theme.uiFont(10), secondaryColor: Theme.dimText,
            in: NSRect(x: 20, y: 0, width: max(0, bounds.width - 24), height: bounds.height))
    }
}

private final class SearchHitCell: DrawnSidebarCell {
    private var content = NSAttributedString()
    private let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        // A single line fragment draws the gutter and preview on exactly the
        // same baseline. The first tab right-aligns the line number; the second
        // establishes the fixed code column.
        style.tabStops = [
            NSTextTab(textAlignment: .right, location: 32, options: [:]),
            NSTextTab(textAlignment: .left, location: 38, options: [:]),
        ]
        return style.copy() as! NSParagraphStyle
    }()
    func configure(hit: SearchViewController.Hit) {
        let number = String(hit.line)
        let prefix = "\t\(number)\t"
        let attributed = NSMutableAttributedString(
            string: prefix + hit.preview,
            attributes: [.font: Theme.uiFont(11),
                         .foregroundColor: Theme.foreground,
                         .paragraphStyle: paragraph])
        attributed.addAttribute(
            .foregroundColor,
            value: Theme.dimText,
            range: NSRange(location: 1, length: (number as NSString).length))
        if let match = hit.matchRange,
           NSMaxRange(match) <= (hit.preview as NSString).length {
            let previewOffset = (prefix as NSString).length
            attributed.addAttribute(
                .backgroundColor,
                value: Theme.searchMatch,
                range: NSRange(location: previewOffset + match.location, length: match.length))
        }
        content = attributed
        exposeToAccessibility("Line \(number): \(hit.preview)")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Gutter number and source text are intentionally one attributed line:
        // tab stops and a shared baseline make vertical drift impossible.
        SidebarCellDrawing.attributedText(
            content,
            in: NSRect(x: 0, y: 0, width: max(0, bounds.width - 4), height: bounds.height))
    }
}

/// Search-result row: flat background, selection uses the same subtle tint as
/// the active file in the tree instead of the system blue highlight.
final class SearchRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {
        Theme.panelBackground.setFill()
        bounds.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        Theme.activeRow.setFill()
        bounds.fill()
    }

    override var isEmphasized: Bool {
        get { false }   // don't switch to the emphasized (blue) system look
        set { }
    }
}

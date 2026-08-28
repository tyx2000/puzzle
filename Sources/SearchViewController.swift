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
    /// Fills the empty result area: what this panel searches, and what the
    /// three cryptic toggles above it mean.
    private let placeholderLabel = NSTextField(labelWithString: "")
    private let outline = NSOutlineView()
    private var searchWork: DispatchWorkItem?
    /// Cancellation alone is not an identity check: an old task can finish
    /// after `searchWork` already points at a newer, non-cancelled task.
    private var searchGeneration = 0

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
    /// Stands in for a row that has gone away between AppKit asking how many
    /// there are and which one. Never part of the results, so AppKit cannot
    /// walk into it.
    private let staleRow = NSObject()

    func setDirectory(_ url: URL) {
        guard directory != url else { return }
        directory = url
        searchGeneration += 1
        searchWork?.cancel()
        searchWork = nil
        groups.removeAll()
        hitRowCache.removeAll()
        if isViewLoaded {
            outline.reloadData()
            summaryLabel.stringValue = ""
            updatePlaceholder(query: "", matches: nil)
        }
    }

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
        PuzzleScroller.adopt(scroll)
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.panelBackground
        scroll.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(searchField)
        placeholderLabel.font = Theme.uiFont(11)
        placeholderLabel.textColor = Theme.dimText
        placeholderLabel.alignment = .center
        placeholderLabel.maximumNumberOfLines = 0
        placeholderLabel.lineBreakMode = .byWordWrapping
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(summaryLabel)
        container.addSubview(placeholderLabel)
        defer { updatePlaceholder(query: "", matches: nil) }
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            summaryLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            summaryLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            summaryLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            placeholderLabel.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 40),
            placeholderLabel.leadingAnchor.constraint(
                equalTo: container.leadingAnchor, constant: 24),
            placeholderLabel.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -24),

            scroll.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        self.view = container
    }

    func focusSearchField() { searchField.focus() }

    /// The results area explains itself when it has nothing to show: what the
    /// panel does before a query, and what came back after one.
    private func updatePlaceholder(query: String, matches: Int?) {
        guard groups.isEmpty else {
            placeholderLabel.isHidden = true
            return
        }
        if query.isEmpty {
            placeholderLabel.stringValue = "Search every file in this project.\n\n"
                + "Aa  match case      wd  whole word      .*  regular expression"
        } else if let matches, matches == 0 {
            placeholderLabel.stringValue = "No matches for “\(query)”."
        } else if query.count < 2 {
            placeholderLabel.stringValue = "Keep typing — searching starts at two characters."
        } else {
            placeholderLabel.stringValue = ""
        }
        placeholderLabel.isHidden = placeholderLabel.stringValue.isEmpty
    }

    var placeholderTextForTesting: String {
        placeholderLabel.isHidden ? "" : placeholderLabel.stringValue
    }

    func refreshFonts() {
        (view as? FlatView)?.fillColor = Theme.panelBackground
        outline.backgroundColor = Theme.panelBackground
        outline.enclosingScrollView?.backgroundColor = Theme.panelBackground
        searchField.refreshFonts()
        summaryLabel.font = Theme.uiFont(10.5)
        outline.reloadData()
        if outline.numberOfRows > 0 {
            outline.noteHeightOfRows(withIndexesChanged:
                IndexSet(integersIn: 0..<outline.numberOfRows))
        }
    }

    func releaseTransientMemory() {
        searchGeneration += 1
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
        searchGeneration += 1
        let generation = searchGeneration
        searchWork?.cancel()
        searchWork = nil
        guard query.count >= 2, let directory else {
            groups = []; hitRowCache.removeAll(); outline.reloadData()
            summaryLabel.stringValue = query.isEmpty ? "" : "Type at least 2 characters"
            updatePlaceholder(query: query, matches: nil)
            return
        }
        // Release the previous result tree before the replacement is built, so
        // two large searches never coexist during the debounce/backend work.
        groups.removeAll()
        hitRowCache.removeAll()
        outline.reloadData()
        summaryLabel.stringValue = "Searching…"
        updatePlaceholder(query: query, matches: nil)
        // Disk search cannot see edits that have not been saved yet. Snapshot
        // modified buffers on the main thread, then let the worker use those
        // immutable strings instead of stale disk content.
        let bufferSnapshots = Dictionary(uniqueKeysWithValues:
            DocumentStore.shared.modifiedTextSnapshots(in: directory).map { ($0.url, $0.text) })
        let work = DispatchWorkItem { [weak self] in
            let found = Self.search(
                query: query, in: directory, options: options,
                inMemoryFiles: bufferSnapshots)
            DispatchQueue.main.async {
                guard let self, self.searchGeneration == generation else { return }
                self.searchWork = nil
                self.hitRowCache.removeAll()   // stale rows from the previous query
                self.groups = found
                self.outline.reloadData()
                for g in found { self.outline.expandItem(g) }
                let matches = found.reduce(0) { $0 + $1.hits.count }
                self.summaryLabel.stringValue = matches == 0
                    ? "No results"
                    : "\(matches) result\(matches == 1 ? "" : "s") in \(found.count) file\(found.count == 1 ? "" : "s")"
                self.updatePlaceholder(query: query, matches: matches)
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
                       options: SearchOptions = SearchOptions(),
                       inMemoryFiles: [URL: String] = [:]) -> [FileGroup] {
        guard let matcher = SearchMatcher(query: query, options: options) else { return [] }
        let diskHits = ripgrepPath.map { ripgrep(rg: $0, query: query, in: directory, options: options) }
            ?? nativeSearch(query: query, in: directory, options: options)
        let snapshots: [(relative: String, text: String)] = inMemoryFiles.compactMap { url, text in
            relativePath(for: url, in: directory).map { ($0, text) }
        }.sorted { $0.relative < $1.relative }
        let overridden = Set(snapshots.map(\.relative))
        var raw: [(String, Int, String)] = []
        raw.reserveCapacity(min(maxHits, diskHits.count + snapshots.count))
        // Modified files take priority so a saturated disk result set cannot
        // hide a current in-memory match. Their old disk hits are removed even
        // when the edit deleted every occurrence.
        for snapshot in snapshots {
            appendMatches(
                in: snapshot.text, relative: snapshot.relative,
                matcher: matcher, query: query, options: options, to: &raw)
            if raw.count >= maxHits { break }
        }
        if raw.count < maxHits {
            raw.append(contentsOf: diskHits.lazy
                .filter { !overridden.contains($0.0) }
                .prefix(maxHits - raw.count))
        }
        // Preserve file order, group hits.
        var order: [String] = []
        var byFile: [String: FileGroup] = [:]
        for (rel, line, text) in raw {
            let url = directory.appendingPathComponent(rel)
            let range = matcher.firstRange(in: text)
            let hit = Hit(line: line, preview: text,
                          matchRange: range)
            if let g = byFile[rel] {
                g.hits.append(hit)
            } else {
                order.append(rel)
                byFile[rel] = FileGroup(url: url, relative: rel, hits: [hit])
            }
        }
        return order.compactMap { byFile[$0] }
    }

    private static func relativePath(for url: URL, in directory: URL) -> String? {
        let root = directory.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    private static func appendMatches(
        in text: String, relative: String, matcher: SearchMatcher,
        query: String, options: SearchOptions,
        to output: inout [(String, Int, String)]
    ) {
        var line = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            line += 1
            let value = String(rawLine)
            guard matcher.firstRange(in: value) != nil else { continue }
            output.append((relative, line, searchPreview(value, query: query, options: options)))
            if output.count >= maxHits { return }
        }
    }

    private static func ripgrep(rg: String, query: String, in directory: URL,
                                options: SearchOptions) -> [(String, Int, String)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: rg)
        // JSON framing keeps paths containing colons or newlines unambiguous.
        // The previous `path:line:text` parser silently discarded valid hits.
        var args = ["--json", "--max-count", "80",
                    "--max-columns", "1000", "--max-columns-preview"]
        if !options.regex { args.append("--fixed-strings") }   // regex is rg's default
        args.append(options.caseSensitive ? "--case-sensitive" : "--ignore-case")
        if options.wholeWord { args.append("--word-regexp") }
        args += ["--", query, "."]
        process.arguments = args
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        // Search errors are represented by no results; leaving an unread stderr
        // pipe here can deadlock on a tree with many permission errors.
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            return nativeSearch(query: query, in: directory, options: options)
        }

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
                guard let object = try? JSONSerialization.jsonObject(with: Data(lineData))
                        as? [String: Any],
                      object["type"] as? String == "match",
                      let payload = object["data"] as? [String: Any],
                      var rel = jsonText(payload["path"]),
                      let textValue = jsonText(payload["lines"]),
                      let no = payload["line_number"] as? Int else { continue }
                if rel.hasPrefix("./") { rel.removeFirst(2) }
                let text = searchPreview(textValue, query: query, options: options)
                out.append((rel, no, text))
                if out.count >= maxHits { done = true; break }
            }
        }
        if done { process.terminate() }        // stop ripgrep early
        process.waitUntilExit()
        return out
    }

    private static func jsonText(_ value: Any?) -> String? {
        guard let object = value as? [String: Any] else { return nil }
        if let text = object["text"] as? String { return text }
        if let encoded = object["bytes"] as? String,
           let data = Data(base64Encoded: encoded) {
            return String(decoding: data, as: UTF8.self)
        }
        return nil
    }

    /// Keep a bounded preview while ensuring a late match remains visible.
    private static func searchPreview(_ line: String, query: String,
                                      options: SearchOptions) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed as NSString
        guard source.length > maxPreviewChars else { return trimmed }
        guard let match = SearchMatcher(query: query, options: options)?.firstRange(in: trimmed),
              match.location >= maxPreviewChars else {
            return source.substring(to: maxPreviewChars)
        }
        let requestedStart = max(0, match.location - maxPreviewChars / 3)
        let requestedLength = min(maxPreviewChars - 1, source.length - requestedStart)
        let safe = source.rangeOfComposedCharacterSequences(
            for: NSRange(location: requestedStart, length: requestedLength))
        return "…" + source.substring(with: safe)
    }

    /// Result caps — the panel can't usefully show more than this, and holding
    /// every hit of a common word was the single largest memory spike measured.
    private static let maxHits = 500
    private static let maxPreviewChars = 160
    static let maxNativeFileBytes = 2_000_000

    private static let skipDirs: Set<String> = [".git", "node_modules", ".build", "build",
                                                "DerivedData", ".svn", "Pods", ".obj"]

    /// Check metadata before allocating file contents. Kept separate so the
    /// large-file rejection is directly regression-testable.
    static func shouldLoadForNativeSearch(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let fileSize = values.fileSize else { return false }
        return fileSize < maxNativeFileBytes
    }

    private static func nativeSearch(query: String, in directory: URL,
                                     options: SearchOptions) -> [(String, Int, String)] {
        var out: [(String, Int, String)] = []
        let fm = FileManager.default
        guard let e = fm.enumerator(at: directory,
                                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                    options: [.skipsHiddenFiles]) else { return [] }
        guard let matcher = SearchMatcher(query: query, options: options) else { return [] }
        // One pool per file: the contents, the split lines and the URL's cached
        // resource values are all released before the next file is read. Without
        // it a whole-project search holds every file it has looked at.
        var finished = false
        while !finished {
            autoreleasepool {
                guard let url = e.nextObject() as? URL else {
                    finished = true
                    return
                }
                if skipDirs.contains(url.lastPathComponent) {
                    e.skipDescendants()
                    return
                }
                guard shouldLoadForNativeSearch(url),
                      let data = try? Data(contentsOf: url),
                      !data.prefix(1024).contains(0) else { return }
                // Not a string subtraction: the enumerator hands back resolved
                // paths (/private/var/…) while `directory` may still be the
                // symlink (/var/…), and replacing that as a substring left
                // "/private" glued to the front of every result.
                guard let rel = relativePath(for: url, in: directory) else { return }
                var no = 0
                for raw in String(decoding: data, as: UTF8.self)
                    .split(separator: "\n", omittingEmptySubsequences: false) {
                    no += 1
                    if matcher.firstRange(in: String(raw)) != nil {
                        out.append((rel, no,
                                    searchPreview(String(raw), query: query, options: options)))
                        if out.count >= maxHits {
                            finished = true
                            return
                        }
                    }
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
        // A data source must never trap: a search finishing between AppKit
        // asking how many children there are and which one it wants leaves the
        // index pointing past the new results.
        if item == nil {
            return groups.indices.contains(index) ? groups[index] : staleRow
        }
        guard let group = item as? FileGroup else { return staleRow }
        let children = rows(for: group)
        return children.indices.contains(index) ? children[index] : staleRow
    }


    func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileGroup) != nil
    }
}

extension SearchViewController: NSOutlineViewDelegate {
    /// File rows and the code lines under them are the same kind of row as the
    /// file tree's, so they take the same `tree_line_height` instead of each
    /// measuring its own font.
    func outlineView(_ ov: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        Theme.treeRowHeight()
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
    private var icon: SidebarIcon?
    private var name = ""
    private var folder = ""

    func configure(group: SearchViewController.FileGroup) {
        icon = .file(group.url)
        name = group.name
        folder = group.folder
        toolTip = group.relative
        exposeToAccessibility(group.relative)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        SidebarCellDrawing.icon(icon,
                                in: NSRect(x: 2, y: floor((bounds.height - 13) / 2),
                                           width: 13, height: 13))
        SidebarCellDrawing.primaryAndSecondary(
            primary: name, primaryFont: Theme.uiFont(11.5), primaryColor: Theme.foreground,
            secondary: folder, secondaryFont: Theme.uiFont(10), secondaryColor: Theme.dimText,
            in: NSRect(x: 20, y: 0, width: max(0, bounds.width - 24), height: bounds.height))
    }
}

final class SearchHitCell: DrawnSidebarCell {
    private var content = NSAttributedString()
    private var highlightRange: NSRange?
    /// Measuring the run costs a TextKit pass, so keep it until the row or the
    /// panel width changes.
    private var cachedHighlight: (width: CGFloat, rect: NSRect)?
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
        // The highlight is painted behind the row rather than set as a
        // background attribute: an attribute only covers the glyph box, which
        // left a band of row above and below it.
        if let match = hit.matchRange,
           NSMaxRange(match) <= (hit.preview as NSString).length {
            let previewOffset = (prefix as NSString).length
            // The fill is dark enough for the row's own text colour to stay
            // readable, so the match is not re-inked.
            highlightRange = NSRange(location: previewOffset + match.location,
                                     length: match.length)
        } else {
            highlightRange = nil
        }
        content = attributed
        cachedHighlight = nil
        exposeToAccessibility("Line \(number): \(hit.preview)")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let textWidth = max(0, bounds.width - 4)
        if let box = highlightBox(width: textWidth) {
            // An outline, not a fill: the preview keeps its own contrast and
            // nothing is painted over the matched text.
            Theme.matchOutline.setStroke()
            let pen = Theme.matchOutlineWidth
            let path = NSBezierPath(
                roundedRect: NSRect(x: box.minX, y: 0,
                                    width: box.width, height: bounds.height)
                    .insetBy(dx: pen / 2, dy: pen / 2),
                xRadius: Theme.matchCornerRadius, yRadius: Theme.matchCornerRadius)
            path.lineWidth = pen
            path.stroke()
        }
        // Gutter number and source text are intentionally one attributed line:
        // tab stops and a shared baseline make vertical drift impossible.
        SidebarCellDrawing.attributedText(
            content,
            in: NSRect(x: 0, y: 0, width: textWidth, height: bounds.height))
    }

    var contentForTesting: NSAttributedString { content }
    func highlightBoxForTesting(width: CGFloat) -> NSRect? { highlightBox(width: width) }

    /// Where the matched run sits horizontally. Measured through TextKit because
    /// the line carries tab stops for the gutter, so a substring width would be
    /// wrong.
    private func highlightBox(width: CGFloat) -> NSRect? {
        guard let highlightRange, width > 0 else { return nil }
        if let cachedHighlight, cachedHighlight.width == width { return cachedHighlight.rect }
        let storage = NSTextStorage(attributedString: content)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        let glyphs = manager.glyphRange(forCharacterRange: highlightRange,
                                        actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
        storage.removeLayoutManager(manager)
        guard rect.width > 0 else { return nil }
        cachedHighlight = (width, rect)
        return rect
    }
}

/// Proves the highlight is painted, not attached to the glyphs: a background
/// attribute would put the colour inside `content` instead.
struct SearchHitCellProbe {
    var fillsRowHeightForTesting: Bool {
        let cell = SearchHitCell()
        cell.frame = NSRect(x: 0, y: 0, width: 320, height: 40)
        cell.configure(hit: SearchViewController.Hit(
            line: 12, preview: "let value = compute()", matchRange: NSRange(location: 4, length: 5)))
        var attributed = false
        cell.contentForTesting.enumerateAttribute(
            .backgroundColor,
            in: NSRange(location: 0, length: cell.contentForTesting.length)
        ) { value, _, _ in
            if value != nil { attributed = true }
        }
        guard !attributed else { return false }
        guard let box = cell.highlightBoxForTesting(width: 316) else { return false }
        return box.width > 0
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

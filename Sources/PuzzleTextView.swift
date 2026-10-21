import AppKit

/// View-space geometry for the active bracket pair. Keeping this independent
/// from TextKit makes viewport continuation and same-line behavior directly
/// regression-testable.
struct BracketScopeGeometry {
    let box: NSRect?
    let polyline: [NSPoint]

    /// The outline is anchored to the text, never to the viewport.
    ///
    /// It used to carry short horizontal caps drawn at the top and bottom edges
    /// of the visible rect, to say the scope continued past them. The text view
    /// scrolls by copying pixels and repainting only what is newly exposed, so
    /// those caps stayed behind at whatever height they were drawn: a single
    /// pair ended up looking like several, with stray ticks across the guide.
    static func make(opening: NSRect, closing: NSRect, guideX: CGFloat,
                     visibleRect: NSRect) -> BracketScopeGeometry {
        // A pair on one visual row reads best as one compact enclosure. A
        // multiline pair uses the open-sided scope contour shown by editors
        // such as Zed: opening row -> indentation guide -> closing row.
        if abs(opening.midY - closing.midY) < 0.5 {
            let union = opening.union(closing).insetBy(dx: -2, dy: -2)
            return BracketScopeGeometry(box: union, polyline: [])
        }

        let openingY = opening.maxY + 1
        let closingY = closing.maxY + 1
        let resolvedGuideX = min(guideX, opening.minX - 3, closing.minX - 3)
        let polyline = [
            NSPoint(x: opening.maxX + 2, y: openingY),
            NSPoint(x: resolvedGuideX, y: openingY),
            NSPoint(x: resolvedGuideX, y: closingY),
            NSPoint(x: closing.maxX + 2, y: closingY),
        ]

        return BracketScopeGeometry(box: nil, polyline: polyline)
    }
}

/// NSTextView that paints the current-line band and keeps the caret the same
/// height as the text rather than the whole tall line box.
final class PuzzleTextView: NSTextView {
    /// Programmatic selection changes (opening/switching tabs) must not look
    /// like a user-selected line. The pane uses this callback to activate line
    /// UI only for real pointer/keyboard interaction.
    var onExplicitCaretInteraction: (() -> Void)?
    /// Return true to consume a Command-click and resolve its file/symbol.
    var onCommandClick: ((Int) -> Bool)?
    /// `nil` means Command was released or the pointer left the text.
    var onCommandHover: ((Int?) -> Void)?
    private var commandHoverTrackingArea: NSTrackingArea?
    private var commandModifierMonitor: Any?
    private(set) var commandHoverRange: NSRange? {
        didSet { if commandHoverRange != oldValue { needsDisplay = true } }
    }

    /// Find-bar matches, drawn here (rather than as temporary attributes) so the
    /// bands are glyph-height instead of the full configured code row, and so they paint
    /// *above* the current-line band instead of being hidden by it.
    var searchMatches: [NSRange] = [] { didSet { needsDisplay = true } }
    var currentMatchIndex: Int? { didSet { needsDisplay = true } }
    var searchResultLineLocation: Int? { didSet { needsDisplay = true } }

    private(set) var bracketMatchRanges: [NSRange] = []
    private var jsxTagMatches: [JSXTagMatch] = []
    private(set) var activeJSXTagMatch: JSXTagMatch?

    func updateJSXTagMatches(_ matches: [JSXTagMatch]) {
        guard matches != jsxTagMatches else { return }
        jsxTagMatches = matches
        refreshBracketMatches()
    }

    func refreshBracketMatches() {
        let refreshed: [NSRange]
        let refreshedTag: JSXTagMatch?
        if selectedRanges.count == 1, selectedRange().length == 0 {
            refreshed = BracketMatcher.ranges(
                in: string as NSString, caret: selectedRange().location)
            // A delimiter immediately beside the caret is more specific than
            // the JSX tag containing it (for example an attribute's `{...}`).
            refreshedTag = refreshed.isEmpty
                ? jsxTagMatch(at: selectedRange().location) : nil
        } else {
            refreshed = []
            refreshedTag = nil
        }
        guard refreshed != bracketMatchRanges
                || refreshedTag != activeJSXTagMatch else { return }
        bracketMatchRanges = refreshed
        activeJSXTagMatch = refreshedTag
        needsDisplay = true
        syncScopeFlow()
    }

    private func jsxTagMatch(at caret: Int) -> JSXTagMatch? {
        jsxTagMatches.compactMap { match -> (JSXTagMatch, Int)? in
            let containing = match.activationRanges.filter {
                caret >= $0.location && caret <= NSMaxRange($0)
            }
            guard let narrowest = containing.min(by: { $0.length < $1.length }) else {
                return nil
            }
            return (match, narrowest.length)
        }.min(by: { $0.1 < $1.1 })?.0
    }

    /// Bound AppKit's responsive-scrolling overdraw.
    ///
    /// By default the scroll view pre-renders a generous area around the viewport
    /// so flicks look smooth; measured, that cost ~21 MB of CoreAnimation backing
    /// store the moment the first document appeared. One screen of margin keeps
    /// scrolling smooth while capping the backing store.
    override func prepareContent(in rect: NSRect) {
        let visible = visibleRect
        guard !visible.isEmpty else { super.prepareContent(in: rect); return }
        super.prepareContent(in: visible.insetBy(dx: 0, dy: -visible.height))
    }

    /// Full-width tints for changed lines in a git diff.
    ///
    /// These are drawn rather than applied as `.backgroundColor` attributes:
    /// an attribute only paints behind the glyphs, so a line whose range happens
    /// to include the trailing newline stretched to full width while the final
    /// line of the buffer did not — the bands looked ragged.
    var diffBands: [(range: NSRange, color: NSColor)] = [] {
        didSet { needsDisplay = true }
    }

    /// File line number for each line of a diff buffer, `nil` for the headers
    /// that belong to no line. Empty for ordinary files, which are simply
    /// numbered from 1.
    var diffLineNumbers: [Int?] = [] {
        didSet { enclosingScrollView?.verticalRulerView?.needsDisplay = true }
    }

    private var markdownCodeBlocks: [MarkdownCodeBlockDecoration] = []
    private var markdownTables: [MarkdownTableDecoration] = []
    private var markdownTasks: [MarkdownTaskDecoration] = []
    private var markdownLineMarkers: [MarkdownLineMarkerDecoration] = []
    private var markdownRules: [MarkdownRuleDecoration] = []
    private var markdownImages: [MarkdownImageDecoration] = []
    /// Decoded at the size they are drawn at, not the size they were saved at,
    /// and only while the document's pictures together stay under a budget: a
    /// three-line Markdown file can reference a folder full of camera JPEGs, and
    /// full-resolution frames for all of them are hundreds of megabytes.
    private struct CachedImage {
        let image: NSImage
        let bytes: Int
    }
    private var markdownImageCache: [URL: CachedImage] = [:]
    /// Enough for the widest measure on a Retina display; the drawn box is at
    /// most 320pt tall, so a larger frame would only be thrown away by `draw`.
    private static let markdownImagePixels = 1600
    private static let markdownImageByteBudget = 48 * 1024 * 1024
    /// The line being edited, whose source shows.
    private var markdownActiveSourceRange: NSRange?
    /// A block's lead the caret is inside, shown in the text itself.
    private var markdownRevealedLead: NSRange?
    private var measuredMarkdownTableWidth: CGFloat = -1
    private var measuredMarkdownTableFont: NSFont?

    func updateMarkdownDecorations(codeBlocks: [MarkdownCodeBlockDecoration],
                                   tables: [MarkdownTableDecoration],
                                   tasks: [MarkdownTaskDecoration] = [],
                                   lineMarkers: [MarkdownLineMarkerDecoration] = [],
                                   rules: [MarkdownRuleDecoration] = [],
                                   images: [MarkdownImageDecoration] = [],
                                   links: [MarkdownLinkDecoration] = [],
                                   activeSourceRange: NSRange?,
                                   revealedLead: NSRange? = nil) {
        if links != markdownLinks {
            markdownLinks = links
            hideLinkPopover()
        }
        let measured = tables != markdownTables || images != markdownImages
            || foldingManager?.markdownTableMetricsNeedRefresh == true
            || measuredMarkdownTableFont != Theme.markdownFont()
        guard measured || codeBlocks != markdownCodeBlocks || tables != markdownTables
                || tasks != markdownTasks
                || lineMarkers != markdownLineMarkers
                || rules != markdownRules
                || images != markdownImages
                || activeSourceRange != markdownActiveSourceRange
                || revealedLead != markdownRevealedLead else { return }
        markdownCodeBlocks = codeBlocks
        markdownTables = tables
        markdownTasks = tasks
        markdownLineMarkers = lineMarkers
        markdownRules = rules
        markdownImages = images
        let retainedURLs = Set(images.compactMap(\.url))
        markdownImageCache = markdownImageCache.filter { retainedURLs.contains($0.key) }
        markdownActiveSourceRange = activeSourceRange
        markdownRevealedLead = revealedLead
        // Rows are measured again only when a table or a picture changed —
        // not for every move of the caret, which re-measured every cell of
        // every table.
        if measured {
            measuredMarkdownTableWidth = -1
            updateMarkdownTableRowMetrics()
        }
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        updateMarkdownTableRowMetrics()
    }

    var markdownDecorationCountsForTesting: (codeBlocks: Int, tables: Int) {
        (markdownCodeBlocks.count, markdownTables.count)
    }
    var markdownTaskCountForTesting: Int { markdownTasks.count }

    private func updateMarkdownTableRowMetrics() {
        let width = bounds.width
        guard abs(width - measuredMarkdownTableWidth) > 0.5
                || measuredMarkdownTableFont != Theme.markdownFont() else { return }
        measuredMarkdownTableWidth = width
        measuredMarkdownTableFont = Theme.markdownFont()
        guard width > 0, !markdownTables.isEmpty || !markdownImages.isEmpty else {
            foldingManager?.updateMarkdownTableRowMetrics([])
            return
        }
        var metrics: [MarkdownTableRowMetric] = []
        var measuredNow: [TableMeasureKey: TableMeasure] = [:]
        for table in markdownTables {
            let measure = tableMeasure(for: table)
            measuredNow[TableMeasureKey(table, width: bounds.width)] = measure
            for (index, row) in table.rows.enumerated() {
                // The metric covers the row's characters, not its line: a
                // hidden line's terminator floats into the *next* fragment, and
                // a fragment holding nothing but that terminator would take the
                // row's height a second time.
                let leading = index == 0 && table.leadsWithBlankLine
                    ? Theme.markdownBlankLineHeight() : 0
                metrics.append(MarkdownTableRowMetric(
                    range: row.sourceRange,
                    height: measure.heights[index] + leading))
            }
            // The last row's terminator has no row after it to float into, so
            // it forms a fragment of its own and would read as a blank line the
            // source does not have.
            if let last = table.rows.last, last.lineRange.length > last.sourceRange.length {
                metrics.append(MarkdownTableRowMetric(
                    range: NSRange(location: NSMaxRange(last.sourceRange), length: 1),
                    height: 1))
            }
        }
        tableMeasures = measuredNow
        for image in markdownImages {
            metrics.append(MarkdownTableRowMetric(
                range: image.lineRange,
                height: markdownImageHeight(image), isImage: true))
        }
        foldingManager?.updateMarkdownTableRowMetrics(metrics)
        needsDisplay = true
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    /// A table's column widths and row heights, by what it holds and the
    /// width it is set in. An edit anywhere moves every table's ranges, and
    /// measuring every cell again for that — and on every draw — was a large
    /// part of a keystroke in a long document.
    private struct TableMeasureKey: Hashable {
        let cells: [[String]]
        let headers: [Bool]
        let width: CGFloat
        /// The type is set in: measured again when the font size changes.
        let font = Theme.markdownFont()
        init(_ table: MarkdownTableDecoration, width: CGFloat) {
            cells = table.rows.map(\.cells)
            headers = table.rows.map(\.isHeader)
            self.width = width
        }
    }
    private struct TableMeasure {
        let widths: [CGFloat]
        let heights: [CGFloat]
    }
    private var tableMeasures: [TableMeasureKey: TableMeasure] = [:]

    private func tableMeasure(for table: MarkdownTableDecoration) -> TableMeasure {
        let key = TableMeasureKey(table, width: bounds.width)
        if let known = tableMeasures[key] { return known }
        let widths = markdownTableColumnWidths(for: table)
        let measure = TableMeasure(widths: widths, heights: table.rows.map {
            markdownTableRowHeight($0, widths: widths)
        })
        tableMeasures[key] = measure
        return measure
    }

    private func markdownTableAttributes(header: Bool)
        -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        // The table is part of the prose, in its face; the header in its bold.
        let size = Theme.markdownFontSize()
        return [
            .font: header ? NSFont.boldSystemFont(ofSize: size) : Theme.markdownFont(),
            .foregroundColor: Theme.foreground,
            .paragraphStyle: paragraph,
        ]
    }

    private func markdownTableColumnWidths(for table: MarkdownTableDecoration) -> [CGFloat] {
        let availableWidth = max(80, bounds.width - textContainerInset.width * 2)
        var widths = Array(repeating: CGFloat(60), count: table.columnCount)
        for row in table.rows {
            let attributes = markdownTableAttributes(header: row.isHeader)
            for (column, cell) in row.cells.enumerated() where column < widths.count {
                widths[column] = max(widths[column],
                    ceil((cell as NSString).size(withAttributes: attributes).width) + 20)
            }
        }
        let preferred = widths.reduce(0, +)
        guard preferred > availableWidth else { return widths }
        let scale = availableWidth / preferred
        widths = widths.map { max(40, floor($0 * scale)) }
        let adjusted = widths.reduce(0, +)
        if adjusted > availableWidth, let last = widths.indices.last {
            widths[last] = max(20, widths[last] - (adjusted - availableWidth))
        }
        return widths
    }

    private func markdownTableRowHeight(_ row: MarkdownTableDecoration.Row,
                                        widths: [CGFloat]) -> CGFloat {
        let attributes = markdownTableAttributes(header: row.isHeader)
        var contentHeight: CGFloat = 0
        for (column, cell) in row.cells.enumerated() where column < widths.count {
            let textWidth = max(1, widths[column] - 16)
            let bounds = (cell as NSString).boundingRect(
                with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes)
            contentHeight = max(contentHeight, ceil(bounds.height))
        }
        return max(Theme.markdownLineHeight(), contentHeight + 12)
    }

    private func markdownImage(_ decoration: MarkdownImageDecoration) -> NSImage? {
        guard let url = decoration.url, url.isFileURL else { return nil }
        if let cached = markdownImageCache[url] { return cached.image }
        let used = markdownImageCache.values.reduce(0) { $0 + $1.bytes }
        // Past the budget the picture falls back to its alt text rather than
        // being decoded. `draw` already has that path for images it cannot read.
        guard used < Self.markdownImageByteBudget,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let source = PreviewImageSource(url: url, data: data),
              let image = source.decode(maximum: Self.markdownImagePixels) else { return nil }
        // The decoded frame keeps the file's logical size, so every measurement
        // below is unchanged; only the bitmap behind it is smaller.
        let longest = max(source.pixelSize.width, source.pixelSize.height)
        let scale = longest > 0 ? min(1, CGFloat(Self.markdownImagePixels) / longest) : 1
        let bytes = Int(source.pixelSize.width * scale)
            * Int(source.pixelSize.height * scale) * 4
        markdownImageCache[url] = CachedImage(image: image, bytes: bytes)
        return image
    }

    private func markdownImageHeight(_ decoration: MarkdownImageDecoration) -> CGFloat {
        let available = max(80, bounds.width - textContainerInset.width * 2)
        guard let image = markdownImage(decoration), image.size.width > 0,
              image.size.height > 0 else { return Theme.markdownLineHeight() * 2 }
        let scale = min(1, available / image.size.width, 320 / image.size.height)
        return max(Theme.markdownLineHeight() * 2, floor(image.size.height * scale) + 8)
    }

    private(set) var codeBlocks: [CodeBlock] = []

    private var foldingManager: FoldingLayoutManager? {
        layoutManager as? FoldingLayoutManager
    }

    func updateCodeBlocks(_ blocks: [CodeBlock], resetFolds: Bool) {
        codeBlocks = blocks
        foldingManager?.updateBlocks(blocks, resetFolds: resetFolds)
        refreshFoldingDisplay()
    }

    func isFolded(_ block: CodeBlock) -> Bool {
        foldingManager?.isFolded(block) ?? false
    }

    func toggleFold(_ block: CodeBlock) {
        guard codeBlocks.contains(block) else { return }
        if !isFolded(block) {
            // Never leave the insertion point inside glyphs that are about to
            // disappear. The source remains unchanged.
            setSelectedRange(NSRange(location: block.openerLocation, length: 0))
        }
        foldingManager?.toggle(block)
        refreshFoldingDisplay()
    }

    /// Open every fold hiding one of `ranges`, and say whether anything moved.
    ///
    /// A search result inside a fold has no geometry to mark — its glyphs are
    /// null — and a result nobody can see is not a result. Finding one opens
    /// the block it is in, which is what the user would have done by hand.
    @discardableResult
    func revealFolds(covering ranges: [NSRange]) -> Bool {
        guard let foldingManager, !ranges.isEmpty else { return false }
        var opened = false
        for block in codeBlocks where foldingManager.isFolded(block) {
            guard ranges.contains(where: {
                NSIntersectionRange($0, block.hiddenRange).length > 0
            }) else { continue }
            foldingManager.toggle(block)
            opened = true
        }
        if opened { refreshFoldingDisplay() }
        return opened
    }

    func unfoldAllCodeBlocks() {
        foldingManager?.unfoldAll()
        refreshFoldingDisplay()
    }

    private func refreshFoldingDisplay() {
        needsDisplay = true
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    /// A blame annotation, and the line it was read for, by where that line
    /// starts.
    struct InlineBlame: Equatable {
        var text: String
        var lineStart: Int
    }

    /// Blame annotation for one line, drawn past the end of its text while the
    /// caret is on it — and only then.
    ///
    /// A click moves the caret and draws at once; the selection change reaches
    /// whoever reads blame only when the mouse is let go. Drawn for "the
    /// caret's line", the previous line's author showed against the line just
    /// clicked, went away when the change arrived, and came back when the new
    /// line's had been read: one annotation shown twice.
    ///
    /// Deliberately drawn rather than inserted into the text storage: the
    /// storage is the document, shared across split panes, and putting
    /// decoration in it would dirty the buffer and land in saved files.
    var inlineBlame: InlineBlame? {
        didSet { if inlineBlame != oldValue { needsDisplay = true } }
    }

    /// Where the line that blame is drawn on for `caret` starts. At the end of
    /// a file that ends in a newline, that is the last line with text.
    func inlineBlameLineStart(at caret: Int) -> Int {
        let ns = string as NSString
        return ns.lineRange(for: NSRange(location: min(caret, max(ns.length - 1, 0)),
                                         length: 0)).location
    }

    /// Where the last draw put the annotation; nil when it drew none.
    private(set) var drawnInlineBlameRectForTesting: NSRect?

    private func drawInlineBlame() {
        drawnInlineBlameRectForTesting = nil
        guard let inlineBlame, !inlineBlame.text.isEmpty,
              let layoutManager, textContainer != nil else { return }
        let blame = inlineBlame.text
        let ns = string as NSString

        let caret = selectedRange().location
        guard caret <= ns.length else { return }
        let lineRange = ns.lineRange(for: NSRange(location: min(caret, max(ns.length - 1, 0)),
                                                  length: 0))
        // Read for another line: the caret has moved and the new line's has
        // not been asked for yet.
        guard lineRange.location == inlineBlame.lineStart else { return }
        // End of the line's text, excluding the newline itself.
        var end = NSMaxRange(lineRange)
        while end > lineRange.location {
            let c = ns.character(at: end - 1)
            if c == 0x0A || c == 0x0D { end -= 1 } else { break }
        }

        let inset = textContainerInset
        let tailGlyph = layoutManager.glyphIndexForCharacter(at: max(end - 1, lineRange.location))
        var frag = layoutManager.lineFragmentRect(forGlyphAt: tailGlyph, effectiveRange: nil)
        var x: CGFloat
        if end > lineRange.location {
            let used = layoutManager.lineFragmentUsedRect(forGlyphAt: tailGlyph,
                                                          effectiveRange: nil)
            x = used.maxX
        } else {
            // Empty line: start at the left margin.
            frag = layoutManager.lineFragmentRect(
                forGlyphAt: layoutManager.glyphIndexForCharacter(at: lineRange.location),
                effectiveRange: nil)
            x = frag.minX
        }

        let font = Theme.editorFont()
        let paragraph = NSMutableParagraphStyle()
        // Truncate rather than wrap or spill: this is drawn decoration, so a
        // second line would land on top of the next line of code.
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont(descriptor: font.fontDescriptor, size: font.pointSize - 1) ?? font,
            .foregroundColor: Theme.dimText.withAlphaComponent(0.75),
            .paragraphStyle: paragraph,
        ]
        let text = "    " + blame as NSString
        let size = text.size(withAttributes: attributes)

        // `code_line_height` owns the full row. Centre the annotation in the
        // same line fragment as the code, line number, active band and caret.
        let y = frag.midY - size.height / 2
        let originX = x + inset.width

        // Whatever room is left after the code, and no less.
        //
        // The annotation must never be moved left to make it fit: doing that
        // draws it straight over the code it is annotating. On a long line the
        // right answer is to truncate it, and if there isn't even room for that,
        // to draw nothing at all.
        let available = bounds.width - originX - inset.width
        let minimumUseful: CGFloat = 60
        guard available >= minimumUseful else { return }

        let width = min(size.width, available)
        let drawn = NSRect(x: originX, y: y + inset.height, width: width, height: size.height)
        text.draw(in: drawn, withAttributes: attributes)
        drawnInlineBlameRectForTesting = drawn
    }

    // Blame sits on top of the glyphs, so it goes here rather than in
    // drawBackground alongside the bands.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Over the active line's band and any selection, which both paint the
        // leading whitespace: under them, the marks vanished on the very line
        // being read. They sit only in that whitespace, so no glyph is covered.
        drawIndentMarkers(in: dirtyRect)
        // After the glyphs, not before: AppKit paints the selection background
        // over anything the view drew in `drawBackground`, which would swallow
        // the rule under whichever match the caret was left on.
        drawSearchUnderlines()
        drawMarkdownTables(in: dirtyRect)
        drawMarkdownImages(in: dirtyRect)
        // Markers hang in the margin, left of the text container — and AppKit
        // leaves the clip at the container once it has drawn the text, which
        // cut a heading's `##` off entirely and a task's `-` off its `[ ]`.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSIntersectionRect(dirtyRect, bounds)).setClip()
        drawMarkdownLineMarkers(in: dirtyRect)
        drawMarkdownTasks(in: dirtyRect)
        drawMarkdownSpanMarks(in: dirtyRect)
        NSGraphicsContext.restoreGraphicsState()
        drawMarkdownRules(in: dirtyRect)
        drawMarkdownCodeLabels(in: dirtyRect)
        drawCommandHoverUnderline()
        // Whatever made this draw may have moved the active pair — an edit, a
        // fold, a new font, a new theme — so the flowing line follows it.
        scheduleScopeFlowSync()
        drawInlineBlame()
    }

    func setCommandHoverRange(_ range: NSRange?) {
        commandHoverRange = range
    }

    private func drawCommandHoverUnderline() {
        guard let range = commandHoverRange,
              range.length > 0,
              NSMaxRange(range) <= (string as NSString).length,
              let layoutManager, let container = textContainer else { return }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range,
                                                   actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return }
        let inset = textContainerInset
        let notSelected = NSRange(location: NSNotFound, length: 0)
        Theme.purple.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphRange,
            withinSelectedGlyphRange: notSelected,
            in: container
        ) { rect, _ in
            let y = floor(rect.maxY + inset.height - 0.5)
            path.move(to: NSPoint(x: rect.minX + inset.width, y: y))
            path.line(to: NSPoint(x: rect.maxX + inset.width, y: y))
        }
        path.stroke()
    }

    private struct BracketGlyphGeometry {
        let glyphBox: NSRect
        let leadingContentX: CGFloat
    }

    private func bracketGlyphGeometry(for range: NSRange) -> BracketGlyphGeometry? {
        guard let layoutManager, let container = textContainer,
              range.location >= 0,
              NSMaxRange(range) <= (string as NSString).length,
              foldingManager?.isCharacterHidden(at: range.location) != true else { return nil }

        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: range, actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return nil }
        let fragment = layoutManager.lineFragmentRect(
            forGlyphAt: glyphRange.location, effectiveRange: nil)
        let raw = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        guard !raw.isEmpty else { return nil }

        let inset = textContainerInset
        let vertical = glyphBox(fragmentHeight: fragment.height)
        let box = NSRect(x: raw.minX + inset.width,
                         y: fragment.minY + vertical.top + inset.height,
                         width: max(raw.width, 1), height: vertical.height)

        let source = string as NSString
        let line = source.lineRange(for: NSRange(location: range.location, length: 0))
        var firstContent = line.location
        let lineEnd = min(NSMaxRange(line), source.length)
        while firstContent < lineEnd {
            let character = source.character(at: firstContent)
            if character == 0x20 || character == 0x09 {
                firstContent += 1
            } else {
                break
            }
        }

        var leadingX = box.minX
        if firstContent < lineEnd,
           source.character(at: firstContent) != 0x0A,
           source.character(at: firstContent) != 0x0D {
            let firstGlyph = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: firstContent, length: 1),
                actualCharacterRange: nil)
            if firstGlyph.length > 0 {
                let firstRect = layoutManager.boundingRect(forGlyphRange: firstGlyph,
                                                           in: container)
                if !firstRect.isEmpty { leadingX = firstRect.minX + inset.width }
            }
        }
        return BracketGlyphGeometry(glyphBox: box, leadingContentX: leadingX)
    }

    func bracketScopeGeometry(in viewport: NSRect? = nil) -> BracketScopeGeometry? {
        guard bracketMatchRanges.count == 2,
              let opening = bracketGlyphGeometry(for: bracketMatchRanges[0]),
              let closing = bracketGlyphGeometry(for: bracketMatchRanges[1]) else { return nil }
        let minimumGuideX = textContainerInset.width
            + (textContainer?.lineFragmentPadding ?? 0) + 1
        let guideX = max(minimumGuideX,
                         min(opening.leadingContentX, closing.leadingContentX) - 3)
        return BracketScopeGeometry.make(
            opening: opening.glyphBox, closing: closing.glyphBox,
            guideX: guideX, visibleRect: viewport ?? visibleRect)
    }

    private func jsxScopeGeometry(in viewport: NSRect? = nil) -> BracketScopeGeometry? {
        guard let match = activeJSXTagMatch,
              let openingAngle = bracketGlyphGeometry(for: match.openingAngleRange),
              let closing = bracketGlyphGeometry(for: match.closingTerminatorRange) else {
            return nil
        }

        let minimumGuideX = textContainerInset.width
            + (textContainer?.lineFragmentPadding ?? 0) + 1
        let guideX = max(minimumGuideX,
                         min(openingAngle.leadingContentX,
                             closing.leadingContentX) - 3)
        let visible = viewport ?? visibleRect

        switch match.kind {
        case .selfClosing:
            // Match the literal `<` and final `>`; on multiple lines this
            // wraps the attributes between them, including a standalone `/>`.
            return BracketScopeGeometry.make(
                opening: openingAngle.glyphBox, closing: closing.glyphBox,
                guideX: guideX, visibleRect: visible)

        case .paired:
            guard let openingHead = bracketGlyphGeometry(
                for: match.openingHeadRange) else { return nil }
            // The paired-element contour owns the complete element, including
            // multiline attributes. Its top edge therefore starts at `<Button`
            // (or `<UI.Button`), never at the opening tag's final `>`.
            return BracketScopeGeometry.make(
                opening: openingHead.glyphBox, closing: closing.glyphBox,
                guideX: guideX, visibleRect: visible)
        }
    }

    private func activeScopeGeometry() -> BracketScopeGeometry? {
        if !bracketMatchRanges.isEmpty { return bracketScopeGeometry() }
        return jsxScopeGeometry()
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawZebraStripes(in: rect)
        drawDiffBands()
        drawMarkdownCodeBlocks(in: rect)
        drawMarkdownInlineCode(in: rect)
        drawCurrentLineBand()
        drawScopeEndTint()
    }

    /// A code span's box: as tall as the code's own type rather than its line
    /// — a heading's line has the room above it, and a background attribute
    /// filled that too — and only around what is drawn: the backtick of a span
    /// opening a line is laid out, hidden, with the line above, and its
    /// background ran across the whole of that line.
    private func drawMarkdownInlineCode(in dirtyRect: NSRect) {
        guard rendersMarkdown, let layoutManager, let container = textContainer else { return }
        let origin = textContainerOrigin
        let visibleGlyphs = layoutManager.glyphRange(
            forBoundingRect: dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        let visible = layoutManager.characterRange(forGlyphRange: visibleGlyphs,
                                                   actualGlyphRange: nil)
        Theme.inputBackground.setFill()
        for box in markdownInlineCodeBoxes(in: visible, font: Theme.editorFont()) {
            NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
        }
    }

    private func markdownInlineCodeBoxes(in visible: NSRange, font: NSFont) -> [NSRect] {
        guard let layoutManager, let container = textContainer else { return [] }
        let origin = textContainerOrigin
        let notSelected = NSRange(location: NSNotFound, length: 0)
        let length = (string as NSString).length
        var boxes: [NSRect] = []
        for span in markdownSpans where span.kind == .code && span.content.length > 0
            && NSIntersectionRange(span.range, visible).length > 0
            && NSMaxRange(span.content) <= length {
            let glyphs = layoutManager.glyphRange(forCharacterRange: span.content,
                                                  actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphs, withinSelectedGlyphRange: notSelected, in: container
            ) { rect, _ in
                guard rect.width > 0 else { return }
                let glyph = layoutManager.glyphIndex(for: NSPoint(x: rect.midX, y: rect.midY),
                                                     in: container)
                let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph,
                                                              effectiveRange: nil)
                let baseline = fragment.minY + layoutManager.location(forGlyphAt: glyph).y
                boxes.append(NSRect(x: rect.minX - 2 + origin.x,
                                    y: baseline - font.ascender - 1 + origin.y,
                                    width: rect.width + 4,
                                    height: font.ascender - font.descender + 2))
            }
        }
        return boxes
    }

    var inlineCodeBoxesForTesting: [NSRect] {
        markdownInlineCodeBoxes(in: NSRange(location: 0, length: (string as NSString).length),
                                font: Theme.editorFont())
    }

    private func drawMarkdownCodeBlocks(in dirtyRect: NSRect) {
        guard !markdownCodeBlocks.isEmpty,
              let layoutManager, let container = textContainer else { return }
        let inset = textContainerInset
        // Only the blocks being drawn: walking the lines of every block in the
        // document, on every draw, was as long as restyling it.
        let reach = dirtyRect.insetBy(dx: 0, dy: -Theme.markdownCodePaddingY * 2)
            .offsetBy(dx: -inset.width, dy: -inset.height)
        let shown = layoutManager.characterRange(
            forGlyphRange: layoutManager.glyphRange(forBoundingRect: reach, in: container),
            actualGlyphRange: nil)
        for block in markdownCodeBlocks
        where NSIntersectionRange(block.range, shown).length > 0
            || NSLocationInRange(shown.location, block.range) {
            // Inside a list the first line starts with the item's hidden
            // indent, which TextKit keeps with the line above.
            let start = firstDrawnCharacter(from: block.range.location)
            let drawn = NSRange(location: start,
                                length: max(0, NSMaxRange(block.range) - start))
            let clamped = NSIntersectionRange(
                drawn, NSRange(location: 0, length: (string as NSString).length))
            guard clamped.length > 0 else { continue }
            let glyphs = layoutManager.glyphRange(
                forCharacterRange: clamped, actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            var union = NSRect.null
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) {
                fragment, _, _, _, _ in union = union.union(fragment)
            }
            guard !union.isNull else { continue }
            // The fence lines above and below are the box's padding; an
            // indented block has none, and takes the same room from the gap
            // around it.
            let padding = Theme.markdownCodePaddingY
            let rect = NSRect(x: inset.width + block.indent,
                              y: union.minY + inset.height - padding,
                              width: max(0, bounds.width - inset.width * 2 - block.indent),
                              height: union.height + padding * 2)
            codeBoxRectsForTesting[block.range.location] = rect
            guard rect.intersects(dirtyRect) else { continue }
            Theme.inputBackground.setFill()
            let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
            path.fill()
            Theme.border.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func drawMarkdownCodeLabels(in dirtyRect: NSRect) {
        guard let layoutManager else { return }
        let inset = textContainerInset
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Theme.uiFont(9.5), .foregroundColor: Theme.dimText,
        ]
        let length = (string as NSString).length
        for block in markdownCodeBlocks {
            guard let language = block.language, !language.isEmpty,
                  block.range.length > 0, NSMaxRange(block.range) <= length else { continue }
            let glyph = layoutManager.glyphIndexForCharacter(
                at: firstDrawnCharacter(from: block.range.location))
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph,
                                                       effectiveRange: nil)
            let size = (language as NSString).size(withAttributes: attributes)
            // In the box's top padding, clear of the code.
            let rect = NSRect(x: max(inset.width, bounds.width - inset.width - size.width - 8),
                              y: line.minY + inset.height - Theme.markdownCodePaddingY + 1,
                              width: size.width, height: size.height)
            guard rect.intersects(dirtyRect) else { continue }
            (language as NSString).draw(in: rect, withAttributes: attributes)
        }
    }

    private func drawMarkdownTables(in dirtyRect: NSRect) {
        guard !markdownTables.isEmpty, let layoutManager,
              let container = textContainer else { return }
        let inset = textContainerInset
        let shown = layoutManager.characterRange(
            forGlyphRange: layoutManager.glyphRange(
                forBoundingRect: dirtyRect.offsetBy(dx: -inset.width, dy: -inset.height),
                in: container),
            actualGlyphRange: nil)

        for table in markdownTables where NSIntersectionRange(table.sourceRange, shown).length > 0 {
            let measure = tableMeasure(for: table)
            let tableWidth = min(max(80, bounds.width - inset.width * 2),
                                 measure.widths.reduce(0, +))
            let widths = measure.widths

            for (rowIndex, row) in table.rows.enumerated() {
                if let active = markdownActiveSourceRange,
                   NSIntersectionRange(active, row.sourceRange).length > 0 {
                    continue
                }
                guard row.sourceRange.length > 0 else { continue }
                // Anchor on the row's first source character, not on its line
                // terminator: TextKit starts a fragment *at* the preceding
                // terminator, so the terminator of a row belongs to the next
                // fragment and reading geometry from it drew every row one line
                // too low — and put the header on the collapsed delimiter line,
                // a 1pt fragment.
                let glyph = layoutManager.glyphIndexForCharacter(
                    at: row.sourceRange.location)
                let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph,
                                                               effectiveRange: nil)
                // The fragment can be taller than the row when it also carries
                // the blank line above the table. The row occupies its bottom.
                let rowHeight = min(fragment.height, measure.heights[rowIndex])
                let rowRect = NSRect(x: inset.width,
                                     y: fragment.maxY - rowHeight + inset.height,
                                     width: tableWidth, height: rowHeight)
                guard rowRect.intersects(dirtyRect) else { continue }

                // Cover the source row first, then paint the rendered cells.
                Theme.editorBackground.setFill()
                NSRect(x: 0, y: rowRect.minY, width: bounds.width,
                       height: rowRect.height).fill()
                (row.isHeader ? Theme.inputBackground : Theme.editorBackground).setFill()
                rowRect.fill()

                var x = rowRect.minX
                for column in 0..<table.columnCount {
                    let width = column < widths.count ? widths[column] : 60
                    let cellRect = NSRect(x: x, y: rowRect.minY,
                                          width: width, height: rowRect.height)
                    let textRect = cellRect.insetBy(dx: 8, dy: 0)
                    let cell = column < row.cells.count ? row.cells[column] : ""
                    let attrs = markdownTableAttributes(header: row.isHeader)
                    let measured = (cell as NSString).boundingRect(
                        with: NSSize(width: max(1, textRect.width),
                                     height: .greatestFiniteMagnitude),
                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                        attributes: attrs)
                    let verticallyCentered = NSRect(
                        x: textRect.minX,
                        y: textRect.midY - ceil(measured.height) / 2,
                        width: textRect.width, height: ceil(measured.height))
                    (cell as NSString).draw(
                        with: verticallyCentered,
                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                        attributes: attrs)
                    x += width
                }

                Theme.border.setStroke()
                let grid = NSBezierPath()
                grid.lineWidth = 1
                grid.appendRect(rowRect)
                x = rowRect.minX
                for width in widths.dropLast() {
                    x += width
                    grid.move(to: NSPoint(x: x, y: rowRect.minY))
                    grid.line(to: NSPoint(x: x, y: rowRect.maxY))
                }
                grid.stroke()
            }
        }
    }

    /// How far a marker drawn in the margin stays from the text it marks.
    private var markerGap: CGFloat { (Theme.markdownFontSize() * 0.45).rounded() }

    /// The first character from `location` on its line that is drawn. A
    /// hidden character at the start of a line — a list marker, a quote's
    /// `>` — has no place of its own, and TextKit puts it with the line
    /// before: anchoring there drew every bullet a line too high.
    private func firstDrawnCharacter(from location: Int) -> Int {
        let source = string as NSString
        guard location < source.length else { return location }
        let line = source.lineRange(for: NSRange(location: location, length: 0))
        var index = location
        while index < NSMaxRange(line) {
            let character = source.character(at: index)
            if character == 0x0A || character == 0x0D { break }
            if foldingManager?.isCharacterHidden(at: index) != true { return index }
            index += 1
        }
        return location
    }

    /// The box a rendered line's text sits in, in view coordinates: the line
    /// a marker in the margin is centred on.
    private func markdownLineBox(at location: Int) -> NSRect? {
        guard let layoutManager, location < (string as NSString).length else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: firstDrawnCharacter(from: location))
        let origin = textContainerOrigin
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let text = foldingManager?.markdownTextBox(forGlyphAt: glyph)?.text ?? fragment
        return text.offsetBy(dx: origin.x, dy: origin.y)
    }

    /// How a block's lead is shown: as its rendered marker, as its own source
    /// in the margin while the line is edited, or not at all once the caret
    /// is inside it and the source is in the text.
    private enum LeadDisplay { case rendered, source, inText }

    private func leadDisplay(for range: NSRange) -> LeadDisplay {
        if let lead = markdownRevealedLead, NSIntersectionRange(lead, range).length > 0 {
            return .inText
        }
        if let active = markdownActiveSourceRange,
           NSIntersectionRange(active, range).length > 0 {
            return .source
        }
        return .rendered
    }

    /// A lead's own characters, as the margin shows them while it is edited.
    private func leadSource(_ range: NSRange) -> String {
        let source = string as NSString
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: source.length))
        return source.substring(with: clamped).trimmingCharacters(in: .whitespaces)
    }

    private var leadSourceAttributes: [NSAttributedString.Key: Any] {
        [.font: Theme.markdownFont(), .foregroundColor: Theme.dimText.withAlphaComponent(0.8)]
    }

    /// Right-aligned against the text, in the margin before it, centred on
    /// the line: where every marker is drawn.
    @discardableResult
    private func drawMarginLabel(_ label: String, attributes: [NSAttributedString.Key: Any],
                                 indent: CGFloat, line: NSRect, in dirtyRect: NSRect) -> NSRect? {
        let size = (label as NSString).size(withAttributes: attributes)
        let rect = NSRect(x: textContainerOrigin.x + indent - markerGap - size.width,
                          y: line.midY - size.height / 2,
                          width: size.width, height: size.height)
        guard rect.intersects(dirtyRect) else { return rect }
        (label as NSString).draw(in: rect, withAttributes: attributes)
        return rect
    }

    private func drawMarkdownTasks(in dirtyRect: NSRect) {
        guard !markdownTasks.isEmpty else { return }
        let origin = textContainerOrigin
        for task in markdownTasks {
            guard task.sourceRange.length > 0,
                  let line = markdownLineBox(at: task.sourceRange.location) else { continue }
            switch leadDisplay(for: task.sourceRange) {
            case .inText:
                continue
            case .source:
                markerRectsForTesting[task.sourceRange.location] = drawMarginLabel(
                    leadSource(task.sourceRange), attributes: leadSourceAttributes,
                    indent: task.indent, line: line, in: dirtyRect)
                markerLabelsForTesting[task.sourceRange.location] = leadSource(task.sourceRange)
                continue
            case .rendered:
                break
            }
            // The box hangs in the margin, as a bullet does, the text after it.
            let side = min(14, max(10, line.height - 8))
            let box = NSRect(x: origin.x + task.indent - markerGap - side,
                             y: line.midY - side / 2,
                             width: side, height: side)
            markerRectsForTesting[task.sourceRange.location] = box
            markerLabelsForTesting[task.sourceRange.location] = task.checked ? "☑" : "☐"
            guard box.intersects(dirtyRect) else { continue }
            let outline = NSBezierPath(roundedRect: box, xRadius: 2.5, yRadius: 2.5)
            if task.checked {
                Theme.blue.setFill()
                outline.fill()
                NSColor.white.setStroke()
                let check = NSBezierPath()
                check.lineWidth = 1.6
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                check.move(to: NSPoint(x: box.minX + side * 0.24,
                                       y: box.midY))
                check.line(to: NSPoint(x: box.minX + side * 0.43,
                                       y: box.maxY - side * 0.27))
                check.line(to: NSPoint(x: box.maxX - side * 0.20,
                                       y: box.minY + side * 0.27))
                check.stroke()
            } else {
                Theme.dimText.setStroke()
                outline.lineWidth = 1.2
                outline.stroke()
            }
        }
    }

    private func drawMarkdownLineMarkers(in dirtyRect: NSRect) {
        guard !markdownLineMarkers.isEmpty, let layoutManager else { return }
        let origin = textContainerOrigin
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: Theme.markdownFont(), .foregroundColor: Theme.dimText,
        ]
        for marker in markdownLineMarkers {
            switch marker.kind {
            case .quote:
                // One bar down the whole quote, every line of it — including
                // those that do not repeat its `>`. From its first drawn
                // character: the hidden `>` before it belongs to the line above.
                let start = firstDrawnCharacter(from: marker.sourceRange.location)
                let quote = NSRange(location: start,
                                    length: max(0, NSMaxRange(marker.sourceRange) - start))
                let glyphs = layoutManager.glyphRange(
                    forCharacterRange: quote, actualCharacterRange: nil)
                guard glyphs.length > 0 else { continue }
                var union = NSRect.null
                layoutManager.enumerateLineFragments(forGlyphRange: glyphs) {
                    fragment, _, _, _, _ in union = union.union(fragment)
                }
                guard !union.isNull else { continue }
                let bar = NSRect(x: origin.x + marker.indent + 1, y: union.minY + origin.y,
                                 width: 3, height: union.height)
                guard bar.intersects(dirtyRect) else { continue }
                Theme.dimText.withAlphaComponent(0.45).setFill()
                bar.fill()
                markerRectsForTesting[marker.sourceRange.location] = bar
            case .bullet, .footnote, .heading:
                guard let line = markdownLineBox(at: marker.sourceRange.location) else {
                    continue
                }
                let display = leadDisplay(for: marker.sourceRange)
                let label: String
                var attributes = labelAttributes
                switch (display, marker.kind) {
                case (.inText, _):
                    continue
                case (.source, _):
                    label = leadSource(marker.sourceRange)
                    attributes = leadSourceAttributes
                case (.rendered, .footnote(let identifier)):
                    label = "\(identifier)."
                case (.rendered, .bullet(let text)):
                    label = text
                default:
                    // A heading draws nothing of its marker until it is edited.
                    continue
                }
                // Right-aligned against the text, so a column of numbers lines
                // up on its full stops and every item's text starts together.
                markerRectsForTesting[marker.sourceRange.location] = drawMarginLabel(
                    label, attributes: attributes, indent: marker.indent,
                    line: line, in: dirtyRect)
                markerLabelsForTesting[marker.sourceRange.location] = label
            }
        }
    }

    /// Where each marker was last drawn, by the location of its source, and
    /// what it said.
    private(set) var markerRectsForTesting: [Int: NSRect] = [:]
    private(set) var markerLabelsForTesting: [Int: String] = [:]
    /// Where each code block's box was last drawn, by where its code starts.
    private(set) var codeBoxRectsForTesting: [Int: NSRect] = [:]

    private func drawMarkdownRules(in dirtyRect: NSRect) {
        guard !markdownRules.isEmpty, let layoutManager else { return }
        let origin = textContainerOrigin
        let length = (string as NSString).length
        for rule in markdownRules {
            // Decorations from the document this view held last, if it has
            // been handed another one since.
            guard rule.lineRange.length > 0, NSMaxRange(rule.lineRange) <= length else { continue }
            let anchor = NSMaxRange(rule.lineRange) - 1
            let glyph = layoutManager.glyphIndexForCharacter(at: anchor)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph,
                                                           effectiveRange: nil)
            let y = fragment.midY + origin.y
            let rect = NSRect(x: origin.x + 4, y: y,
                              width: max(0, bounds.width - origin.x * 2 - 8), height: 1)
            guard rect.intersects(dirtyRect) else { continue }
            Theme.border.setFill()
            rect.fill()
        }
    }

    private func drawMarkdownImages(in dirtyRect: NSRect) {
        guard !markdownImages.isEmpty, let layoutManager else { return }
        let origin = textContainerOrigin
        let available = max(80, bounds.width - origin.x * 2)
        for decoration in markdownImages {
            if let active = markdownActiveSourceRange,
               NSIntersectionRange(active, decoration.sourceRange).length > 0 { continue }
            let anchor = decoration.lineRange.length > decoration.sourceRange.length
                ? NSMaxRange(decoration.lineRange) - 1 : decoration.sourceRange.location
            let glyph = layoutManager.glyphIndexForCharacter(at: anchor)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph,
                                                           effectiveRange: nil)
            let row = NSRect(x: 0, y: fragment.minY + origin.y,
                             width: bounds.width, height: fragment.height)
            guard row.intersects(dirtyRect) else { continue }
            Theme.editorBackground.setFill()
            row.fill()
            if let image = markdownImage(decoration), image.size.width > 0,
               image.size.height > 0 {
                let scale = min(1, available / image.size.width,
                                max(1, row.height - 8) / image.size.height)
                let size = NSSize(width: floor(image.size.width * scale),
                                  height: floor(image.size.height * scale))
                let rect = NSRect(x: origin.x, y: row.midY - size.height / 2,
                                  width: size.width, height: size.height)
                image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                           respectFlipped: true, hints: nil)
            } else {
                let label = decoration.alt.isEmpty ? "Image" : decoration.alt
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: Theme.editorFont(), .foregroundColor: Theme.dimText,
                ]
                let icon = Theme.symbol("photo", accessibilityDescription: "Image",
                                        pointSize: 13)
                icon?.draw(in: NSRect(x: origin.x, y: row.midY - 7,
                                      width: 14, height: 14))
                (label as NSString).draw(
                    in: NSRect(x: origin.x + 20, y: row.midY - 9,
                               width: max(0, available - 20), height: 18),
                    withAttributes: attributes)
            }
        }
    }

    private func drawDiffBands() {
        guard !diffBands.isEmpty, let layoutManager, let container = textContainer else { return }
        let inset = textContainerInset
        let visible = visibleRect
        // A horizontally scrolling text container is intentionally configured
        // with an unbounded width. Never turn that sentinel into a draw rect:
        // enormous fills escape normal clip/layer tiling and appear fixed while
        // the document scrolls. Use finite laid-out content/view coordinates.
        let laidOutWidth = layoutManager.usedRect(for: container).maxX
            + inset.width * 2
        let width = max(bounds.width, visible.maxX, laidOutWidth)
        let length = (string as NSString).length

        for band in diffBands {
            let clamped = NSIntersectionRange(band.range, NSRange(location: 0, length: length))
            guard clamped.length > 0 else { continue }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: clamped,
                                                      actualCharacterRange: nil)
            guard glyphRange.length > 0 else { continue }
            band.color.setFill()
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragRect, _, _, _, _ in
                var r = fragRect
                r.origin.x = 0
                r.size.width = width
                r = r.offsetBy(dx: 0, dy: inset.height)
                if r.intersects(visible.insetBy(dx: 0, dy: -r.height)) { r.fill() }
            }
        }
    }

    /// Every match gets a heavy rule under it, in the accent yellow for the one
    /// the ↑↓ buttons are on and in red for the rest. Underlining is the only
    /// marking that leaves the code exactly as it was: the glyphs keep their
    /// syntax colours, and a selection sitting on the match keeps its own.
    private func drawSearchUnderlines() {
        guard !searchMatches.isEmpty,
              let layoutManager, let container = textContainer else { return }
        let inset = textContainerInset
        let notSelected = NSRange(location: NSNotFound, length: 0)
        let visibleContainerRect = visibleRect.offsetBy(dx: -inset.width, dy: -inset.height)
        let visibleGlyphs = layoutManager.glyphRange(
            forBoundingRect: visibleContainerRect, in: container)
        let visibleCharacters = layoutManager.characterRange(
            forGlyphRange: visibleGlyphs, actualGlyphRange: nil)

        for (index, range) in searchMatches.enumerated() {
            let clamped = NSIntersectionRange(range,
                                              NSRange(location: 0, length: (string as NSString).length))
            guard clamped.length > 0,
                  NSIntersectionRange(clamped, visibleCharacters).length > 0,
                  // Hidden text — a fold that stayed shut, Markdown syntax the
                  // renderer suppressed — has no glyph run to underline, and
                  // asking for one back gives the whole line fragment.
                  foldingManager?.isCharacterHidden(at: clamped.location) != true
            else { continue }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: clamped,
                                                      actualCharacterRange: nil)
            guard glyphRange.length > 0 else { continue }
            (index == self.currentMatchIndex
                ? Theme.currentMatchUnderline : Theme.matchUnderline).setFill()

            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphRange,
                withinSelectedGlyphRange: notSelected,
                in: container
            ) { enclosing, _ in
                self.underlineRect(for: enclosing).fill()
            }
        }
    }

    /// The rule for one run of matched glyphs, positioned off the text baseline
    /// rather than off the line fragment: the configured row is twice the
    /// height of the glyphs, and a rule at the bottom of the row would float
    /// halfway to the line below.
    private func underlineRect(for enclosing: NSRect) -> NSRect {
        guard let layoutManager, let container = textContainer else { return .zero }
        let inset = textContainerInset
        let glyph = layoutManager.glyphIndex(for: NSPoint(x: enclosing.midX,
                                                          y: enclosing.midY),
                                             in: container)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let baseline = fragment.minY + layoutManager.location(forGlyphAt: glyph).y
        let pen = Theme.matchUnderlineWidth
        // The row height is a setting: on a tight one the rule rides up against
        // the baseline rather than hanging into the line below.
        let top = min(baseline + Theme.matchUnderlineOffset, fragment.maxY - pen)
            + inset.height
        return NSRect(x: enclosing.minX + inset.width, y: top,
                      width: enclosing.width, height: pen)
    }

    /// The rules `drawSearchUnderlines` would fill, ignoring what is on screen.
    /// Keeps the highlight geometry checkable without a live scroll view.
    func matchHighlightRectsForTesting() -> [NSRect] {
        guard let layoutManager, let container = textContainer else { return [] }
        var rects: [NSRect] = []
        for range in searchMatches {
            let glyphs = layoutManager.glyphRange(forCharacterRange: range,
                                                  actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphs,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: container
            ) { enclosing, _ in
                rects.append(self.underlineRect(for: enclosing))
            }
        }
        return rects
    }

    /// Vertical geometry of just the glyphs inside a line fragment. Search-match
    /// decorations use this smaller box; row-level decorations use the complete
    /// `code_line_height` fragment.
    private func glyphBox(fragmentHeight: CGFloat) -> (top: CGFloat, height: CGFloat) {
        let font = self.font ?? Theme.editorFont()
        let height = font.ascender - font.descender
        return ((fragmentHeight - height) / 2, height)
    }

    /// The line fragment the caret sits in, handling the trailing empty line —
    /// which lives in `extraLineFragmentRect` and is never visited by
    /// `enumerateLineFragments`, so the band used to be missing there.
    private func caretLineFragment(at resultLocation: Int? = nil) -> NSRect? {
        guard let layoutManager, let container = textContainer else { return nil }
        let ns = string as NSString
        let location = min(resultLocation ?? selectedRange().location, ns.length)

        // Source documents lay out on demand. In particular, an edit at EOF
        // invalidates the extra fragment, so make the caret's layout current
        // before reading either its ordinary or trailing-empty-line geometry.
        layoutManager.ensureLayout(forCharacterRange: NSRange(
            location: location, length: location < ns.length ? 1 : 0))

        // Caret past the final newline => the extra (empty) line fragment.
        if layoutManager.extraLineFragmentTextContainer === container,
           location == ns.length,
           ns.length == 0 || ns.character(at: ns.length - 1) == 0x0A {
            return layoutManager.extraLineFragmentRect
        }
        guard layoutManager.numberOfGlyphs > 0 else { return layoutManager.extraLineFragmentRect }
        let glyphIndex = min(layoutManager.glyphIndexForCharacter(at: location),
                             layoutManager.numberOfGlyphs - 1)
        return layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
    }

    /// Rect of the current-line band, in view coordinates. Shared by drawing and
    /// by the tests so they can't drift apart.
    /// False while the pane has no open document — otherwise the empty editor
    /// would show a stray band (the "row line" in the blank area).
    var showsCurrentLineBand = true {
        didSet {
            guard showsCurrentLineBand != oldValue else { return }
            needsDisplay = true
        }
    }

    func currentLineBandRect() -> NSRect? {
        // Nothing is being worked on in a buffer that cannot be typed into, so
        // no line is the active one: a diff is read, not edited. The gutter
        // still underlines the caret's line — that is where the pointer left
        // off, which is worth knowing while reading.
        guard isEditable else { return nil }
        if searchResultLineLocation == nil {
            guard showsCurrentLineBand,
                  selectedRanges.count == 1, selectedRange().length == 0 else { return nil }
        }
        guard let fragment = caretLineFragment(at: searchResultLineLocation) else { return nil }
        // The no-wrap container's width is an unbounded layout sentinel, not
        // drawable geometry. Feeding it to a fill loses the row's position and
        // height in Core Graphics. Paint the finite document canvas instead;
        // that covers the viewport after horizontal scrolling as well.
        return NSRect(x: bounds.minX,
                      y: fragment.minY + textContainerOrigin.y,
                      width: max(bounds.width, visibleRect.maxX - bounds.minX),
                      height: fragment.height)
    }

    private func drawCurrentLineBand() {
        guard let rect = currentLineBandRect() else { return }
        Theme.lineHighlight.setFill()
        rect.fill()
    }

    /// The caret uses the complete configured code row, matching the active
    /// line background exactly — or, in rendered Markdown, the height of the
    /// line it is on: a heading's, or a line of prose, not the code row.
    func caretRect(from rect: NSRect) -> NSRect {
        var r = rect
        r.size.height = Theme.lineMetrics().target
        r.size.width = 2
        guard let foldingManager, let container = textContainer else { return r }
        let origin = textContainerOrigin
        let point = NSPoint(x: max(0, rect.minX - origin.x), y: rect.midY - origin.y)
        let glyph = foldingManager.glyphIndex(for: point, in: container)
        guard let placed = foldingManager.markdownTextBox(forGlyphAt: glyph),
              point.y >= placed.fragment.minY, point.y <= placed.fragment.maxY else { return r }
        r.origin.y = placed.text.minY + origin.y
        r.size.height = placed.text.height
        return r
    }

    /// In rendered Markdown the caret also says what typing would be: thicker
    /// in bold, slanted in italic, capped at both ends in code — the only way
    /// to tell the two places at a hidden `**` apart.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        let caret = caretRect(from: rect)
        let formats = caretFormats
        guard flag, !formats.isEmpty else {
            // Whatever the caret was, a slanted one reaches past the rect.
            if rendersMarkdown {
                setNeedsDisplay(NSRect(x: caret.minX - Self.codeCaretCap - 1, y: caret.minY,
                                       width: caret.width + Self.italicCaretSlant(caret)
                                        + Self.codeCaretCap * 2 + 3,
                                       height: caret.height))
            }
            super.drawInsertionPoint(in: caret, color: color, turnedOn: flag)
            return
        }
        color.setFill()
        Self.caretShape(in: caret, formats: formats).fill()
    }

    static func caretShape(in caret: NSRect,
                           formats: Set<MarkdownSpanDecoration.Kind>) -> NSBezierPath {
        let width: CGFloat = formats.contains(.strong) ? 3 : caret.width
        let slant = formats.contains(.emphasis) ? italicCaretSlant(caret) : 0
        let path = NSBezierPath()
        path.move(to: NSPoint(x: caret.minX, y: caret.maxY))
        path.line(to: NSPoint(x: caret.minX + width, y: caret.maxY))
        path.line(to: NSPoint(x: caret.minX + width + slant, y: caret.minY))
        path.line(to: NSPoint(x: caret.minX + slant, y: caret.minY))
        path.close()
        if formats.contains(.code) {
            let cap = codeCaretCap
            path.append(NSBezierPath(rect: NSRect(x: caret.minX + slant - cap, y: caret.minY,
                                                  width: width + cap * 2, height: 2)))
            path.append(NSBezierPath(rect: NSRect(x: caret.minX - cap, y: caret.maxY - 2,
                                                  width: width + cap * 2, height: 2)))
        }
        return path
    }

    private static func italicCaretSlant(_ caret: NSRect) -> CGFloat {
        round(caret.height * 0.18)
    }
    private static let codeCaretCap: CGFloat = 2

    /// Lay the caret's own line out before the caret is placed on it.
    ///
    /// Non-contiguous layout is on, so TextKit is free to leave a freshly
    /// edited line unlaid until something asks. NSTextView does not ask: it
    /// reads the insertion point's rect straight from the layout manager and
    /// gets the stale answer — which is why Return on an indented line drew the
    /// caret at column zero, on the line above, until the next keystroke forced
    /// the layout and it jumped to where it had been all along.
    override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
        if let layoutManager, layoutManager.allowsNonContiguousLayout {
            let source = string as NSString
            let caret = min(selectedRange().location, source.length)
            layoutManager.ensureLayout(
                forCharacterRange: source.lineRange(for: NSRange(location: caret, length: 0)))
        }
        super.updateInsertionPointStateAndRestartTimer(restartFlag)
    }

    /// Home and End. AppKit binds them to the document ends, which in an editor
    /// is what ⌘↑ and ⌘↓ are for; every other editor on this machine puts them
    /// on the line's ends, and those keep their own bindings.
    override func scrollToBeginningOfDocument(_ sender: Any?) {
        let source = string as NSString
        let caret = min(selectedRange().location, source.length)
        var start = 0
        var contentEnd = 0
        source.getLineStart(&start, end: nil, contentsEnd: &contentEnd,
                            for: NSRange(location: caret, length: 0))
        var target = start
        while target < contentEnd,
              let scalar = UnicodeScalar(source.character(at: target)),
              CharacterSet.whitespaces.contains(scalar) {
            target += 1
        }
        // Whitespace-only lines have no text to target. Stay at their column
        // zero, without stepping across a newline or toggling on repeated Home.
        if target == contentEnd { target = start }
        let selection = NSRange(location: target, length: 0)
        setSelectedRange(selection)
        scrollRangeToVisible(selection)
    }

    override func scrollToEndOfDocument(_ sender: Any?) {
        moveToEndOfLine(sender)
    }

    override func mouseDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == [.command],
           let location = commandClickCharacterIndex(for: event),
           onCommandClick?(location) == true {
            return
        }
        onExplicitCaretInteraction?()
        super.mouseDown(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard commandHoverTrackingArea == nil else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved,
                      .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        commandHoverTrackingArea = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let commandModifierMonitor {
            NSEvent.removeMonitor(commandModifierMonitor)
            self.commandModifierMonitor = nil
        }
        if let scopeFlowScrollObserver {
            NotificationCenter.default.removeObserver(scopeFlowScrollObserver)
            self.scopeFlowScrollObserver = nil
        }
        guard window != nil else {
            clearCommandHover()
            scopeFlow?.isHidden = true
            return
        }
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            scopeFlowScrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in self?.syncScopeFlow() }
        }
        scheduleScopeFlowSync()
        // flagsChanged is normally delivered only to the first responder. A
        // local monitor also clears/starts the underline when focus is in the
        // sidebar or find bar while the pointer is stationary over code.
        commandModifierMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .flagsChanged) { [weak self] event in
                self?.handleCommandModifierChange(event)
                return event
            }
    }

    deinit {
        if let commandModifierMonitor { NSEvent.removeMonitor(commandModifierMonitor) }
        if let scopeFlowScrollObserver { NotificationCenter.default.removeObserver(scopeFlowScrollObserver) }
        if let caretLinkScrollObserver {
            NotificationCenter.default.removeObserver(caretLinkScrollObserver)
        }
        caretLinkBar.close()
    }

    override func mouseEntered(with event: NSEvent) { updateCommandHover(with: event) }
    override func mouseMoved(with event: NSEvent) {
        updateCommandHover(with: event)
        updateLinkHover(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        clearCommandHover()
        updateLinkHover(with: nil)
    }

    // MARK: - Markdown link hover

    /// Links in the rendered document, and the one the pointer is on.
    private(set) var markdownLinks: [MarkdownLinkDecoration] = []
    private var hoveredLink: MarkdownLinkDecoration?
    private let linkCard = MarkdownLinkCard()
    private var linkHoverWork: DispatchWorkItem?
    /// Long enough that crossing a link on the way somewhere else does not
    /// open anything — the delay every editor's hover card uses.
    private static let linkHoverDelay: TimeInterval = 0.35

    /// Show what a link points at while the pointer rests on it. Nothing here
    /// follows a link on its own: the address on the card is what is clicked.
    private func updateLinkHover(with event: NSEvent?) {
        guard !markdownLinks.isEmpty else {
            if hoveredLink != nil { hideLinkPopover() }
            return
        }
        let link = event.flatMap { event -> MarkdownLinkDecoration? in
            guard let index = characterIndex(atWindowPoint: event.locationInWindow) else {
                return nil
            }
            return markdownLinks.first { NSLocationInRange(index, $0.sourceRange) }
        }.flatMap { link in
            // The caret's link has its bar already.
            caretLink?.sourceRange == link.sourceRange && caretLinkBar.isVisible ? nil : link
        }
        guard link?.sourceRange != hoveredLink?.sourceRange else { return }
        linkHoverWork?.cancel()
        guard let link else {
            // The pointer may have travelled onto the card itself, which is a
            // window of its own and stops sending this view mouse events.
            guard !pointerIsOverLinkPopover else { return }
            hideLinkPopover()
            return
        }
        hoveredLink = link
        let work = DispatchWorkItem { [weak self] in self?.showLinkPopover(for: link) }
        linkHoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.linkHoverDelay, execute: work)
    }

    private var pointerIsOverLinkPopover: Bool {
        guard linkCard.isVisible else { return false }
        return linkCard.screenFrame.insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation)
    }

    private func showLinkPopover(for link: MarkdownLinkDecoration) {
        guard hoveredLink?.sourceRange == link.sourceRange,
              let layoutManager, let textContainer, let window else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: link.sourceRange,
                                              actualCharacterRange: nil)
        var anchor = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        anchor.origin.x += textContainerOrigin.x
        anchor.origin.y += textContainerOrigin.y
        let onScreen = window.convertToScreen(convert(anchor, to: nil))
        linkCard.onOpen = { [weak self] in
            self?.hideLinkPopover()
            self?.onOpenLink?(link)
        }
        linkCard.show(destination: link.destination, above: onScreen, in: window)
    }

    private func hideLinkPopover() {
        linkHoverWork?.cancel()
        linkHoverWork = nil
        hoveredLink = nil
        linkCard.close()
    }

    /// What clicking the address on the card does. Set by the pane, which
    /// owns the decision.
    var onOpenLink: ((MarkdownLinkDecoration) -> Void)?
    var linkCardForTesting: MarkdownLinkCard { linkCard }

    // MARK: - The caret's link

    /// The link the caret is in, whose address the bar under it shows: the
    /// address is hidden in the text, and editing no longer shows it.
    private var caretLink: MarkdownLinkDecoration?
    private var caretLinkEditable = false
    private let caretLinkBar = MarkdownLinkCard()
    private var caretLinkScrollObserver: NSObjectProtocol?
    /// The bar's Edit: the pane shows the link as written.
    var onEditLink: ((MarkdownLinkDecoration) -> Void)?

    func setCaretLink(_ link: MarkdownLinkDecoration?, editable: Bool) {
        guard link != caretLink || editable != caretLinkEditable || link != nil else { return }
        caretLink = link
        caretLinkEditable = editable
        // The bar says what the hover card would.
        if let link, hoveredLink?.sourceRange == link.sourceRange { hideLinkPopover() }
        placeCaretLinkBar()
    }

    /// Under the link, while this view has the caret and the link is in sight.
    private func placeCaretLinkBar() {
        guard let link = caretLink, let window, window.firstResponder === self,
              let layoutManager, let textContainer,
              NSMaxRange(link.sourceRange) <= (string as NSString).length else {
            caretLinkBar.close()
            return
        }
        let glyphs = layoutManager.glyphRange(forCharacterRange: link.sourceRange,
                                              actualCharacterRange: nil)
        var anchor = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        anchor.origin.x += textContainerOrigin.x
        anchor.origin.y += textContainerOrigin.y
        guard visibleRect.intersects(anchor) else {
            caretLinkBar.close()
            return
        }
        let onScreen = window.convertToScreen(convert(anchor, to: nil))
        caretLinkBar.onOpen = { [weak self] in self?.onOpenLink?(link) }
        caretLinkBar.onEdit = caretLinkEditable
            ? { [weak self] in self?.onEditLink?(link) } : nil
        caretLinkBar.show(destination: link.destination, below: onScreen, in: window)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let caretLinkScrollObserver {
            NotificationCenter.default.removeObserver(caretLinkScrollObserver)
            self.caretLinkScrollObserver = nil
        }
        guard let clip = superview as? NSClipView else { return }
        clip.postsBoundsChangedNotifications = true
        caretLinkScrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip,
            queue: .main) { [weak self] _ in
            guard let self, self.caretLink != nil else { return }
            self.placeCaretLinkBar()
        }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became, caretLink != nil { placeCaretLinkBar() }
        return became
    }

    var caretLinkBarForTesting: MarkdownLinkCard { caretLinkBar }

    // MARK: - Marks at the edges of formatting

    /// Formatting the caret is in or at the edge of, whose hidden delimiters
    /// are drawn faintly at its edges.
    private var markdownSpanMarks: [MarkdownSpanDecoration] = []

    func setMarkdownSpanMarks(_ spans: [MarkdownSpanDecoration]) {
        guard spans != markdownSpanMarks else { return }
        markdownSpanMarks = spans
        needsDisplay = true
    }

    /// One mark: the delimiters on one side of a span — or of several, when
    /// they meet, as `***` does — drawn small, above the capitals, outside the
    /// text they close: an opening one ends where the text starts, a closing
    /// one starts where it ends. Laid over the text, so nothing moves to make
    /// room — and above it, where all they cross is the odd ascender.
    private func markdownSpanMarkLayout() -> [(text: String, rect: NSRect)] {
        guard !markdownSpanMarks.isEmpty, let layoutManager, let textContainer,
              let folding = foldingManager else { return [] }
        let source = string as NSString
        var runs: [(range: NSRange, opens: Bool)] = []
        for span in markdownSpanMarks {
            runs.append((span.opening, true))
            runs.append((span.closing, false))
        }
        runs.sort { $0.range.location < $1.range.location }
        var merged: [(range: NSRange, opens: Bool)] = []
        for run in runs {
            if let last = merged.last, last.opens == run.opens,
               NSMaxRange(last.range) == run.range.location {
                merged[merged.count - 1].range.length += run.range.length
            } else if merged.last?.range != run.range {
                merged.append(run)
            }
        }
        let font = Self.spanMarkFont
        let prose = Theme.markdownFont()
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let origin = textContainerOrigin
        var marks: [(text: String, rect: NSRect)] = []
        for run in merged {
            guard NSMaxRange(run.range) <= source.length,
                  folding.isCharacterHidden(at: run.range.location) else { continue }
            // The character the mark sits against: the first one after an
            // opening run, the last one before a closing run.
            let neighbour = run.opens ? NSMaxRange(run.range) : run.range.location - 1
            guard neighbour >= 0, neighbour < source.length,
                  !folding.isCharacterHidden(at: neighbour) else { continue }
            let glyph = layoutManager.glyphIndexForCharacter(at: neighbour)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph,
                                                          effectiveRange: nil)
            let location = layoutManager.location(forGlyphAt: glyph)
            let glyphBox = layoutManager.boundingRect(
                forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
            let text = source.substring(with: run.range)
            let measured = (text as NSString).size(withAttributes: attributes)
            let edge = run.opens ? fragment.minX + location.x : glyphBox.maxX
            let baseline = fragment.minY + location.y - prose.capHeight
            let rect = NSRect(x: origin.x + (run.opens ? edge - measured.width - 0.5 : edge + 0.5),
                              y: origin.y + baseline - font.ascender,
                              width: ceil(measured.width), height: ceil(measured.height))
            marks.append((text, rect))
        }
        return marks
    }

    private func drawMarkdownSpanMarks(in dirtyRect: NSRect) {
        let marks = markdownSpanMarkLayout()
        guard !marks.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.spanMarkFont, .foregroundColor: Theme.dimText,
        ]
        for mark in marks where mark.rect.intersects(dirtyRect) {
            (mark.text as NSString).draw(at: mark.rect.origin, withAttributes: attributes)
        }
    }

    private static var spanMarkFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: round(Theme.markdownFontSize() * 0.55),
                                    weight: .regular)
    }

    var spanMarksForTesting: [(text: String, rect: NSRect)] { markdownSpanMarkLayout() }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        handleCommandModifierChange(event)
    }

    private func handleCommandModifierChange(_ event: NSEvent) {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
              let window, window.isKeyWindow else {
            clearCommandHover()
            return
        }
        let point = window.mouseLocationOutsideOfEventStream
        let local = convert(point, from: nil)
        guard bounds.contains(local) else {
            clearCommandHover()
            return
        }
        updateCommandHover(atWindowPoint: point)
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        guard NSEvent.modifierFlags.contains(.command), let window else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.updateCommandHover(atWindowPoint: window.mouseLocationOutsideOfEventStream)
        }
    }

    private func updateCommandHover(with event: NSEvent) {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .contains(.command) else {
            clearCommandHover()
            return
        }
        updateCommandHover(atWindowPoint: event.locationInWindow)
    }

    private func updateCommandHover(atWindowPoint point: NSPoint) {
        guard let location = characterIndex(atWindowPoint: point) else {
            clearCommandHover()
            return
        }
        onCommandHover?(location)
    }

    private func clearCommandHover() {
        onCommandHover?(nil)
        commandHoverRange = nil
    }

    private func commandClickCharacterIndex(for event: NSEvent) -> Int? {
        characterIndex(atWindowPoint: event.locationInWindow)
    }

    private func characterIndex(atWindowPoint windowPoint: NSPoint) -> Int? {
        guard let layoutManager, let textContainer, !string.isEmpty else { return nil }
        let local = convert(windowPoint, from: nil)
        let point = NSPoint(x: local.x - textContainerOrigin.x,
                            y: local.y - textContainerOrigin.y)
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        guard glyphRange.length > 0 else { return nil }
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(
            for: point, in: textContainer, fractionOfDistanceThroughGlyph: &fraction)
        guard NSLocationInRange(glyph, glyphRange) else { return nil }
        let line = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph,
                                                       effectiveRange: nil)
        guard point.y >= line.minY, point.y <= line.maxY,
              point.x >= line.minX, point.x <= line.maxX + 2 else { return nil }
        return layoutManager.characterIndexForGlyph(at: glyph)
    }

    /// The editor gave up focus — clicked away from, or the window went
    /// inactive. What that is worth saving is the pane's business.
    var onLostFocus: (() -> Void)?

    /// The column the text is set in, centred, following the pane's width
    /// between its narrowest and widest. `nil` for source, which fills the pane: a line of code means
    /// something at column 120, and moving it would misrepresent the file.
    /// Rendered Markdown is prose, and prose read across a full-width window is
    /// hard to track from one line to the next.
    var readingColumn: MarkdownColumn? {
        didSet {
            guard readingColumn != oldValue else { return }
            applyReadingInset()
        }
    }
    /// The insets the pane configured, before any centring.
    private var baseHorizontalInset: CGFloat = 6
    private var baseVerticalInset: CGFloat = 0
    func rememberBaseInset() {
        baseHorizontalInset = textContainerInset.width
        baseVerticalInset = textContainerInset.height
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyReadingInset()
    }

    /// Room above the text, left by the pane when the text above the caret
    /// got shorter by more than the view could scroll back up: the caret's
    /// line stays put, the page above it grows instead. The pane takes it back
    /// once it is out of sight.
    var topSlack: CGFloat = 0 {
        didSet {
            guard topSlack != oldValue else { return }
            applyReadingInset()
        }
    }

    private func applyReadingInset() {
        guard let readingColumn else {
            setInset(width: baseHorizontalInset, height: baseVerticalInset + topSlack)
            return
        }
        // Centred; never narrower than the pane's own margin. A document also
        // starts a little way down the page rather than against the tabs.
        setInset(width: readingColumn.inset(forWidth: bounds.width, base: baseHorizontalInset),
                 height: max(baseVerticalInset, Theme.markdownTopInset) + topSlack)
    }

    private func setInset(width: CGFloat, height: CGFloat) {
        guard abs(textContainerInset.width - width) > 0.01
                || abs(textContainerInset.height - height) > 0.01 else { return }
        textContainerInset = NSSize(width: width, height: height)
        // Decorations are drawn from the inset, and the container's width is
        // derived from it, so both have to be redrawn from scratch.
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            caretLinkBar.close()
            onLostFocus?()
        }
        return resigned
    }

    /// VS Code's macOS folding shortcuts: ⌥⌘[ toggles the innermost block at
    /// the caret, and ⌥⌘] unfolds the pane.
    override func keyDown(with event: NSEvent) {
        onExplicitCaretInteraction?()
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 51, modifiers == [.shift] {
            deleteCurrentLine()
            return
        }
        // Return on the line, not in it: the caret can be anywhere and still
        // start a fresh line underneath.
        if event.keyCode == 36, modifiers == [.shift] {
            insertLineBelow()
            return
        }
        if event.keyCode == 2, modifiers == [.command] {   // D
            duplicateCurrentLine()
            return
        }
        if modifiers.contains([.command, .option]),
           let key = event.charactersIgnoringModifiers {
            if key == "[", let block = innermostBlock(at: selectedRange().location) {
                toggleFold(block)
                return
            }
            if key == "]" {
                unfoldAllCodeBlocks()
                return
            }
        }
        super.keyDown(with: event)
    }

    /// Shift+Backspace removes the complete logical line at the insertion
    /// point. For a final line without its own terminator, consume the previous
    /// newline too so no empty replacement line is left behind.
    @discardableResult
    func deleteCurrentLine() -> Bool {
        let source = string as NSString
        guard source.length > 0 else { return false }
        let caret = min(selectedRange().location, source.length)
        var range: NSRange

        if caret == source.length,
           source.character(at: source.length - 1) == 0x0A {
            let length = source.length >= 2
                && source.character(at: source.length - 2) == 0x0D ? 2 : 1
            range = NSRange(location: source.length - length, length: length)
        } else {
            let probe = min(caret, source.length - 1)
            range = source.lineRange(for: NSRange(location: probe, length: 0))
            if NSMaxRange(range) == source.length, range.location > 0 {
                let previous = source.character(at: range.location - 1)
                if previous == 0x0A {
                    let prefix = range.location >= 2
                        && source.character(at: range.location - 2) == 0x0D ? 2 : 1
                    range.location -= prefix
                    range.length += prefix
                } else if previous == 0x0D {
                    range.location -= 1
                    range.length += 1
                }
            }
        }

        guard range.length > 0,
              shouldChangeText(in: range, replacementString: "") else { return false }
        textStorage?.replaceCharacters(in: range, with: "")
        didChangeText()
        setSelectedRange(NSRange(location: min(range.location, (string as NSString).length),
                                 length: 0))
        refreshBracketMatches()
        return true
    }


    // MARK: - Line editing

    /// The whitespace a new line inherits from the line at `location`: its own
    /// leading run of spaces and tabs, cut at the caret when the caret is still
    /// inside that run, so splitting an indent does not duplicate it.
    private func carriedIndent(at location: Int) -> String {
        let source = string as NSString
        let line = source.lineRange(for: NSRange(location: location, length: 0))
        var end = line.location
        let limit = min(NSMaxRange(line), source.length)
        while end < limit {
            let character = source.character(at: end)
            guard character == 0x20 || character == 0x09 else { break }
            end += 1
        }
        end = min(end, max(location, line.location))
        guard end > line.location else { return "" }
        return source.substring(with: NSRange(location: line.location,
                                              length: end - line.location))
    }

    /// Where the line at `location` stops carrying text, before whatever
    /// terminates it. Inserting here appends to the line rather than to the one
    /// below, and works the same on a final line with no terminator at all.
    private func endOfLineContent(at location: Int) -> Int {
        let source = string as NSString
        let line = source.lineRange(for: NSRange(location: location, length: 0))
        var end = NSMaxRange(line)
        if end > line.location, source.character(at: end - 1) == 0x0A { end -= 1 }
        if end > line.location, source.character(at: end - 1) == 0x0D { end -= 1 }
        return end
    }

    /// Whether Return deepens the indent after a `{`, `[` or `(`.
    ///
    /// Off for prose — a Markdown paragraph ending in a bracket is not opening
    /// a block — and for files with no language at all.
    var usesBracketIndent = true

    /// The characters that open a block, and what closes each of them.
    private static let brackets: [(open: Character, close: Character)] =
        [("{", "}"), ("[", "]"), ("(", ")")]

    /// One level of indentation, in whatever the line is already written in: a
    /// tab where the indent is tabs, `tab_size` spaces otherwise.
    private func indentUnit(matching indent: String) -> String {
        indent.contains("\t") ? "\t" : String(repeating: " ", count: max(1, Settings.shared.tabSize))
    }

    /// The bracket the line opens with, reading back from `location` over any
    /// trailing whitespace. Nil when the line ends on anything else.
    private func openerEndingLine(before location: Int) -> Character? {
        guard usesBracketIndent else { return nil }
        let source = string as NSString
        let line = source.lineRange(for: NSRange(location: location, length: 0))
        var index = min(location, NSMaxRange(line))
        while index > line.location {
            let character = source.character(at: index - 1)
            guard character == 0x20 || character == 0x09 else { break }
            index -= 1
        }
        guard index > line.location,
              let scalar = UnicodeScalar(source.character(at: index - 1)) else { return nil }
        let previous = Character(scalar)
        return Self.brackets.first { $0.open == previous }?.open
    }

    /// True when `closer` is the next thing after `location`, give or take
    /// spaces: the caret is sitting between a pair.
    private func closerFollows(_ closer: Character, after location: Int) -> Bool {
        let source = string as NSString
        var index = location
        while index < source.length {
            let character = source.character(at: index)
            if character == 0x20 || character == 0x09 { index += 1; continue }
            guard let scalar = UnicodeScalar(character) else { return false }
            return Character(scalar) == closer
        }
        return false
    }

    /// Typing a closing bracket on an otherwise empty line pulls that line back
    /// one level, so a block closes where it opened.
    ///
    /// This is the other half of the rule Return applies — VS Code calls the
    /// pair `increaseIndentPattern` / `decreaseIndentPattern`, and every editor
    /// that auto-indents does both. One level less, rather than hunting for the
    /// matching opener: the structure model is rebuilt on a debounce and would
    /// be a keystroke behind, while the line in front of the caret is not.
    ///
    /// The whitespace and the bracket are replaced together, so the dedent is
    /// part of typing the character and one ⌘Z takes both back.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard usesBracketIndent, selectedRange().length == 0,
              let typed = (string as? String) ?? (string as? NSAttributedString)?.string,
              typed.count == 1, let character = typed.first,
              Self.brackets.contains(where: { $0.close == character }) else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        let source = self.string as NSString
        let caret = min(selectedRange().location, source.length)
        let line = source.lineRange(for: NSRange(location: caret, length: 0))
        let prefix = source.substring(with: NSRange(location: line.location,
                                                    length: caret - line.location))
        guard !prefix.isEmpty,
              prefix.allSatisfy({ $0 == " " || $0 == "\t" }) else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        let unit = indentUnit(matching: prefix)
        guard prefix.hasSuffix(unit) else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        let dedented = String(prefix.dropLast(unit.count))
        super.insertText(dedented + typed,
                         replacementRange: NSRange(location: line.location,
                                                   length: caret - line.location))
    }

    /// A new line inherits the indentation of the one it came from, and one
    /// level more when that line opened a block. Splitting a pair puts the
    /// closer on a line of its own, which is what every editor does:
    ///
    ///     if x {|}        →      if x {
    ///                                |
    ///                            }
    override func insertNewline(_ sender: Any?) {
        let caret = min(selectedRange().location, (string as NSString).length)
        let indent = carriedIndent(at: caret)
        guard let opener = openerEndingLine(before: caret) else {
            guard !indent.isEmpty else {
                super.insertNewline(sender)
                return
            }
            insertText("\n" + indent, replacementRange: selectedRange())
            return
        }
        let inner = indent + indentUnit(matching: indent)
        let closer = Self.brackets.first { $0.open == opener }!.close
        guard closerFollows(closer, after: caret) else {
            insertText("\n" + inner, replacementRange: selectedRange())
            return
        }
        // The closer goes to its own line at the outer indent, and the caret
        // stays on the empty line between them.
        let text = "\n" + inner + "\n" + indent
        let replaced = selectedRange()
        insertText(text, replacementRange: replaced)
        setSelectedRange(NSRange(location: replaced.location + 1 + (inner as NSString).length,
                                 length: 0))
        scrollRangeToVisible(selectedRange())
    }

    /// Shift-Return: open a line under the current one, indented like it, from
    /// anywhere on the line. No need to walk the caret to the end first.
    @discardableResult
    func insertLineBelow() -> Bool {
        let source = string as NSString
        let caret = min(selectedRange().location, source.length)
        var indent = indentOfLine(at: caret)
        let insertion = endOfLineContent(at: caret)
        // Same rule as Return: a line that opened a block gets its body one
        // level in. There is no pair to split here — the line below is opened
        // from wherever the caret happens to be.
        if openerEndingLine(before: insertion) != nil {
            indent += indentUnit(matching: indent)
        }
        let text = "\n" + indent
        guard shouldChangeText(in: NSRange(location: insertion, length: 0),
                               replacementString: text) else { return false }
        textStorage?.replaceCharacters(in: NSRange(location: insertion, length: 0), with: text)
        didChangeText()
        setSelectedRange(NSRange(location: insertion + (text as NSString).length, length: 0))
        scrollRangeToVisible(selectedRange())
        refreshBracketMatches()
        return true
    }

    /// Command-D: copy the caret's line — or every line the selection touches —
    /// underneath itself, leaving the caret in the same spot of the copy.
    @discardableResult
    func duplicateCurrentLine() -> Bool {
        let source = string as NSString
        let selection = selectedRange()
        let caret = min(selection.location, source.length)
        let lines = source.lineRange(for: NSRange(location: caret,
                                                  length: min(selection.length,
                                                              source.length - caret)))
        let end = endOfLineContent(at: max(lines.location, NSMaxRange(lines) - 1))
        let block = NSRange(location: lines.location, length: end - lines.location)
        guard block.length >= 0 else { return false }
        let text = "\n" + source.substring(with: block)
        guard shouldChangeText(in: NSRange(location: end, length: 0),
                               replacementString: text) else { return false }
        textStorage?.replaceCharacters(in: NSRange(location: end, length: 0), with: text)
        didChangeText()
        let shift = (text as NSString).length
        setSelectedRange(NSRange(location: min(caret + shift, (string as NSString).length),
                                 length: 0))
        scrollRangeToVisible(selectedRange())
        refreshBracketMatches()
        return true
    }

    /// ⌘/'s comment for the language on screen. Nil for plain text, and then
    /// the command is unavailable.
    var commentSyntax: CommentToggle.Syntax?

    /// Comment the lines the selection touches, or uncomment them — see
    /// `CommentToggle` for the rule. One edit, so one ⌘Z takes it back.
    @objc func toggleComment(_ sender: Any?) {
        guard isEditable, let syntax = commentSyntax else {
            NSSound.beep()
            return
        }
        let source = string as NSString
        let selection = selectedRange()
        let start = min(selection.location, source.length)
        var end = min(NSMaxRange(selection), source.length)
        // Whole lines dragged over end at the start of the next one, which
        // is not part of what was chosen.
        if end > start, source.character(at: end - 1) == 0x0A { end -= 1 }
        let block = source.lineRange(for: NSRange(location: start, length: end - start))
        let original = source.substring(with: block)
        let edits = CommentToggle.edits(for: original, syntax: syntax)
        guard !edits.isEmpty else { return }
        let replacement = CommentToggle.apply(edits, to: original)
        guard shouldChangeText(in: block, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: block, with: replacement)
        didChangeText()
        // The selection keeps to the text it was on, whatever went in or out
        // in front of it.
        let isCaret = selection.length == 0
        let from = block.location
            + CommentToggle.map(selection.location - block.location, through: edits,
                                carryingAtPoint: isCaret)
        let to = isCaret ? from : block.location
            + CommentToggle.map(NSMaxRange(selection) - block.location, through: edits)
        setSelectedRange(NSRange(location: from, length: max(0, to - from)))
        refreshBracketMatches()
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(toggleComment(_:)) {
            return isEditable && commentSyntax != nil
        }
        switch item.action {
        case #selector(toggleMarkdownBold(_:)), #selector(toggleMarkdownItalic(_:)),
             #selector(toggleMarkdownCode(_:)), #selector(insertMarkdownLink(_:)):
            return isEditable && rendersMarkdown
        case #selector(toggleMarkdownSource(_:)):
            return rendersMarkdown
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    // MARK: - Editing rendered Markdown

    /// Set by the pane for a Markdown document, rendered or shown as source.
    var rendersMarkdown = false
    /// Every span of inline formatting in the document, for the commands that
    /// add and remove it and for the caret that shows it.
    var markdownSpans: [MarkdownSpanDecoration] = []
    /// Show `range` as written until the caret leaves it: a link just made,
    /// whose address goes where nothing is drawn.
    var onShowMarkdownSource: ((NSRange) -> Void)?
    /// ⇧⌘M: the whole document as source, or rendered again.
    var onToggleMarkdownSource: (() -> Void)?

    // AppKit's arrows step over hidden characters, but land on one side of
    // them only — after a `**` going right, before it going left — so typing
    // at the end of bold text, or just before it, could not be reached from
    // the keyboard at all. Each edge of a span is two stops here, outside and
    // then inside, that look alike: the marks at the edges and the caret
    // itself say which one it is. A block's lead is one stop, the text's
    // start: stepping into a `##` would bring it into the line.
    override func moveRight(_ sender: Any?) {
        guard let target = markdownStep(forward: true) else {
            super.moveRight(sender)
            return
        }
        placeCaretByKeyboard(target)
    }

    override func moveLeft(_ sender: Any?) {
        guard let target = markdownStep(forward: false) else {
            super.moveLeft(sender)
            return
        }
        placeCaretByKeyboard(target)
    }

    override func moveForward(_ sender: Any?) {
        guard let target = markdownStep(forward: true) else {
            super.moveForward(sender)
            return
        }
        placeCaretByKeyboard(target)
    }

    override func moveBackward(_ sender: Any?) {
        guard let target = markdownStep(forward: false) else {
            super.moveBackward(sender)
            return
        }
        placeCaretByKeyboard(target)
    }

    private func placeCaretByKeyboard(_ location: Int) {
        setSelectedRange(NSRange(location: location, length: 0))
        scrollRangeToVisible(NSRange(location: location, length: 0))
    }

    /// Where one press of an arrow takes the caret in rendered Markdown; nil
    /// where AppKit's own step is the right one — a selection, or no hidden
    /// syntax next to the caret, where AppKit also knows which way is visually
    /// right in a right-to-left line. Next to hidden syntax it is not: from
    /// just before a `**` its left arrow went to another line entirely.
    private func markdownStep(forward: Bool) -> Int? {
        guard rendersMarkdown, let folding = foldingManager else { return nil }
        let selection = selectedRange()
        let source = string as NSString
        guard selection.length == 0 else { return nil }
        var position = min(selection.location, source.length)
        let besideHidden = (position > 0 && folding.isCharacterHidden(at: position - 1))
            || (position < source.length && folding.isCharacterHidden(at: position))
        if forward {
            guard position < source.length else { return nil }
            if folding.isMarkdownInlineSyntaxHidden(at: position) {
                // Outside an edge: in.
                while position < source.length,
                      folding.isMarkdownInlineSyntaxHidden(at: position) { position += 1 }
                return position
            }
            let character = visibleCharacter(at: position, in: source)
            position = NSMaxRange(character)
            // Onto a line with a lead: at its text.
            var skippedLead = false
            while position < source.length, folding.isMarkdownLeadHidden(at: position) {
                position += 1
                skippedLead = true
            }
            // Up to an edge, where AppKit would carry on past it; or over an
            // entity, which it would step into.
            let stopsAtEdge = position < source.length
                && folding.isMarkdownInlineSyntaxHidden(at: position)
            let isEntity = character != source.rangeOfComposedCharacterSequence(
                at: character.location)
            return skippedLead || stopsAtEdge || isEntity || besideHidden ? position : nil
        }
        guard position > 0 else { return nil }
        if folding.isMarkdownInlineSyntaxHidden(at: position - 1) {
            // Inside an edge: out.
            while position > 0, folding.isMarkdownInlineSyntaxHidden(at: position - 1) {
                position -= 1
            }
            return position
        }
        if folding.isMarkdownLeadHidden(at: position - 1) {
            // From a block's text, over its lead, to the end of the line above.
            while position > 0, folding.isMarkdownLeadHidden(at: position - 1) { position -= 1 }
            return position > 0 ? position - 1 : selection.location
        }
        let character = visibleCharacter(at: position - 1, in: source)
        let stopsAtEdge = character.location > 0
            && folding.isMarkdownInlineSyntaxHidden(at: character.location - 1)
        let isEntity = character != source.rangeOfComposedCharacterSequence(at: position - 1)
        return stopsAtEdge || isEntity || besideHidden ? character.location : nil
    }

    /// The drawn character at `location`: a composed sequence, or an entity
    /// drawn as one character.
    private func visibleCharacter(at location: Int, in source: NSString) -> NSRange {
        foldingManager?.markdownDrawnReplacement(containing: location)
            ?? source.rangeOfComposedCharacterSequence(at: location)
    }

    /// Delete never takes a character that is not drawn: removing half a `**`
    /// changed the formatting of a whole span with nothing seen to go. Hidden
    /// syntax in front of the caret is stepped over, and the character the
    /// reader sees before it goes instead — with its span, when it was all
    /// the span held. At the start of a heading or a list item, what goes is
    /// the `##` or the `-`: the block becomes a paragraph, as the line shows.
    override func deleteBackward(_ sender: Any?) {
        guard rendersMarkdown, let folding = foldingManager, isEditable,
              selectedRange().length == 0 else {
            super.deleteBackward(sender)
            return
        }
        let source = string as NSString
        let caret = min(selectedRange().location, source.length)
        var visible = caret
        while visible > 0, folding.isMarkdownInlineSyntaxHidden(at: visible - 1) { visible -= 1 }
        if visible > 0, folding.isMarkdownLeadHidden(at: visible - 1),
           let lead = folding.markdownLeadRange(endingAt: visible) {
            let marker = Self.leadMarker(in: source.substring(with: lead))
            replaceMarkdown(NSRange(location: NSMaxRange(lead) - marker, length: marker),
                            with: "", caret: NSMaxRange(lead) - marker)
            return
        }
        guard visible > 0 else {
            if visible < caret { setSelectedRange(NSRange(location: 0, length: 0)) }
            return
        }
        let character = visibleCharacter(at: visible - 1, in: source)
        // Nothing hidden in the way: AppKit's own Delete, which is what joins
        // a run of them into one ⌘Z.
        guard visible < caret
                || character != source.rangeOfComposedCharacterSequence(at: visible - 1)
                || markdownSpans.contains(where: { $0.content == character }) else {
            super.deleteBackward(sender)
            return
        }
        deleteVisibleCharacter(character)
    }

    override func deleteForward(_ sender: Any?) {
        guard rendersMarkdown, let folding = foldingManager, isEditable,
              selectedRange().length == 0 else {
            super.deleteForward(sender)
            return
        }
        let source = string as NSString
        let caret = min(selectedRange().location, source.length)
        var visible = caret
        while visible < source.length, folding.isMarkdownInlineSyntaxHidden(at: visible) {
            visible += 1
        }
        guard visible < source.length else {
            if visible > caret { setSelectedRange(NSRange(location: source.length, length: 0)) }
            return
        }
        let character = visibleCharacter(at: visible, in: source)
        guard visible > caret
                || character != source.rangeOfComposedCharacterSequence(at: visible)
                || markdownSpans.contains(where: { $0.content == character }) else {
            super.deleteForward(sender)
            return
        }
        deleteVisibleCharacter(character)
    }

    /// Delete one drawn character — or, when it is all a span holds, the span:
    /// an empty `****` is not formatting any more but four asterisks. The
    /// caret keeps its side of the hidden syntax it was on: Delete from after
    /// a `**` leaves it after the `**`, still outside the bold.
    private func deleteVisibleCharacter(_ character: NSRange) {
        let deleted = markdownSpans.first(where: { $0.content == character })?.range ?? character
        let caret = selectedRange().location
        let after = caret >= NSMaxRange(deleted) ? caret - deleted.length
            : caret <= deleted.location ? caret : deleted.location
        replaceMarkdown(deleted, with: "", caret: after)
    }

    /// How much of a lead's end one Delete takes: its last marker and the
    /// space after it — a `- [ ] `'s box before its bullet, the innermost of
    /// `> - `, the whole of an indent.
    static func leadMarker(in lead: String) -> Int {
        let characters = Array(lead.utf16)
        var end = characters.count
        while end > 0, characters[end - 1] == 0x20 || characters[end - 1] == 0x09 { end -= 1 }
        guard end > 0 else { return characters.count }
        // A task's box has a space inside it.
        if end >= 3, characters[end - 1] == 0x5D, characters[end - 3] == 0x5B {
            return characters.count - (end - 3)
        }
        var start = end
        while start > 0, characters[start - 1] != 0x20, characters[start - 1] != 0x09 { start -= 1 }
        return characters.count - start
    }

    /// One edit, one ⌘Z.
    private func replaceMarkdown(_ range: NSRange, with replacement: String, caret: Int,
                                 selecting length: Int = 0) {
        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()
        setSelectedRange(NSRange(location: caret, length: length))
    }

    /// The formatting typing at the caret would get: the spans whose text the
    /// caret is in, either end of it included.
    var caretFormats: Set<MarkdownSpanDecoration.Kind> {
        guard rendersMarkdown else { return [] }
        let selection = selectedRange()
        guard selection.length == 0 else { return [] }
        return Set(markdownSpans.filter {
            NSLocationInRange(selection.location, NSRange(location: $0.content.location,
                                                          length: $0.content.length + 1))
                && foldingManager?.isCharacterHidden(at: $0.opening.location) == true
        }.map(\.kind))
    }

    // MARK: Formatting commands

    @objc func toggleMarkdownBold(_ sender: Any?) { toggleMarkdownSpan(.strong) }
    @objc func toggleMarkdownItalic(_ sender: Any?) { toggleMarkdownSpan(.emphasis) }
    @objc func toggleMarkdownCode(_ sender: Any?) { toggleMarkdownSpan(.code) }
    @objc func toggleMarkdownSource(_ sender: Any?) { onToggleMarkdownSource?() }

    private static func delimiter(for kind: MarkdownSpanDecoration.Kind) -> String {
        switch kind {
        case .strong: return "**"
        case .emphasis: return "*"
        case .strikethrough: return "~~"
        case .code: return "`"
        }
    }

    /// Bold, italic or code: off where the selection or the caret is already
    /// in it, on otherwise — around the selection, the word at the caret, or
    /// an empty pair to type into.
    func toggleMarkdownSpan(_ kind: MarkdownSpanDecoration.Kind) {
        guard isEditable, rendersMarkdown else {
            NSSound.beep()
            return
        }
        let source = string as NSString
        let selection = selectedRange()
        // Taking it off: the span the selection is, or the caret is in.
        if let span = markdownSpans.filter({ span in
            span.kind == kind && (selection.length > 0
                ? selection == span.content || selection == span.range
                : NSLocationInRange(selection.location,
                                    NSRange(location: span.content.location,
                                            length: span.content.length + 1)))
        }).min(by: { $0.range.length < $1.range.length }) {
            let content = source.substring(with: span.content)
            let offset = selection.location - span.content.location
            replaceMarkdown(span.range, with: content,
                            caret: span.range.location + max(0, min(offset, span.content.length)),
                            selecting: selection.length > 0 ? span.content.length : 0)
            return
        }
        var target = selection
        if target.length > 0 {
            // `**word **` is not bold: the delimiters go against the text.
            while target.length > 0, Self.isSpace(source.character(at: target.location)) {
                target.location += 1
                target.length -= 1
            }
            while target.length > 0, Self.isSpace(source.character(at: NSMaxRange(target) - 1)) {
                target.length -= 1
            }
        } else {
            target = wordRange(at: selection.location, in: source)
        }
        var delimiter = Self.delimiter(for: kind)
        let text = source.substring(with: target)
        var inner = text
        if kind == .code, text.contains("`") {
            delimiter = "``"
            inner = " " + text + " "
        }
        let caret = target.location + delimiter.utf16.count
            + (selection.length > 0 ? (inner.utf16.count - text.utf16.count) / 2
                                    : selection.location - target.location)
        replaceMarkdown(target, with: delimiter + inner + delimiter, caret: caret,
                        selecting: selection.length > 0 ? text.utf16.count : 0)
    }

    private static func isSpace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09 || character == 0x0A || character == 0x0D
    }

    /// The word the caret is in or against; empty where there is none.
    private func wordRange(at location: Int, in source: NSString) -> NSRange {
        func isWord(_ index: Int) -> Bool {
            guard index >= 0, index < source.length else { return false }
            guard let scalar = UnicodeScalar(source.character(at: index)) else { return false }
            return CharacterSet.alphanumerics.contains(scalar)
        }
        var start = location
        while isWord(start - 1) { start -= 1 }
        var end = location
        while isWord(end) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    /// ⌘K: a link around the selection — or, in a link already, that link's
    /// source — with what goes nowhere on screen shown until the caret leaves.
    @objc func insertMarkdownLink(_ sender: Any?) {
        guard isEditable, rendersMarkdown else {
            NSSound.beep()
            return
        }
        let selection = selectedRange()
        if let link = markdownLinks.first(where: {
            $0.fullRange.location < selection.location
                && NSMaxRange(selection) < NSMaxRange($0.fullRange)
        }) {
            onEditLink?(link)
            return
        }
        let label = (string as NSString).substring(with: selection)
        let link = "[" + label + "]()"
        replaceMarkdown(selection, with: link,
                        caret: selection.length > 0 ? selection.location + link.utf16.count - 1
                                                    : selection.location + 1)
        onShowMarkdownSource?(NSRange(location: selection.location, length: link.utf16.count))
    }

    /// The full leading whitespace of a line, whatever the caret is doing:
    /// measured from the end of the line's text, so a caret sitting inside the
    /// indent does not shorten it.
    private func indentOfLine(at location: Int) -> String {
        carriedIndent(at: endOfLineContent(at: location))
    }

    private func innermostBlock(at location: Int) -> CodeBlock? {
        codeBlocks
            .filter { NSLocationInRange(location, $0.fullRange) }
            .max { $0.depth < $1.depth }
    }

    /// Keep the caret rect consistent when AppKit asks for it.
    override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
        super.setNeedsDisplay(rect.insetBy(dx: -1, dy: -2), avoidAdditionalLayout: flag)
    }

    // MARK: - Reading aids

    /// Line numbers, for which rows the stripes go on, from the document's
    /// index — counting newlines here would walk the file on every draw.
    var lineIndexProvider: (() -> LineIndex?)?

    /// The file's indent step, kept for the text it was worked out from.
    private var indentUnitCache: (storage: ObjectIdentifier, length: Int, unit: Int)?

    /// What the last background draw put down, for the tests.
    private(set) var drawnReadingAidsForTesting = (stripes: [NSRect](), guides: [NSRect](),
                                                   dots: [NSRect]())

    /// The code rows a draw of `rect` covers, numbered from the document's
    /// index — or nil where the reading aids are not drawn: rendered
    /// Markdown, whose lines are prose of many heights, and diffs, whose
    /// lines carry bands of their own.
    private func readingAidRows(in rect: NSRect)
        -> (text: NSString, index: LineIndex, rows: [(row: NSRect, line: Int, startsLine: Bool)])? {
        guard !rendersMarkdown, diffBands.isEmpty,
              let layoutManager, let container = textContainer else { return nil }
        let text = string as NSString
        guard text.length > 0 else { return nil }
        let origin = textContainerOrigin
        let glyphs = layoutManager.glyphRange(
            forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        guard glyphs.length > 0 else { return nil }
        let index = lineIndexProvider?() ?? LineIndex(text)
        var rows: [(row: NSRect, line: Int, startsLine: Bool)] = []
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, glyphRange, _ in
            let characters = layoutManager.characterRange(forGlyphRange: glyphRange,
                                                          actualGlyphRange: nil)
            let line = index.line(at: characters.location)
            rows.append((fragment.offsetBy(dx: origin.x, dy: origin.y), line,
                         characters.location == index.start(ofLine: line)))
        }
        return (text, index, rows)
    }

    /// Every other code line on a faint band, as settings.json asks — under
    /// everything, the active line's band and the selection included.
    private func drawZebraStripes(in rect: NSRect) {
        drawnReadingAidsForTesting.stripes = []
        guard Settings.shared.zebraStripes, let aid = readingAidRows(in: rect) else { return }
        Theme.stripedRow.setFill()
        for (row, line, _) in aid.rows where line % 2 == 0 {
            let band = NSRect(x: bounds.minX, y: row.minY, width: bounds.width, height: row.height)
            band.fill()
            drawnReadingAidsForTesting.stripes.append(band)
        }
    }

    /// The leading indentation marked with guides or dots, as settings.json
    /// asks, on each line's first row.
    private func drawIndentMarkers(in rect: NSRect) {
        drawnReadingAidsForTesting.guides = []
        drawnReadingAidsForTesting.dots = []
        let settings = Settings.shared
        let markers = settings.indentMarkers
        guard markers != .none, let container = textContainer,
              let aid = readingAidRows(in: rect) else { return }
        let (text, index) = (aid.text, aid.index)
        let tabSize = settings.tabSize
        let unit = indentUnit(of: text, tabSize: tabSize)
        let column = Theme.characterWidth()
        let left = textContainerOrigin.x + container.lineFragmentPadding
        let dotSize = max(1.5, (column * 0.22).rounded())
        (markers == .guides ? Theme.gutter.withAlphaComponent(0.55)
                            : Theme.gutter.withAlphaComponent(0.8)).setFill()
        for (row, line, startsLine) in aid.rows where startsLine {
            let lead = Self.leadingColumns(of: text, line: line, index: index, tabSize: tabSize)
            switch markers {
            case .guides:
                // A blank line inside a block keeps the block's guides; one
                // between blocks takes the shallower of its neighbours, so a
                // guide stops where its block does.
                let indent = lead ?? min(
                    Self.neighbourIndent(of: text, from: line, step: -1, index: index, tabSize: tabSize),
                    Self.neighbourIndent(of: text, from: line, step: 1, index: index, tabSize: tabSize))
                var level = 0
                while level * unit < indent {
                    let mark = NSRect(x: floor(left + CGFloat(level * unit) * column), y: row.minY,
                                      width: 1, height: row.height)
                    // Blended: a plain fill copies the translucent colour in,
                    // and the stripe or band under it showed through as the
                    // code area's colour instead.
                    mark.fill(using: .sourceOver)
                    drawnReadingAidsForTesting.guides.append(mark)
                    level += 1
                }
            case .dots:
                guard let lead, lead > 0 else { continue }
                for position in 0..<lead {
                    let centre = left + (CGFloat(position) + 0.5) * column
                    let mark = NSRect(x: centre - dotSize / 2, y: row.midY - dotSize / 2,
                                      width: dotSize, height: dotSize)
                    NSBezierPath(ovalIn: mark).fill()
                    drawnReadingAidsForTesting.dots.append(mark)
                }
            case .none:
                break
            }
        }
    }

    /// Columns of leading whitespace on a 1-based line, a tab reaching the
    /// next tab stop; nil for a line that is only whitespace.
    static func leadingColumns(of text: NSString, line: Int, index: LineIndex,
                               tabSize: Int) -> Int? {
        var location = index.start(ofLine: line)
        var columns = 0
        while location < text.length {
            switch text.character(at: location) {
            case 0x20: columns += 1
            case 0x09: columns += tabSize - columns % max(1, tabSize)
            case 0x0A, 0x0D: return nil
            default: return columns
            }
            location += 1
        }
        return nil
    }

    /// The indentation of the nearest line with text above or below.
    private static func neighbourIndent(of text: NSString, from line: Int, step: Int,
                                        index: LineIndex, tabSize: Int) -> Int {
        var other = line + step
        var looked = 0
        // Bounded: a run of blank lines longer than this draws no guides.
        while other >= 1, other <= index.lineCount, looked < 200 {
            if let lead = leadingColumns(of: text, line: other, index: index, tabSize: tabSize) {
                return lead
            }
            other += step
            looked += 1
        }
        return 0
    }

    /// The step the file indents by: the rise taken most often from one line
    /// with text to the next, over its first thousand lines — continuation
    /// lines aligned under a bracket rise by odd amounts, but less often.
    /// The setting's tab size when nothing in the file is indented.
    private func indentUnit(of text: NSString, tabSize: Int) -> Int {
        let key = (ObjectIdentifier(textStorage ?? NSTextStorage()), text.length)
        if let cached = indentUnitCache, cached.storage == key.0, cached.length == key.1 {
            return cached.unit
        }
        let unit = Self.indentUnit(of: text, tabSize: tabSize)
        indentUnitCache = (key.0, key.1, unit)
        return unit
    }

    static func indentUnit(of text: NSString, tabSize: Int, sampleLines: Int = 1000) -> Int {
        var rises: [Int: Int] = [:]
        var previous: Int?
        var location = 0
        var lines = 0
        while location < text.length, lines < sampleLines {
            let range = text.lineRange(for: NSRange(location: location, length: 0))
            var columns = 0
            var blank = true
            var cursor = range.location
            scan: while cursor < NSMaxRange(range) {
                switch text.character(at: cursor) {
                case 0x20: columns += 1
                case 0x09: columns += tabSize - columns % max(1, tabSize)
                case 0x0A, 0x0D: break scan
                default:
                    blank = false
                    break scan
                }
                cursor += 1
            }
            if !blank {
                if let previous, columns > previous { rises[columns - previous, default: 0] += 1 }
                previous = columns
            }
            location = NSMaxRange(range)
            lines += 1
        }
        let step = rises.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
        return min(max(step ?? tabSize, 1), 16)
    }

    // MARK: - The active pair: its ends tinted, its line flowing

    /// The two ends the line joins: the bracket pair, or a component's opening
    /// and closing tags (one tag, for a self-closing component).
    private var scopeEndRanges: [NSRange] {
        if bracketMatchRanges.count == 2 { return bracketMatchRanges }
        guard let match = activeJSXTagMatch else { return [] }
        return [match.openingTagRange] + (match.closingTagRange.map { [$0] } ?? [])
    }

    /// Where the ends' tint goes: around each end's glyphs, row by row — an
    /// opening tag whose attributes run over several lines is tinted on each,
    /// from its first character, not from the indentation before it.
    func scopeEndTintRects() -> [NSRect] {
        guard let layoutManager, let container = textContainer else { return [] }
        let text = string as NSString
        let inset = textContainerInset
        var rects: [NSRect] = []
        for range in scopeEndRanges where range.length > 0 && NSMaxRange(range) <= text.length {
            guard foldingManager?.isCharacterHidden(at: range.location) != true else { continue }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, rowGlyphs, _ in
                var part = layoutManager.characterRange(
                    forGlyphRange: NSIntersectionRange(rowGlyphs, glyphs), actualGlyphRange: nil)
                while part.length > 0,
                      let c = UnicodeScalar(text.character(at: part.location)),
                      CharacterSet.whitespacesAndNewlines.contains(c) {
                    part = NSRange(location: part.location + 1, length: part.length - 1)
                }
                while part.length > 0,
                      let c = UnicodeScalar(text.character(at: NSMaxRange(part) - 1)),
                      CharacterSet.whitespacesAndNewlines.contains(c) {
                    part.length -= 1
                }
                guard part.length > 0 else { return }
                let raw = layoutManager.boundingRect(
                    forGlyphRange: layoutManager.glyphRange(forCharacterRange: part,
                                                            actualCharacterRange: nil),
                    in: container)
                let vertical = self.glyphBox(fragmentHeight: fragment.height)
                rects.append(NSRect(x: raw.minX + inset.width - 2,
                                    y: fragment.minY + vertical.top + inset.height,
                                    width: raw.width + 4, height: vertical.height))
            }
        }
        return rects
    }

    private(set) var drawnScopeTintsForTesting: [NSRect] = []

    /// A light wash of the line's red behind both ends, so the pair is found
    /// at a glance — under the text, over the active line's band.
    private func drawScopeEndTint() {
        let rects = scopeEndTintRects()
        drawnScopeTintsForTesting = rects
        guard !rects.isEmpty else { return }
        Theme.red.withAlphaComponent(0.14).setFill()
        rects.forEach { $0.fill(using: .sourceOver) }
    }

    /// The active pair's line, flowing from its opening end to its closing
    /// one. A shape layer over the text: Core Animation moves the dashes in
    /// the render server, so the text view draws no frame of it. With Reduce
    /// Motion on, it is the still, solid line it always was.
    private var scopeFlow: ScopeFlowOverlay?
    private var scopeFlowScrollObserver: NSObjectProtocol?
    private var scopeFlowSyncScheduled = false
    /// Stands in for the system's Reduce Motion setting in tests.
    static var reducesMotionOverride: Bool?
    private var reducesMotion: Bool {
        Self.reducesMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    /// 4pt of line, 3pt of gap, moving along at 17.5pt a second.
    static let scopeFlowDash: [CGFloat] = [4, 3]
    static let scopeFlowPeriod: CFTimeInterval = 0.4

    /// One sync for however many draws ask for it, after the draw: views are
    /// not to be added or moved while one is being drawn.
    private func scheduleScopeFlowSync() {
        guard !scopeFlowSyncScheduled else { return }
        scopeFlowSyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scopeFlowSyncScheduled = false
            self.syncScopeFlow()
        }
    }

    private func syncScopeFlow() {
        guard window != nil, let geometry = activeScopeGeometry() else {
            scopeFlow?.isHidden = true
            return
        }
        let overlay: ScopeFlowOverlay
        if let existing = scopeFlow {
            overlay = existing
        } else {
            overlay = ScopeFlowOverlay(frame: bounds)
            overlay.autoresizingMask = [.width, .height]
            addSubview(overlay)
            scopeFlow = overlay
        }
        if overlay.frame != bounds { overlay.frame = bounds }
        overlay.isHidden = false
        let path = CGMutablePath()
        if let box = geometry.box {
            path.addRect(box)
        } else if let first = geometry.polyline.first {
            path.move(to: first)
            geometry.polyline.dropFirst().forEach { path.addLine(to: $0) }
        }
        // Only what is near the screen is given to the layer: a scope can run
        // for thousands of lines, and a layer that tall is not one to make.
        let near = visibleRect.insetBy(dx: -visibleRect.width, dy: -visibleRect.height)
        let frame = path.boundingBoxOfPath.insetBy(dx: -2, dy: -2).intersection(near)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let shape = overlay.shape
        shape.frame = frame.isNull ? .zero : frame
        var shift = CGAffineTransform(translationX: -shape.frame.minX, y: -shape.frame.minY)
        shape.path = path.copy(using: &shift)
        shape.strokeColor = Theme.red.cgColor
        if reducesMotion {
            shape.lineDashPattern = nil
            shape.removeAnimation(forKey: "flow")
        } else {
            shape.lineDashPattern = Self.scopeFlowDash.map { NSNumber(value: Double($0)) }
            if shape.animation(forKey: "flow") == nil {
                let flow = CABasicAnimation(keyPath: "lineDashPhase")
                flow.fromValue = 0
                // Negative: the dashes travel the way the path runs.
                flow.toValue = -Self.scopeFlowDash.reduce(0, +)
                flow.duration = Self.scopeFlowPeriod
                flow.repeatCount = .infinity
                shape.add(flow, forKey: "flow")
            }
        }
        CATransaction.commit()
    }

    /// The flowing line as it stands, for the tests: whether it shows, its
    /// path in the text view's coordinates, and whether it is moving.
    var scopeFlowForTesting: (visible: Bool, path: CGRect, dashed: Bool, flowing: Bool) {
        syncScopeFlow()
        guard let overlay = scopeFlow, !overlay.isHidden, let path = overlay.shape.path else {
            return (false, .zero, false, false)
        }
        let box = path.boundingBoxOfPath.offsetBy(dx: overlay.shape.frame.minX,
                                                  dy: overlay.shape.frame.minY)
        return (true, box, overlay.shape.lineDashPattern != nil,
                overlay.shape.animation(forKey: "flow") != nil)
    }
}

/// Holds the active pair's flowing line over the text. It takes no clicks:
/// they go through to the text under it.
private final class ScopeFlowOverlay: NSView {
    let shape = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Square corners, square ends: the corners it draws are the corners
        // of the code it encloses.
        shape.fillColor = nil
        shape.lineWidth = 1.5
        shape.lineCap = .butt
        shape.lineJoin = .miter
        shape.masksToBounds = true
        layer?.addSublayer(shape)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}


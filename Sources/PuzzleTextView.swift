import AppKit

/// View-space geometry for the active bracket pair. Keeping this independent
/// from TextKit makes viewport continuation and same-line behavior directly
/// regression-testable.
struct BracketScopeGeometry {
    let box: NSRect?
    let polyline: [NSPoint]
    let viewportCaps: [[NSPoint]]

    static func make(opening: NSRect, closing: NSRect, guideX: CGFloat,
                     visibleRect: NSRect) -> BracketScopeGeometry {
        // A pair on one visual row reads best as one compact enclosure. A
        // multiline pair uses the open-sided scope contour shown by editors
        // such as Zed: opening row -> indentation guide -> closing row.
        if abs(opening.midY - closing.midY) < 0.5 {
            let union = opening.union(closing).insetBy(dx: -2, dy: -2)
            return BracketScopeGeometry(box: union, polyline: [], viewportCaps: [])
        }

        let openingY = opening.maxY + 1
        let closingY = closing.maxY + 1
        let topY = min(openingY, closingY)
        let bottomY = max(openingY, closingY)
        let resolvedGuideX = min(guideX, opening.minX - 3, closing.minX - 3)
        let polyline = [
            NSPoint(x: opening.maxX + 2, y: openingY),
            NSPoint(x: resolvedGuideX, y: openingY),
            NSPoint(x: resolvedGuideX, y: closingY),
            NSPoint(x: closing.maxX + 2, y: closingY),
        ]

        var caps: [[NSPoint]] = []
        let capWidth: CGFloat = 7
        if topY < visibleRect.minY, bottomY > visibleRect.minY {
            let y = visibleRect.minY + 1
            caps.append([NSPoint(x: resolvedGuideX, y: y),
                         NSPoint(x: resolvedGuideX + capWidth, y: y)])
        }
        if bottomY > visibleRect.maxY, topY < visibleRect.maxY {
            let y = visibleRect.maxY - 1
            caps.append([NSPoint(x: resolvedGuideX, y: y),
                         NSPoint(x: resolvedGuideX + capWidth, y: y)])
        }
        return BracketScopeGeometry(box: nil, polyline: polyline, viewportCaps: caps)
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
    private var markdownImageCache: [URL: NSImage] = [:]
    private var markdownActiveSourceRange: NSRange?
    private var measuredMarkdownTableWidth: CGFloat = -1

    func updateMarkdownDecorations(codeBlocks: [MarkdownCodeBlockDecoration],
                                   tables: [MarkdownTableDecoration],
                                   tasks: [MarkdownTaskDecoration] = [],
                                   lineMarkers: [MarkdownLineMarkerDecoration] = [],
                                   rules: [MarkdownRuleDecoration] = [],
                                   images: [MarkdownImageDecoration] = [],
                                   activeSourceRange: NSRange?) {
        guard codeBlocks != markdownCodeBlocks || tables != markdownTables
                || tasks != markdownTasks
                || lineMarkers != markdownLineMarkers
                || rules != markdownRules
                || images != markdownImages
                || activeSourceRange != markdownActiveSourceRange else { return }
        markdownCodeBlocks = codeBlocks
        markdownTables = tables
        markdownTasks = tasks
        markdownLineMarkers = lineMarkers
        markdownRules = rules
        markdownImages = images
        let retainedURLs = Set(images.compactMap(\.url))
        markdownImageCache = markdownImageCache.filter { retainedURLs.contains($0.key) }
        markdownActiveSourceRange = activeSourceRange
        measuredMarkdownTableWidth = -1
        updateMarkdownTableRowMetrics()
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
        guard abs(width - measuredMarkdownTableWidth) > 0.5 else { return }
        measuredMarkdownTableWidth = width
        guard width > 0, !markdownTables.isEmpty || !markdownImages.isEmpty else {
            foldingManager?.updateMarkdownTableRowMetrics([])
            return
        }
        var metrics: [MarkdownTableRowMetric] = []
        for table in markdownTables {
            let widths = markdownTableColumnWidths(for: table)
            for row in table.rows {
                metrics.append(MarkdownTableRowMetric(
                    range: row.lineRange,
                    height: markdownTableRowHeight(row, widths: widths)))
            }
        }
        for image in markdownImages {
            metrics.append(MarkdownTableRowMetric(
                range: image.lineRange,
                height: markdownImageHeight(image)))
        }
        foldingManager?.updateMarkdownTableRowMetrics(metrics)
        needsDisplay = true
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    private func markdownTableAttributes(header: Bool)
        -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        var attributes: [NSAttributedString.Key: Any] = [
            .font: Theme.editorFont(),
            .foregroundColor: Theme.foreground,
            .paragraphStyle: paragraph,
        ]
        if header { attributes[.strokeWidth] = -2.0 }
        return attributes
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
        return max(Theme.lineMetrics().target, contentHeight + 8)
    }

    private func markdownImage(_ decoration: MarkdownImageDecoration) -> NSImage? {
        guard let url = decoration.url, url.isFileURL else { return nil }
        if let cached = markdownImageCache[url] { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        markdownImageCache[url] = image
        return image
    }

    private func markdownImageHeight(_ decoration: MarkdownImageDecoration) -> CGFloat {
        let available = max(80, bounds.width - textContainerInset.width * 2)
        guard let image = markdownImage(decoration), image.size.width > 0,
              image.size.height > 0 else { return Theme.lineMetrics().target * 2 }
        let scale = min(1, available / image.size.width, 320 / image.size.height)
        return max(Theme.lineMetrics().target * 2, floor(image.size.height * scale) + 8)
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

    func unfoldAllCodeBlocks() {
        foldingManager?.unfoldAll()
        refreshFoldingDisplay()
    }

    private func refreshFoldingDisplay() {
        needsDisplay = true
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    /// Blame annotation for the caret's line, drawn past the end of the text.
    ///
    /// Deliberately drawn rather than inserted into the text storage: the
    /// storage is the document, shared across split panes, and putting
    /// decoration in it would dirty the buffer and land in saved files.
    var inlineBlame: String? {
        didSet { if inlineBlame != oldValue { needsDisplay = true } }
    }

    private func drawInlineBlame() {
        guard let blame = inlineBlame, !blame.isEmpty,
              let layoutManager, textContainer != nil else { return }
        let ns = string as NSString
        guard ns.length > 0 || !blame.isEmpty else { return }

        let caret = selectedRange().location
        guard caret <= ns.length else { return }
        let lineRange = ns.lineRange(for: NSRange(location: min(caret, max(ns.length - 1, 0)),
                                                  length: 0))
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
        text.draw(in: NSRect(x: originX, y: y + inset.height,
                             width: width, height: size.height),
                  withAttributes: attributes)
    }

    // Blame sits on top of the glyphs, so it goes here rather than in
    // drawBackground alongside the bands.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawMarkdownTables(in: dirtyRect)
        drawMarkdownImages(in: dirtyRect)
        drawMarkdownLineMarkers(in: dirtyRect)
        drawMarkdownTasks(in: dirtyRect)
        drawMarkdownRules(in: dirtyRect)
        drawMarkdownCodeLabels(in: dirtyRect)
        drawCommandHoverUnderline()
        drawBracketScopeOutline()
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

    private func drawBracketScopeOutline() {
        guard let geometry = activeScopeGeometry() else { return }
        NSGraphicsContext.saveGraphicsState()
        visibleRect.clip()
        defer { NSGraphicsContext.restoreGraphicsState() }

        Theme.red.withAlphaComponent(0.9).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        if let box = geometry.box {
            path.appendRoundedRect(box, xRadius: 5, yRadius: 5)
        } else {
            appendRoundedPolyline(geometry.polyline, radius: 5, to: path)
        }
        for cap in geometry.viewportCaps where cap.count == 2 {
            path.move(to: cap[0])
            path.line(to: cap[1])
        }
        path.stroke()
    }

    /// Append a polyline whose corners use a geometric radius independent of
    /// stroke width. `lineJoinStyle = .round` alone only rounds by roughly half
    /// the 1.5pt stroke and is visually indistinguishable from a sharp corner.
    private func appendRoundedPolyline(_ points: [NSPoint], radius: CGFloat,
                                       to path: NSBezierPath) {
        guard let first = points.first else { return }
        guard points.count > 2 else {
            path.move(to: first)
            if let last = points.last, last != first { path.line(to: last) }
            return
        }

        path.move(to: first)
        for index in 1..<(points.count - 1) {
            let previous = points[index - 1]
            let corner = points[index]
            let next = points[index + 1]
            let incoming = NSPoint(x: corner.x - previous.x,
                                   y: corner.y - previous.y)
            let outgoing = NSPoint(x: next.x - corner.x,
                                   y: next.y - corner.y)
            let incomingLength = hypot(incoming.x, incoming.y)
            let outgoingLength = hypot(outgoing.x, outgoing.y)
            guard incomingLength > 0, outgoingLength > 0 else {
                path.line(to: corner)
                continue
            }

            let resolvedRadius = min(radius, incomingLength / 2, outgoingLength / 2)
            let before = NSPoint(
                x: corner.x - incoming.x / incomingLength * resolvedRadius,
                y: corner.y - incoming.y / incomingLength * resolvedRadius)
            let after = NSPoint(
                x: corner.x + outgoing.x / outgoingLength * resolvedRadius,
                y: corner.y + outgoing.y / outgoingLength * resolvedRadius)
            path.line(to: before)

            // Convert a quadratic curve with `corner` as its control point to
            // the cubic representation exposed by NSBezierPath.
            let control1 = NSPoint(
                x: before.x + (corner.x - before.x) * 2 / 3,
                y: before.y + (corner.y - before.y) * 2 / 3)
            let control2 = NSPoint(
                x: after.x + (corner.x - after.x) * 2 / 3,
                y: after.y + (corner.y - after.y) * 2 / 3)
            path.curve(to: after, controlPoint1: control1, controlPoint2: control2)
        }
        if let last = points.last { path.line(to: last) }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawDiffBands()
        drawMarkdownCodeBlocks(in: rect)
        drawCurrentLineBand()
        drawSearchMatches()
    }

    private func drawMarkdownCodeBlocks(in dirtyRect: NSRect) {
        guard !markdownCodeBlocks.isEmpty,
              let layoutManager, textContainer != nil else { return }
        let inset = textContainerInset
        for block in markdownCodeBlocks {
            let clamped = NSIntersectionRange(
                block.range, NSRange(location: 0, length: (string as NSString).length))
            guard clamped.length > 0 else { continue }
            let glyphs = layoutManager.glyphRange(
                forCharacterRange: clamped, actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            var union = NSRect.null
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) {
                fragment, _, _, _, _ in union = union.union(fragment)
            }
            guard !union.isNull else { continue }
            let rect = NSRect(x: inset.width,
                              y: union.minY + inset.height,
                              width: max(0, bounds.width - inset.width * 2),
                              height: union.height)
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
        for block in markdownCodeBlocks {
            guard let language = block.language, !language.isEmpty,
                  block.range.length > 0 else { continue }
            let glyph = layoutManager.glyphIndexForCharacter(at: block.range.location)
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph,
                                                       effectiveRange: nil)
            let size = (language as NSString).size(withAttributes: attributes)
            let rect = NSRect(x: max(inset.width, bounds.width - inset.width - size.width - 6),
                              y: line.minY + inset.height + 2,
                              width: size.width, height: size.height)
            guard rect.intersects(dirtyRect) else { continue }
            (language as NSString).draw(in: rect, withAttributes: attributes)
        }
    }

    private func drawMarkdownTables(in dirtyRect: NSRect) {
        guard !markdownTables.isEmpty, let layoutManager else { return }
        let inset = textContainerInset

        for table in markdownTables {
            let widths = markdownTableColumnWidths(for: table)
            let tableWidth = min(max(80, bounds.width - inset.width * 2),
                                 widths.reduce(0, +))

            for row in table.rows {
                if let active = markdownActiveSourceRange,
                   NSIntersectionRange(active, row.sourceRange).length > 0 {
                    continue
                }
                guard row.sourceRange.length > 0 else { continue }
                // Rendered table source glyphs are null. Anchor geometry to the
                // still-visible line terminator so TextKit returns the dynamic
                // logical-row fragment rather than a zero-width null glyph run.
                let anchor = row.lineRange.length > row.sourceRange.length
                    ? NSMaxRange(row.lineRange) - 1 : row.sourceRange.location
                let glyph = layoutManager.glyphIndexForCharacter(at: anchor)
                let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph,
                                                               effectiveRange: nil)
                let rowRect = NSRect(x: inset.width,
                                     y: fragment.minY + inset.height,
                                     width: tableWidth, height: fragment.height)
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

    private func drawMarkdownTasks(in dirtyRect: NSRect) {
        guard !markdownTasks.isEmpty, let layoutManager, textContainer != nil else { return }
        let origin = textContainerOrigin
        for task in markdownTasks {
            if let active = markdownActiveSourceRange,
               NSIntersectionRange(active, task.sourceRange).length > 0 {
                continue
            }
            let clamped = NSIntersectionRange(
                task.sourceRange,
                NSRange(location: 0, length: (string as NSString).length))
            guard clamped.length > 0 else { continue }
            let glyphs = layoutManager.glyphRange(
                forCharacterRange: clamped, actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            let raw = layoutManager.boundingRect(forGlyphRange: glyphs,
                                                  in: textContainer!)
            let fragment = layoutManager.lineFragmentRect(
                forGlyphAt: glyphs.location, effectiveRange: nil)
            let cover = NSRect(x: raw.minX + origin.x,
                               y: fragment.minY + origin.y,
                               width: raw.width, height: fragment.height)
            guard cover.intersects(dirtyRect) else { continue }

            Theme.editorBackground.setFill()
            cover.fill()
            let side = min(14, max(10, fragment.height - 8))
            let box = NSRect(x: cover.minX + 1,
                             y: cover.midY - side / 2,
                             width: side, height: side)
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
        guard !markdownLineMarkers.isEmpty,
              let layoutManager, let container = textContainer else { return }
        let origin = textContainerOrigin
        let bulletAttributes: [NSAttributedString.Key: Any] = [
            .font: Theme.editorFont(), .foregroundColor: Theme.dimText,
        ]
        for marker in markdownLineMarkers {
            if let active = markdownActiveSourceRange,
               NSIntersectionRange(active, marker.sourceRange).length > 0 { continue }
            let glyphs = layoutManager.glyphRange(
                forCharacterRange: marker.sourceRange, actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            let raw = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            let fragment = layoutManager.lineFragmentRect(
                forGlyphAt: glyphs.location, effectiveRange: nil)
            let cover = NSRect(x: raw.minX + origin.x,
                               y: fragment.minY + origin.y,
                               width: raw.width, height: fragment.height)
            guard cover.intersects(dirtyRect) else { continue }
            Theme.editorBackground.setFill()
            cover.fill()
            switch marker.kind {
            case .bullet(let label):
                let size = (label as NSString).size(withAttributes: bulletAttributes)
                let rect = NSRect(x: max(cover.minX, cover.maxX - size.width - 3),
                                  y: cover.midY - size.height / 2,
                                  width: size.width, height: size.height)
                (label as NSString).draw(in: rect, withAttributes: bulletAttributes)
            case .quote(let depth):
                Theme.border.setFill()
                for level in 0..<depth {
                    NSRect(x: cover.minX + CGFloat(level) * 4 + 1,
                           y: cover.minY + 2,
                           width: 2, height: max(0, cover.height - 4)).fill()
                }
            case .footnote(let identifier):
                let label = "\(identifier)."
                let size = (label as NSString).size(withAttributes: bulletAttributes)
                let rect = NSRect(x: max(cover.minX, cover.maxX - size.width - 3),
                                  y: cover.midY - size.height / 2,
                                  width: size.width, height: size.height)
                (label as NSString).draw(in: rect, withAttributes: bulletAttributes)
            }
        }
    }

    private func drawMarkdownRules(in dirtyRect: NSRect) {
        guard !markdownRules.isEmpty, let layoutManager else { return }
        let origin = textContainerOrigin
        for rule in markdownRules {
            guard rule.lineRange.length > 0 else { continue }
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

    private func drawSearchMatches() {
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
                  NSIntersectionRange(clamped, visibleCharacters).length > 0 else { continue }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: clamped,
                                                      actualCharacterRange: nil)
            guard glyphRange.length > 0 else { continue }
            Theme.matchOutline.setStroke()
            let outlineWidth = index == currentMatchIndex
                ? Theme.currentMatchOutlineWidth : Theme.matchOutlineWidth

            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphRange,
                withinSelectedGlyphRange: notSelected,
                in: container
            ) { enclosing, _ in
                // The highlight is the whole row: a glyph-height band left the
                // configured line height showing above and below it, which read
                // as a stripe rather than a highlighted line.
                var eff = NSRange()
                let frag = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location,
                                                          effectiveRange: &eff)
                var r = enclosing
                r.origin.y = frag.minY
                r.size.height = frag.height
                r = r.offsetBy(dx: inset.width, dy: inset.height)
                // Inset by half the pen so the stroke lands inside the row
                // instead of straddling the line below it.
                let path = NSBezierPath(roundedRect: r.insetBy(dx: outlineWidth / 2,
                                                               dy: outlineWidth / 2),
                                        xRadius: Theme.matchCornerRadius,
                                        yRadius: Theme.matchCornerRadius)
                path.lineWidth = outlineWidth
                path.stroke()
            }
        }
    }

    /// The rects `drawSearchMatches` would fill, ignoring what is on screen.
    /// Keeps the highlight geometry checkable without a live scroll view.
    func matchHighlightRectsForTesting() -> [NSRect] {
        guard let layoutManager, let container = textContainer else { return [] }
        let inset = textContainerInset
        var rects: [NSRect] = []
        for range in searchMatches {
            let glyphs = layoutManager.glyphRange(forCharacterRange: range,
                                                  actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            var effective = NSRange()
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location,
                                                          effectiveRange: &effective)
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphs,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: container
            ) { enclosing, _ in
                var rect = enclosing
                rect.origin.y = fragment.minY
                rect.size.height = fragment.height
                rects.append(rect.offsetBy(dx: inset.width, dy: inset.height))
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
    private func caretLineFragment() -> NSRect? {
        guard let layoutManager, let container = textContainer else { return nil }
        let ns = string as NSString
        let location = min(selectedRange().location, ns.length)

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
        guard showsCurrentLineBand,
              selectedRanges.count == 1, selectedRange().length == 0,
              let fragment = caretLineFragment() else { return nil }
        return NSRect(x: 0,
                      y: fragment.minY + textContainerInset.height,
                      width: max(bounds.width, textContainer?.size.width ?? bounds.width),
                      height: fragment.height)
    }

    private func drawCurrentLineBand() {
        guard let rect = currentLineBandRect() else { return }
        Theme.lineHighlight.setFill()
        rect.fill()
    }

    /// The caret uses the complete configured code row, matching the active
    /// line background exactly.
    func caretRect(from rect: NSRect) -> NSRect {
        var r = rect
        r.size.height = Theme.lineMetrics().target
        r.size.width = 2
        return r
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        super.drawInsertionPoint(in: caretRect(from: rect), color: color, turnedOn: flag)
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
        guard window != nil else {
            clearCommandHover()
            return
        }
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
    }

    override func mouseEntered(with event: NSEvent) { updateCommandHover(with: event) }
    override func mouseMoved(with event: NSEvent) { updateCommandHover(with: event) }
    override func mouseExited(with event: NSEvent) { clearCommandHover() }

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

    /// VS Code's macOS folding shortcuts: ⌥⌘[ toggles the innermost block at
    /// the caret, and ⌥⌘] unfolds the pane.
    override func keyDown(with event: NSEvent) {
        onExplicitCaretInteraction?()
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 51, modifiers == [.shift] {
            deleteCurrentLine()
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

    private func innermostBlock(at location: Int) -> CodeBlock? {
        codeBlocks
            .filter { NSLocationInRange(location, $0.fullRange) }
            .max { $0.depth < $1.depth }
    }

    /// Keep the caret rect consistent when AppKit asks for it.
    override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
        super.setNeedsDisplay(rect.insetBy(dx: -1, dy: -2), avoidAdditionalLayout: flag)
    }
}

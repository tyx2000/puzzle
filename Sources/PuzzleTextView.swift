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
        drawCurrentLineBand()
        drawSearchMatches()
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

    /// The editor gave up focus — clicked away from, or the window went
    /// inactive. What that is worth saving is the pane's business.
    var onLostFocus: (() -> Void)?

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onLostFocus?() }
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

    /// A new line inherits the indentation of the one it came from. Without
    /// this every Return in indented code sent the caret back to column zero.
    override func insertNewline(_ sender: Any?) {
        let indent = carriedIndent(at: min(selectedRange().location, (string as NSString).length))
        guard !indent.isEmpty else {
            super.insertNewline(sender)
            return
        }
        insertText("\n" + indent, replacementRange: selectedRange())
    }

    /// Shift-Return: open a line under the current one, indented like it, from
    /// anywhere on the line. No need to walk the caret to the end first.
    @discardableResult
    func insertLineBelow() -> Bool {
        let source = string as NSString
        let caret = min(selectedRange().location, source.length)
        let indent = indentOfLine(at: caret)
        let insertion = endOfLineContent(at: caret)
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
}

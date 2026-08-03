import AppKit

/// NSTextView that paints the current-line band and keeps the caret the same
/// height as the text rather than the whole tall line box.
final class PuzzleTextView: NSTextView {

    /// Find-bar matches, drawn here (rather than as temporary attributes) so the
    /// bands are glyph-height instead of the full 1.8 line box, and so they paint
    /// *above* the current-line band instead of being hidden by it.
    var searchMatches: [NSRange] = [] { didSet { needsDisplay = true } }
    var currentMatchIndex: Int? { didSet { needsDisplay = true } }

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

        // Vertically centre on the glyphs, not the tall line box.
        let box = glyphBox(fragmentHeight: frag.height)
        let y = frag.minY + box.top + (box.height - size.height) / 2
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
        drawInlineBlame()
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
        let width = max(bounds.width, container.size.width)
        let visible = visibleRect
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
            (index == currentMatchIndex ? Theme.findMatchCurrent : Theme.findMatch).setFill()

            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphRange,
                withinSelectedGlyphRange: notSelected,
                in: container
            ) { [weak self] rect, _ in
                guard let self else { return }
                // Match the glyph box so the band isn't the full tall line height.
                var eff = NSRange()
                let frag = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location,
                                                          effectiveRange: &eff)
                let box = self.glyphBox(fragmentHeight: frag.height)
                var r = rect
                r.origin.y = frag.minY + box.top
                r.size.height = box.height
                r = r.offsetBy(dx: inset.width, dy: inset.height)
                r.fill()
            }
        }
    }

    /// Vertical geometry of the glyphs inside a line fragment.
    ///
    /// `lineHeightMultiple` adds its extra leading *above* the glyphs, so the text
    /// sits at the bottom of the line box: the space below the baseline stays at
    /// the font's natural `lineHeight - ascender`. That makes the glyph box a pure
    /// function of the fragment height:
    ///
    ///     top = fragmentHeight - naturalLineHeight
    ///
    /// NOTE: this used to read the baseline from `location(forGlyphAt:)`, which is
    /// only meaningful for real glyphs. On an empty line (right after Enter) or a
    /// control glyph it reports a fragment-absolute value instead, which put the
    /// caret ~4pt off and made it jump when the glyph under it changed (e.g. Tab).
    private func glyphBox(fragmentHeight: CGFloat) -> (top: CGFloat, height: CGFloat) {
        let font = self.font ?? Theme.editorFont()
        let natural = layoutManager?.defaultLineHeight(for: font)
            ?? (font.ascender - font.descender)
        return (fragmentHeight - natural, font.ascender - font.descender)
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
        didSet { if showsCurrentLineBand != oldValue { needsDisplay = true } }
    }

    func currentLineBandRect() -> NSRect? {
        guard showsCurrentLineBand,
              selectedRanges.count == 1, selectedRange().length == 0,
              let fragment = caretLineFragment() else { return nil }
        let box = glyphBox(fragmentHeight: fragment.height)
        return NSRect(x: 0,
                      y: fragment.minY + box.top + textContainerInset.height,
                      width: max(bounds.width, textContainer?.size.width ?? bounds.width),
                      height: box.height)
    }

    private func drawCurrentLineBand() {
        guard let rect = currentLineBandRect() else { return }
        Theme.lineHighlight.setFill()
        rect.fill()
    }

    /// The default caret spans the whole line fragment, which with a 1.8 line
    /// height towers over the text and above the current-line band. Shrink it to
    /// the glyph height and center it like the text.
    /// The caret rect for the current selection, aligned to the glyph box so it
    /// matches the current-line band exactly on every kind of line.
    func caretRect(from rect: NSRect) -> NSRect {
        var r = rect
        // AppKit hands us the full line box; shrink to the glyphs. `rect.height`
        // is the fragment height, so the same deterministic box applies.
        let box = glyphBox(fragmentHeight: rect.height)
        r.origin.y += box.top
        r.size.height = box.height
        r.size.width = 2
        return r
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        super.drawInsertionPoint(in: caretRect(from: rect), color: color, turnedOn: flag)
    }

    /// VS Code's macOS folding shortcuts: ⌥⌘[ toggles the innermost block at
    /// the caret, and ⌥⌘] unfolds the pane.
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
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

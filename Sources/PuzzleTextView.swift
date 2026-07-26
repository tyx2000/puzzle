import AppKit

/// NSTextView that paints the current-line band, keeps the caret the same height
/// as the text (not the whole tall line box), and can show a wrap guide.
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

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawCurrentLineBand()
        drawSearchMatches()
        drawWrapGuide()
    }

    private func drawSearchMatches() {
        guard !searchMatches.isEmpty,
              let layoutManager, let container = textContainer else { return }
        let inset = textContainerInset
        let notSelected = NSRange(location: NSNotFound, length: 0)

        for (index, range) in searchMatches.enumerated() {
            let clamped = NSIntersectionRange(range,
                                              NSRange(location: 0, length: (string as NSString).length))
            guard clamped.length > 0 else { continue }
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

    private func drawWrapGuide() {
        guard Settings.shared.showWrapGuides else { return }
        let x = textContainerInset.width + Theme.characterWidth() * CGFloat(Settings.shared.wrapColumn)
        guard x < bounds.width else { return }
        Theme.wrapGuide.setFill()
        NSRect(x: x, y: 0, width: 1, height: bounds.height).fill()
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

    /// Keep the caret rect consistent when AppKit asks for it.
    override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
        super.setNeedsDisplay(rect.insetBy(dx: -1, dy: -2), avoidAdditionalLayout: flag)
    }
}

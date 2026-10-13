import AppKit
import CoreText

/// A visual/foldable source block. Locations are UTF-16 offsets so they can be
/// passed directly to TextKit without converting from Swift String indices.
struct CodeBlock: Equatable {
    let openerLocation: Int
    let openerLineStart: Int
    let endLocation: Int
    /// Characters suppressed by a collapsed block. The opener's newline stays
    /// visible while the body and the closing line's newline are hidden. That
    /// lets the next visible source line occupy the very next layout fragment.
    let hiddenRange: NSRange
    let depth: Int

    var identity: Int { openerLocation }
    var fullRange: NSRange {
        NSRange(location: openerLineStart,
                length: max(0, endLocation - openerLineStart + 1))
    }

    func withDepth(_ depth: Int) -> CodeBlock {
        CodeBlock(openerLocation: openerLocation, openerLineStart: openerLineStart,
                  endLocation: endLocation, hiddenRange: hiddenRange,
                  depth: depth)
    }
}

/// Lightweight structure discovery for bracketed languages plus indentation
/// blocks in Python/YAML. It deliberately ignores braces inside common string
/// and comment forms; structure is presentation metadata, never saved text.
enum CodeBlockAnalyzer {
    static let maxCharacters = 2_000_000

    private enum LexicalMode {
        case normal, singleQuote, doubleQuote, backtick
        case tripleSingle, tripleDouble
        case lineComment, blockComment
    }

    private struct Opening {
        let character: unichar
        let location: Int
        let lineStart: Int
    }

    private struct Line {
        let start: Int
        let contentEnd: Int
        let indent: Int
        let trimmed: String
        var isBlank: Bool { trimmed.isEmpty }
    }

    static func analyze(_ text: String, language: String?,
                        tabSize: Int = Settings.shared.tabSize) -> [CodeBlock] {
        let source = text as NSString
        guard source.length > 0, source.length <= maxCharacters else { return [] }

        var blocks = bracketBlocks(in: source, language: language)
        if language == "python" || language == "yaml" {
            blocks += indentationBlocks(in: source, language: language!, tabSize: tabSize)
        }

        // Outer blocks sort before inner blocks that start on the same line.
        blocks.sort {
            if $0.openerLocation != $1.openerLocation {
                return $0.openerLocation < $1.openerLocation
            }
            return $0.endLocation > $1.endLocation
        }

        var nested: [CodeBlock] = []
        var stack: [CodeBlock] = []
        var seen = Set<String>()
        for block in blocks {
            let key = "\(block.openerLocation):\(block.endLocation)"
            guard seen.insert(key).inserted else { continue }
            while let parent = stack.last, parent.endLocation < block.endLocation {
                stack.removeLast()
            }
            let resolved = block.withDepth(stack.count)
            nested.append(resolved)
            stack.append(resolved)
        }
        return nested
    }

    private static func bracketBlocks(in source: NSString,
                                      language: String?) -> [CodeBlock] {
        var blocks: [CodeBlock] = []
        var openings: [Opening] = []
        var mode = LexicalMode.normal
        var escaped = false
        var lineStart = 0
        let hashComments = language == "python" || language == "yaml"
            || language == "bash" || language == "dockerfile"
            || language == "gitignore"

        var index = 0
        while index < source.length {
            let char = source.character(at: index)
            let next = index + 1 < source.length ? source.character(at: index + 1) : 0
            let nextTwo = index + 2 < source.length ? source.character(at: index + 2) : 0

            if char == 0x0A {
                if mode == .lineComment { mode = .normal }
                lineStart = index + 1
                escaped = false
                index += 1
                continue
            }

            switch mode {
            case .lineComment:
                index += 1
                continue
            case .blockComment:
                if char == 0x2A, next == 0x2F {
                    mode = .normal
                    index += 2
                } else {
                    index += 1
                }
                continue
            case .singleQuote, .doubleQuote, .backtick:
                let terminator: unichar = mode == .singleQuote ? 0x27
                    : (mode == .doubleQuote ? 0x22 : 0x60)
                if char == terminator, !escaped { mode = .normal }
                escaped = char == 0x5C && !escaped
                if char != 0x5C { escaped = false }
                index += 1
                continue
            case .tripleSingle, .tripleDouble:
                let terminator: unichar = mode == .tripleSingle ? 0x27 : 0x22
                if char == terminator, next == terminator, nextTwo == terminator {
                    mode = .normal
                    index += 3
                } else {
                    index += 1
                }
                continue
            case .normal:
                break
            }

            if char == 0x2F, next == 0x2F {
                mode = .lineComment
                index += 2
                continue
            }
            if char == 0x2F, next == 0x2A {
                mode = .blockComment
                index += 2
                continue
            }
            if hashComments, char == 0x23,
               index == lineStart
                || source.character(at: index - 1) == 0x20
                || source.character(at: index - 1) == 0x09 {
                mode = .lineComment
                index += 1
                continue
            }
            if (char == 0x27 || char == 0x22), next == char, nextTwo == char {
                mode = char == 0x27 ? .tripleSingle : .tripleDouble
                index += 3
                continue
            }
            if char == 0x27 || char == 0x22 || char == 0x60 {
                mode = char == 0x27 ? .singleQuote : (char == 0x22 ? .doubleQuote : .backtick)
                escaped = false
                index += 1
                continue
            }

            if char == 0x7B || char == 0x5B { // { [
                openings.append(Opening(
                    character: char, location: index, lineStart: lineStart))
            } else if char == 0x7D || char == 0x5D { // } ]
                let expected: unichar = char == 0x7D ? 0x7B : 0x5B
                if let opening = openings.last, opening.character == expected {
                    openings.removeLast()
                    if let block = makeBlock(source: source, opening: opening,
                                             closingLocation: index) {
                        blocks.append(block)
                    }
                }
            }
            index += 1
        }
        return blocks
    }

    private static func makeBlock(source: NSString, opening: Opening,
                                  closingLocation: Int) -> CodeBlock? {
        let openingLine = source.lineRange(
            for: NSRange(location: opening.location, length: 0))
        let closingLine = source.lineRange(
            for: NSRange(location: closingLocation, length: 0))
        guard openingLine.location != closingLine.location else { return nil }
        let hiddenStart = NSMaxRange(openingLine)
        let hiddenEnd = NSMaxRange(closingLine)
        guard hiddenEnd > hiddenStart else { return nil }
        return CodeBlock(
            openerLocation: opening.location,
            openerLineStart: opening.lineStart,
            endLocation: closingLocation,
            hiddenRange: NSRange(location: hiddenStart, length: hiddenEnd - hiddenStart),
            depth: 0)
    }

    private static func indentationBlocks(in source: NSString, language: String,
                                          tabSize: Int) -> [CodeBlock] {
        let lines = lineInfo(in: source, tabSize: tabSize)
        guard lines.count > 1 else { return [] }
        var blocks: [CodeBlock] = []

        for index in lines.indices {
            let line = lines[index]
            guard !line.isBlank else { continue }
            let opens: Bool
            if language == "python" {
                opens = line.trimmed.hasSuffix(":")
            } else {
                opens = line.trimmed.hasSuffix(":")
                    || line.trimmed == "-"
                    || line.trimmed.hasPrefix("- ")
            }
            guard opens,
                  let childIndex = ((index + 1)..<lines.count)
                    .first(where: { !lines[$0].isBlank }),
                  lines[childIndex].indent > line.indent else { continue }

            var afterBody = childIndex + 1
            while afterBody < lines.count {
                let candidate = lines[afterBody]
                if !candidate.isBlank, candidate.indent <= line.indent { break }
                afterBody += 1
            }
            let lastBody = lines[max(childIndex, afterBody - 1)]
            guard lastBody.contentEnd > line.contentEnd else { continue }
            let openingLineRange = source.lineRange(
                for: NSRange(location: line.start, length: 0))
            let lastBodyLineRange = source.lineRange(
                for: NSRange(location: lastBody.start, length: 0))
            let hiddenStart = NSMaxRange(openingLineRange)
            let hiddenEnd = NSMaxRange(lastBodyLineRange)
            blocks.append(CodeBlock(
                openerLocation: max(line.start, line.contentEnd - 1),
                openerLineStart: line.start,
                endLocation: lastBody.contentEnd,
                hiddenRange: NSRange(
                    location: hiddenStart,
                    length: max(0, hiddenEnd - hiddenStart)),
                depth: 0))
        }
        return blocks
    }

    private static func lineInfo(in source: NSString, tabSize: Int) -> [Line] {
        var lines: [Line] = []
        var location = 0
        while location < source.length {
            let range = source.lineRange(for: NSRange(location: location, length: 0))
            let end = contentEnd(of: range, in: source)
            var cursor = range.location
            var indent = 0
            while cursor < end {
                let char = source.character(at: cursor)
                if char == 0x20 {
                    indent += 1
                } else if char == 0x09 {
                    indent += tabSize - (indent % tabSize)
                } else {
                    break
                }
                cursor += 1
            }
            let raw = source.substring(with: NSRange(
                location: cursor, length: max(0, end - cursor)))
            lines.append(Line(
                start: range.location, contentEnd: end, indent: indent,
                trimmed: raw.trimmingCharacters(in: .whitespaces)))
            let next = NSMaxRange(range)
            guard next > location else { break }
            location = next
        }
        return lines
    }

    private static func contentEnd(of lineRange: NSRange, in source: NSString) -> Int {
        var end = NSMaxRange(lineRange)
        while end > lineRange.location {
            let char = source.character(at: end - 1)
            guard char == 0x0A || char == 0x0D else { break }
            end -= 1
        }
        return end
    }

}

/// TextKit-1 folding is pane-local: null glyphs collapse display without
/// deleting or attributing the shared document storage.
struct MarkdownTableRowMetric: Equatable {
    let range: NSRange
    let height: CGFloat
    /// A picture's line rather than a table row: found by the fragment's
    /// first drawn character, so the blank line above it — which TextKit lays
    /// out with the picture's hidden source — keeps its own height.
    var isImage = false
}

final class FoldingLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    private var blocks: [CodeBlock] = []
    private(set) var foldedBlockStarts = Set<Int>()
    private var markdownSyntaxRanges: [NSRange] = []
    private var markdownLeadRanges: [NSRange] = []
    /// A block's lead shown in the text: only while the caret is inside it.
    private var revealedLeadRange: NSRange?
    private var markdownCollapsedLineRanges: [NSRange] = []
    private var markdownGlyphReplacements: [MarkdownGlyphReplacement] = []
    private var revealedMarkdownRange: NSRange?
    private var markdownTableRowMetrics: [MarkdownTableRowMetric] = []
    private(set) var markdownTableMetricsNeedRefresh = false

    var foldedBlockIdentities: Set<Int> { foldedBlockStarts }

    override init() {
        super.init()
        delegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
    }

    func updateBlocks(_ blocks: [CodeBlock], resetFolds: Bool) {
        self.blocks = blocks
        if resetFolds {
            foldedBlockStarts.removeAll()
        } else {
            let available = Set(blocks.map(\.identity))
            foldedBlockStarts.formIntersection(available)
        }
        invalidateFoldedGlyphs()
    }

    // MARK: Invalidating no more than changed
    //
    // Every edit used to throw away the glyphs and layout of the whole
    // document: the hidden Markdown, the folds and the table rows arrived
    // again, every range after the edit moved, and anything different was
    // taken to mean everything was. Measured on an 1,800-line document, one
    // keystroke regenerated every glyph — 1.4s. What this layout manager holds
    // is now moved with each edit, as TextKit moves the glyphs themselves, so
    // what arrives next differs only where something really changed, and only
    // the lines there are laid out again.

    /// How many glyphs have been generated, for a test to tell a keystroke
    /// that laid out its own lines from one that redid the document.
    var glyphsGeneratedForTesting = 0

    /// Hidden state needs working out from scratch: the layout manager has
    /// been given another document, whose glyphs it knows nothing about.
    private var hiddenStateIsStale = true

    override var textStorage: NSTextStorage? {
        didSet {
            hiddenStateIsStale = true
            // Attaching lays the new document out from scratch; its folds are
            // whatever is restored next.
            appliedFoldedRanges = []
        }
    }

    /// The folds whose glyphs are hidden now, to tell what a change to them
    /// changed.
    private var appliedFoldedRanges: [NSRange] = []

    /// `ranges` after an edit that replaced `old` and changed the length by
    /// `delta`: those before it as they were, those after it moved, and what
    /// the edit replaced cut out of any that spanned it.
    static func shifted(_ ranges: [NSRange], replacing old: NSRange, delta: Int) -> [NSRange] {
        guard !ranges.isEmpty else { return ranges }
        let oldEnd = NSMaxRange(old)
        var result: [NSRange] = []
        result.reserveCapacity(ranges.count + 1)
        for range in ranges {
            let end = NSMaxRange(range)
            if end <= old.location {
                result.append(range)
            } else if range.location >= oldEnd {
                result.append(NSRange(location: range.location + delta, length: range.length))
            } else {
                if range.location < old.location {
                    result.append(NSRange(location: range.location,
                                          length: old.location - range.location))
                }
                if end > oldEnd {
                    result.append(NSRange(location: oldEnd + delta, length: end - oldEnd))
                }
            }
        }
        return result
    }

    /// A range the edit moved — or nil, when the edit reached into it and
    /// whatever it stood for is to be worked out again.
    static func moved(_ range: NSRange, replacing old: NSRange, delta: Int) -> NSRange? {
        if NSMaxRange(range) <= old.location { return range }
        if range.location >= NSMaxRange(old) {
            return NSRange(location: range.location + delta, length: range.length)
        }
        return nil
    }

    /// One range after the edit: grown or shrunk by an edit inside it, moved
    /// by one before it.
    static func shifted(_ range: NSRange?, replacing old: NSRange, delta: Int) -> NSRange? {
        guard let range else { return nil }
        let oldEnd = NSMaxRange(old)
        if old.location >= range.location, oldEnd <= NSMaxRange(range) {
            return NSRange(location: range.location, length: max(0, range.length + delta))
        }
        if oldEnd <= range.location {
            return NSRange(location: range.location + delta, length: range.length)
        }
        if old.location >= NSMaxRange(range) { return range }
        let start = min(range.location, old.location)
        return NSRange(location: start,
                       length: max(0, max(NSMaxRange(range), oldEnd) + delta - start))
    }

    /// Where two sorted lists of ranges cover different characters. Runs of
    /// equal entries at either end — after an edit, nearly all of them — are
    /// skipped without being looked at.
    static func changedRegions(_ a: [NSRange], _ b: [NSRange]) -> [NSRange] {
        guard a != b else { return [] }
        var head = 0
        while head < a.count, head < b.count, a[head] == b[head] { head += 1 }
        var tailA = a.count, tailB = b.count
        while tailA > head, tailB > head, a[tailA - 1] == b[tailB - 1] {
            tailA -= 1
            tailB -= 1
        }
        let restA = Array(a[head..<tailA]), restB = Array(b[head..<tailB])
        var points: [Int] = []
        for range in restA + restB {
            points.append(range.location)
            points.append(NSMaxRange(range))
        }
        points = Array(Set(points)).sorted()
        func covers(_ list: [NSRange], _ location: Int) -> Bool {
            var lower = 0, upper = list.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if location < list[middle].location {
                    upper = middle
                } else if location >= NSMaxRange(list[middle]) {
                    lower = middle + 1
                } else {
                    return true
                }
            }
            return false
        }
        var regions: [NSRange] = []
        for (start, end) in zip(points, points.dropFirst())
        where covers(restA, start) != covers(restB, start) {
            if let last = regions.last, NSMaxRange(last) == start {
                regions[regions.count - 1].length += end - start
            } else {
                regions.append(NSRange(location: start, length: end - start))
            }
        }
        // Equal coverage but different pieces — a range split in two — still
        // changes nothing on screen.
        return regions
    }

    /// Lay out again the lines `regions` touch — and the line before each:
    /// characters hidden at the start of a line are laid out with the line
    /// above it — regenerating their glyphs when what is hidden changed.
    private func invalidate(lines regions: [NSRange], glyphs: Bool) {
        guard let storage = textStorage, storage.length > 0, !regions.isEmpty else { return }
        let source = storage.string as NSString
        var spans: [NSRange] = []
        for region in regions.sorted(by: { $0.location < $1.location }) {
            let start = min(max(0, region.location), source.length)
            let end = min(max(start, NSMaxRange(region)), source.length)
            let first = source.lineRange(for: NSRange(location: start, length: 0))
            var before = first.location > 0
                ? source.lineRange(for: NSRange(location: first.location - 1, length: 0)) : first
            // From a line that is drawn: a line that draws nothing — a table's
            // divider, a fence — is laid out joined to its neighbours, and
            // laying out again from inside it broke the lines differently from
            // laying the document out whole: the row under a divider came out
            // a point high.
            var steps = 0
            while before.location > 0, steps < 64, drawsNothing(before, in: source) {
                before = source.lineRange(for: NSRange(location: before.location - 1, length: 0))
                steps += 1
            }
            let last = source.lineRange(for: NSRange(location: max(start, end - 1), length: 0))
            let span = NSUnionRange(before, last)
            if let previous = spans.last, NSMaxRange(previous) >= span.location {
                spans[spans.count - 1] = NSUnionRange(previous, span)
            } else {
                spans.append(span)
            }
        }
        for span in spans {
            if glyphs {
                invalidateGlyphs(forCharacterRange: span, changeInLength: 0,
                                 actualCharacterRange: nil)
            }
            invalidateLayout(forCharacterRange: span, actualCharacterRange: nil)
        }
    }

    private func drawsNothing(_ line: NSRange, in source: NSString) -> Bool {
        var index = line.location
        let end = min(NSMaxRange(line), source.length)
        while index < end {
            let character = source.character(at: index)
            if character != 0x0A, character != 0x0D,
               !isMarkdownSyntaxHidden(at: index), !isMarkdownControlLineCollapsed(at: index) {
                return false
            }
            index += 1
        }
        return true
    }

    /// Hidden state that came in in one go — a new document, or the first
    /// time — is applied to all of it.
    private func invalidateHiddenState(_ regions: [NSRange]) {
        if hiddenStateIsStale {
            hiddenStateIsStale = false
            invalidateHiddenGlyphs()
        } else {
            invalidate(lines: regions, glyphs: true)
        }
    }

    private static func replacementRegions(_ a: [MarkdownGlyphReplacement],
                                           _ b: [MarkdownGlyphReplacement]) -> [NSRange] {
        guard a != b else { return [] }
        var head = 0
        while head < a.count, head < b.count, a[head] == b[head] { head += 1 }
        var tailA = a.count, tailB = b.count
        while tailA > head, tailB > head, a[tailA - 1] == b[tailB - 1] {
            tailA -= 1
            tailB -= 1
        }
        return a[head..<tailA].map(\.sourceRange) + b[head..<tailB].map(\.sourceRange)
    }

    private static func revealRegions(_ old: NSRange?, _ new: NSRange?) -> [NSRange] {
        guard old != new else { return [] }
        return [old, new].compactMap { $0 }
    }

    private static func normalizedFolds(_ ranges: [NSRange]) -> [NSRange] {
        var merged: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) where range.length > 0 {
            if let last = merged.last, NSMaxRange(last) >= range.location {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    func isFolded(_ block: CodeBlock) -> Bool {
        foldedBlockStarts.contains(block.identity)
    }

    func isCharacterHidden(at location: Int) -> Bool {
        foldedRanges.contains { NSLocationInRange(location, $0) }
            || isMarkdownSyntaxHidden(at: location)
    }

    func isMarkdownControlLineCollapsed(at location: Int) -> Bool {
        revealedMarkdownRange.map { NSLocationInRange(location, $0) } != true
            && contains(location, in: markdownCollapsedLineRanges)
    }

    func updateMarkdownSyntaxRanges(_ ranges: [NSRange],
                                    leads: [NSRange] = [],
                                    collapsedLines: [NSRange] = [],
                                    replacements: [MarkdownGlyphReplacement] = [],
                                    revealing range: NSRange?,
                                    revealingLead lead: NSRange? = nil) {
        guard hiddenStateIsStale
                || ranges != markdownSyntaxRanges
                || leads != markdownLeadRanges
                || collapsedLines != markdownCollapsedLineRanges
                || replacements != markdownGlyphReplacements
                || range != revealedMarkdownRange
                || lead != revealedLeadRange else { return }
        let changed = Self.changedRegions(markdownSyntaxRanges, ranges)
            + Self.changedRegions(markdownLeadRanges, leads)
            + Self.changedRegions(markdownCollapsedLineRanges, collapsedLines)
            + Self.replacementRegions(markdownGlyphReplacements, replacements)
            + Self.revealRegions(revealedMarkdownRange, range)
            + Self.revealRegions(revealedLeadRange, lead)
        markdownSyntaxRanges = ranges
        markdownLeadRanges = leads
        markdownCollapsedLineRanges = collapsedLines
        markdownGlyphReplacements = replacements
        revealedMarkdownRange = range
        revealedLeadRange = lead
        invalidateHiddenState(changed)
    }

    /// Show the source of `range` — the line being edited, or a line that
    /// draws nothing otherwise — and of `lead`, a block's lead the caret is
    /// inside. Answers whether anything changed.
    @discardableResult
    func revealMarkdownSyntax(in range: NSRange?, lead: NSRange? = nil) -> Bool {
        guard range != revealedMarkdownRange || lead != revealedLeadRange else { return false }
        let changed = Self.revealRegions(revealedMarkdownRange, range)
            + Self.revealRegions(revealedLeadRange, lead)
        revealedMarkdownRange = range
        revealedLeadRange = lead
        invalidateHiddenState(changed)
        return true
    }

    func updateMarkdownTableRowMetrics(_ metrics: [MarkdownTableRowMetric]) {
        markdownTableMetricsNeedRefresh = false
        guard metrics != markdownTableRowMetrics else { return }
        let old = markdownTableRowMetrics
        markdownTableRowMetrics = metrics
        var head = 0
        while head < old.count, head < metrics.count, old[head] == metrics[head] { head += 1 }
        var tailOld = old.count, tailNew = metrics.count
        while tailOld > head, tailNew > head, old[tailOld - 1] == metrics[tailNew - 1] {
            tailOld -= 1
            tailNew -= 1
        }
        invalidate(lines: old[head..<tailOld].map(\.range) + metrics[head..<tailNew].map(\.range),
                   glyphs: false)
    }

    func markdownTableRowHeightForTesting(at location: Int) -> CGFloat? {
        markdownTableRowMetrics.first { NSLocationInRange(location, $0.range) }?.height
    }

    func restoreFoldedBlockIdentities(_ identities: Set<Int>) {
        let available = Set(blocks.map(\.identity))
        foldedBlockStarts = identities.intersection(available)
        invalidateFoldedGlyphs()
    }

    /// A folded block is remembered by the character offset of its opener, and
    /// every edit before it moves that offset. Shift the remembered offsets by
    /// the same delta here, or the fold silently opens on the next reanalysis —
    /// and can re-attach to whatever block now starts at the old offset.
    override func processEditing(for textStorage: NSTextStorage,
                                 edited editMask: NSTextStorageEditActions,
                                 range newCharRange: NSRange,
                                 changeInLength delta: Int,
                                 invalidatedRange invalidatedCharRange: NSRange) {
        // Moved before TextKit hears of the edit: it can generate the edited
        // lines' glyphs straight away, and against the old positions it hid
        // the wrong characters — a list item's `-` drawn after a line above it
        // lost its `##`.
        if editMask.contains(.editedCharacters) {
            // What was replaced, in the text as it was.
            let old = NSRange(location: newCharRange.location,
                              length: max(0, newCharRange.length - delta))
            markdownSyntaxRanges = Self.shifted(markdownSyntaxRanges, replacing: old, delta: delta)
            markdownLeadRanges = Self.shifted(markdownLeadRanges, replacing: old, delta: delta)
            markdownCollapsedLineRanges = Self.shifted(markdownCollapsedLineRanges,
                                                       replacing: old, delta: delta)
            markdownGlyphReplacements = markdownGlyphReplacements.compactMap { replacement in
                Self.moved(replacement.sourceRange, replacing: old, delta: delta).map {
                    MarkdownGlyphReplacement(sourceRange: $0, character: replacement.character)
                }
            }
            revealedMarkdownRange = Self.shifted(revealedMarkdownRange, replacing: old, delta: delta)
            revealedLeadRange = Self.shifted(revealedLeadRange, replacing: old, delta: delta)
            let previousMetricCount = markdownTableRowMetrics.count
            markdownTableRowMetrics = markdownTableRowMetrics.compactMap { metric in
                Self.moved(metric.range, replacing: old, delta: delta).map {
                    MarkdownTableRowMetric(range: $0, height: metric.height,
                                           isImage: metric.isImage)
                }
            }
            if markdownTableRowMetrics.count != previousMetricCount {
                markdownTableMetricsNeedRefresh = true
            }
            appliedFoldedRanges = Self.shifted(appliedFoldedRanges, replacing: old, delta: delta)
        }
        super.processEditing(for: textStorage, edited: editMask, range: newCharRange,
                             changeInLength: delta,
                             invalidatedRange: invalidatedCharRange)
        guard editMask.contains(.editedCharacters), delta != 0,
              !foldedBlockStarts.isEmpty else { return }
        let editStart = newCharRange.location
        let removedEnd = editStart + max(0, (newCharRange.length - delta))
        foldedBlockStarts = Set(foldedBlockStarts.compactMap { start in
            if start < editStart { return start }
            // An opener inside the replaced text is gone; dropping it is right,
            // and keeping a shifted ghost would fold an unrelated block.
            if start < removedEnd { return nil }
            return start + delta
        })
    }

    func toggle(_ block: CodeBlock) {
        if foldedBlockStarts.remove(block.identity) == nil {
            foldedBlockStarts.insert(block.identity)
        }
        invalidateFoldedGlyphs()
    }

    func unfoldAll() {
        guard !foldedBlockStarts.isEmpty else { return }
        foldedBlockStarts.removeAll()
        invalidateFoldedGlyphs()
    }

    private var foldedRanges: [NSRange] {
        blocks.compactMap { foldedBlockStarts.contains($0.identity) ? $0.hiddenRange : nil }
    }

    /// Only the folds that opened or closed — usually none: the blocks arrive
    /// again after every edit, and nothing folded is the common case.
    private func invalidateFoldedGlyphs() {
        let now = Self.normalizedFolds(foldedRanges)
        let changed = Self.changedRegions(appliedFoldedRanges, now)
        appliedFoldedRanges = now
        invalidate(lines: changed, glyphs: true)
    }

    private func invalidateHiddenGlyphs() {
        guard let storage = textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        invalidateGlyphs(forCharacterRange: full, changeInLength: 0,
                         actualCharacterRange: nil)
        invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes charIndexes: UnsafePointer<Int>,
        font aFont: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        glyphsGeneratedForTesting += glyphRange.length
        let folded = foldedRanges
        guard !folded.isEmpty || !markdownSyntaxRanges.isEmpty || !markdownLeadRanges.isEmpty
                || !markdownGlyphReplacements.isEmpty else { return 0 }
        var modifiedGlyphs = Array(
            UnsafeBufferPointer(start: glyphs, count: glyphRange.length))
        var modified = Array(
            UnsafeBufferPointer(start: props, count: glyphRange.length))
        var changed = false
        for offset in 0..<glyphRange.length {
            let character = charIndexes[offset]
            let foldedCharacter = folded.contains { NSLocationInRange(character, $0) }
            let markdownCharacter = isMarkdownSyntaxHidden(at: character)
            if foldedCharacter || markdownCharacter {
                modified[offset].insert(.null)
                changed = true
            } else if revealedMarkdownRange.map({ NSLocationInRange(character, $0) }) != true,
                      let replacement = markdownReplacement(containing: character) {
                if character == replacement.sourceRange.location {
                    var unicode = UniChar(replacement.character)
                    var glyph: CGGlyph = 0
                    if CTFontGetGlyphsForCharacters(aFont, &unicode, &glyph, 1), glyph != 0 {
                        modifiedGlyphs[offset] = glyph
                        modified[offset].remove(.null)
                        changed = true
                    }
                } else {
                    modified[offset].insert(.null)
                    changed = true
                }
            }
        }
        guard changed else { return 0 }
        modified.withUnsafeBufferPointer {
            layoutManager.setGlyphs(
                modifiedGlyphs, properties: $0.baseAddress!,
                characterIndexes: charIndexes, font: aFont,
                forGlyphRange: glyphRange)
        }
        return glyphRange.length
    }

    /// Markdown ranges are sorted and non-overlapping, so lookup stays
    /// logarithmic even in long documentation files.
    private func contains(_ location: Int, in ranges: [NSRange]) -> Bool {
        var lower = 0
        var upper = ranges.count
        while lower < upper {
            let middle = (lower + upper) / 2
            let range = ranges[middle]
            if location < range.location {
                upper = middle
            } else if location >= NSMaxRange(range) {
                lower = middle + 1
            } else {
                return true
            }
        }
        return false
    }

    private func markdownReplacement(containing location: Int)
        -> MarkdownGlyphReplacement? {
        var lower = 0
        var upper = markdownGlyphReplacements.count
        while lower < upper {
            let middle = (lower + upper) / 2
            let replacement = markdownGlyphReplacements[middle]
            if location < replacement.sourceRange.location {
                upper = middle
            } else if location >= NSMaxRange(replacement.sourceRange) {
                lower = middle + 1
            } else {
                return replacement
            }
        }
        return nil
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer,
        forGlyphRange glyphRange: NSRange
    ) -> Bool {
        if glyphRange.length > 0 {
            let firstCharacter = characterIndexForGlyph(at: glyphRange.location)
            let lastCharacter = characterIndexForGlyph(
                at: NSMaxRange(glyphRange) - 1)
            let characterRange = NSRange(
                location: min(firstCharacter, lastCharacter),
                length: abs(lastCharacter - firstCharacter) + 1)
            // A null-glyph Markdown control line can be coalesced into the same
            // TextKit fragment as the preceding line terminator. Intersection
            // testing therefore compresses the preceding visible content line
            // to 1pt, most visibly on the final row of a fenced code block.
            // Classify the fragment by its first non-newline source character.
            let representative = firstContentCharacter(in: characterRange)
            let isRevealed = revealedMarkdownRange.map {
                NSLocationInRange(representative, $0)
            } == true
            if !isRevealed && contains(representative,
                                       in: markdownCollapsedLineRanges) {
                lineFragmentRect.pointee.size.height = 1
                lineFragmentUsedRect.pointee.size.height = 1
                baselineOffset.pointee = 0
                return true
            }
            if !isRevealed,
               let metric = markdownTableRowMetrics.first(where: {
                   !$0.isImage && NSLocationInRange(representative, $0.range)
               }) ?? markdownImageMetric(forCharacters: characterRange) {
                // Heights arrive measured, including the deliberate 1pt one
                // that swallows a rendered table's trailing terminator.
                let height = metric.height
                lineFragmentRect.pointee.size.height = height
                lineFragmentUsedRect.pointee.size.height = height
                baselineOffset.pointee = height < Theme.lineMetrics().target
                    ? 0
                    : (height - Theme.lineMetrics().natural) / 2
                        + Theme.editorFont().ascender
                return true
            }
        }
        // Rendered Markdown sizes each line for what it holds — a heading, a
        // line of prose, the gap a blank line stands for, a row of code —
        // rather than giving every line the code row.
        if glyphRange.length > 0, let placed = markdownLineBox(forGlyphRange: glyphRange) {
            lineFragmentRect.pointee.size.height = placed.height
            lineFragmentUsedRect.pointee.size.height = placed.height
            baselineOffset.pointee = placed.layout.baselineOffset(spaceAbove: placed.spaceAbove)
            return true
        }
        let metrics = Theme.lineMetrics()
        lineFragmentRect.pointee.size.height = metrics.target
        lineFragmentUsedRect.pointee.size.height = metrics.target

        let font = Theme.editorFont()
        let glyphHeight = font.ascender - font.descender
        baselineOffset.pointee = (metrics.target - glyphHeight) / 2 + font.ascender
        return true
    }

    /// The layout of the rendered-Markdown line a fragment belongs to, and the
    /// space above it — given only to the first fragment of its line, never to
    /// the lines a long one wraps onto. Nil outside rendered Markdown.
    ///
    /// A fragment is the line its first *drawn* character is on. Characters
    /// hidden at the start of a line — a heading's `#`, a list's `-` — have
    /// no place of their own, and TextKit lays them out with the line before:
    /// read by its first character, the blank line above a heading took the
    /// heading's height and the heading lost the room above it.
    private func markdownLineBox(forGlyphRange glyphRange: NSRange)
        -> (layout: MarkdownLineLayout, spaceAbove: CGFloat, height: CGFloat)? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let source = storage.string as NSString
        let first = characterIndexForGlyph(at: glyphRange.location)
        let last = characterIndexForGlyph(at: NSMaxRange(glyphRange) - 1)
        let characters = NSRange(location: min(first, last),
                                 length: abs(last - first) + 1)
        var representative = min(characters.location, source.length - 1)
        for index in characters.location..<min(NSMaxRange(characters), source.length) {
            let character = source.character(at: index)
            if character == 0x0A || character == 0x0D { continue }
            if !isMarkdownSyntaxHidden(at: index) {
                representative = index
                break
            }
        }
        guard var layout = storage.attribute(.markdownLineLayout, at: representative,
                                             effectiveRange: nil) as? MarkdownLineLayout
        else { return nil }
        if let revealed = layout.whenRevealed,
           revealedMarkdownRange.map({ NSLocationInRange(representative, $0) }) == true {
            layout = revealed
        }
        // The room above a line is its first fragment's: the first one that
        // draws anything of the line, whatever hidden characters lead it.
        let lineStart = source.lineRange(
            for: NSRange(location: representative, length: 0)).location
        var isFirst = true
        var index = lineStart
        while index < representative {
            if !isMarkdownSyntaxHidden(at: index) {
                isFirst = false
                break
            }
            index += 1
        }
        let spaceAbove = isFirst ? layout.spaceBefore : 0
        return (layout, spaceAbove, layout.lineHeight + spaceAbove)
    }

    /// Hidden as Markdown syntax — the lookup the line sizing can afford for
    /// every fragment, without the folds `isCharacterHidden` also checks. A
    /// block's lead is hidden even on the line being edited; it shows only
    /// while the caret is inside it.
    private func isMarkdownSyntaxHidden(at location: Int) -> Bool {
        if contains(location, in: markdownLeadRanges) {
            return revealedLeadRange.map { NSLocationInRange(location, $0) } != true
        }
        return revealedMarkdownRange.map { NSLocationInRange(location, $0) } != true
            && contains(location, in: markdownSyntaxRanges)
    }

    /// Inline syntax that is hidden — a `**`, a link's `](…)` — as opposed to
    /// a block's lead. The caret steps over it, and Delete never removes it
    /// unseen.
    func isMarkdownInlineSyntaxHidden(at location: Int) -> Bool {
        !contains(location, in: markdownLeadRanges) && isMarkdownSyntaxHidden(at: location)
    }

    /// A block's lead that is hidden — a heading's `## `, a list's `- `.
    func isMarkdownLeadHidden(at location: Int) -> Bool {
        contains(location, in: markdownLeadRanges) && isMarkdownSyntaxHidden(at: location)
    }

    /// The lead that ends at `location`, where the block's text starts.
    func markdownLeadRange(endingAt location: Int) -> NSRange? {
        markdownLeadRanges.first { NSMaxRange($0) == location }
    }

    /// An entity drawn as the one character it stands for — `&amp;` as `&` —
    /// which the caret and Delete take whole.
    func markdownDrawnReplacement(containing location: Int) -> NSRange? {
        guard revealedMarkdownRange.map({ NSLocationInRange(location, $0) }) != true,
              let replacement = markdownReplacement(containing: location) else { return nil }
        return replacement.sourceRange
    }

    /// Where the text of the rendered-Markdown line holding `glyph` sits in
    /// its fragment: below the space a heading keeps above it, and as tall as
    /// the line — what the caret is drawn against. Nil outside rendered
    /// Markdown, and for the collapsed and measured lines that hold no text.
    func markdownTextBox(forGlyphAt glyph: Int) -> (fragment: NSRect, text: NSRect)? {
        guard glyph < numberOfGlyphs else { return nil }
        var fragmentGlyphs = NSRange()
        let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: &fragmentGlyphs)
        guard fragmentGlyphs.length > 0,
              let placed = markdownLineBox(forGlyphRange: fragmentGlyphs),
              abs(fragment.height - placed.height) < 0.5 else { return nil }
        return (fragment, NSRect(x: fragment.minX, y: fragment.minY + placed.spaceAbove,
                                 width: fragment.width, height: placed.layout.lineHeight))
    }

    /// A picture's metric, by the fragment's first drawn character — or by
    /// its first character when it draws none, as the picture's own line does.
    private func markdownImageMetric(forCharacters range: NSRange) -> MarkdownTableRowMetric? {
        guard markdownTableRowMetrics.contains(where: \.isImage),
              let storage = textStorage, storage.length > 0 else { return nil }
        let source = storage.string as NSString
        var drawn = min(range.location, source.length - 1)
        for index in range.location..<min(NSMaxRange(range), source.length) {
            let character = source.character(at: index)
            if character == 0x0A || character == 0x0D { continue }
            if !isMarkdownSyntaxHidden(at: index) {
                drawn = index
                break
            }
        }
        return markdownTableRowMetrics.first {
            $0.isImage && NSLocationInRange(drawn, $0.range)
        }
    }

    private func firstContentCharacter(in range: NSRange) -> Int {
        guard let storage = textStorage, storage.length > 0 else {
            return range.location
        }
        let source = storage.string as NSString
        let end = min(NSMaxRange(range), source.length)
        var location = min(range.location, max(0, source.length - 1))
        while location < end {
            let character = source.character(at: location)
            if character != 0x0A && character != 0x0D { return location }
            location += 1
        }
        return min(range.location, max(0, source.length - 1))
    }
}

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
}

final class FoldingLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    private var blocks: [CodeBlock] = []
    private(set) var foldedBlockStarts = Set<Int>()
    private var markdownSyntaxRanges: [NSRange] = []
    private var markdownCollapsedLineRanges: [NSRange] = []
    private var markdownGlyphReplacements: [MarkdownGlyphReplacement] = []
    private var revealedMarkdownRange: NSRange?
    private var markdownTableRowMetrics: [MarkdownTableRowMetric] = []

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

    func isFolded(_ block: CodeBlock) -> Bool {
        foldedBlockStarts.contains(block.identity)
    }

    func isCharacterHidden(at location: Int) -> Bool {
        foldedRanges.contains { NSLocationInRange(location, $0) }
            || (revealedMarkdownRange.map { NSLocationInRange(location, $0) } != true
                && contains(location, in: markdownSyntaxRanges))
    }

    func isMarkdownControlLineCollapsed(at location: Int) -> Bool {
        revealedMarkdownRange.map { NSLocationInRange(location, $0) } != true
            && contains(location, in: markdownCollapsedLineRanges)
    }

    func updateMarkdownSyntaxRanges(_ ranges: [NSRange],
                                    collapsedLines: [NSRange] = [],
                                    replacements: [MarkdownGlyphReplacement] = [],
                                    revealing range: NSRange?) {
        guard ranges != markdownSyntaxRanges
                || collapsedLines != markdownCollapsedLineRanges
                || replacements != markdownGlyphReplacements
                || range != revealedMarkdownRange else { return }
        markdownSyntaxRanges = ranges
        markdownCollapsedLineRanges = collapsedLines
        markdownGlyphReplacements = replacements
        revealedMarkdownRange = range
        invalidateHiddenGlyphs()
    }

    func revealMarkdownSyntax(in range: NSRange?) {
        guard range != revealedMarkdownRange else { return }
        revealedMarkdownRange = range
        invalidateHiddenGlyphs()
    }

    func updateMarkdownTableRowMetrics(_ metrics: [MarkdownTableRowMetric]) {
        guard metrics != markdownTableRowMetrics else { return }
        markdownTableRowMetrics = metrics
        guard let storage = textStorage else { return }
        invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length),
                         actualCharacterRange: nil)
    }

    func markdownTableRowHeightForTesting(at location: Int) -> CGFloat? {
        markdownTableRowMetrics.first { NSLocationInRange(location, $0.range) }?.height
    }

    func restoreFoldedBlockIdentities(_ identities: Set<Int>) {
        let available = Set(blocks.map(\.identity))
        foldedBlockStarts = identities.intersection(available)
        invalidateFoldedGlyphs()
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

    private func invalidateFoldedGlyphs() {
        invalidateHiddenGlyphs()
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
        let folded = foldedRanges
        guard !folded.isEmpty || !markdownSyntaxRanges.isEmpty
                || !markdownGlyphReplacements.isEmpty else { return 0 }
        var modifiedGlyphs = Array(
            UnsafeBufferPointer(start: glyphs, count: glyphRange.length))
        var modified = Array(
            UnsafeBufferPointer(start: props, count: glyphRange.length))
        var changed = false
        for offset in 0..<glyphRange.length {
            let character = charIndexes[offset]
            let foldedCharacter = folded.contains { NSLocationInRange(character, $0) }
            let markdownCharacter = revealedMarkdownRange.map {
                NSLocationInRange(character, $0)
            } != true && contains(character, in: markdownSyntaxRanges)
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
                   NSLocationInRange(representative, $0.range)
               }) {
                let height = max(Theme.lineMetrics().target, metric.height)
                lineFragmentRect.pointee.size.height = height
                lineFragmentUsedRect.pointee.size.height = height
                baselineOffset.pointee = (height - Theme.lineMetrics().natural) / 2
                    + Theme.editorFont().ascender
                return true
            }
        }
        let metrics = Theme.lineMetrics()
        lineFragmentRect.pointee.size.height = metrics.target
        lineFragmentUsedRect.pointee.size.height = metrics.target

        let font = Theme.editorFont()
        let glyphHeight = font.ascender - font.descender
        baselineOffset.pointee = (metrics.target - glyphHeight) / 2 + font.ascender
        return true
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

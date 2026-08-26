import AppKit

struct MarkdownCodeBlockDecoration: Equatable {
    let range: NSRange
    let language: String?
}

struct MarkdownTableDecoration: Equatable {
    struct Row: Equatable {
        let sourceRange: NSRange
        /// Complete logical line including its terminator. TextKit uses this
        /// range to give the rendered row one dynamic-height fragment.
        let lineRange: NSRange
        let cells: [String]
        let isHeader: Bool
    }
    let sourceRange: NSRange
    let rows: [Row]
    let columnCount: Int
}

struct MarkdownTaskDecoration: Equatable {
    let sourceRange: NSRange
    let checked: Bool
}

enum MarkdownLineMarkerKind: Equatable {
    case bullet(String)
    case quote(Int)
    case footnote(String)
}

struct MarkdownLineMarkerDecoration: Equatable {
    let sourceRange: NSRange
    let kind: MarkdownLineMarkerKind
}

struct MarkdownRuleDecoration: Equatable {
    let lineRange: NSRange
}

struct MarkdownImageDecoration: Equatable {
    let sourceRange: NSRange
    let lineRange: NSRange
    let alt: String
    let url: URL?
}

struct MarkdownGlyphReplacement: Equatable {
    let sourceRange: NSRange
    let character: UInt16
}

struct MarkdownPresentation: Equatable {
    var hiddenSyntaxRanges: [NSRange] = []
    var collapsedLineRanges: [NSRange] = []
    var codeBlocks: [MarkdownCodeBlockDecoration] = []
    var tables: [MarkdownTableDecoration] = []
    var tasks: [MarkdownTaskDecoration] = []
    var lineMarkers: [MarkdownLineMarkerDecoration] = []
    var rules: [MarkdownRuleDecoration] = []
    var images: [MarkdownImageDecoration] = []
    var glyphReplacements: [MarkdownGlyphReplacement] = []
}

/// Paints Markdown semantics directly onto the editable source buffer.
///
/// The styler never inserts, removes, or replaces characters. That invariant
/// keeps TextKit ranges, undo, search, selections, and the bytes written to disk
/// aligned with the Markdown source while editing and reading share one surface.
enum MarkdownLiveStyler {
    private static func expression(_ pattern: String,
                                   options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // These are compile-time fixtures; a malformed pattern is a programmer
        // error and should fail loudly in tests/builds.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let heading = expression(#"^(#{1,6})[\t ]+(.+?)[\t ]*#*[\t ]*$"#,
                                            options: [.anchorsMatchLines])
    private static let quote = expression(#"^[\t ]*(>+)[\t ]?"#,
                                          options: [.anchorsMatchLines])
    private static let list = expression(#"^[\t ]*(?:([-+*])|(\d+[.)]))[\t ]+"#,
                                         options: [.anchorsMatchLines])
    private static let thematicBreak = expression(#"^[\t ]{0,3}(?:(?:\*[\t ]*){3,}|(?:-[\t ]*){3,}|(?:_[\t ]*){3,})$"#,
                                                  options: [.anchorsMatchLines])
    private static let fence = expression(#"^([\t ]*)(`{3,}|~{3,})[^\n]*\n([\s\S]*?)^\1\2[\t ]*$"#,
                                          options: [.anchorsMatchLines])
    private static let inlineCode = expression(#"(`+)([^\n]*?)\1"#)
    private static let strong = expression(#"(?<![\\*])(?:\*\*|__)(?=\S)(.+?\S)(?:\*\*|__)"#)
    private static let emphasis = expression(#"(?<![\*_])(?:\*|_)(?=\S)(.+?\S)(?:\*|_)(?![\*_])"#)
    private static let strike = expression(#"~~(?=\S)(.+?\S)~~"#)
    private static let link = expression(#"!?\[([^\]\n]+)\]\(([^)\n]+)\)"#)
    private static let autoLink = expression(#"<(https?://[^>\s]+)>"#)
    private static let emailAutoLink = expression(
        #"<([A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?(?:\.[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?)+)>"#,
        options: [.caseInsensitive])
    private static let bareURL = expression(#"(?<![<(])\bhttps?://[^\s<>\]]+"#,
                                            options: [.caseInsensitive])
    private static let task = expression(
        #"^[\t ]*[-+*][\t ]+\[([ xX])\][\t ]+"#,
        options: [.anchorsMatchLines])
    private static let standaloneImage = expression(
        #"^[\t ]*!\[([^\]\n]*)\]\((?:<([^>\n]+)>|([^\s)\n]+))(?:[\t ]+[\"'][^\"']*[\"'])?\)[\t ]*$"#,
        options: [.anchorsMatchLines])
    private static let referenceDefinition = expression(
        #"^[\t ]{0,3}\[([^\]\n]+)\]:[\t ]+(?:<([^>\n]+)>|([^\s\n]+)).*$"#,
        options: [.anchorsMatchLines])
    private static let footnoteDefinition = expression(
        #"^[\t ]{0,3}\[\^([^\]\n]+)\]:[\t ]+"#,
        options: [.anchorsMatchLines])
    private static let footnoteReference = expression(#"\[\^([^\]\n]+)\]"#)
    private static let escapedPunctuation = expression(#"\\([\\`*{}\[\]()#+\-.!_>~|])"#)
    private static let simpleHTMLPair = expression(
        #"<([A-Za-z][A-Za-z0-9-]*)(?:[\t ][^>\n]*)?>([^<\n]*)</\1>"#)
    private static let htmlComment = expression(#"<!--[\s\S]*?-->"#)
    private static let htmlTag = expression(
        #"</?[A-Za-z][A-Za-z0-9-]*(?:[\t ][^>\n]*)?/?>"#)
    private static let hardBreakMarker = expression(#"(?:\\|[\t ]{2,})$"#,
                                                    options: [.anchorsMatchLines])
    private static let htmlEntity = expression(
        #"&(?:#([0-9]+)|#x([0-9A-Fa-f]+)|([A-Za-z][A-Za-z0-9]+));"#)

    /// Returns source ranges whose glyphs should be collapsed by the pane's
    /// layout manager while the user is not editing their line.
    @discardableResult
    static func apply(text: String, to storage: NSTextStorage,
                      documentURL: URL? = nil) -> MarkdownPresentation {
        let full = NSRange(location: 0, length: storage.length)
        guard full.length > 0 else { return MarkdownPresentation() }
        let source = text as NSString
        let baseFont = Theme.editorFont()
        let boldFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
        let italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
        let boldItalicFont = NSFontManager.shared.convert(
            boldFont, toHaveTrait: .italicFontMask)
        let marker: [NSAttributedString.Key: Any] = [.foregroundColor: Theme.dimText]
        let code: [NSAttributedString.Key: Any] = [
            .foregroundColor: Theme.foreground,
        ]
        let inlineCodeStyle: [NSAttributedString.Key: Any] = [
            .foregroundColor: Theme.yellow,
            .backgroundColor: Theme.inputBackground,
        ]
        let linkStyle: [NSAttributedString.Key: Any] = [
            .foregroundColor: Theme.blue,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]

        var fencedRanges: [NSRange] = []
        var syntaxRanges: [NSRange] = []
        var collapsedLines: [NSRange] = []
        var codeBlocks: [MarkdownCodeBlockDecoration] = []
        var tasks: [MarkdownTaskDecoration] = []
        var lineMarkers: [MarkdownLineMarkerDecoration] = []
        var rules: [MarkdownRuleDecoration] = []
        var images: [MarkdownImageDecoration] = []
        var inlineCodeRanges: [NSRange] = []
        var glyphReplacements: [MarkdownGlyphReplacement] = []
        var footnoteDefinitionRanges: [NSRange] = []
        storage.beginEditing()

        enumerate(fence, in: source, full: full) { match in
            fencedRanges.append(match.range)
            let opening = source.lineRange(for: NSRange(location: match.range.location, length: 0))
            let closingLocation = max(match.range.location, NSMaxRange(match.range) - 1)
            let closing = source.lineRange(for: NSRange(location: closingLocation, length: 0))
            let openingText = source.substring(with: lineContentRange(opening, in: source))
            let delimiter = match.range(at: 2)
            let delimiterText = source.substring(with: delimiter)
            let language = openingText
                .replacingOccurrences(of: delimiterText, with: "", options: .anchored)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let bodyStart = NSMaxRange(opening)
            let bodyEnd = closing.location
            let body = NSRange(location: bodyStart, length: max(0, bodyEnd - bodyStart))
            if body.length > 0 {
                storage.addAttributes(code, range: body)
                codeBlocks.append(MarkdownCodeBlockDecoration(
                    range: body, language: language.isEmpty ? nil : language))
            }
            // Opening line, closing line, and delimiters remain editable but
            // recede visually from the code payload.
            storage.addAttributes(marker, range: NSIntersectionRange(opening, match.range))
            storage.addAttributes(marker, range: NSIntersectionRange(closing, match.range))
            syntaxRanges.append(lineContentRange(opening, in: source))
            syntaxRanges.append(lineContentRange(closing, in: source))
            collapsedLines.append(opening)
            collapsedLines.append(closing)
        }

        enumerate(heading, in: source, full: full) { match in
            let markerRange = match.range(at: 1)
            let contentRange = match.range(at: 2)
            storage.addAttributes(marker, range: markerRange)
            syntaxRanges.append(NSRange(location: match.range.location,
                                        length: contentRange.location - match.range.location))
            if NSMaxRange(contentRange) < NSMaxRange(match.range) {
                syntaxRanges.append(NSRange(location: NSMaxRange(contentRange),
                                            length: NSMaxRange(match.range)
                                                - NSMaxRange(contentRange)))
            }
            let level = max(1, min(6, markerRange.length))
            let scale: CGFloat = [1.0, 1.22, 1.16, 1.10, 1.05, 1.0, 1.0][level]
            let maximum = max(baseFont.pointSize, Theme.lineMetrics().target * 0.72)
            let size = min(baseFont.pointSize * scale, maximum)
            let font = NSFont(descriptor: boldFont.fontDescriptor, size: size) ?? boldFont
            storage.addAttributes([.font: font,
                                   .strokeWidth: -2.0,
                                   .foregroundColor: Theme.foreground],
                                  range: contentRange)
        }

        enumerate(quote, in: source, full: full) { match in
            guard !intersects(match.range, fencedRanges) else { return }
            storage.addAttributes(marker, range: match.range)
            let text = source.substring(with: match.range(at: 1))
            lineMarkers.append(MarkdownLineMarkerDecoration(
                sourceRange: match.range,
                kind: .quote(max(1, text.filter { $0 == ">" }.count))))
        }
        enumerate(list, in: source, full: full) { match in
            guard !intersects(match.range, fencedRanges) else { return }
            let lineText = source.substring(with: source.lineRange(
                for: NSRange(location: match.range.location, length: 0)))
            if lineText.range(of: #"^[\t ]*[-+*][\t ]+\[[ xX]\]"#,
                              options: .regularExpression) != nil { return }
            storage.addAttributes(marker, range: match.range)
            let bullet: String
            if match.range(at: 2).location != NSNotFound {
                bullet = source.substring(with: match.range(at: 2))
            } else {
                bullet = "•"
            }
            lineMarkers.append(MarkdownLineMarkerDecoration(
                sourceRange: match.range, kind: .bullet(bullet)))
        }
        enumerate(thematicBreak, in: source, full: full) { match in
            guard !intersects(match.range, fencedRanges),
                  !isSetextUnderline(match.range, in: source) else { return }
            storage.addAttributes(marker, range: match.range)
            syntaxRanges.append(match.range)
            rules.append(MarkdownRuleDecoration(
                lineRange: source.lineRange(
                    for: NSRange(location: match.range.location, length: 0))))
        }

        applySetextHeadings(in: source, storage: storage, baseFont: baseFont,
                            boldFont: boldFont, marker: marker,
                            excluded: fencedRanges,
                            syntaxRanges: &syntaxRanges,
                            collapsedLines: &collapsedLines)
        applyIndentedCodeBlocks(in: source, storage: storage, code: code,
                                excluded: fencedRanges,
                                syntaxRanges: &syntaxRanges,
                                codeBlocks: &codeBlocks)

        enumerate(standaloneImage, in: source, full: full) { match in
            guard !intersects(match.range, fencedRanges) else { return }
            let alt = source.substring(with: match.range(at: 1))
            let destinationRange = match.range(at: 2).location != NSNotFound
                ? match.range(at: 2) : match.range(at: 3)
            let destination = source.substring(with: destinationRange)
            let url = resolvedImageURL(destination, relativeTo: documentURL)
            let line = source.lineRange(
                for: NSRange(location: match.range.location, length: 0))
            images.append(MarkdownImageDecoration(
                sourceRange: match.range, lineRange: line, alt: alt, url: url))
            syntaxRanges.append(match.range)
        }

        enumerate(footnoteDefinition, in: source, full: full) { match in
            guard !intersects(match.range, fencedRanges) else { return }
            footnoteDefinitionRanges.append(match.range)
            let identifier = source.substring(with: match.range(at: 1))
            storage.addAttributes(marker, range: match.range)
            syntaxRanges.append(match.range)
            lineMarkers.append(MarkdownLineMarkerDecoration(
                sourceRange: match.range, kind: .footnote(identifier)))
        }
        enumerate(footnoteReference, in: source, full: full) { match in
            guard !intersects(match.range, fencedRanges + footnoteDefinitionRanges) else { return }
            let identifier = match.range(at: 1)
            storage.addAttributes(linkStyle, range: identifier)
            storage.addAttributes([.superscript: 1], range: identifier)
            syntaxRanges.append(contentsOf: outerRanges(of: match, content: identifier))
        }

        var references: [String: String] = [:]
        enumerate(referenceDefinition, in: source, full: full) { match in
            guard !intersects(match.range, fencedRanges) else { return }
            let key = source.substring(with: match.range(at: 1)).lowercased()
            guard !key.hasPrefix("^") else { return }
            let destinationRange = match.range(at: 2).location != NSNotFound
                ? match.range(at: 2) : match.range(at: 3)
            references[key] = source.substring(with: destinationRange)
            syntaxRanges.append(match.range)
            collapsedLines.append(source.lineRange(
                for: NSRange(location: match.range.location, length: 0)))
        }
        applyReferenceLinks(in: source, storage: storage, references: references,
                            linkStyle: linkStyle, marker: marker,
                            excluded: fencedRanges, syntaxRanges: &syntaxRanges)

        enumerate(task, in: source, full: full) { match in
            guard !intersects(match.range, fencedRanges) else { return }
            storage.addAttributes(marker, range: match.range)
            let state = source.substring(with: match.range(at: 1)).lowercased()
            let checked = state == "x"
            tasks.append(MarkdownTaskDecoration(
                sourceRange: match.range, checked: checked))
            if checked {
                let line = lineContentRange(
                    source.lineRange(for: NSRange(location: match.range.location, length: 0)),
                    in: source)
                if NSMaxRange(match.range) < NSMaxRange(line) {
                    storage.addAttribute(
                        .strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                        range: NSRange(location: NSMaxRange(match.range),
                                       length: NSMaxRange(line) - NSMaxRange(match.range)))
                }
            }
        }

        enumerate(inlineCode, in: source, full: full) { match in
            guard !intersects(match.range, fencedRanges) else { return }
            inlineCodeRanges.append(match.range)
            storage.addAttributes(inlineCodeStyle, range: match.range)
            let delimiterLength = match.range(at: 1).length
            storage.addAttributes(marker,
                                  range: NSRange(location: match.range.location,
                                                 length: delimiterLength))
            storage.addAttributes(marker,
                                  range: NSRange(location: NSMaxRange(match.range) - delimiterLength,
                                                 length: delimiterLength))
            syntaxRanges.append(NSRange(location: match.range.location,
                                        length: delimiterLength))
            syntaxRanges.append(NSRange(location: NSMaxRange(match.range) - delimiterLength,
                                        length: delimiterLength))
        }

        enumerate(strong, in: source, full: full) { match in
            guard !intersects(match.range, fencedRanges) else { return }
            storage.addAttributes([.font: boldFont, .strokeWidth: -2.0],
                                  range: match.range(at: 1))
            dimOuterMarkers(of: match, content: match.range(at: 1), storage: storage)
            syntaxRanges.append(contentsOf: outerRanges(of: match,
                                                        content: match.range(at: 1)))
        }
        enumerate(emphasis, in: source, full: full) { match in
            guard !intersects(match.range, fencedRanges) else { return }
            let content = match.range(at: 1)
            let isStrong = storage.attribute(.strokeWidth, at: content.location,
                                             effectiveRange: nil) != nil
            storage.addAttributes([.font: isStrong ? boldItalicFont : italicFont,
                                   .obliqueness: 0.16],
                                  range: content)
            dimOuterMarkers(of: match, content: content, storage: storage)
            syntaxRanges.append(contentsOf: outerRanges(of: match, content: content))
        }
        enumerate(strike, in: source, full: full) { match in
            guard !intersects(match.range, fencedRanges) else { return }
            storage.addAttribute(.strikethroughStyle,
                                 value: NSUnderlineStyle.single.rawValue,
                                 range: match.range(at: 1))
            dimOuterMarkers(of: match, content: match.range(at: 1), storage: storage)
            syntaxRanges.append(contentsOf: outerRanges(of: match,
                                                        content: match.range(at: 1)))
        }

        enumerate(link, in: source, full: full) { match in
            guard !intersects(match.range, fencedRanges) else { return }
            storage.addAttributes(linkStyle, range: match.range(at: 1))
            storage.addAttributes(marker, range: match.range(at: 2))
            dimOuterMarkers(of: match, content: match.range(at: 1), storage: storage)
            syntaxRanges.append(contentsOf: outerRanges(of: match,
                                                        content: match.range(at: 1)))
        }
        enumerate(autoLink, in: source, full: full) { match in
            guard !intersects(match.range, fencedRanges) else { return }
            storage.addAttributes(linkStyle, range: match.range(at: 1))
            dimOuterMarkers(of: match, content: match.range(at: 1), storage: storage)
            syntaxRanges.append(contentsOf: outerRanges(of: match,
                                                        content: match.range(at: 1)))
        }
        enumerate(emailAutoLink, in: source, full: full) { match in
            guard !intersects(match.range, fencedRanges) else { return }
            storage.addAttributes(linkStyle, range: match.range(at: 1))
            dimOuterMarkers(of: match, content: match.range(at: 1), storage: storage)
            syntaxRanges.append(contentsOf: outerRanges(of: match,
                                                        content: match.range(at: 1)))
        }
        enumerate(bareURL, in: source, full: full) { match in
            guard !intersects(match.range, fencedRanges) else { return }
            var styled = match.range
            while styled.length > 0 {
                let tail = source.character(at: NSMaxRange(styled) - 1)
                guard tail == 0x2E || tail == 0x2C || tail == 0x3B || tail == 0x3A
                        || tail == 0x21 || tail == 0x3F else { break }
                styled.length -= 1
            }
            if styled.length > 0 { storage.addAttributes(linkStyle, range: styled) }
        }
        enumerate(escapedPunctuation, in: source, full: full) { match in
            guard !intersects(match.range, fencedRanges) else { return }
            syntaxRanges.append(NSRange(location: match.range.location, length: 1))
        }
        enumerate(simpleHTMLPair, in: source, full: full) { match in
            guard !intersects(match.range, fencedRanges) else { return }
            let content = match.range(at: 2)
            syntaxRanges.append(contentsOf: outerRanges(of: match, content: content))
        }
        enumerate(htmlComment, in: source, full: full) { match in
            guard !intersects(match.range, fencedRanges) else { return }
            syntaxRanges.append(match.range)
        }
        enumerate(htmlTag, in: source, full: full) { match in
            guard !intersects(match.range, fencedRanges) else { return }
            syntaxRanges.append(match.range)
        }
        enumerate(hardBreakMarker, in: source, full: full) { match in
            guard !intersects(match.range, fencedRanges) else { return }
            syntaxRanges.append(match.range)
        }
        enumerate(htmlEntity, in: source, full: full) { match in
            guard !intersects(match.range, fencedRanges + inlineCodeRanges),
                  let character = decodedEntity(match, in: source) else { return }
            glyphReplacements.append(MarkdownGlyphReplacement(
                sourceRange: match.range, character: character))
        }

        storage.endEditing()
        let tableResult = tables(in: source, full: full)
        collapsedLines.append(contentsOf: tableResult.separatorLines)
        for table in tableResult.tables {
            syntaxRanges.append(contentsOf: table.rows.map(\.sourceRange))
        }
        return MarkdownPresentation(
            hiddenSyntaxRanges: normalized(syntaxRanges.filter { $0.length > 0 }),
            collapsedLineRanges: normalized(collapsedLines.filter { $0.length > 0 }),
            codeBlocks: codeBlocks,
            tables: tableResult.tables,
            tasks: tasks,
            lineMarkers: lineMarkers,
            rules: rules,
            images: images,
            glyphReplacements: glyphReplacements)
    }

    private static func enumerate(_ expression: NSRegularExpression,
                                  in source: NSString,
                                  full: NSRange,
                                  _ body: (NSTextCheckingResult) -> Void) {
        expression.enumerateMatches(in: source as String, range: full) { result, _, _ in
            if let result { body(result) }
        }
    }

    private static func intersects(_ range: NSRange, _ excluded: [NSRange]) -> Bool {
        excluded.contains { NSIntersectionRange(range, $0).length > 0 }
    }

    private static func dimOuterMarkers(of match: NSTextCheckingResult,
                                        content: NSRange,
                                        storage: NSTextStorage) {
        let whole = match.range
        if content.location > whole.location {
            storage.addAttribute(.foregroundColor, value: Theme.dimText,
                                 range: NSRange(location: whole.location,
                                                length: content.location - whole.location))
        }
        if NSMaxRange(content) < NSMaxRange(whole) {
            storage.addAttribute(.foregroundColor, value: Theme.dimText,
                                 range: NSRange(location: NSMaxRange(content),
                                                length: NSMaxRange(whole) - NSMaxRange(content)))
        }
    }

    private static func outerRanges(of match: NSTextCheckingResult,
                                    content: NSRange) -> [NSRange] {
        var ranges: [NSRange] = []
        if content.location > match.range.location {
            ranges.append(NSRange(location: match.range.location,
                                  length: content.location - match.range.location))
        }
        if NSMaxRange(content) < NSMaxRange(match.range) {
            ranges.append(NSRange(location: NSMaxRange(content),
                                  length: NSMaxRange(match.range) - NSMaxRange(content)))
        }
        return ranges
    }

    private static func lineContentRange(_ line: NSRange, in source: NSString) -> NSRange {
        var end = NSMaxRange(line)
        while end > line.location {
            let character = source.character(at: end - 1)
            guard character == 0x0A || character == 0x0D else { break }
            end -= 1
        }
        return NSRange(location: line.location, length: end - line.location)
    }

    private static func normalized(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges.sorted {
            $0.location == $1.location ? $0.length < $1.length : $0.location < $1.location
        }
        var result: [NSRange] = []
        for range in sorted {
            guard let last = result.last, range.location <= NSMaxRange(last) else {
                result.append(range)
                continue
            }
            result[result.count - 1] = NSUnionRange(last, range)
        }
        return result
    }

    private static func isSetextUnderline(_ range: NSRange, in source: NSString) -> Bool {
        let line = source.lineRange(for: NSRange(location: range.location, length: 0))
        guard line.location > 0 else { return false }
        let previousProbe = max(0, line.location - 1)
        let previous = lineContentRange(
            source.lineRange(for: NSRange(location: previousProbe, length: 0)),
            in: source)
        return !source.substring(with: previous)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func applySetextHeadings(
        in source: NSString,
        storage: NSTextStorage,
        baseFont: NSFont,
        boldFont: NSFont,
        marker: [NSAttributedString.Key: Any],
        excluded: [NSRange],
        syntaxRanges: inout [NSRange],
        collapsedLines: inout [NSRange]
    ) {
        let lines = sourceLines(in: source)
        guard lines.count > 1 else { return }
        for index in 1..<lines.count {
            let underline = lines[index]
            let trimmed = underline.text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  trimmed.allSatisfy({ $0 == "=" }) || trimmed.allSatisfy({ $0 == "-" }),
                  !intersects(underline.contentRange, excluded) else { continue }
            let content = lines[index - 1]
            guard !content.text.trimmingCharacters(in: .whitespaces).isEmpty,
                  !content.text.contains("|") else { continue }
            let level = trimmed.first == "=" ? 1 : 2
            let scale: CGFloat = level == 1 ? 1.22 : 1.16
            let maximum = max(baseFont.pointSize, Theme.lineMetrics().target * 0.72)
            let font = NSFont(descriptor: boldFont.fontDescriptor,
                              size: min(baseFont.pointSize * scale, maximum)) ?? boldFont
            storage.addAttributes([.font: font, .strokeWidth: -2.0,
                                   .foregroundColor: Theme.foreground],
                                  range: content.contentRange)
            storage.addAttributes(marker, range: underline.contentRange)
            syntaxRanges.append(underline.contentRange)
            collapsedLines.append(underline.range)
        }
    }

    private static func applyIndentedCodeBlocks(
        in source: NSString,
        storage: NSTextStorage,
        code: [NSAttributedString.Key: Any],
        excluded: [NSRange],
        syntaxRanges: inout [NSRange],
        codeBlocks: inout [MarkdownCodeBlockDecoration]
    ) {
        let lines = sourceLines(in: source)
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let prefixLength = indentationPrefixLength(line.text)
            let previousBlank = index == 0
                || lines[index - 1].text.trimmingCharacters(in: .whitespaces).isEmpty
            guard prefixLength > 0, previousBlank,
                  !intersects(line.contentRange, excluded) else {
                index += 1
                continue
            }
            let start = index
            var end = index
            while end < lines.count {
                let candidate = lines[end]
                let prefix = indentationPrefixLength(candidate.text)
                let blank = candidate.text.trimmingCharacters(in: .whitespaces).isEmpty
                guard (prefix > 0 || blank),
                      !intersects(candidate.contentRange, excluded) else { break }
                if prefix > 0 {
                    syntaxRanges.append(NSRange(location: candidate.contentRange.location,
                                                length: prefix))
                }
                end += 1
            }
            let range = NSRange(location: lines[start].range.location,
                                length: NSMaxRange(lines[max(start, end - 1)].contentRange)
                                    - lines[start].range.location)
            storage.addAttributes(code, range: range)
            codeBlocks.append(MarkdownCodeBlockDecoration(range: range, language: nil))
            index = max(end, index + 1)
        }
    }

    private static func indentationPrefixLength(_ line: String) -> Int {
        if line.hasPrefix("\t") { return 1 }
        return line.hasPrefix("    ") ? 4 : 0
    }

    private static func applyReferenceLinks(
        in source: NSString,
        storage: NSTextStorage,
        references: [String: String],
        linkStyle: [NSAttributedString.Key: Any],
        marker: [NSAttributedString.Key: Any],
        excluded: [NSRange],
        syntaxRanges: inout [NSRange]
    ) {
        guard !references.isEmpty else { return }
        let full = NSRange(location: 0, length: source.length)
        let reference = expression(#"!?\[([^\]\n]+)\]\[([^\]\n]*)\]"#)
        var styled: [NSRange] = []
        enumerate(reference, in: source, full: full) { match in
            guard !intersects(match.range, excluded) else { return }
            let label = match.range(at: 1)
            let identifierText = match.range(at: 2).length == 0
                ? source.substring(with: label)
                : source.substring(with: match.range(at: 2))
            guard references[identifierText.lowercased()] != nil else { return }
            storage.addAttributes(linkStyle, range: label)
            dimOuterMarkers(of: match, content: label, storage: storage)
            syntaxRanges.append(contentsOf: outerRanges(of: match, content: label))
            styled.append(match.range)
        }
        let shortcut = expression(#"\[([^\]\n]+)\]"#)
        enumerate(shortcut, in: source, full: full) { match in
            guard !intersects(match.range, excluded + styled) else { return }
            let label = match.range(at: 1)
            guard references[source.substring(with: label).lowercased()] != nil else { return }
            storage.addAttributes(linkStyle, range: label)
            storage.addAttributes(marker, range: match.range)
            syntaxRanges.append(contentsOf: outerRanges(of: match, content: label))
        }
    }

    private static func resolvedImageURL(_ destination: String,
                                         relativeTo documentURL: URL?) -> URL? {
        if let url = URL(string: destination), url.scheme != nil { return url }
        guard let documentURL else { return nil }
        let decoded = destination.removingPercentEncoding ?? destination
        return documentURL.deletingLastPathComponent()
            .appendingPathComponent(decoded).standardizedFileURL
    }

    private static func sourceLines(in source: NSString) -> [SourceLine] {
        var lines: [SourceLine] = []
        var location = 0
        while location < source.length {
            let range = source.lineRange(for: NSRange(location: location, length: 0))
            let content = lineContentRange(range, in: source)
            lines.append(SourceLine(range: range, contentRange: content,
                                    text: source.substring(with: content)))
            let next = NSMaxRange(range)
            guard next > location else { break }
            location = next
        }
        return lines
    }

    private struct TableParseResult {
        var tables: [MarkdownTableDecoration] = []
        var separatorLines: [NSRange] = []
    }

    private struct SourceLine {
        let range: NSRange
        let contentRange: NSRange
        let text: String
    }

    private static func tables(in source: NSString, full: NSRange) -> TableParseResult {
        let lines = sourceLines(in: source)

        var result = TableParseResult()
        var index = 1
        while index < lines.count {
            let separators = tableCells(lines[index].text)
            guard !separators.isEmpty,
                  separators.allSatisfy(isTableSeparator),
                  lines[index - 1].text.contains("|") else {
                index += 1
                continue
            }
            let headerCells = tableCells(lines[index - 1].text)
            guard !headerCells.isEmpty else { index += 1; continue }
            let columnCount = max(headerCells.count, separators.count)
            var rows = [MarkdownTableDecoration.Row(
                sourceRange: lines[index - 1].contentRange,
                lineRange: lines[index - 1].range,
                cells: padded(headerCells, to: columnCount), isHeader: true)]
            var end = index + 1
            while end < lines.count, lines[end].text.contains("|") {
                let cells = tableCells(lines[end].text)
                guard !cells.isEmpty else { break }
                rows.append(MarkdownTableDecoration.Row(
                    sourceRange: lines[end].contentRange,
                    lineRange: lines[end].range,
                    cells: padded(cells, to: columnCount), isHeader: false))
                end += 1
            }
            let startLocation = lines[index - 1].range.location
            let endLocation = rows.last.map { NSMaxRange($0.sourceRange) }
                ?? NSMaxRange(lines[index].contentRange)
            result.tables.append(MarkdownTableDecoration(
                sourceRange: NSRange(location: startLocation,
                                     length: endLocation - startLocation),
                rows: rows, columnCount: columnCount))
            result.separatorLines.append(lines[index].range)
            index = end
        }
        return result
    }

    private static func tableCells(_ line: String) -> [String] {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }
        guard value.contains("|") else { return [] }
        var cells: [String] = []
        var cell = ""
        var escaped = false
        var codeDelimiterLength = 0
        var backtickRun = 0
        let characters = Array(value)
        for (index, character) in characters.enumerated() {
            if escaped {
                cell.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                cell.append(character)
                continue
            }
            if character == "`" {
                backtickRun += 1
                let nextIsBacktick = index + 1 < characters.count
                    && characters[index + 1] == "`"
                cell.append(character)
                if nextIsBacktick { continue }
                if codeDelimiterLength == 0 {
                    codeDelimiterLength = backtickRun
                } else if codeDelimiterLength == backtickRun {
                    codeDelimiterLength = 0
                }
                backtickRun = 0
                continue
            }
            backtickRun = 0
            if character == "|", codeDelimiterLength == 0 {
                cells.append(renderedCell(cell.trimmingCharacters(in: .whitespaces)))
                cell = ""
            } else {
                cell.append(character)
            }
        }
        if escaped { cell.append("\\") }
        cells.append(renderedCell(cell.trimmingCharacters(in: .whitespaces)))
        return cells
    }

    private static func isTableSeparator(_ value: String) -> Bool {
        value.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil
    }

    private static func padded(_ cells: [String], to count: Int) -> [String] {
        cells + Array(repeating: "", count: max(0, count - cells.count))
    }

    private static func renderedCell(_ source: String) -> String {
        var value = source
        if let expression = try? NSRegularExpression(
            pattern: #"!?\[([^\]]+)\]\([^)]+\)"#) {
            value = expression.stringByReplacingMatches(
                in: value, range: NSRange(location: 0, length: (value as NSString).length),
                withTemplate: "$1")
        }
        for marker in ["**", "__", "~~", "`", "*", "_"] {
            value = value.replacingOccurrences(of: marker, with: "")
        }
        value = value.replacingOccurrences(of: #"\|"#, with: "|")
        return decodeCommonEntities(in: value)
    }

    private static func decodeCommonEntities(in source: String) -> String {
        let mutable = NSMutableString(string: source)
        let full = NSRange(location: 0, length: mutable.length)
        let nsSource = source as NSString
        for match in htmlEntity.matches(in: source, range: full).reversed() {
            if let character = decodedEntity(match, in: nsSource),
               let scalar = UnicodeScalar(character) {
                mutable.replaceCharacters(in: match.range, with: String(scalar))
            }
        }
        return mutable as String
    }

    private static func decodedEntity(_ match: NSTextCheckingResult,
                                      in source: NSString) -> UInt16? {
        let value: UInt32?
        if match.range(at: 1).location != NSNotFound {
            value = UInt32(source.substring(with: match.range(at: 1)))
        } else if match.range(at: 2).location != NSNotFound {
            value = UInt32(source.substring(with: match.range(at: 2)), radix: 16)
        } else {
            let named: [String: UInt32] = [
                "amp": 0x26, "lt": 0x3C, "gt": 0x3E, "quot": 0x22,
                "apos": 0x27, "nbsp": 0x00A0, "copy": 0x00A9, "reg": 0x00AE,
                "trade": 0x2122, "ndash": 0x2013, "mdash": 0x2014,
                "hellip": 0x2026, "laquo": 0x00AB, "raquo": 0x00BB,
            ]
            value = named[source.substring(with: match.range(at: 3))]
        }
        guard let value, value <= UInt16.max,
              !(0xD800...0xDFFF).contains(value) else { return nil }
        return UInt16(value)
    }
}

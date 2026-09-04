import AppKit

struct MarkdownCodeBlockDecoration: Equatable {
    let range: NSRange
    let language: String?
}

struct MarkdownTableDecoration: Equatable {
    struct Row: Equatable {
        /// The row's own characters, terminator excluded. TextKit gives this
        /// range one dynamic-height fragment, and the renderer anchors on its
        /// first character.
        let sourceRange: NSRange
        /// Complete logical line including its terminator.
        let lineRange: NSRange
        let cells: [String]
        let isHeader: Bool
    }
    let sourceRange: NSRange
    let rows: [Row]
    let columnCount: Int
    /// True when a blank line sits directly above the table. Such a line has no
    /// glyphs of its own and TextKit folds it into the first row's fragment, so
    /// the first row carries its height and the table is drawn at the bottom of
    /// that fragment — otherwise the table clamps onto the block above it.
    let leadsWithBlankLine: Bool
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
///
/// Structure comes from `MarkdownSyntaxTree` — the tree-sitter grammars — not
/// from patterns run over the whole buffer. What a character means in Markdown
/// depends on what it sits inside, which is precisely what a pattern cannot see.
enum MarkdownLiveStyler {
    @discardableResult
    static func apply(text: String, to storage: NSTextStorage,
                      documentURL: URL? = nil) -> MarkdownPresentation {
        guard storage.length > 0 else { return MarkdownPresentation() }
        var builder = Builder(text: text, storage: storage, documentURL: documentURL)
        builder.run()
        return builder.result
    }

    /// Walks the parsed document once, painting attributes as it goes and
    /// collecting what the pane's layout manager needs to hide, collapse or
    /// draw.
    private struct Builder {
        let source: NSString
        let storage: NSTextStorage
        let documentURL: URL?

        private let baseFont = Theme.editorFont()
        private let boldFont: NSFont
        private let italicFont: NSFont
        private let boldItalicFont: NSFont
        private let marker: [NSAttributedString.Key: Any]
        private let codeStyle: [NSAttributedString.Key: Any]
        private let inlineCodeStyle: [NSAttributedString.Key: Any]
        private let linkStyle: [NSAttributedString.Key: Any]

        private var syntax: [NSRange] = []
        private var collapsed: [NSRange] = []
        private var codeBlocks: [MarkdownCodeBlockDecoration] = []
        private var tables: [MarkdownTableDecoration] = []
        private var tasks: [MarkdownTaskDecoration] = []
        private var lineMarkers: [MarkdownLineMarkerDecoration] = []
        private var rules: [MarkdownRuleDecoration] = []
        private var images: [MarkdownImageDecoration] = []
        private var glyphs: [MarkdownGlyphReplacement] = []
        /// Spans whose text is literal — a code span or a fenced block — so the
        /// GFM bare-URL scan does not link inside them.
        private var literalRanges: [NSRange] = []
        private let text: String

        init(text: String, storage: NSTextStorage, documentURL: URL?) {
            self.text = text
            self.source = text as NSString
            self.storage = storage
            self.documentURL = documentURL
            let bold = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
            boldFont = bold
            italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
            boldItalicFont = NSFontManager.shared.convert(bold, toHaveTrait: .italicFontMask)
            marker = [.foregroundColor: Theme.dimText]
            codeStyle = [.foregroundColor: Theme.foreground]
            inlineCodeStyle = [.foregroundColor: Theme.yellow,
                               .backgroundColor: Theme.inputBackground]
            linkStyle = [.foregroundColor: Theme.blue,
                         .underlineStyle: NSUnderlineStyle.single.rawValue]
        }

        var result: MarkdownPresentation {
            MarkdownPresentation(
                hiddenSyntaxRanges: MarkdownLiveStyler.normalized(syntax.filter { $0.length > 0 }),
                collapsedLineRanges: MarkdownLiveStyler.normalized(
                    collapsed.filter { $0.length > 0 }),
                codeBlocks: codeBlocks, tables: tables, tasks: tasks,
                lineMarkers: lineMarkers, rules: rules, images: images,
                glyphReplacements: glyphs)
        }

        mutating func run() {
            let document = MarkdownSyntaxTree.parse(text)
            storage.beginEditing()
            walkBlocks(document.blocks, quoteDepth: 0)
            walkInlines(document.inlines)
            bareURLs()
            storage.endEditing()
        }

        // MARK: Collecting

        /// Hidden ranges never include a line terminator. A hidden newline joins
        /// its line to the next one, which paints the heading above a list over
        /// the bullet below it. Removing a whole line from the layout is what
        /// `collapse` is for.
        mutating func hide(_ range: NSRange) {
            var trimmed = range
            while trimmed.length > 0 {
                let last = source.character(at: NSMaxRange(trimmed) - 1)
                guard last == 0x0A || last == 0x0D else { break }
                trimmed.length -= 1
            }
            guard trimmed.length > 0 else { return }
            syntax.append(trimmed)
        }

        mutating func collapse(_ line: NSRange) { collapsed.append(line) }

        /// True when the line above `line` holds nothing but its terminator.
        func precededByBlankLine(_ line: NSRange) -> Bool {
            guard line.location > 0 else { return false }
            let previous = self.line(at: line.location - 1)
            return MarkdownLiveStyler.lineContentRange(previous, in: source).length == 0
        }

        func dim(_ range: NSRange) { style(marker, range) }

        func style(_ attributes: [NSAttributedString.Key: Any], _ range: NSRange) {
            let clamped = NSIntersectionRange(
                range, NSRange(location: 0, length: storage.length))
            guard clamped.length > 0 else { return }
            storage.addAttributes(attributes, range: clamped)
        }

        func line(at location: Int) -> NSRange {
            let probe = min(max(0, location), max(0, source.length - 1))
            guard source.length > 0 else { return NSRange(location: 0, length: 0) }
            return source.lineRange(for: NSRange(location: probe, length: 0))
        }

        /// Wrapped lines of a block start under its text rather than at the
        /// margin. `firstLineHeadIndent` is left alone: every source line is its
        /// own paragraph to TextKit, so only soft wraps are affected.
        func hangingIndent(_ range: NSRange, by columns: CGFloat) {
            guard range.length > 0 else { return }
            let style = (Theme.paragraphStyle().mutableCopy() as? NSMutableParagraphStyle)
                ?? NSMutableParagraphStyle()
            style.headIndent = columns * Theme.characterWidth()
            self.style([.paragraphStyle: style.copy()], range)
        }

        // MARK: Blocks

        mutating func walkBlocks(_ nodes: [MarkdownNode], quoteDepth: Int) {
            for node in nodes {
                switch node.type {
                case "atx_heading": heading(node)
                case "setext_heading": setextHeading(node)
                case "fenced_code_block": fencedCode(node)
                case "indented_code_block": indentedCode(node)
                case "thematic_break": thematicBreak(node)
                case "pipe_table": table(node)
                case "link_reference_definition": referenceDefinition(node)
                case "html_block": hide(node.range)
                case "block_quote":
                    for child in node.all("block_quote_marker") {
                        dim(child.range)
                        lineMarkers.append(MarkdownLineMarkerDecoration(
                            sourceRange: child.range, kind: .quote(quoteDepth + 1)))
                    }
                    walkBlocks(node.children, quoteDepth: quoteDepth + 1)
                case "list_item":
                    listItem(node)
                    walkBlocks(node.children, quoteDepth: quoteDepth)
                case "paragraph":
                    footnoteDefinition(node)
                    walkBlocks(node.children, quoteDepth: quoteDepth)
                default:
                    walkBlocks(node.children, quoteDepth: quoteDepth)
                }
            }
        }

        mutating func heading(_ node: MarkdownNode) {
            guard let markerNode = node.children.first(where: {
                $0.type.hasPrefix("atx_h") && $0.type.hasSuffix("_marker")
            }) else { return }
            let level = Int(String(markerNode.type.dropFirst(5).prefix(1))) ?? 1
            dim(markerNode.range)
            guard let content = node.first("inline") else {
                hide(node.range)
                return
            }
            // The marker and the space after it.
            hide(NSRange(location: node.range.location,
                         length: max(0, content.range.location - node.range.location)))
            // A closing run of #s, if the author wrote one.
            let contentEnd = NSMaxRange(content.range)
            let lineEnd = NSMaxRange(MarkdownLiveStyler.lineContentRange(
                line(at: node.range.location), in: source))
            if lineEnd > contentEnd {
                hide(NSRange(location: contentEnd, length: lineEnd - contentEnd))
            }
            style(headingAttributes(level: level), content.range)
        }

        mutating func setextHeading(_ node: MarkdownNode) {
            guard let underline = node.children.first(where: {
                $0.type.hasPrefix("setext_h") && $0.type.hasSuffix("_underline")
            }) else { return }
            let level = node.first("setext_h1_underline") != nil ? 1 : 2
            for content in node.descendants("inline") {
                style(headingAttributes(level: level), content.range)
            }
            let underlineLine = line(at: underline.range.location)
            dim(underlineLine)
            hide(MarkdownLiveStyler.lineContentRange(underlineLine, in: source))
            collapse(underlineLine)
        }

        func headingAttributes(level: Int) -> [NSAttributedString.Key: Any] {
            let scale: CGFloat = [1.0, 1.22, 1.16, 1.10, 1.05, 1.0, 1.0][max(1, min(6, level))]
            let maximum = max(baseFont.pointSize, Theme.lineMetrics().target * 0.72)
            let size = min(baseFont.pointSize * scale, maximum)
            let font = NSFont(descriptor: boldFont.fontDescriptor, size: size) ?? boldFont
            return [.font: font, .strokeWidth: -2.0, .foregroundColor: Theme.foreground]
        }

        mutating func fencedCode(_ node: MarkdownNode) {
            let language = node.descendants("language").first
                .map { source.substring(with: $0.range) }
                ?? node.first("info_string").map {
                    source.substring(with: $0.range)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            var body = node.first("code_fence_content")?.range
            var closingLine: NSRange?
            // A fence closed by the very end of the file, with no newline after
            // it, is not reported as a delimiter: the grammar folds it into the
            // content. Take that line back, or the ``` reads as code.
            if node.all("fenced_code_block_delimiter").count < 2, let content = body,
               content.length > 0 {
                let last = line(at: max(content.location, NSMaxRange(content) - 1))
                let value = source.substring(
                    with: MarkdownLiveStyler.lineContentRange(last, in: source))
                    .trimmingCharacters(in: .whitespaces)
                if value.count >= 3, let fence = value.first, fence == "`" || fence == "~",
                   value.allSatisfy({ $0 == fence }) {
                    closingLine = last
                    body = NSRange(location: content.location,
                                   length: max(0, last.location - content.location))
                }
            }
            if let body, body.length > 0 {
                style(codeStyle, body)
                codeBlocks.append(MarkdownCodeBlockDecoration(
                    range: body, language: (language?.isEmpty ?? true) ? nil : language))
                literalRanges.append(body)
            }
            // The fence lines leave the layout — from the fence marker onwards,
            // not from the start of the line. A fence can open on the same line
            // as the list marker that owns it ("1. ```bash"), and hiding the
            // whole line took the marker with it: the number was then drawn
            // against a collapsed 1pt row, at the far right of the page.
            let fences = node.all("fenced_code_block_delimiter").map(\.range)
                + (closingLine.map {
                    [MarkdownLiveStyler.lineContentRange($0, in: source)]
                } ?? [])
            for fence in fences {
                let fenceLine = line(at: fence.location)
                let content = MarkdownLiveStyler.lineContentRange(fenceLine, in: source)
                let tail = NSRange(location: fence.location,
                                   length: max(0, NSMaxRange(content) - fence.location))
                dim(tail)
                hide(tail)
                // Only a line that is nothing but its fence can leave the
                // layout; one that carries a marker still has to be drawn.
                let prefix = source.substring(
                    with: NSRange(location: content.location,
                                  length: max(0, fence.location - content.location)))
                if prefix.allSatisfy({ $0 == " " || $0 == "\t" }) {
                    collapse(fenceLine)
                }
            }
        }

        mutating func indentedCode(_ node: MarkdownNode) {
            style(codeStyle, node.range)
            codeBlocks.append(MarkdownCodeBlockDecoration(range: node.range, language: nil))
            literalRanges.append(node.range)
        }

        mutating func thematicBreak(_ node: MarkdownNode) {
            let ruleLine = line(at: node.range.location)
            dim(node.range)
            hide(MarkdownLiveStyler.lineContentRange(ruleLine, in: source))
            rules.append(MarkdownRuleDecoration(lineRange: ruleLine))
        }

        mutating func listItem(_ node: MarkdownNode) {
            guard let bullet = node.children.first(where: {
                $0.type.hasPrefix("list_marker_")
            }) else { return }
            dim(bullet.range)
            // A line too long for the column wraps, and the wrap used to come
            // back to the left margin — in the middle of a list item, which read
            // as if the text had escaped its bullet.
            hangingIndent(node.range, by: CGFloat(bullet.range.length))
            let checkbox = node.descendants("task_list_marker_checked").first
                ?? node.descendants("task_list_marker_unchecked").first
            guard let checkbox else {
                let label = source.substring(with: bullet.range)
                    .trimmingCharacters(in: .whitespaces)
                lineMarkers.append(MarkdownLineMarkerDecoration(
                    sourceRange: bullet.range,
                    kind: .bullet(label.allSatisfy { "-+*".contains($0) } ? "•" : label)))
                return
            }
            let checked = checkbox.type.hasSuffix("checked")
                && !checkbox.type.hasSuffix("unchecked")
            let span = NSRange(location: bullet.range.location,
                               length: max(0, NSMaxRange(checkbox.range) - bullet.range.location))
            dim(span)
            tasks.append(MarkdownTaskDecoration(sourceRange: span, checked: checked))
            guard checked else { return }
            let content = MarkdownLiveStyler.lineContentRange(
                line(at: span.location), in: source)
            if NSMaxRange(span) < NSMaxRange(content) {
                style([.strikethroughStyle: NSUnderlineStyle.single.rawValue],
                      NSRange(location: NSMaxRange(span),
                              length: NSMaxRange(content) - NSMaxRange(span)))
            }
        }

        /// `[^note]: text`. Footnotes are an extension the grammar does not
        /// enable, so a definition arrives as an ordinary paragraph and the
        /// marker has to be recognised here.
        mutating func footnoteDefinition(_ node: MarkdownNode) {
            let content = MarkdownLiveStyler.lineContentRange(
                line(at: node.range.location), in: source)
            guard content.length > 3 else { return }
            let value = source.substring(with: content) as NSString
            guard value.hasPrefix("[^") else { return }
            let close = value.range(of: "]:")
            guard close.location != NSNotFound else { return }
            let identifier = value.substring(with: NSRange(location: 2,
                                                           length: close.location - 2))
            let span = NSRange(location: content.location,
                               length: close.location + 2)
            dim(span)
            hide(span)
            lineMarkers.append(MarkdownLineMarkerDecoration(
                sourceRange: span, kind: .footnote(identifier)))
        }

        mutating func referenceDefinition(_ node: MarkdownNode) {
            let definitionLine = line(at: node.range.location)
            dim(node.range)
            hide(node.range)
            // The definition is bookkeeping for the links that use it; the
            // rendered document has no place for it.
            collapse(definitionLine)
        }

        mutating func table(_ node: MarkdownNode) {
            var rows: [MarkdownTableDecoration.Row] = []
            var columns = 0
            for child in node.children {
                switch child.type {
                case "pipe_table_header", "pipe_table_row":
                    let cells = child.all("pipe_table_cell").map {
                        MarkdownLiveStyler.renderedCell(source.substring(with: $0.range))
                    }
                    columns = max(columns, cells.count)
                    // The header node carries its line terminator and a body row
                    // does not. Both are stored as the line's *content*, so the
                    // renderer can tell "row has a terminator to anchor to" from
                    // the two ranges and treats every row alike.
                    let rowLine = line(at: child.range.location)
                    let content = MarkdownLiveStyler.lineContentRange(rowLine, in: source)
                    rows.append(MarkdownTableDecoration.Row(
                        sourceRange: content,
                        lineRange: rowLine,
                        cells: cells,
                        isHeader: child.type == "pipe_table_header"))
                    hide(content)
                case "pipe_table_delimiter_row":
                    // The dashes are layout, not content: the row leaves the
                    // display entirely.
                    let delimiterLine = line(at: child.range.location)
                    hide(MarkdownLiveStyler.lineContentRange(delimiterLine, in: source))
                    collapse(delimiterLine)
                default: break
                }
            }
            guard !rows.isEmpty, columns > 0 else { return }
            let padded = rows.map {
                MarkdownTableDecoration.Row(
                    sourceRange: $0.sourceRange, lineRange: $0.lineRange,
                    cells: $0.cells + Array(repeating: "",
                                            count: max(0, columns - $0.cells.count)),
                    isHeader: $0.isHeader)
            }
            tables.append(MarkdownTableDecoration(
                sourceRange: node.range, rows: padded, columnCount: columns,
                leadsWithBlankLine: precededByBlankLine(padded[0].lineRange)))
        }

        // MARK: Inlines

        mutating func walkInlines(_ nodes: [MarkdownNode]) {
            for node in nodes {
                switch node.type {
                case "code_span":
                    style(inlineCodeStyle, node.range)
                    literalRanges.append(node.range)
                    for delimiter in node.all("code_span_delimiter") {
                        dim(delimiter.range)
                        hide(delimiter.range)
                    }
                case "emphasis", "strong_emphasis", "strikethrough":
                    emphasis(node)
                case "inline_link", "full_reference_link", "collapsed_reference_link",
                     "shortcut_link":
                    link(node)
                case "image":
                    image(node)
                case "uri_autolink", "email_autolink":
                    // `<https://…>`: the brackets are syntax, the address is the
                    // link.
                    let inner = NSRange(location: node.range.location + 1,
                                        length: max(0, node.range.length - 2))
                    style(linkStyle, inner)
                    hide(NSRange(location: node.range.location, length: 1))
                    hide(NSRange(location: NSMaxRange(node.range) - 1, length: 1))
                case "entity_reference", "numeric_character_reference":
                    if let character = MarkdownLiveStyler.decodedEntity(
                        source.substring(with: node.range)) {
                        glyphs.append(MarkdownGlyphReplacement(
                            sourceRange: node.range, character: character))
                    }
                case "backslash_escape":
                    hide(NSRange(location: node.range.location, length: 1))
                case "hard_line_break", "html_tag":
                    hide(node.range)
                default: break
                }
                walkInlines(node.children)
            }
        }

        mutating func emphasis(_ node: MarkdownNode) {
            let delimiters = node.all("emphasis_delimiter")
            let content: NSRange
            if let opening = delimiters.first, let closing = delimiters.last,
               delimiters.count >= 2 {
                content = NSRange(location: NSMaxRange(opening.range),
                                  length: max(0, closing.range.location
                                                - NSMaxRange(opening.range)))
            } else {
                content = node.range
            }
            switch node.type {
            case "strong_emphasis":
                style([.font: boldFont, .strokeWidth: -2.0], content)
            case "strikethrough":
                style([.strikethroughStyle: NSUnderlineStyle.single.rawValue], content)
            default:
                // Emphasis inside strong emphasis wants both, and the strong
                // pass has already run over this range.
                let isStrong = storage.length > content.location
                    && storage.attribute(.strokeWidth, at: content.location,
                                         effectiveRange: nil) != nil
                style([.font: isStrong ? boldItalicFont : italicFont,
                       .obliqueness: 0.16], content)
            }
            for delimiter in delimiters {
                dim(delimiter.range)
                hide(delimiter.range)
            }
        }

        mutating func link(_ node: MarkdownNode) {
            let label = node.first("link_text") ?? node.first("link_label")
            guard let label else {
                hide(node.range)
                return
            }
            let identifier = source.substring(with: label.range)
            style(linkStyle, label.range)
            // `[^detail]` is a footnote reference, not a link to a label.
            if node.type == "shortcut_link", identifier.hasPrefix("^") {
                style([.superscript: 1], label.range)
            }
            // Everything around the text — brackets, destination, title — is
            // syntax.
            hide(NSRange(location: node.range.location,
                         length: max(0, label.range.location - node.range.location)))
            hide(NSRange(location: NSMaxRange(label.range),
                         length: max(0, NSMaxRange(node.range) - NSMaxRange(label.range))))
        }

        mutating func image(_ node: MarkdownNode) {
            let alt = node.first("image_description").map { source.substring(with: $0.range) } ?? ""
            let destination = node.first("link_destination")
                .map { source.substring(with: $0.range) } ?? ""
            let imageLine = line(at: node.range.location)
            let content = MarkdownLiveStyler.lineContentRange(imageLine, in: source)
            hide(node.range)
            // Only an image that is the whole line is drawn in place; one inside
            // a sentence keeps its place in the text.
            guard node.range.location == content.location,
                  NSMaxRange(node.range) == NSMaxRange(content) else {
                style(linkStyle, node.range)
                return
            }
            images.append(MarkdownImageDecoration(
                sourceRange: node.range, lineRange: imageLine, alt: alt,
                url: MarkdownLiveStyler.resolvedImageURL(destination,
                                                         relativeTo: documentURL)))
        }

        /// GFM links a bare URL that is not already inside a link or a code
        /// span. The inline grammar has no node for it, so this is the one
        /// pattern left — and it now runs only over text the tree says is plain.
        mutating func bareURLs() {
            guard let expression = try? NSRegularExpression(
                pattern: #"(?<![<(\w])https?://[^\s<>\])]+"#,
                options: [.caseInsensitive]) else { return }
            let full = NSRange(location: 0, length: source.length)
            expression.enumerateMatches(in: text, range: full) { match, _, _ in
                guard let match else { return }
                guard !literalRanges.contains(where: {
                    NSIntersectionRange($0, match.range).length > 0
                }), !syntax.contains(where: {
                    NSIntersectionRange($0, match.range).length > 0
                }) else { return }
                var styled = match.range
                while styled.length > 0 {
                    let tail = source.character(at: NSMaxRange(styled) - 1)
                    guard tail == 0x2E || tail == 0x2C || tail == 0x3B || tail == 0x3A
                            || tail == 0x21 || tail == 0x3F else { break }
                    styled.length -= 1
                }
                if styled.length > 0 { style(linkStyle, styled) }
            }
        }
    }

    // MARK: - Shared helpers

    static func lineContentRange(_ line: NSRange, in source: NSString) -> NSRange {
        var end = NSMaxRange(line)
        while end > line.location {
            let character = source.character(at: end - 1)
            guard character == 0x0A || character == 0x0D else { break }
            end -= 1
        }
        return NSRange(location: line.location, length: end - line.location)
    }

    static func normalized(_ ranges: [NSRange]) -> [NSRange] {
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

    static func resolvedImageURL(_ destination: String, relativeTo documentURL: URL?) -> URL? {
        if let url = URL(string: destination), url.scheme != nil { return url }
        guard let documentURL else { return nil }
        let decoded = destination.removingPercentEncoding ?? destination
        return documentURL.deletingLastPathComponent()
            .appendingPathComponent(decoded).standardizedFileURL
    }

    /// `&amp;` / `&#169;` / `&#xA9;` → the character it stands for.
    static func decodedEntity(_ source: String) -> UInt16? {
        let named: [String: UInt32] = [
            "amp": 0x26, "lt": 0x3C, "gt": 0x3E, "quot": 0x22,
            "apos": 0x27, "nbsp": 0x00A0, "copy": 0x00A9, "reg": 0x00AE,
            "trade": 0x2122, "ndash": 0x2013, "mdash": 0x2014,
            "hellip": 0x2026, "laquo": 0x00AB, "raquo": 0x00BB,
        ]
        var body = source
        guard body.hasPrefix("&"), body.hasSuffix(";") else { return nil }
        body = String(body.dropFirst().dropLast())
        let value: UInt32?
        if body.hasPrefix("#x") || body.hasPrefix("#X") {
            value = UInt32(body.dropFirst(2), radix: 16)
        } else if body.hasPrefix("#") {
            value = UInt32(body.dropFirst())
        } else {
            value = named[body.lowercased()]
        }
        guard let value, value <= UInt16.max,
              !(0xD800...0xDFFF).contains(value) else { return nil }
        return UInt16(value)
    }

    /// A table cell is drawn, not laid out from the source, so its own markup
    /// is resolved to the text it stands for.
    static func renderedCell(_ source: String) -> String {
        var value = source.trimmingCharacters(in: .whitespaces)
        if let expression = try? NSRegularExpression(pattern: #"!?\[([^\]]+)\]\([^)]+\)"#) {
            value = expression.stringByReplacingMatches(
                in: value, range: NSRange(location: 0, length: (value as NSString).length),
                withTemplate: "$1")
        }
        for token in ["**", "__", "~~", "`", "*", "_"] {
            value = value.replacingOccurrences(of: token, with: "")
        }
        value = value.replacingOccurrences(of: #"\|"#, with: "|")
        if let expression = try? NSRegularExpression(
            pattern: #"&(?:#[0-9]+|#[xX][0-9A-Fa-f]+|[A-Za-z][A-Za-z0-9]+);"#) {
            let mutable = NSMutableString(string: value)
            for match in expression.matches(
                in: value, range: NSRange(location: 0, length: mutable.length)).reversed() {
                let entity = (value as NSString).substring(with: match.range)
                if let character = decodedEntity(entity), let scalar = UnicodeScalar(character) {
                    mutable.replaceCharacters(in: match.range, with: String(scalar))
                }
            }
            value = mutable as String
        }
        return value
    }
}

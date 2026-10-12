import AppKit

extension NSAttributedString.Key {
    /// How one line of rendered Markdown is laid out. Set by the styler on
    /// every line, read by the layout manager in place of the fixed code row.
    static let markdownLineLayout = NSAttributedString.Key("PuzzleMarkdownLineLayout")
}

/// The height of one line of rendered Markdown, the space above it, and the
/// metrics of the face it is set in — what the layout manager needs to size
/// the line and put its baseline in the middle of it.
///
/// An object rather than a struct because attribute values are compared with
/// `isEqual`: equal layouts on neighbouring lines then share one attribute run.
final class MarkdownLineLayout: NSObject {
    let lineHeight: CGFloat
    /// Applied to a line's first fragment only, never to the lines it wraps
    /// onto.
    let spaceBefore: CGFloat
    let ascender: CGFloat
    let descender: CGFloat
    /// The line's layout while its source shows, for a line that draws nothing
    /// otherwise: a code fence is padding inside its box until the caret is on
    /// it, and then it has to be a line its backticks fit in.
    let whenRevealed: MarkdownLineLayout?

    init(lineHeight: CGFloat, spaceBefore: CGFloat = 0, font: NSFont,
         whenRevealed: MarkdownLineLayout? = nil) {
        self.lineHeight = lineHeight
        self.spaceBefore = spaceBefore
        ascender = font.ascender
        descender = font.descender
        self.whenRevealed = whenRevealed
    }

    /// Where the baseline goes in a fragment that starts with `spaceAbove`.
    func baselineOffset(spaceAbove: CGFloat) -> CGFloat {
        spaceAbove + (lineHeight - (ascender - descender)) / 2 + ascender
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? MarkdownLineLayout else { return false }
        return lineHeight == other.lineHeight && spaceBefore == other.spaceBefore
            && ascender == other.ascender && descender == other.descender
            && whenRevealed == other.whenRevealed
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(lineHeight)
        hasher.combine(spaceBefore)
        hasher.combine(ascender)
        hasher.combine(descender)
        return hasher.finalize()
    }
}

struct MarkdownCodeBlockDecoration: Equatable {
    let range: NSRange
    let language: String?
    /// Where the block's box starts across the column: in from the margin by
    /// whatever list or quote holds the block.
    var indent: CGFloat = 0
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
    /// Where the item's text starts; the box is drawn in the margin before it.
    var indent: CGFloat = 0
}

enum MarkdownLineMarkerKind: Equatable {
    case bullet(String)
    case quote(Int)
    case footnote(String)
    /// A heading's `#`s: drawn only while the heading is edited, in the margin.
    case heading
}

struct MarkdownLineMarkerDecoration: Equatable {
    /// A bullet or footnote marker's own characters, or a whole quote.
    let sourceRange: NSRange
    let kind: MarkdownLineMarkerKind
    /// For a bullet or a footnote, where the text starts: the marker is drawn
    /// in the margin to the left of it. For a quote, where its bar goes.
    var indent: CGFloat = 0
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

/// A link in the rendered document: the text the reader sees, and where it
/// points. The destination is kept as written as well as resolved, so a
/// relative path can still be shown when it resolves to nothing.
struct MarkdownLinkDecoration: Equatable {
    /// The visible text — the label, not the `[…](…)` around it.
    let sourceRange: NSRange
    let destination: String
    let url: URL?
    /// The whole link as written, `[…](…)` and all: what is shown when the
    /// link itself is to be edited.
    var fullRange: NSRange

    init(sourceRange: NSRange, destination: String, url: URL?, fullRange: NSRange? = nil) {
        self.sourceRange = sourceRange
        self.destination = destination
        self.url = url
        self.fullRange = fullRange ?? sourceRange
    }
}

/// Inline formatting — emphasis, strong, strikethrough, a code span — with
/// its delimiters, which are hidden. While the caret is in the span or at its
/// edge the delimiters are drawn faintly at its edges, taking no room: the
/// reader can see which side of a `**` the caret is on without the line
/// moving to show it.
struct MarkdownSpanDecoration: Equatable {
    enum Kind: Equatable { case emphasis, strong, strikethrough, code }

    let range: NSRange
    let opening: NSRange
    let closing: NSRange
    var kind: Kind = .emphasis

    /// What is between the delimiters. The caret anywhere in it, either end
    /// included, types into the span.
    var content: NSRange {
        NSRange(location: NSMaxRange(opening), length: closing.location - NSMaxRange(opening))
    }
}

struct MarkdownGlyphReplacement: Equatable {
    let sourceRange: NSRange
    let character: UInt16
}

struct MarkdownPresentation: Equatable {
    var hiddenSyntaxRanges: [NSRange] = []
    /// What a block puts in front of its text — a heading's `#`, a list's
    /// marker, a quote's `>`, the indent a container repeats. Kept apart from
    /// the inline syntax: editing a line shows that line's inline syntax, but
    /// its lead stays out of the text and is drawn in the margin instead, so
    /// the text does not move sideways as editing starts.
    var leadRanges: [NSRange] = []
    var collapsedLineRanges: [NSRange] = []
    var codeBlocks: [MarkdownCodeBlockDecoration] = []
    var tables: [MarkdownTableDecoration] = []
    var tasks: [MarkdownTaskDecoration] = []
    var lineMarkers: [MarkdownLineMarkerDecoration] = []
    var rules: [MarkdownRuleDecoration] = []
    var images: [MarkdownImageDecoration] = []
    var glyphReplacements: [MarkdownGlyphReplacement] = []
    var links: [MarkdownLinkDecoration] = []
    var spans: [MarkdownSpanDecoration] = []
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

        /// Prose is set in the reading face; code keeps the editor's.
        private let baseFont = Theme.markdownFont()
        private let codeFont = Theme.editorFont()
        private let boldFont: NSFont
        private let italicFont: NSFont
        private let boldItalicFont: NSFont
        /// A face that has no italic of its own is slanted instead.
        private let fakesItalic: Bool
        private let bodyLayout: MarkdownLineLayout
        private let blankLayout: MarkdownLineLayout
        private let codeLayout: MarkdownLineLayout
        private let fencePaddingLayout: MarkdownLineLayout
        private let marker: [NSAttributedString.Key: Any]
        private let codeStyle: [NSAttributedString.Key: Any]
        private let inlineCodeStyle: [NSAttributedString.Key: Any]
        private let linkStyle: [NSAttributedString.Key: Any]

        private var syntax: [NSRange] = []
        private var leads: [NSRange] = []
        private var collapsed: [NSRange] = []
        private var codeBlocks: [MarkdownCodeBlockDecoration] = []
        private var tables: [MarkdownTableDecoration] = []
        private var tasks: [MarkdownTaskDecoration] = []
        private var lineMarkers: [MarkdownLineMarkerDecoration] = []
        private var rules: [MarkdownRuleDecoration] = []
        private var images: [MarkdownImageDecoration] = []
        private var glyphs: [MarkdownGlyphReplacement] = []
        private var links: [MarkdownLinkDecoration] = []
        private var spans: [MarkdownSpanDecoration] = []
        /// Reference links resolved once the whole document is known: a
        /// definition may sit below the paragraph that uses it.
        private var pendingReferenceLinks: [(range: NSRange, full: NSRange, label: String)] = []
        private var linkDefinitions: [String: String] = [:]
        /// Spans whose text is literal — a code span or a fenced block — so the
        /// GFM bare-URL scan does not link inside them.
        private var literalRanges: [NSRange] = []
        private let text: String

        init(text: String, storage: NSTextStorage, documentURL: URL?) {
            self.text = text
            self.source = text as NSString
            self.storage = storage
            self.documentURL = documentURL
            let bold = NSFont.boldSystemFont(ofSize: baseFont.pointSize)
            boldFont = bold
            let italic = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
            fakesItalic = !NSFontManager.shared.traits(of: italic).contains(.italicFontMask)
            italicFont = italic
            boldItalicFont = NSFontManager.shared.convert(bold, toHaveTrait: .italicFontMask)
            bodyLayout = MarkdownLineLayout(lineHeight: Theme.markdownLineHeight(),
                                            font: baseFont)
            blankLayout = MarkdownLineLayout(lineHeight: Theme.markdownBlankLineHeight(),
                                             font: baseFont)
            codeLayout = MarkdownLineLayout(lineHeight: Theme.lineMetrics().target,
                                            font: codeFont)
            fencePaddingLayout = MarkdownLineLayout(lineHeight: Theme.markdownCodePaddingY,
                                                    font: baseFont, whenRevealed: bodyLayout)
            marker = [.foregroundColor: Theme.dimText]
            codeStyle = [.foregroundColor: Theme.foreground, .font: codeFont]
            // No background attribute: TextKit fills it the height of the
            // line, a heading's room above included. The text view draws the
            // box instead, as tall as the code.
            inlineCodeStyle = [.foregroundColor: Theme.yellow, .font: codeFont]
            linkStyle = [.foregroundColor: Theme.blue,
                         .underlineStyle: NSUnderlineStyle.single.rawValue]
        }

        var result: MarkdownPresentation {
            MarkdownPresentation(
                hiddenSyntaxRanges: MarkdownLiveStyler.normalized(syntax.filter { $0.length > 0 }),
                leadRanges: MarkdownLiveStyler.normalized(leads.filter { $0.length > 0 }),
                collapsedLineRanges: MarkdownLiveStyler.normalized(
                    collapsed.filter { $0.length > 0 }),
                codeBlocks: codeBlocks, tables: tables, tasks: tasks,
                lineMarkers: lineMarkers, rules: rules, images: images,
                glyphReplacements: glyphs, links: links, spans: spans)
        }

        mutating func run() {
            let document = MarkdownSyntaxTree.parse(text)
            storage.beginEditing()
            setUpLines()
            walkBlocks(document.blocks, quoteDepth: 0, indent: 0)
            walkInlines(document.inlines)
            bareURLs()
            resolveReferenceLinks()
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

        /// Hidden like syntax, but a block's lead: see `leadRanges`.
        mutating func lead(_ range: NSRange) {
            var trimmed = range
            while trimmed.length > 0 {
                let last = source.character(at: NSMaxRange(trimmed) - 1)
                guard last == 0x0A || last == 0x0D else { break }
                trimmed.length -= 1
            }
            guard trimmed.length > 0 else { return }
            leads.append(trimmed)
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

        /// Every line set as prose before the blocks say otherwise: the reading
        /// face, a paragraph with no fixed height, and a layout — a line of
        /// text, or the shorter gap a blank line stands for.
        func setUpLines() {
            let full = NSRange(location: 0, length: storage.length)
            style([.font: baseFont,
                   .paragraphStyle: MarkdownLiveStyler.paragraph(indent: 0),
                   .markdownLineLayout: bodyLayout], full)
            // Then only the blank lines, found by scanning rather than by
            // slicing each line out: this runs on every keystroke.
            var lineStart = 0
            var blank = true
            for index in 0..<source.length {
                let character = source.character(at: index)
                if character == 0x0A {
                    if blank {
                        style([.markdownLineLayout: blankLayout],
                              NSRange(location: lineStart, length: index + 1 - lineStart))
                    }
                    lineStart = index + 1
                    blank = true
                } else if character != 0x20 && character != 0x09 && character != 0x0D {
                    blank = false
                }
            }
            if blank, lineStart < source.length {
                style([.markdownLineLayout: blankLayout],
                      NSRange(location: lineStart, length: source.length - lineStart))
            }
        }

        /// The whole lines `range` touches. TextKit reads a paragraph's style
        /// from its first character, so an indent has to cover the line from
        /// its start — the hidden marker included.
        func lines(of range: NSRange) -> NSRange {
            guard source.length > 0 else { return range }
            let first = line(at: range.location)
            let last = line(at: max(range.location, NSMaxRange(range) - 1))
            return NSUnionRange(first, last)
        }

        /// Set the lines of `range` in from the margin by `indent`, wrapped
        /// lines with them.
        func indentLines(_ range: NSRange, by indent: CGFloat) {
            guard range.length > 0 else { return }
            style([.paragraphStyle: MarkdownLiveStyler.paragraph(indent: indent)],
                  lines(of: range))
        }

        func layOutLines(_ range: NSRange, as layout: MarkdownLineLayout) {
            guard range.length > 0 else { return }
            style([.markdownLineLayout: layout], lines(of: range))
        }

        // MARK: Blocks

        /// `indent` is where the blocks being walked start across the column:
        /// a list item or a quote sets what it holds further in.
        mutating func walkBlocks(_ nodes: [MarkdownNode], quoteDepth: Int, indent: CGFloat) {
            for node in nodes {
                switch node.type {
                case "atx_heading": heading(node, indent: indent)
                case "setext_heading": setextHeading(node, indent: indent)
                case "fenced_code_block": fencedCode(node, indent: indent)
                case "indented_code_block": indentedCode(node, indent: indent)
                case "thematic_break": thematicBreak(node)
                case "pipe_table": table(node)
                case "link_reference_definition": referenceDefinition(node)
                case "html_block": hide(node.range)
                case "block_continuation":
                    // What a container repeats at the start of each line it
                    // holds — a list item's indent, a quote's `>` — is drawn
                    // as the container's own indent and bar instead.
                    dim(node.range)
                    lead(node.range)
                case "block_quote":
                    // The bar goes down the whole quote, not only beside the
                    // lines that repeat its marker.
                    for child in node.all("block_quote_marker") {
                        dim(child.range)
                        lead(child.range)
                    }
                    lineMarkers.append(MarkdownLineMarkerDecoration(
                        sourceRange: node.range, kind: .quote(quoteDepth + 1), indent: indent))
                    let inner = indent + Theme.markdownQuoteIndent()
                    indentLines(node.range, by: inner)
                    walkBlocks(node.children, quoteDepth: quoteDepth + 1, indent: inner)
                case "list_item":
                    let inner = indent + Theme.markdownListIndent()
                    listItem(node, textStart: inner)
                    walkBlocks(node.children, quoteDepth: quoteDepth, indent: inner)
                case "paragraph":
                    // Already where its list item or quote set every line it
                    // holds, or at the margin the base pass set.
                    footnoteDefinition(node, indent: indent)
                    walkBlocks(node.children, quoteDepth: quoteDepth, indent: indent)
                default:
                    walkBlocks(node.children, quoteDepth: quoteDepth, indent: indent)
                }
            }
        }

        mutating func heading(_ node: MarkdownNode, indent: CGFloat) {
            guard let markerNode = node.children.first(where: {
                $0.type.hasPrefix("atx_h") && $0.type.hasSuffix("_marker")
            }) else { return }
            let level = Int(String(markerNode.type.dropFirst(5).prefix(1))) ?? 1
            dim(markerNode.range)
            guard let content = node.first("inline") else {
                hide(node.range)
                return
            }
            // The marker and the space after it — drawn in the margin while
            // the heading is edited.
            lead(NSRange(location: node.range.location,
                         length: max(0, content.range.location - node.range.location)))
            lineMarkers.append(MarkdownLineMarkerDecoration(
                sourceRange: markerNode.range, kind: .heading, indent: indent))
            // A closing run of #s, if the author wrote one.
            let contentEnd = NSMaxRange(content.range)
            let lineEnd = NSMaxRange(MarkdownLiveStyler.lineContentRange(
                line(at: node.range.location), in: source))
            if lineEnd > contentEnd {
                hide(NSRange(location: contentEnd, length: lineEnd - contentEnd))
            }
            style(headingAttributes(level: level), content.range)
            layOutHeading(node.range, level: level, indent: indent)
        }

        /// A heading's line: tall enough for its size, with room above it —
        /// none at the very top, where the pane's own margin already is.
        mutating func layOutHeading(_ range: NSRange, level: Int, indent: CGFloat) {
            let font = headingFont(level: level)
            let lines = self.lines(of: range)
            layOutLines(range, as: MarkdownLineLayout(
                lineHeight: (font.pointSize * 1.3).rounded(),
                spaceBefore: lines.location == 0 ? 0 : Theme.markdownHeadingSpaceBefore(level: level),
                font: font))
        }

        mutating func setextHeading(_ node: MarkdownNode, indent: CGFloat) {
            guard let underline = node.children.first(where: {
                $0.type.hasPrefix("setext_h") && $0.type.hasSuffix("_underline")
            }) else { return }
            let level = node.first("setext_h1_underline") != nil ? 1 : 2
            for content in node.descendants("inline") {
                style(headingAttributes(level: level), content.range)
                layOutHeading(content.range, level: level, indent: indent)
            }
            let underlineLine = line(at: underline.range.location)
            dim(underlineLine)
            hide(MarkdownLiveStyler.lineContentRange(underlineLine, in: source))
            collapse(underlineLine)
        }

        /// Each level its own size: the line a heading is set on grows to fit
        /// it, so the size is no longer held under the height of a code row —
        /// which had left H1, H2 and H3 all within a point of each other.
        func headingFont(level: Int) -> NSFont {
            NSFont.boldSystemFont(ofSize: Theme.markdownHeadingSize(level: level))
        }

        func headingAttributes(level: Int) -> [NSAttributedString.Key: Any] {
            [.font: headingFont(level: level),
             .foregroundColor: level >= 6 ? Theme.dimText : Theme.foreground]
        }

        mutating func fencedCode(_ node: MarkdownNode, indent: CGFloat) {
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
            // Inside a list the code's lines repeat the item's indent; that is
            // the item's, drawn as the block's own indent, not the code's.
            for continuation in node.descendants("block_continuation") {
                lead(continuation.range)
            }
            if let body, body.length > 0 {
                style(codeStyle, body)
                layOutCode(body, indent: indent)
                codeBlocks.append(MarkdownCodeBlockDecoration(
                    range: body, language: (language?.isEmpty ?? true) ? nil : language,
                    indent: indent))
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
                // A line that is nothing but its fence becomes the padding
                // inside the block's box, above or below the code; one that
                // carries a marker still has to be drawn as a line of its own.
                let prefix = source.substring(
                    with: NSRange(location: content.location,
                                  length: max(0, fence.location - content.location)))
                if prefix.allSatisfy({ $0 == " " || $0 == "\t" }) {
                    style([.markdownLineLayout: fencePaddingLayout], fenceLine)
                }
            }
        }

        mutating func indentedCode(_ node: MarkdownNode, indent: CGFloat) {
            style(codeStyle, node.range)
            layOutCode(node.range, indent: indent)
            codeBlocks.append(MarkdownCodeBlockDecoration(range: node.range, language: nil,
                                                         indent: indent))
            literalRanges.append(node.range)
        }

        /// Code keeps the editor's face and row, set in from the box's edge.
        mutating func layOutCode(_ range: NSRange, indent: CGFloat) {
            layOutLines(range, as: codeLayout)
            indentLines(range, by: indent + Theme.markdownCodePaddingX)
        }

        mutating func thematicBreak(_ node: MarkdownNode) {
            let ruleLine = line(at: node.range.location)
            dim(node.range)
            hide(MarkdownLiveStyler.lineContentRange(ruleLine, in: source))
            rules.append(MarkdownRuleDecoration(lineRange: ruleLine))
        }

        /// A list item's text starts at `textStart`, on every line it has, and
        /// its marker is drawn in the margin to the left — so items line up
        /// whatever their marker, and a wrapped line comes back under the text
        /// rather than under the bullet.
        mutating func listItem(_ node: MarkdownNode, textStart: CGFloat) {
            guard let bullet = node.children.first(where: {
                $0.type.hasPrefix("list_marker_")
            }) else { return }
            dim(bullet.range)
            indentLines(node.range, by: textStart)
            // The item's own checkbox, never one belonging to an item nested
            // inside it: searching every descendant took a nested `[x]` for
            // this item's, and everything between the two left the page.
            let checkbox = node.first("task_list_marker_checked")
                ?? node.first("task_list_marker_unchecked")
            // Everything from the start of the line to the text — the indent
            // the source nests with, the marker, a checkbox — leaves the line.
            let markerLine = line(at: bullet.range.location)
            var lead = NSMaxRange(checkbox?.range ?? bullet.range)
            while lead < NSMaxRange(markerLine),
                  source.character(at: lead) == 0x20 || source.character(at: lead) == 0x09 {
                lead += 1
            }
            self.lead(NSRange(location: markerLine.location, length: lead - markerLine.location))
            guard let checkbox else {
                let label = source.substring(with: bullet.range)
                    .trimmingCharacters(in: .whitespaces)
                lineMarkers.append(MarkdownLineMarkerDecoration(
                    sourceRange: bullet.range,
                    kind: .bullet(label.allSatisfy { "-+*".contains($0) } ? "•" : label),
                    indent: textStart))
                return
            }
            let checked = checkbox.type.hasSuffix("checked")
                && !checkbox.type.hasSuffix("unchecked")
            let span = NSRange(location: bullet.range.location,
                               length: max(0, NSMaxRange(checkbox.range) - bullet.range.location))
            dim(span)
            tasks.append(MarkdownTaskDecoration(sourceRange: span, checked: checked,
                                                indent: textStart))
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
        mutating func footnoteDefinition(_ node: MarkdownNode, indent: CGFloat) {
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
            // The body hangs like a list item's, its label in the margin.
            var lead = NSMaxRange(span)
            while lead < NSMaxRange(content), source.character(at: lead) == 0x20 { lead += 1 }
            self.lead(NSRange(location: span.location, length: lead - span.location))
            let textStart = indent + Theme.markdownListIndent()
            indentLines(node.range, by: textStart)
            lineMarkers.append(MarkdownLineMarkerDecoration(
                sourceRange: span, kind: .footnote(identifier), indent: textStart))
        }

        /// Record one link. The destination is kept verbatim as well as
        /// resolved: a relative path that points at nothing is still worth
        /// showing to whoever is hovering it.
        mutating func note(link range: NSRange, full: NSRange? = nil, destination: String) {
            let trimmed = destination.trimmingCharacters(in: .whitespaces)
            guard range.length > 0, !trimmed.isEmpty else { return }
            links.append(MarkdownLinkDecoration(
                sourceRange: range, destination: trimmed,
                url: MarkdownLiveStyler.resolvedLinkURL(trimmed, relativeTo: documentURL),
                fullRange: full))
        }

        /// Reference links, once every definition in the document has been read.
        mutating func resolveReferenceLinks() {
            for pending in pendingReferenceLinks {
                guard let destination =
                        linkDefinitions[MarkdownLiveStyler.linkKey(pending.label)] else { continue }
                note(link: pending.range, full: pending.full, destination: destination)
            }
            pendingReferenceLinks.removeAll()
        }

        mutating func referenceDefinition(_ node: MarkdownNode) {
            if let label = node.first("link_label"), let target = node.first("link_destination") {
                linkDefinitions[MarkdownLiveStyler.linkKey(source.substring(with: label.range))]
                    = source.substring(with: target.range)
            }
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
                    let delimiters = node.all("code_span_delimiter")
                    for delimiter in delimiters {
                        dim(delimiter.range)
                        hide(delimiter.range)
                    }
                    noteSpan(node, delimiters: delimiters)
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
                    note(link: inner, full: node.range,
                         destination: node.type == "email_autolink"
                            ? "mailto:" + source.substring(with: inner)
                            : source.substring(with: inner))
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
            // Whichever of the two is outside has already styled the range:
            // `***both***` wants bold and italic, not the inner one alone.
            let current = storage.length > content.location
                ? storage.attribute(.font, at: content.location, effectiveRange: nil)
                    as? NSFont : nil
            let traits = current.map { NSFontManager.shared.traits(of: $0) } ?? []
            switch node.type {
            case "strong_emphasis":
                // A slanted face keeps its slant: that is an attribute of its
                // own, and setting the font leaves it.
                style([.font: traits.contains(.italicFontMask) ? boldItalicFont : boldFont],
                      content)
            case "strikethrough":
                style([.strikethroughStyle: NSUnderlineStyle.single.rawValue], content)
            default:
                let isStrong = traits.contains(.boldFontMask)
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: isStrong ? boldItalicFont : italicFont,
                ]
                if fakesItalic { attributes[.obliqueness] = 0.16 }
                style(attributes, content)
            }
            for delimiter in delimiters {
                dim(delimiter.range)
                hide(delimiter.range)
            }
            noteSpan(node, delimiters: delimiters)
        }

        /// A span whose delimiters open and close it — the only kind whose
        /// edges can be marked.
        /// The grammar gives `**` as two delimiters, one per character, so an
        /// edge is the run of them that touches it.
        mutating func noteSpan(_ node: MarkdownNode, delimiters: [MarkdownNode]) {
            var opening = NSRange(location: node.range.location, length: 0)
            for delimiter in delimiters where delimiter.range.location == NSMaxRange(opening) {
                opening.length += delimiter.range.length
            }
            var closing = NSRange(location: NSMaxRange(node.range), length: 0)
            for delimiter in delimiters.reversed()
            where NSMaxRange(delimiter.range) == closing.location {
                closing = NSRange(location: delimiter.range.location,
                                  length: closing.length + delimiter.range.length)
            }
            guard opening.length > 0, closing.length > 0,
                  NSMaxRange(opening) <= closing.location else { return }
            let kind: MarkdownSpanDecoration.Kind
            switch node.type {
            case "strong_emphasis": kind = .strong
            case "strikethrough": kind = .strikethrough
            case "code_span": kind = .code
            default: kind = .emphasis
            }
            spans.append(MarkdownSpanDecoration(range: node.range, opening: opening,
                                                closing: closing, kind: kind))
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
            } else if let destination = node.first("link_destination") {
                note(link: label.range, full: node.range,
                     destination: source.substring(with: destination.range))
            } else {
                // A reference link names a definition that may not have been
                // read yet. `[text][label]` names one; `[text]` is its own.
                let reference = node.first("link_label").map { source.substring(with: $0.range) }
                pendingReferenceLinks.append((label.range, node.range, reference ?? identifier))
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
                if styled.length > 0 {
                    style(linkStyle, styled)
                    note(link: styled, destination: source.substring(with: styled))
                }
            }
        }
    }

    // MARK: - Shared helpers

    /// A paragraph of rendered Markdown: in from the margin by `indent` on
    /// every line, wrapped ones included, and no fixed height — the layout
    /// manager sizes each line from its `MarkdownLineLayout`.
    static func paragraph(indent: CGFloat) -> NSParagraphStyle {
        if let cached = paragraphCache[indent] { return cached }
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        style.lineBreakMode = .byWordWrapping
        style.defaultTabInterval = (Theme.markdownFontSize() * 2).rounded()
        style.tabStops = []
        let frozen = style.copy() as! NSParagraphStyle
        paragraphCache[indent] = frozen
        return frozen
    }
    private static var paragraphCache: [CGFloat: NSParagraphStyle] = [:]
    /// Called when the settings change the type size the indents follow.
    static func invalidateCaches() { paragraphCache.removeAll() }

    /// Link labels match case-insensitively and ignore surrounding brackets and
    /// whitespace, which is what CommonMark says about reference labels.
    static func linkKey(_ label: String) -> String {
        var text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("[") { text.removeFirst() }
        if text.hasSuffix("]") { text.removeLast() }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// What a link destination points at. An absolute URL is taken as written;
    /// anything else is resolved against the document, so `./notes.md` opens
    /// the file next to it rather than nothing at all.
    static func resolvedLinkURL(_ destination: String, relativeTo documentURL: URL?) -> URL? {
        var text = destination.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("<") && text.hasSuffix(">") {
            // The angle brackets are how Markdown writes a destination that
            // contains spaces. Splitting one on the first space defeats them.
            text = String(text.dropFirst().dropLast())
        } else if let space = text.firstIndex(where: { $0 == " " || $0 == "\t" }) {
            // A title after the destination — `(url "Title")` — is not part of
            // it, and a bare destination cannot contain a space anyway.
            text = String(text[text.startIndex..<space])
        }
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text) ?? URL(string: text.addingPercentEncoding(
                withAllowedCharacters: .urlFragmentAllowed) ?? ""),
           url.scheme != nil {
            return url
        }
        guard let documentURL, !text.hasPrefix("#") else { return nil }
        // A relative destination is a URI, not a filename: `notes.md#intro`
        // names a place inside `notes.md`, and asking the file system for a
        // file called "notes.md#intro" only ever misses.
        var path = text
        if let fragment = path.firstIndex(of: "#") { path = String(path[..<fragment]) }
        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
        guard !path.isEmpty else { return nil }
        let base = documentURL.deletingLastPathComponent()
        return URL(fileURLWithPath: path.removingPercentEncoding ?? path,
                   relativeTo: base).standardizedFileURL
    }

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
        func replace(_ expression: NSRegularExpression?, with template: String) {
            guard let expression else { return }
            value = expression.stringByReplacingMatches(
                in: value, range: NSRange(location: 0, length: (value as NSString).length),
                withTemplate: template)
        }
        replace(cellLink, with: "$1")
        // Only delimiters that open and close a span are markup. Removing every
        // `_` and `*` took the underscores out of `code_line_height` and the
        // operator out of `2 * 3`.
        for span in cellSpans { replace(span, with: "$1") }
        value = value.replacingOccurrences(of: #"\|"#, with: "|")
        if let cellEntity {
            let mutable = NSMutableString(string: value)
            for match in cellEntity.matches(
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

    // Compiled once: every cell of every table is resolved on every keystroke,
    // and compiling the patterns per cell was most of the time spent styling a
    // document with tables in it.
    private static let cellLink = try? NSRegularExpression(pattern: #"!?\[([^\]]+)\]\([^)]+\)"#)
    private static let cellSpans: [NSRegularExpression] = [
        #"`([^`]+)`"#,
        #"(?<![\w*])\*\*(?=\S)(.+?)(?<=\S)\*\*(?![\w*])"#,
        #"(?<![\w_])__(?=\S)(.+?)(?<=\S)__(?![\w_])"#,
        #"~~(?=\S)(.+?)(?<=\S)~~"#,
        #"(?<![\w*])\*(?=\S)(.+?)(?<=\S)\*(?![\w*])"#,
        #"(?<![\w_])_(?=\S)(.+?)(?<=\S)_(?![\w_])"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }
    private static let cellEntity = try? NSRegularExpression(
        pattern: #"&(?:#[0-9]+|#[xX][0-9A-Fa-f]+|[A-Za-z][A-Za-z0-9]+);"#)
}

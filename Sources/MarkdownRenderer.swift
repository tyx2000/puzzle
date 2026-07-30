import AppKit

/// Renders markdown source to an `NSAttributedString` for the live preview.
///
/// Uses the two vendored tree-sitter markdown grammars rather than a web view:
/// the block grammar for document structure, the inline grammar for emphasis,
/// links and code spans inside each `inline` node. Fenced code blocks are run
/// through the app's own `SyntaxHighlighter`, so a ```swift fence in a README
/// gets exactly the colours the editor would give it.
enum MarkdownRenderer {

    // Parsers are expensive to build and cheap to keep; one of each is reused
    // for every render. They hold no document state between calls.
    private static var blockParser: OpaquePointer?
    private static var inlineParser: OpaquePointer?

    private static func parser(_ existing: inout OpaquePointer?,
                               _ language: () -> OpaquePointer?) -> OpaquePointer? {
        if let existing { return existing }
        guard let p = ts_parser_new(), let lang = language() else { return nil }
        ts_parser_set_language(p, lang)
        existing = p
        return p
    }

    /// Whether either parser is currently materialised (tests / diagnostics).
    static var parsersLoaded: Bool { blockParser != nil || inlineParser != nil }

    /// Drop the parsers when no preview is open — mirrors grammar eviction in
    /// `DocumentStore.release`.
    static func releaseParsers() {
        if let p = blockParser { ts_parser_delete(p) }
        if let p = inlineParser { ts_parser_delete(p) }
        blockParser = nil
        inlineParser = nil
        highlighters.removeAll()
    }

    // MARK: - Fonts

    private static func bodyFont(_ size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    private static func monoFont(_ size: CGFloat = 12) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Apply a trait to whatever font a range already has, so **bold** inside a
    /// heading stays heading-sized and `*em*` inside **bold** keeps the bold.
    private static func addTrait(_ trait: NSFontDescriptor.SymbolicTraits,
                                 to string: NSMutableAttributedString,
                                 range: NSRange) {
        string.enumerateAttribute(.font, in: range) { value, sub, _ in
            let font = (value as? NSFont) ?? bodyFont()
            var traits = font.fontDescriptor.symbolicTraits
            traits.insert(trait)
            let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
            if let derived = NSFont(descriptor: descriptor, size: font.pointSize) {
                string.addAttribute(.font, value: derived, range: sub)
            }
        }
    }

    private static func paragraphStyle(headIndent: CGFloat = 0,
                                       firstLineIndent: CGFloat = 0,
                                       spacingBefore: CGFloat = 0,
                                       spacingAfter: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.25
        style.headIndent = headIndent
        style.firstLineHeadIndent = firstLineIndent
        style.paragraphSpacingBefore = spacingBefore
        style.paragraphSpacing = spacingAfter
        return style
    }

    // MARK: - Entry point

    static func render(_ source: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let bytes = Array(source.utf8)
        guard !bytes.isEmpty, let parser = parser(&blockParser, { tree_sitter_markdown() }) else {
            return out
        }
        guard let tree = bytes.withUnsafeBufferPointer({ buffer -> OpaquePointer? in
            buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: bytes.count) {
                ts_parser_parse_string(parser, nil, $0, UInt32(bytes.count))
            }
        }) else { return out }
        defer { ts_tree_delete(tree) }

        let ctx = Context(bytes: bytes)
        renderChildren(of: ts_tree_root_node(tree), into: out, ctx: ctx, listDepth: 0)

        // Trailing blank line so the last paragraph isn't flush against the edge.
        if out.length > 0 {
            out.append(NSAttributedString(string: "\n",
                                          attributes: [.font: bodyFont(),
                                                       .foregroundColor: Theme.foreground]))
        }
        return out
    }

    /// Byte-slicing helper. tree-sitter reports UTF-8 byte offsets, so the
    /// source is kept as bytes and decoded per node — indexing a Swift String
    /// by byte offset is not valid.
    private final class Context {
        let bytes: [UInt8]
        init(bytes: [UInt8]) { self.bytes = bytes }

        func text(_ node: TSNode) -> String {
            let lo = Int(ts_node_start_byte(node)), hi = Int(ts_node_end_byte(node))
            guard lo < hi, hi <= bytes.count else { return "" }
            return String(decoding: bytes[lo..<hi], as: UTF8.self)
        }
    }

    /// Text of an `inline` node with continuation markers removed.
    ///
    /// The block grammar keeps the `> ` that starts each wrapped line of a
    /// block quote *inside* the inline node (as a `block_continuation` child),
    /// so slicing the node's byte range verbatim would print it as content.
    private static func inlineText(_ node: TSNode, ctx: Context) -> String {
        var skips: [(Int, Int)] = []
        func collect(_ n: TSNode) {
            if type(n) == "block_continuation" {
                skips.append((Int(ts_node_start_byte(n)), Int(ts_node_end_byte(n))))
                return
            }
            for child in children(n) { collect(child) }
        }
        collect(node)
        guard !skips.isEmpty else { return ctx.text(node) }

        let lo = Int(ts_node_start_byte(node)), hi = Int(ts_node_end_byte(node))
        guard lo < hi, hi <= ctx.bytes.count else { return "" }
        var kept: [UInt8] = []
        var cursor = lo
        for (start, end) in skips.sorted(by: { $0.0 < $1.0 }) {
            if start > cursor { kept.append(contentsOf: ctx.bytes[cursor..<min(start, hi)]) }
            cursor = max(cursor, end)
        }
        if cursor < hi { kept.append(contentsOf: ctx.bytes[cursor..<hi]) }
        return String(decoding: kept, as: UTF8.self)
    }

    private static func children(_ node: TSNode) -> [TSNode] {
        (0..<ts_node_child_count(node)).map { ts_node_child(node, $0) }
    }

    private static func type(_ node: TSNode) -> String {
        String(cString: ts_node_type(node))
    }

    private static func firstChild(_ node: TSNode, ofType wanted: String) -> TSNode? {
        children(node).first { type($0) == wanted }
    }

    // MARK: - Blocks

    private static func renderChildren(of node: TSNode, into out: NSMutableAttributedString,
                                       ctx: Context, listDepth: Int) {
        for child in children(node) {
            renderBlock(child, into: out, ctx: ctx, listDepth: listDepth)
        }
    }

    private static func renderBlock(_ node: TSNode, into out: NSMutableAttributedString,
                                    ctx: Context, listDepth: Int) {
        switch type(node) {
        case "section", "document":
            renderChildren(of: node, into: out, ctx: ctx, listDepth: listDepth)

        case "atx_heading", "setext_heading":
            renderHeading(node, into: out, ctx: ctx)

        case "paragraph":
            let body = NSMutableAttributedString()
            for inline in children(node) where type(inline) == "inline" {
                appendInline(inlineText(inline, ctx: ctx), to: body, base: baseAttributes())
            }
            guard body.length > 0 else { return }
            body.addAttribute(.paragraphStyle,
                              value: paragraphStyle(headIndent: CGFloat(listDepth) * 18,
                                                    firstLineIndent: CGFloat(listDepth) * 18,
                                                    spacingAfter: listDepth > 0 ? 2 : 10),
                              range: NSRange(location: 0, length: body.length))
            out.append(body)
            out.append(newline())

        case "fenced_code_block", "indented_code_block":
            renderCodeBlock(node, into: out, ctx: ctx, listDepth: listDepth)

        case "list":
            renderList(node, into: out, ctx: ctx, listDepth: listDepth)

        case "block_quote":
            renderBlockQuote(node, into: out, ctx: ctx, listDepth: listDepth)

        case "thematic_break":
            renderThematicBreak(into: out)

        case "pipe_table":
            renderTable(node, into: out, ctx: ctx)

        case "html_block":
            // Raw HTML can't be rendered natively; show it as dimmed source
            // rather than silently dropping content.
            let text = ctx.text(node).trimmingCharacters(in: .newlines)
            guard !text.isEmpty else { return }
            out.append(NSAttributedString(string: text + "\n",
                                          attributes: [.font: monoFont(11),
                                                       .foregroundColor: Theme.dimText,
                                                       .paragraphStyle: paragraphStyle(spacingAfter: 10)]))

        default:
            // Unknown container (e.g. list_item handled by its parent): recurse
            // so nested blocks still render.
            if ts_node_named_child_count(node) > 0 {
                renderChildren(of: node, into: out, ctx: ctx, listDepth: listDepth)
            }
        }
    }

    private static func baseAttributes() -> [NSAttributedString.Key: Any] {
        [.font: bodyFont(), .foregroundColor: Theme.foreground]
    }

    private static func newline() -> NSAttributedString {
        NSAttributedString(string: "\n", attributes: baseAttributes())
    }

    // MARK: Headings

    private static func renderHeading(_ node: TSNode, into out: NSMutableAttributedString,
                                      ctx: Context) {
        var level = 1
        for child in children(node) {
            let t = type(child)
            if t.hasPrefix("atx_h"), let digit = t.dropFirst(5).first,
               let n = Int(String(digit)) { level = n }
            if t == "setext_h1_underline" { level = 1 }
            if t == "setext_h2_underline" { level = 2 }
        }
        let sizes: [CGFloat] = [24, 19, 16, 14, 13, 12]
        let size = sizes[min(level, sizes.count) - 1]

        let body = NSMutableAttributedString()
        for inline in children(node) where type(inline) == "inline" {
            appendInline(inlineText(inline, ctx: ctx), to: body,
                         base: [.font: bodyFont(size, weight: .semibold),
                                .foregroundColor: Theme.foreground])
        }
        guard body.length > 0 else { return }
        body.addAttribute(.paragraphStyle,
                          value: paragraphStyle(spacingBefore: out.length == 0 ? 0 : 16,
                                                spacingAfter: 6),
                          range: NSRange(location: 0, length: body.length))
        out.append(body)
        out.append(newline())
    }

    // MARK: Code blocks

    private static func renderCodeBlock(_ node: TSNode, into out: NSMutableAttributedString,
                                        ctx: Context, listDepth: Int) {
        var code = ""
        var languageName: String?

        if type(node) == "fenced_code_block" {
            if let info = firstChild(node, ofType: "info_string") {
                languageName = ctx.text(info).trimmingCharacters(in: .whitespaces)
                    .split(separator: " ").first.map(String.init)
            }
            for child in children(node) where type(child) == "code_fence_content" {
                code += ctx.text(child)
            }
        } else {
            // Indented blocks carry their four leading spaces in the source.
            code = ctx.text(node)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.hasPrefix("    ") ? String($0.dropFirst(4)) : String($0) }
                .joined(separator: "\n")
        }

        code = trimTrailingNewlines(code)
        if type(node) == "fenced_code_block" { code = dropUnterminatedFence(code) }
        guard !code.isEmpty else { return }

        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.2
        style.headIndent = CGFloat(listDepth) * 18 + 10
        style.firstLineHeadIndent = CGFloat(listDepth) * 18 + 10
        style.tailIndent = -10
        style.paragraphSpacingBefore = 6
        style.paragraphSpacing = 12

        let block = NSMutableAttributedString(
            string: code,
            attributes: [.font: monoFont(),
                         .foregroundColor: Theme.foreground,
                         .codeBlock: true,
                         .paragraphStyle: style])

        // Reuse the editor's highlighter so fences match the editor exactly.
        if let name = languageName?.lowercased(),
           let spec = SyntaxHighlighter.spec(forExtension: fenceExtension(name)) {
            applyHighlight(spec: spec, to: block, code: code)
        }

        out.append(block)
        out.append(NSAttributedString(string: "\n",
                                      attributes: [.font: monoFont(),
                                                   .paragraphStyle: style]))
    }

    /// Fence info strings are language names ("swift", "bash"); the highlighter
    /// keys off file extensions. They coincide for most, so map the exceptions.
    private static func fenceExtension(_ name: String) -> String {
        switch name {
        case "javascript", "js", "typescript", "ts", "jsx", "tsx": return "ts"
        case "shell", "sh", "bash", "zsh", "console", "terminal": return "sh"
        case "yml", "yaml": return "yaml"
        case "objective-c", "objc": return "c"
        case "markdown": return "md"
        case "python", "py", "python3": return "py"
        case "rust": return "rs"
        case "golang": return "go"
        case "docker", "dockerfile": return "dockerfile"
        case "postgres", "postgresql", "sqlite", "mysql": return "sql"
        case "svg": return "xml"
        default: return name
        }
    }

    /// Highlighters compile their queries in `init`, which is far too costly to
    /// repeat per code block on every keystroke — cache one per language.
    private static var highlighters: [String: SyntaxHighlighter] = [:]

    private static func applyHighlight(spec: SyntaxHighlighter.LanguageSpec,
                                       to block: NSMutableAttributedString, code: String) {
        let highlighter: SyntaxHighlighter
        if let hit = highlighters[spec.name] {
            highlighter = hit
        } else {
            guard let definition = SyntaxHighlighter.definition(for: spec),
                  let made = SyntaxHighlighter(definition: definition), made.isUsable else { return }
            highlighters[spec.name] = made
            highlighter = made
        }

        // `highlight` paints into an NSTextStorage, so colour a throwaway copy
        // and lift just the foreground colours back onto the block — the block
        // keeps its own font, background and paragraph style.
        let scratch = NSTextStorage(attributedString: block)
        let full = NSRange(location: 0, length: scratch.length)
        highlighter.highlight(text: code, storage: scratch, fullRange: full)
        scratch.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            guard let color = value as? NSColor, NSMaxRange(range) <= block.length else { return }
            block.addAttribute(.foregroundColor, value: color, range: range)
        }
    }

    /// A closing ``` that isn't followed by a newline (i.e. at end of a file
    /// with no trailing newline) is parsed as content rather than as a fence
    /// delimiter, so it would otherwise be displayed as code.
    private static func dropUnterminatedFence(_ code: String) -> String {
        var lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        guard let last = lines.last else { return code }
        let trimmed = last.trimmingCharacters(in: .whitespaces)
        let isFence = trimmed.count >= 3
            && (trimmed.allSatisfy { $0 == "`" } || trimmed.allSatisfy { $0 == "~" })
        guard isFence else { return code }
        lines.removeLast()
        return trimTrailingNewlines(lines.joined(separator: "\n"))
    }

    private static func trimTrailingNewlines(_ s: String) -> String {
        var out = s
        while out.hasSuffix("\n") || out.hasSuffix("\r") { out.removeLast() }
        return out
    }

    // MARK: Lists

    private static func renderList(_ node: TSNode, into out: NSMutableAttributedString,
                                   ctx: Context, listDepth: Int) {
        var ordinal = 1
        for item in children(node) where type(item) == "list_item" {
            renderListItem(item, into: out, ctx: ctx, listDepth: listDepth, ordinal: &ordinal)
        }
        if listDepth == 0, out.length > 0 {
            out.append(NSAttributedString(string: "\n",
                                          attributes: [.font: bodyFont(4)]))
        }
    }

    private static func renderListItem(_ item: TSNode, into out: NSMutableAttributedString,
                                       ctx: Context, listDepth: Int, ordinal: inout Int) {
        // The marker tells us bullet vs number, and whether it's a task item.
        var marker = "•"
        var isOrdered = false
        for child in children(item) {
            let t = type(child)
            if t.hasPrefix("list_marker_dot") || t.hasPrefix("list_marker_parenthesis") {
                isOrdered = true
            }
            if t == "task_list_marker_checked" { marker = "☑" }
            if t == "task_list_marker_unchecked" { marker = "☐" }
        }
        if isOrdered {
            marker = "\(ordinal)."
            ordinal += 1
        }

        let indent = CGFloat(listDepth) * 18
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.25
        style.firstLineHeadIndent = indent + 4
        style.headIndent = indent + 22
        style.paragraphSpacing = 2
        style.tabStops = [NSTextTab(textAlignment: .left, location: indent + 22)]

        // The item's own text is its first paragraph; deeper blocks recurse.
        var wroteMarker = false
        for child in children(item) {
            switch type(child) {
            case "paragraph":
                let body = NSMutableAttributedString()
                for inline in children(child) where type(inline) == "inline" {
                    appendInline(inlineText(inline, ctx: ctx), to: body, base: baseAttributes())
                }
                guard body.length > 0 else { continue }
                if !wroteMarker {
                    body.insert(NSAttributedString(
                        string: "\(marker)\t",
                        attributes: [.font: bodyFont(),
                                     .foregroundColor: isOrdered ? Theme.foreground : Theme.dimText]),
                                at: 0)
                    wroteMarker = true
                }
                body.addAttribute(.paragraphStyle, value: style,
                                  range: NSRange(location: 0, length: body.length))
                out.append(body)
                out.append(newline())

            case "list":
                renderList(child, into: out, ctx: ctx, listDepth: listDepth + 1)

            case "fenced_code_block", "indented_code_block", "block_quote":
                renderBlock(child, into: out, ctx: ctx, listDepth: listDepth + 1)

            default:
                continue
            }
        }
    }

    // MARK: Block quotes

    private static func renderBlockQuote(_ node: TSNode, into out: NSMutableAttributedString,
                                         ctx: Context, listDepth: Int) {
        let start = out.length
        for child in children(node) {
            let t = type(child)
            guard t != "block_quote_marker", t != "block_continuation" else { continue }
            renderBlock(child, into: out, ctx: ctx, listDepth: listDepth)
        }
        guard out.length > start else { return }

        // Dim + indent the whole quote. The left bar is drawn by the preview
        // view, which looks for this custom attribute.
        let range = NSRange(location: start, length: out.length - start)
        out.addAttribute(.foregroundColor, value: Theme.dimText, range: range)
        out.addAttribute(.quoteLevel, value: 1, range: range)
        out.enumerateAttribute(.paragraphStyle, in: range) { value, sub, _ in
            let base = (value as? NSParagraphStyle) ?? paragraphStyle()
            guard let style = base.mutableCopy() as? NSMutableParagraphStyle else { return }
            style.headIndent += 18
            style.firstLineHeadIndent += 18
            out.addAttribute(.paragraphStyle, value: style, range: sub)
        }
    }

    // MARK: Rules and tables

    private static func renderThematicBreak(into out: NSMutableAttributedString) {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 8
        style.paragraphSpacing = 14
        // A styled newline the preview view draws a rule across.
        out.append(NSAttributedString(string: "\n",
                                      attributes: [.font: bodyFont(6),
                                                   .paragraphStyle: style,
                                                   .thematicBreak: true]))
    }

    /// Tables render as aligned monospaced text — real `NSTextTable` layout is
    /// far heavier and TextKit 1 handles it poorly.
    private static func renderTable(_ node: TSNode, into out: NSMutableAttributedString,
                                    ctx: Context) {
        var rows: [[String]] = []
        var headerCount = 0
        for child in children(node) {
            let t = type(child)
            guard t == "pipe_table_header" || t == "pipe_table_row" else { continue }
            let cells = children(child)
                .filter { type($0) == "pipe_table_cell" }
                .map { ctx.text($0).trimmingCharacters(in: .whitespaces) }
            guard !cells.isEmpty else { continue }
            if t == "pipe_table_header" { headerCount = rows.count + 1 }
            rows.append(cells)
        }
        guard !rows.isEmpty else { return }

        let columns = rows.map(\.count).max() ?? 0
        var widths = [Int](repeating: 0, count: columns)
        for row in rows {
            for (i, cell) in row.enumerated() { widths[i] = max(widths[i], cell.count) }
        }

        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.2
        style.firstLineHeadIndent = 10
        style.headIndent = 10
        style.paragraphSpacingBefore = 6
        style.paragraphSpacing = 12

        let table = NSMutableAttributedString()
        for (index, row) in rows.enumerated() {
            let line = (0..<columns).map { i -> String in
                let cell = i < row.count ? row[i] : ""
                return cell.padding(toLength: widths[i], withPad: " ", startingAt: 0)
            }.joined(separator: "  │  ")
            let isHeader = index < headerCount
            table.append(NSAttributedString(
                string: line + "\n",
                attributes: [.font: monoFont(11.5),
                             .foregroundColor: Theme.foreground,
                             .paragraphStyle: style]))
            if isHeader {
                let divider = (0..<columns).map {
                    String(repeating: "─", count: widths[$0])
                }.joined(separator: "──┼──")
                table.append(NSAttributedString(
                    string: divider + "\n",
                    attributes: [.font: monoFont(11.5),
                                 .foregroundColor: Theme.border,
                                 .paragraphStyle: style]))
            }
        }
        out.append(table)
    }

    // MARK: - Inline

    /// Parse one `inline` node's text with the inline grammar and append it.
    private static func appendInline(_ text: String, to out: NSMutableAttributedString,
                                     base: [NSAttributedString.Key: Any]) {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return }
        guard let parser = parser(&inlineParser, { tree_sitter_markdown_inline() }),
              let tree = bytes.withUnsafeBufferPointer({ buffer -> OpaquePointer? in
                  buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: bytes.count) {
                      ts_parser_parse_string(parser, nil, $0, UInt32(bytes.count))
                  }
              }) else {
            out.append(NSAttributedString(string: text, attributes: base))
            return
        }
        defer { ts_tree_delete(tree) }

        let piece = NSMutableAttributedString(string: text, attributes: base)
        let ctx = Context(bytes: bytes)
        // Offsets map 1:1 only if the string is ASCII; otherwise byte offsets
        // must be converted to UTF-16 positions before touching the string.
        let map = ByteMap(bytes: bytes)
        styleInline(ts_tree_root_node(tree), in: piece, ctx: ctx, map: map)

        // Markdown treats a single newline as a space (soft break).
        let flattened = piece.mutableCopy() as! NSMutableAttributedString
        replaceSoftBreaks(in: flattened)
        out.append(flattened)
    }

    /// UTF-8 byte offset → UTF-16 offset, for non-ASCII inline text.
    private struct ByteMap {
        private let table: [Int]?
        init(bytes: [UInt8]) {
            // Fast path: pure ASCII means byte offset == UTF-16 offset.
            if !bytes.contains(where: { $0 >= 0x80 }) {
                table = nil
                return
            }
            var built = [Int](repeating: 0, count: bytes.count + 1)
            var utf16 = 0
            var i = 0
            while i < bytes.count {
                built[i] = utf16
                let b = bytes[i]
                let width = b < 0x80 ? 1 : (b < 0xE0 ? 2 : (b < 0xF0 ? 3 : 4))
                utf16 += width == 4 ? 2 : 1   // astral scalars are surrogate pairs
                i += width
                for pad in (i - width + 1)..<min(i, bytes.count) { built[pad] = utf16 }
            }
            built[bytes.count] = utf16
            table = built
        }
        func offset(_ byte: Int) -> Int {
            guard let table else { return byte }
            return byte < table.count ? table[byte] : (table.last ?? byte)
        }
    }

    private static func styleInline(_ node: TSNode, in piece: NSMutableAttributedString,
                                    ctx: Context, map: ByteMap) {
        for child in children(node) {
            let t = type(child)
            let lo = map.offset(Int(ts_node_start_byte(child)))
            let hi = map.offset(Int(ts_node_end_byte(child)))
            guard lo < hi, hi <= piece.length else {
                styleInline(child, in: piece, ctx: ctx, map: map)
                continue
            }
            let range = NSRange(location: lo, length: hi - lo)

            switch t {
            case "strong_emphasis":
                addTrait(.bold, to: piece, range: range)
                styleInline(child, in: piece, ctx: ctx, map: map)
                hideDelimiters(of: child, in: piece, map: map, types: ["emphasis_delimiter"])

            case "emphasis":
                addTrait(.italic, to: piece, range: range)
                styleInline(child, in: piece, ctx: ctx, map: map)
                hideDelimiters(of: child, in: piece, map: map, types: ["emphasis_delimiter"])

            case "strikethrough":
                piece.addAttribute(.strikethroughStyle,
                                   value: NSUnderlineStyle.single.rawValue, range: range)
                styleInline(child, in: piece, ctx: ctx, map: map)
                hideDelimiters(of: child, in: piece, map: map,
                               types: ["emphasis_delimiter", "strikethrough_delimiter"])

            case "code_span":
                piece.addAttributes([.font: monoFont(),
                                     .backgroundColor: Theme.lineHighlight,
                                     .foregroundColor: Theme.red], range: range)
                hideDelimiters(of: child, in: piece, map: map, types: ["code_span_delimiter"])

            case "inline_link", "image":
                styleLink(child, in: piece, ctx: ctx, map: map, isImage: t == "image")

            case "uri_autolink":
                piece.addAttributes([.foregroundColor: Theme.blue,
                                     .underlineStyle: NSUnderlineStyle.single.rawValue],
                                    range: range)

            default:
                styleInline(child, in: piece, ctx: ctx, map: map)
            }
        }
    }

    private static func styleLink(_ node: TSNode, in piece: NSMutableAttributedString,
                                  ctx: Context, map: ByteMap, isImage: Bool) {
        var destination: String?
        var textRange: NSRange?
        for child in children(node) {
            let t = type(child)
            let lo = map.offset(Int(ts_node_start_byte(child)))
            let hi = map.offset(Int(ts_node_end_byte(child)))
            guard lo <= hi, hi <= piece.length else { continue }
            if t == "link_destination" { destination = ctx.text(child) }
            if t == "link_text" || t == "image_description" {
                // Trim the surrounding brackets, which are part of the node.
                textRange = NSRange(location: lo, length: hi - lo)
            }
        }

        // Hide the markup, keeping only the visible label.
        let whole = NSRange(location: map.offset(Int(ts_node_start_byte(node))),
                            length: map.offset(Int(ts_node_end_byte(node)))
                                  - map.offset(Int(ts_node_start_byte(node))))
        guard whole.location + whole.length <= piece.length else { return }

        if let textRange, textRange.length > 0 {
            piece.addAttributes([.foregroundColor: isImage ? Theme.dimText : Theme.blue,
                                 .underlineStyle: isImage ? 0 : NSUnderlineStyle.single.rawValue],
                                range: textRange)
            if let destination, let url = URL(string: destination), !isImage {
                piece.addAttribute(.link, value: url, range: textRange)
            }
            // Collapse everything outside the label: the leading "[" / "![",
            // and the trailing "](url)".
            let leading = NSRange(location: whole.location,
                                  length: textRange.location - whole.location)
            let trailing = NSRange(location: textRange.location + textRange.length,
                                   length: whole.location + whole.length
                                         - (textRange.location + textRange.length))
            for r in [leading, trailing] where r.length > 0 {
                piece.addAttribute(.markdownHidden, value: true, range: r)
            }
        }
    }

    /// Mark `*`, `_`, `` ` `` and friends for removal — they're structure, not text.
    private static func hideDelimiters(of node: TSNode, in piece: NSMutableAttributedString,
                                       map: ByteMap, types: [String]) {
        for child in children(node) where types.contains(type(child)) {
            let lo = map.offset(Int(ts_node_start_byte(child)))
            let hi = map.offset(Int(ts_node_end_byte(child)))
            guard lo < hi, hi <= piece.length else { continue }
            piece.addAttribute(.markdownHidden, value: true,
                               range: NSRange(location: lo, length: hi - lo))
        }
    }

    /// Delete every range marked hidden, and turn soft line breaks into spaces.
    private static func replaceSoftBreaks(in piece: NSMutableAttributedString) {
        var doomed: [NSRange] = []
        piece.enumerateAttribute(.markdownHidden,
                                 in: NSRange(location: 0, length: piece.length)) { value, range, _ in
            if value != nil { doomed.append(range) }
        }
        // Back to front so earlier ranges stay valid.
        for range in doomed.sorted(by: { $0.location > $1.location }) {
            piece.deleteCharacters(in: range)
        }
        let text = piece.string as NSString
        var search = NSRange(location: 0, length: text.length)
        while search.length > 0 {
            let hit = text.range(of: "\n", options: [], range: search)
            guard hit.location != NSNotFound else { break }
            piece.replaceCharacters(in: hit, with: " ")
            let next = hit.location + 1
            search = NSRange(location: next, length: max(0, piece.length - next))
        }
    }
}

extension NSAttributedString.Key {
    /// Marks markup that should be deleted before display (`*`, `` ` ``, `](url)`).
    static let markdownHidden = NSAttributedString.Key("puzzleMarkdownHidden")
    /// Paragraphs inside a block quote — the preview view draws the left bar.
    static let quoteLevel = NSAttributedString.Key("puzzleQuoteLevel")
    /// A horizontal rule; the preview view strikes a line across it.
    static let thematicBreak = NSAttributedString.Key("puzzleThematicBreak")
    /// A fenced/indented code block. Drawn as a full-width band rather than a
    /// `.backgroundColor` attribute, which only paints behind glyphs and so
    /// leaves every line a different width.
    static let codeBlock = NSAttributedString.Key("puzzleCodeBlock")
}

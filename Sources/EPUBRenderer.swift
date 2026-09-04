import AppKit
import ImageIO

/// Turns one chapter's XHTML into an attributed string the editor can display.
///
/// This is deliberately not a browser. A book's CSS is ignored and the markup
/// is read for its *structure* — headings, paragraphs, lists, quotes, code,
/// images, links — which is what carries a novel or a manual. The alternative,
/// a `WKWebView` per chapter, renders a stylesheet faithfully and costs a web
/// content process of a few hundred megabytes, which is the entire memory
/// budget of this app several times over.
///
/// The markup is parsed with the vendored tree-sitter HTML grammar the editor
/// already links and compiles. That buys error tolerance an XML parser does not
/// have: plenty of shipping EPUBs are not the well-formed XHTML the spec asks
/// for, and tree-sitter recovers from a stray unclosed tag instead of refusing
/// the file.
enum EPUBRenderer {
    struct Rendered {
        let text: NSAttributedString
        /// Element id -> offset, so a link carrying a `#fragment` can scroll to
        /// the exact place inside the chapter rather than to its top.
        let anchors: [String: Int]
    }

    /// Links are rewritten to this scheme so the reader can tell a jump inside
    /// the book from a link out to the web.
    static let linkScheme = "puzzle-epub"

    // MARK: - Parsing

    /// A node of the HTML tree. The same shape as the Markdown tree's node;
    /// kept separate because the two grammars share nothing else.
    private struct Node {
        let type: String
        let range: NSRange
        let children: [Node]
    }

    private static let parserLock = NSLock()
    private static var htmlParser: OpaquePointer?

    private static func parse(_ text: String) -> [Node] {
        let byteCount = text.utf8.count
        guard byteCount > 0 else { return [] }
        parserLock.lock()
        defer { parserLock.unlock() }
        if htmlParser == nil {
            guard let parser = ts_parser_new() else { return [] }
            guard ts_parser_set_language(parser, tree_sitter_html()) else {
                ts_parser_delete(parser)
                return []
            }
            htmlParser = parser
        }
        guard let parser = htmlParser else { return [] }

        var result: [Node] = []
        text.withCString { cstr in
            guard let tree = ts_parser_parse_string(parser, nil, cstr,
                                                    UInt32(byteCount)) else { return }
            defer { ts_tree_delete(tree) }
            let mapper = ByteMapper(text: text, utf8Count: byteCount)
            result = children(of: ts_tree_root_node(tree), mapper: mapper)
        }
        return result
    }

    private static func children(of node: TSNode, mapper: ByteMapper) -> [Node] {
        var built: [Node] = []
        let count = ts_node_child_count(node)
        guard count > 0 else { return built }
        for index in 0..<count {
            let child = ts_node_child(node, index)
            guard ts_node_is_named(child) else { continue }
            guard let start = mapper.utf16(forByte: Int(ts_node_start_byte(child))),
                  let end = mapper.utf16(forByte: Int(ts_node_end_byte(child))),
                  end >= start else { continue }
            built.append(Node(type: String(cString: ts_node_type(child)),
                              range: NSRange(location: start, length: end - start),
                              children: children(of: child, mapper: mapper)))
        }
        return built
    }

    // MARK: - Styling

    /// Body size drives everything else, and follows the UI font scale so the
    /// reader grows with the rest of the app rather than being pinned in points.
    static func bodyFont() -> NSFont { Theme.uiFont(13) }

    /// A book is prose: a full-window measure is hard to track from the end of
    /// one line back to the start of the next.
    static func readingWidth() -> CGFloat { bodyFont().pointSize * 34 }

    private struct Inline {
        var bold = false
        var italic = false
        var monospace = false
        var color: NSColor = Theme.foreground
        var link: URL?
        var sizeScale: CGFloat = 1
        var preformatted = false
    }

    private struct Block {
        var font: NSFont
        /// Gap above this block. Spacing is only ever expressed as "before":
        /// a trailing space on one block and a leading space on the next both
        /// apply, and the sum is never what either of them asked for.
        var spacing: CGFloat
        var indent: CGFloat = 0
        var alignment: NSTextAlignment = .natural
    }

    // MARK: - Rendering

    static func render(xhtml: Data, chapterPath: String, book: EPUBBook) -> Rendered {
        guard let source = decode(xhtml) else {
            return Rendered(text: NSAttributedString(string: ""), anchors: [:])
        }
        var builder = Builder(source: source as NSString,
                              directory: EPUBBook.directory(of: chapterPath),
                              book: book)
        builder.walk(parse(source), inline: Inline(), list: nil)
        builder.finish()
        return Rendered(text: builder.out, anchors: builder.anchors)
    }

    /// XHTML declares UTF-8 in practice; Latin-1 is the permissive fallback the
    /// editor already uses for text files it cannot decode as UTF-8.
    private static func decode(_ data: Data) -> String? {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private struct Builder {
        let source: NSString
        let directory: String
        let book: EPUBBook
        let out = NSMutableAttributedString()
        var anchors: [String: Int] = [:]

        /// Blocks are separated when the *next* one starts, not when the last
        /// one ends: that way a run of empty or skipped elements cannot leave a
        /// stack of blank lines behind.
        private var needsSeparator = false
        private var blockStart = 0
        private var currentBlock: Block?
        /// Whether the last thing emitted ended in whitespace. Source markup is
        /// indented for whoever reads the markup, so a text node routinely
        /// begins with a newline and two spaces that must not reach the page.
        private var endsWithWhitespace = true
        /// Indentation contributed by the elements this block sits inside. A
        /// quotation holds paragraphs, and it is the paragraphs that are drawn:
        /// without carrying the indent down, a <blockquote><p> is indented by
        /// nothing at all.
        private var inheritedIndent: CGFloat = 0

        init(source: NSString, directory: String, book: EPUBBook) {
            self.source = source
            self.directory = directory
            self.book = book
        }

        // MARK: Block bookkeeping

        private mutating func openBlock(_ block: Block) {
            var block = block
            block.indent += inheritedIndent
            closeBlock()
            needsSeparator = true
            currentBlock = block
            blockStart = out.length
            endsWithWhitespace = true
        }

        private mutating func closeBlock() {
            guard let block = currentBlock else { return }
            currentBlock = nil
            guard out.length > blockStart else { return }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineHeightMultiple = 1.45
            paragraph.paragraphSpacingBefore = block.spacing
            paragraph.firstLineHeadIndent = block.indent
            paragraph.headIndent = block.indent
            paragraph.alignment = block.alignment
            let full = NSRange(location: blockStart, length: out.length - blockStart)
            out.addAttribute(.paragraphStyle, value: paragraph, range: full)

            // The gap belongs above the block, not above every line inside it.
            // A <pre> or a run of <br> makes several paragraphs out of one
            // block, and each of them would otherwise take the block's spacing.
            let newline = (out.string as NSString).range(of: "\n", range: full)
            guard newline.location != NSNotFound else { return }
            let continuation = paragraph.mutableCopy() as! NSMutableParagraphStyle
            continuation.paragraphSpacingBefore = 0
            let rest = newline.location + newline.length
            guard rest < full.location + full.length else { return }
            out.addAttribute(.paragraphStyle, value: continuation,
                             range: NSRange(location: rest,
                                            length: full.location + full.length - rest))
        }

        mutating func finish() { closeBlock() }

        /// End the previous paragraph, once it is known that the block being
        /// opened actually has something in it.
        private mutating func separate() {
            guard needsSeparator else { return }
            needsSeparator = false
            guard out.length > 0 else { return }
            out.append(NSAttributedString(string: "\n",
                                          attributes: [.font: EPUBRenderer.bodyFont()]))
            blockStart = out.length
        }

        // MARK: Text

        private mutating func append(_ string: String, inline: Inline) {
            guard !string.isEmpty else { return }
            // Text can appear outside any block — books put bare text straight
            // in <body>. Give it a paragraph rather than dropping its styling.
            if currentBlock == nil { openBlock(EPUBRenderer.defaultBlock()) }
            separate()
            let block = currentBlock ?? EPUBRenderer.defaultBlock()
            var font = inline.monospace ? Theme.editorFont() : block.font
            if inline.sizeScale != 1 {
                font = NSFont(descriptor: font.fontDescriptor,
                              size: font.pointSize * inline.sizeScale) ?? font
            }
            if inline.bold || inline.italic {
                var traits: NSFontDescriptor.SymbolicTraits = []
                if inline.bold { traits.insert(.bold) }
                if inline.italic { traits.insert(.italic) }
                let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
                font = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: inline.link == nil ? inline.color : Theme.blue,
            ]
            if let link = inline.link {
                attributes[.link] = link
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            out.append(NSAttributedString(string: string, attributes: attributes))
            endsWithWhitespace = string.last?.isWhitespace ?? endsWithWhitespace
        }

        private mutating func appendAttachment(_ attachment: NSTextAttachment) {
            separate()
            out.append(NSAttributedString(attachment: attachment))
            endsWithWhitespace = false
        }

        // MARK: Walking

        mutating func walk(_ nodes: [Node], inline: Inline, list: ListState?) {
            var list = list
            var previousEnd: Int?
            for node in nodes {
                // The HTML grammar's `text` token stops at the whitespace on
                // either side of it, and that whitespace is an anonymous node
                // the tree walker drops. Without putting it back, every word
                // that touches a tag or an entity fuses to its neighbour:
                // "a <em>ZIP</em> archive" comes out as "aZIParchive".
                // Only inside a block: the whitespace *between* two blocks is
                // the markup's own indentation, and emitting it would open a
                // paragraph holding nothing but a space.
                if let start = previousEnd, node.range.location > start,
                   currentBlock != nil {
                    let gap = source.substring(with: NSRange(
                        location: start, length: node.range.location - start))
                    if gap.allSatisfy({ $0.isWhitespace }) {
                        if inline.preformatted {
                            append(gap, inline: inline)
                        } else if !endsWithWhitespace {
                            append(" ", inline: inline)
                        }
                    }
                }
                previousEnd = node.range.location + node.range.length
                switch node.type {
                case "text", "entity", "raw_text":
                    let raw = source.substring(with: node.range)
                    let decoded = EPUBRenderer.decodeEntities(raw)
                    let text = inline.preformatted
                        ? decoded
                        : EPUBRenderer.collapseWhitespace(decoded,
                                                          trimLeading: endsWithWhitespace)
                    append(text, inline: inline)
                case "element", "script_element", "style_element":
                    element(node, inline: inline, list: &list)
                default:
                    walk(node.children, inline: inline, list: list)
                }
            }
        }

        private mutating func element(_ node: Node, inline: Inline, list: inout ListState?) {
            guard let tag = tagName(of: node) else {
                walk(node.children, inline: inline, list: list)
                return
            }
            let attributes = attributeMap(of: node)
            // Anchors are recorded for every element, not just <a>: a contents
            // link commonly targets the section or heading it names.
            if let id = attributes["id"] ?? attributes["name"], anchors[id] == nil {
                anchors[id] = out.length
            }
            let body = node.children.filter { $0.type != "start_tag" && $0.type != "end_tag"
                && $0.type != "self_closing_tag" }

            switch tag {
            case "script", "style", "head", "title", "meta", "link", "svg":
                return

            case "h1", "h2", "h3", "h4", "h5", "h6":
                let level = Int(tag.dropFirst()) ?? 1
                openBlock(EPUBRenderer.headingBlock(level: level))
                var inner = inline
                inner.bold = true
                walk(body, inline: inner, list: nil)
                closeBlock()

            case "p", "div", "section", "article", "header", "footer", "main",
                 "figcaption", "dd", "dt":
                openBlock(EPUBRenderer.defaultBlock())
                walk(body, inline: inline, list: list)
                closeBlock()

            case "blockquote":
                let outerIndent = inheritedIndent
                inheritedIndent += EPUBRenderer.bodyFont().pointSize * 1.6
                openBlock(EPUBRenderer.defaultBlock())
                var inner = inline
                inner.italic = true
                inner.color = Theme.dimText
                walk(body, inline: inner, list: list)
                closeBlock()
                inheritedIndent = outerIndent

            case "pre":
                var block = EPUBRenderer.defaultBlock()
                block.font = Theme.editorFont()
                block.indent = EPUBRenderer.bodyFont().pointSize
                openBlock(block)
                var inner = inline
                inner.preformatted = true
                inner.monospace = true
                walk(body, inline: inner, list: list)
                closeBlock()

            case "ul", "ol":
                // A nested list gets its own counter, and the enclosing list's
                // is untouched because the state travels down by value.
                walk(body, inline: inline,
                     list: ListState(ordered: tag == "ol",
                                     depth: (list?.depth ?? -1) + 1, index: 1))

            case "li":
                var block = EPUBRenderer.defaultBlock()
                let step = EPUBRenderer.bodyFont().pointSize * 1.4
                block.indent = step * CGFloat((list?.depth ?? 0) + 1)
                block.spacing = EPUBRenderer.bodyFont().pointSize * 0.35
                openBlock(block)
                let marker: String
                if let list, list.ordered {
                    marker = "\(list.index). "
                } else {
                    marker = "• "
                }
                var markerStyle = inline
                markerStyle.color = Theme.dimText
                append(marker, inline: markerStyle)
                // A paragraph nested in the item lines up with the item's text
                // rather than resetting to the margin.
                let outerIndent = inheritedIndent
                inheritedIndent = block.indent
                walk(body, inline: inline, list: list)
                closeBlock()
                inheritedIndent = outerIndent
                list?.index += 1

            case "br":
                append("\n", inline: inline)

            case "hr":
                var block = EPUBRenderer.defaultBlock()
                block.alignment = .center
                openBlock(block)
                var rule = inline
                rule.color = Theme.dimText
                append("* * *", inline: rule)
                closeBlock()

            case "img", "image":
                image(source: attributes["src"] ?? attributes["xlink:href"],
                      alt: attributes["alt"], inline: inline)

            case "table", "tbody", "thead", "tr":
                // Tables are laid out as their rows: a real column layout in an
                // attributed string needs tab stops measured against content
                // this renderer never sees in one piece.
                if tag == "tr" {
                    openBlock(EPUBRenderer.defaultBlock())
                    walk(body, inline: inline, list: list)
                    closeBlock()
                } else {
                    walk(body, inline: inline, list: list)
                }

            case "td", "th":
                var inner = inline
                inner.bold = inline.bold || tag == "th"
                walk(body, inline: inner, list: list)
                append("  ", inline: inline)

            case "a":
                var inner = inline
                if let href = attributes["href"], let link = self.link(for: href) {
                    inner.link = link
                }
                walk(body, inline: inner, list: list)

            case "em", "i", "cite", "var", "dfn":
                var inner = inline
                inner.italic = true
                walk(body, inline: inner, list: list)

            case "strong", "b":
                var inner = inline
                inner.bold = true
                walk(body, inline: inner, list: list)

            case "code", "kbd", "samp", "tt":
                var inner = inline
                inner.monospace = true
                walk(body, inline: inner, list: list)

            case "small", "sup", "sub":
                var inner = inline
                inner.sizeScale = 0.8
                walk(body, inline: inner, list: list)

            default:
                walk(body, inline: inline, list: list)
            }
        }

        // MARK: Elements needing the archive

        private mutating func image(source href: String?, alt: String?, inline: Inline) {
            guard let href, !href.isEmpty else { return }
            let path = EPUBBook.resolve(EPUBBook.stripFragment(href), against: directory)
            guard let data = book.data(at: path),
                  let image = EPUBRenderer.decodeBounded(data) else {
                // A picture that will not decode still occupied a place in the
                // text; say so rather than dropping it silently.
                if let alt = alt, !alt.isEmpty {
                    var caption = inline
                    caption.color = Theme.dimText
                    caption.italic = true
                    openBlock(EPUBRenderer.defaultBlock())
                    append(alt, inline: caption)
                    closeBlock()
                }
                return
            }
            var block = EPUBRenderer.defaultBlock()
            block.alignment = .center
            openBlock(block)
            let attachment = NSTextAttachment()
            attachment.image = image
            // Never wider than the measure, and never enlarged past its own
            // pixels — an inline decoration blown up to full width is worse
            // than one left small.
            let width = min(image.size.width, EPUBRenderer.readingWidth())
            let height = image.size.width > 0
                ? width * image.size.height / image.size.width : image.size.height
            attachment.bounds = NSRect(x: 0, y: 0, width: width, height: height)
            appendAttachment(attachment)
            closeBlock()
        }

        /// Rewrite an href so the reader can act on it. Links inside the book
        /// become `puzzle-epub:` URLs carrying the resolved archive path;
        /// anything already absolute is left to the system browser.
        private func link(for href: String) -> URL? {
            if href.hasPrefix("#") {
                var components = URLComponents()
                components.scheme = EPUBRenderer.linkScheme
                components.host = ""
                components.fragment = String(href.dropFirst())
                return components.url
            }
            if let absolute = URL(string: href), let scheme = absolute.scheme,
               scheme != "file" {
                return absolute
            }
            let path = EPUBBook.resolve(EPUBBook.stripFragment(href), against: directory)
            guard !path.isEmpty else { return nil }
            var components = URLComponents()
            components.scheme = EPUBRenderer.linkScheme
            components.host = ""
            components.path = "/" + path
            if let hash = href.firstIndex(of: "#") {
                components.fragment = String(href[href.index(after: hash)...])
            }
            return components.url
        }

        // MARK: Tag helpers

        private func tagName(of element: Node) -> String? {
            for child in element.children
            where child.type == "start_tag" || child.type == "self_closing_tag" {
                if let name = child.children.first(where: { $0.type == "tag_name" }) {
                    return source.substring(with: name.range).lowercased()
                }
            }
            return nil
        }

        private func attributeMap(of element: Node) -> [String: String] {
            var found: [String: String] = [:]
            for child in element.children
            where child.type == "start_tag" || child.type == "self_closing_tag" {
                for attribute in child.children where attribute.type == "attribute" {
                    guard let nameNode = attribute.children.first(where: {
                        $0.type == "attribute_name"
                    }) else { continue }
                    let name = source.substring(with: nameNode.range).lowercased()
                    var value = ""
                    for valueNode in attribute.children {
                        switch valueNode.type {
                        case "attribute_value":
                            value = source.substring(with: valueNode.range)
                        case "quoted_attribute_value":
                            if let inner = valueNode.children.first(where: {
                                $0.type == "attribute_value"
                            }) {
                                value = source.substring(with: inner.range)
                            }
                        default:
                            continue
                        }
                    }
                    found[name] = EPUBRenderer.decodeEntities(value)
                }
            }
            return found
        }
    }

    /// Where a list is, so `<li>` knows its marker and its indent.
    private struct ListState {
        let ordered: Bool
        let depth: Int
        var index: Int
    }

    private static func defaultBlock() -> Block {
        let font = bodyFont()
        return Block(font: font, spacing: font.pointSize * 0.75)
    }

    private static func headingBlock(level: Int) -> Block {
        let base = bodyFont()
        let scale: CGFloat = [1.0, 1.6, 1.42, 1.28, 1.16, 1.08, 1.0][max(1, min(6, level))]
        let font = NSFont(descriptor: base.fontDescriptor, size: base.pointSize * scale) ?? base
        return Block(font: font, spacing: base.pointSize * (level <= 2 ? 1.8 : 1.3))
    }

    // MARK: - Text utilities

    /// HTML collapses every run of whitespace to one space, and the source is
    /// indented for people reading the markup, not the book.
    static func collapseWhitespace(_ text: String, trimLeading: Bool) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        var inWhitespace = trimLeading
        for character in text {
            if character.isWhitespace {
                if !inWhitespace { output.append(" ") }
                inWhitespace = true
            } else {
                output.append(character)
                inWhitespace = false
            }
        }
        return output
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "mdash": "—", "ndash": "–", "hellip": "…",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}",
        "rdquo": "\u{201D}", "bull": "•", "middot": "·", "times": "×",
        "copy": "©", "reg": "®", "trade": "™", "deg": "°", "shy": "\u{00AD}",
        "laquo": "«", "raquo": "»", "eacute": "é", "egrave": "è", "agrave": "à",
        "ccedil": "ç", "uuml": "ü", "ouml": "ö", "auml": "ä", "szlig": "ß",
        "ntilde": "ñ", "frac12": "½", "frac14": "¼", "pound": "£", "euro": "€",
        "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}",
        "sbquo": "‚", "bdquo": "„", "dagger": "†", "Dagger": "‡", "permil": "‰",
        "lsaquo": "‹", "rsaquo": "›", "prime": "′", "Prime": "″", "oline": "‾",
        "frasl": "⁄", "minus": "−", "divide": "÷", "plusmn": "±", "sup2": "²",
        "sup3": "³", "sup1": "¹", "frac34": "¾", "micro": "µ", "para": "¶",
        "sect": "§", "cent": "¢", "yen": "¥", "curren": "¤", "brvbar": "¦",
        "uml": "¨", "ordf": "ª", "not": "¬", "macr": "¯", "acute": "´",
        "cedil": "¸", "ordm": "º", "iquest": "¿", "iexcl": "¡", "hearts": "♥",
        "larr": "←", "uarr": "↑", "rarr": "→", "darr": "↓", "harr": "↔",
        // The Latin-1 letters, which older books use in preference to UTF-8.
        "Agrave": "À", "Aacute": "Á", "Acirc": "Â", "Atilde": "Ã", "Auml": "Ä",
        "Aring": "Å", "AElig": "Æ", "Ccedil": "Ç", "Egrave": "È", "Eacute": "É",
        "Ecirc": "Ê", "Euml": "Ë", "Igrave": "Ì", "Iacute": "Í", "Icirc": "Î",
        "Iuml": "Ï", "ETH": "Ð", "Ntilde": "Ñ", "Ograve": "Ò", "Oacute": "Ó",
        "Ocirc": "Ô", "Otilde": "Õ", "Ouml": "Ö", "Oslash": "Ø", "Ugrave": "Ù",
        "Uacute": "Ú", "Ucirc": "Û", "Uuml": "Ü", "Yacute": "Ý", "THORN": "Þ",
        "aacute": "á", "acirc": "â", "atilde": "ã", "aring": "å", "aelig": "æ",
        "ecirc": "ê", "euml": "ë", "igrave": "ì", "iacute": "í", "icirc": "î",
        "iuml": "ï", "eth": "ð", "ograve": "ò", "oacute": "ó", "ocirc": "ô",
        "otilde": "õ", "oslash": "ø", "ugrave": "ù", "uacute": "ú", "ucirc": "û",
        "yacute": "ý", "thorn": "þ", "yuml": "ÿ",
    ]

    /// Resolve the entities a book actually uses. An `&` that starts nothing
    /// recognisable is left exactly as it was — books contain stray ampersands,
    /// and mangling one is worse than leaving it.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var output = ""
        output.reserveCapacity(text.count)
        var rest = Substring(text)
        while let start = rest.firstIndex(of: "&") {
            output.append(contentsOf: rest[..<start])
            let after = rest.index(after: start)
            guard let semicolon = rest[after...].firstIndex(of: ";"),
                  rest.distance(from: after, to: semicolon) <= 10 else {
                output.append("&")
                rest = rest[after...]
                continue
            }
            let name = String(rest[after..<semicolon])
            if let replacement = namedEntities[name] {
                output.append(replacement)
            } else if name.hasPrefix("#"),
                      let scalar = numericScalar(name.dropFirst()) {
                output.append(Character(scalar))
            } else {
                output.append("&")
                rest = rest[after...]
                continue
            }
            rest = rest[rest.index(after: semicolon)...]
        }
        output.append(contentsOf: rest)
        return output
    }

    private static func numericScalar(_ digits: Substring) -> Unicode.Scalar? {
        let value: UInt32?
        if digits.hasPrefix("x") || digits.hasPrefix("X") {
            value = UInt32(digits.dropFirst(), radix: 16)
        } else {
            value = UInt32(digits, radix: 10)
        }
        guard let value else { return nil }
        return Unicode.Scalar(value)
    }

    /// Decode an illustration at a bounded resolution, for the same reason the
    /// image preview does: a full-resolution bitmap of a cover is tens of
    /// megabytes, and it is being drawn at column width.
    static func decodeBounded(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: thumbnail,
                       size: NSSize(width: thumbnail.width, height: thumbnail.height))
    }
}

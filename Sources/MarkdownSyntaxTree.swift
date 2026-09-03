import AppKit

/// One node of a parsed Markdown document, in the UTF-16 offsets the text
/// system works in.
struct MarkdownNode {
    let type: String
    let range: NSRange
    let children: [MarkdownNode]

    func first(_ type: String) -> MarkdownNode? { children.first { $0.type == type } }
    func all(_ type: String) -> [MarkdownNode] { children.filter { $0.type == type } }
    /// Every descendant of a type, at any depth.
    func descendants(_ type: String) -> [MarkdownNode] {
        var found: [MarkdownNode] = []
        for child in children {
            if child.type == type { found.append(child) }
            found.append(contentsOf: child.descendants(type))
        }
        return found
    }
}

/// Parses Markdown with the tree-sitter grammars the app already vendors and
/// links — the same ones Zed and Neovim use.
///
/// A pattern cannot decide Markdown: what a character means depends on what it
/// sits *inside*. A `#` inside a fenced block is not a heading, a `*` inside a
/// code span is not emphasis, and a fence can open on the same line as the list
/// marker that owns it. Every one of those was a bug in the expression-based
/// styler this replaced, and none of them is fixable by tightening a pattern.
///
/// The grammar is split in two, as CommonMark itself is: a block pass finds
/// headings, lists, fences and tables and marks the spans that hold running
/// text, and an inline pass parses emphasis, links and code spans inside each
/// of those spans. Both parsers are kept alive between documents; creating one
/// costs more than parsing a file with it.
enum MarkdownSyntaxTree {
    struct Document {
        /// Top-level block nodes, nested as they are in the source.
        let blocks: [MarkdownNode]
        /// Inline nodes, already shifted into whole-document offsets.
        let inlines: [MarkdownNode]
    }

    private static let lock = NSLock()
    private static var blockParser: OpaquePointer?
    private static var inlineParser: OpaquePointer?

    static func parse(_ text: String) -> Document {
        guard !text.isEmpty else { return Document(blocks: [], inlines: []) }
        lock.lock()
        defer { lock.unlock() }
        if blockParser == nil {
            blockParser = makeParser(tree_sitter_markdown())
            inlineParser = makeParser(tree_sitter_markdown_inline())
        }
        guard let blockParser else { return Document(blocks: [], inlines: []) }

        let blocks = nodes(of: text, using: blockParser)
        // Running text is parsed span by span rather than by handing the inline
        // parser a set of included ranges: an `inline` node is self-contained,
        // so the result is the same, and the parser never has to be told about
        // the block structure around it.
        var inlines: [MarkdownNode] = []
        if let inlineParser {
            let source = text as NSString
            for span in inlineSpans(in: blocks) {
                let fragment = source.substring(with: span)
                let parsed = nodes(of: fragment, using: inlineParser)
                inlines.append(contentsOf: parsed.map { shift($0, by: span.location) })
            }
        }
        return Document(blocks: blocks, inlines: inlines)
    }

    private static func inlineSpans(in nodes: [MarkdownNode]) -> [NSRange] {
        var spans: [NSRange] = []
        for node in nodes {
            if node.type == "inline" {
                spans.append(node.range)
            } else {
                spans.append(contentsOf: inlineSpans(in: node.children))
            }
        }
        return spans
    }

    private static func shift(_ node: MarkdownNode, by offset: Int) -> MarkdownNode {
        MarkdownNode(type: node.type,
                     range: NSRange(location: node.range.location + offset,
                                    length: node.range.length),
                     children: node.children.map { shift($0, by: offset) })
    }

    private static func makeParser(_ language: OpaquePointer?) -> OpaquePointer? {
        guard let parser = ts_parser_new() else { return nil }
        guard ts_parser_set_language(parser, language) else {
            ts_parser_delete(parser)
            return nil
        }
        return parser
    }

    private static func nodes(of text: String, using parser: OpaquePointer) -> [MarkdownNode] {
        let byteCount = text.utf8.count
        guard byteCount > 0 else { return [] }
        var result: [MarkdownNode] = []
        text.withCString { cstr in
            guard let tree = ts_parser_parse_string(parser, nil, cstr,
                                                    UInt32(byteCount)) else { return }
            defer { ts_tree_delete(tree) }
            let mapper = ByteMapper(text: text, utf8Count: byteCount)
            result = children(of: ts_tree_root_node(tree), mapper: mapper)
        }
        return result
    }

    private static func children(of node: TSNode, mapper: ByteMapper) -> [MarkdownNode] {
        var built: [MarkdownNode] = []
        let count = ts_node_child_count(node)
        guard count > 0 else { return built }
        for index in 0..<count {
            let child = ts_node_child(node, index)
            guard ts_node_is_named(child) else { continue }
            guard let start = mapper.utf16(forByte: Int(ts_node_start_byte(child))),
                  let end = mapper.utf16(forByte: Int(ts_node_end_byte(child))),
                  end >= start else { continue }
            let type = String(cString: ts_node_type(child))
            built.append(MarkdownNode(type: type,
                                      range: NSRange(location: start, length: end - start),
                                      children: children(of: child, mapper: mapper)))
        }
        return built
    }
}

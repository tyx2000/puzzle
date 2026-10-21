import AppKit

/// Describes one supported language: its grammar and highlight queries.
struct LanguageDefinition {
    let name: String
    let language: OpaquePointer            // TSLanguage *
    let querySources: [String]             // one or more highlights.scm bodies
    let extensions: Set<String>
    let display: String
}

/// tree-sitter backed highlighter. Parses a document and applies the theme's
/// syntax colours to an NSTextStorage, evaluating #eq?/#match?/#any-of?
/// predicates.
final class SyntaxHighlighter {

    // MARK: Language registry

    private static let queryDir: URL? = {
        Bundle.main.resourceURL?.appendingPathComponent("queries")
    }()

    private static func loadQuery(_ file: String) -> String {
        guard let dir = queryDir,
              let text = try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
        else { return "" }
        return text
    }

    /// A language we *can* load, described without touching its grammar.
    ///
    /// IMPORTANT: this table holds no parser and no query text. Calling
    /// `tree_sitter_swift()` pages in ~20 MB of generated parser tables, and each
    /// query file costs a disk read plus a compiled `TSQuery`. Building all eight
    /// eagerly (the old `static let languages`) meant opening *any* file paid for
    /// *every* language. Grammars are now materialised on first real use.
    struct LanguageSpec {
        let name: String
        let display: String
        let extensions: Set<String>
        /// Whole filenames, lowercased. Needed for files that have no usable
        /// extension — `Dockerfile`, `.gitignore`, `Cargo.lock` — where
        /// `pathExtension` is empty or means nothing.
        let filenames: Set<String>
        let queryFiles: [String]
        let makeLanguage: () -> OpaquePointer?

        init(name: String, display: String, extensions: Set<String>,
             filenames: Set<String> = [], queryFiles: [String],
             makeLanguage: @escaping () -> OpaquePointer?) {
            self.name = name
            self.display = display
            self.extensions = extensions
            self.filenames = filenames
            self.queryFiles = queryFiles
            self.makeLanguage = makeLanguage
        }
    }

    static let specs: [LanguageSpec] = [
        LanguageSpec(name: "json", display: "JSON",
                     extensions: ["json", "jsonc", "geojson"],
                     queryFiles: ["json.scm"], makeLanguage: { tree_sitter_json() }),
        LanguageSpec(name: "bash", display: "Shell",
                     extensions: ["sh", "bash", "zsh", "zshrc", "bashrc", "profile"],
                     queryFiles: ["bash.scm"], makeLanguage: { tree_sitter_bash() }),
        LanguageSpec(name: "yaml", display: "YAML",
                     extensions: ["yaml", "yml"],
                     queryFiles: ["yaml.scm"], makeLanguage: { tree_sitter_yaml() }),
        LanguageSpec(name: "typescript", display: "TypeScript",
                     extensions: ["ts", "mts", "cts"],
                     queryFiles: ["typescript.scm", "typescript_ecma.scm"],
                     makeLanguage: { tree_sitter_typescript() }),
        // The TSX dialect is required to distinguish JSX tags from TypeScript
        // generics. JavaScript uses it as well because React commonly ships JSX
        // in .js/.mjs/.cjs files.
        LanguageSpec(name: "tsx", display: "JavaScript / TSX",
                     extensions: ["tsx", "jsx", "js", "mjs", "cjs"],
                     queryFiles: ["typescript.scm", "typescript_ecma.scm"],
                     makeLanguage: { tree_sitter_tsx() }),
        LanguageSpec(name: "markdown", display: "Markdown",
                     extensions: ["md", "markdown", "mdx"],
                     queryFiles: ["markdown.scm"], makeLanguage: { tree_sitter_markdown() }),
        LanguageSpec(name: "swift", display: "Swift",
                     extensions: ["swift"],
                     queryFiles: ["swift.scm"], makeLanguage: { tree_sitter_swift() }),
        LanguageSpec(name: "html", display: "HTML",
                     extensions: ["html", "htm", "xhtml"],
                     queryFiles: ["html.scm"], makeLanguage: { tree_sitter_html() }),
        LanguageSpec(name: "css", display: "CSS",
                     extensions: ["css", "scss"],
                     queryFiles: ["css.scm"], makeLanguage: { tree_sitter_css() }),
        LanguageSpec(name: "python", display: "Python",
                     extensions: ["py", "pyi", "pyw"],
                     queryFiles: ["python.scm"], makeLanguage: { tree_sitter_python() }),
        LanguageSpec(name: "rust", display: "Rust",
                     extensions: ["rs"],
                     queryFiles: ["rust.scm"], makeLanguage: { tree_sitter_rust() }),
        LanguageSpec(name: "go", display: "Go",
                     extensions: ["go"],
                     queryFiles: ["go.scm"], makeLanguage: { tree_sitter_go() }),
        LanguageSpec(name: "c", display: "C",
                     extensions: ["c", "h"],
                     queryFiles: ["c.scm"], makeLanguage: { tree_sitter_c() }),
        // Several lockfiles are TOML with a name that hides it.
        LanguageSpec(name: "toml", display: "TOML",
                     extensions: ["toml"],
                     filenames: ["cargo.lock", "poetry.lock", "uv.lock", "gopkg.lock"],
                     queryFiles: ["toml.scm"], makeLanguage: { tree_sitter_toml() }),
        LanguageSpec(name: "xml", display: "XML",
                     extensions: ["xml", "xsd", "xsl", "xslt", "svg", "plist",
                                  "storyboard", "xib", "csproj", "resx"],
                     queryFiles: ["xml.scm"], makeLanguage: { tree_sitter_xml() }),
        LanguageSpec(name: "sql", display: "SQL",
                     extensions: ["sql", "psql", "mysql", "ddl"],
                     queryFiles: ["sql.scm"], makeLanguage: { tree_sitter_sql() }),
        LanguageSpec(name: "dockerfile", display: "Dockerfile",
                     extensions: ["dockerfile"],
                     filenames: ["dockerfile", "containerfile"],
                     queryFiles: ["dockerfile.scm"], makeLanguage: { tree_sitter_dockerfile() }),
        // Every *ignore file shares gitignore's syntax.
        LanguageSpec(name: "gitignore", display: "Ignore",
                     extensions: ["gitignore", "dockerignore", "npmignore",
                                  "eslintignore", "prettierignore", "rgignore"],
                     filenames: [".gitignore", ".dockerignore", ".npmignore",
                                 ".eslintignore", ".prettierignore", ".rgignore",
                                 ".gitattributes", ".ignore", "exclude"],
                     queryFiles: ["gitignore.scm"], makeLanguage: { tree_sitter_gitignore() }),
    ]

    /// Lockfiles that are really JSON / YAML under another name.
    private static let filenameAliases: [String: String] = [
        "composer.lock": "json", "deno.lock": "json", "flake.lock": "json",
        "pipfile.lock": "json", "package-lock.json": "json",
        "yarn.lock": "yaml", "pnpm-lock.yaml": "yaml",
    ]

    /// Materialised definitions, built on demand and cached by name.
    private static var loaded: [String: LanguageDefinition] = [:]

    /// The spec for an extension — cheap, touches no grammar.
    static func spec(forExtension ext: String) -> LanguageSpec? {
        let e = ext.lowercased()
        return specs.first { $0.extensions.contains(e) }
    }

    /// The spec for a file, by name first and extension second.
    ///
    /// Extension alone is not enough: `Dockerfile` has none, `.gitignore` is
    /// all extension and no stem, and `Cargo.lock` shares `.lock` with files
    /// that are actually JSON.
    static func spec(for url: URL) -> LanguageSpec? {
        let name = url.lastPathComponent.lowercased()
        if let language = filenameAliases[name] {
            return specs.first { $0.name == language }
        }
        if let hit = specs.first(where: { $0.filenames.contains(name) }) { return hit }
        // Dockerfile.dev, Dockerfile.prod — the suffix is a variant, not a type.
        if name.hasPrefix("dockerfile.") || name.hasSuffix(".dockerfile") {
            return specs.first { $0.name == "dockerfile" }
        }
        return spec(forExtension: url.pathExtension)
    }

    /// Load (and cache) the grammar + queries for a spec. Only call this when a
    /// document of that language is actually being highlighted.
    static func definition(for spec: LanguageSpec) -> LanguageDefinition? {
        if let hit = loaded[spec.name] { return hit }
        guard let language = spec.makeLanguage() else { return nil }
        let sources = spec.queryFiles.map { loadQuery($0) }.filter { !$0.isEmpty }
        let def = LanguageDefinition(name: spec.name, language: language,
                                     querySources: sources,
                                     extensions: spec.extensions, display: spec.display)
        loaded[spec.name] = def
        return def
    }

    /// Drop cached query text for languages nothing has open any more.
    static func unloadDefinitions(keeping names: Set<String>) {
        for key in loaded.keys where !names.contains(key) { loaded.removeValue(forKey: key) }
    }

    /// Eagerly materialise every language. Only used by tests.
    static var languages: [LanguageDefinition] { specs.compactMap { definition(for: $0) } }

    static func language(forExtension ext: String) -> LanguageDefinition? {
        spec(forExtension: ext).flatMap { definition(for: $0) }
    }

    // MARK: Instance

    private var previousTree: OpaquePointer?
    private var previousBytes: [UInt8] = []
    private weak var previousStorage: NSTextStorage?
    /// The offsets of `previousBytes`, kept with them: a pass that colours a
    /// part of the text would otherwise map all of it again to find the part.
    private var previousMapper: ByteMapper?
    private(set) var incrementalParseCount = 0
    private(set) var fullParseCount = 0
    private(set) var lastParseDuration: TimeInterval = 0

    /// Code longer than this is shown as plain text. Highlighting colours what
    /// an edit changed rather than the whole text, so the limit is what one
    /// parse of the whole may cost, not one pass.
    static let maximumBytes = 2_000_000

    func discardParseTree() {
        if let previousTree { ts_tree_delete(previousTree) }
        previousTree = nil
        previousBytes = []
        previousStorage = nil
        previousMapper = nil
    }

    /// Whether the tree held now is `storage`'s, so its next parse is an edit.
    func holdsTree(for storage: NSTextStorage) -> Bool {
        previousTree != nil && previousStorage === storage
    }

    /// Parse `bytes` with a parser of its own, on whatever thread calls this:
    /// a long text's first parse, which the reader should not wait on. The
    /// tree comes back to its highlighter through `adopt`.
    static func parseDetached(_ bytes: [UInt8], language: OpaquePointer) -> OpaquePointer? {
        guard !bytes.isEmpty, let parser = ts_parser_new() else { return nil }
        defer { ts_parser_delete(parser) }
        guard ts_parser_set_language(parser, language) else { return nil }
        return bytes.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                ts_parser_parse_string(parser, nil, $0, UInt32(buffer.count))
            }
        }
    }

    /// Take `tree`, parsed from `bytes` for `storage` by `parseDetached`, as
    /// this highlighter's own: the next parse of `storage` edits it.
    func adopt(_ tree: OpaquePointer, bytes: [UInt8], for storage: NSTextStorage) {
        discardParseTree()
        previousTree = tree
        previousBytes = bytes
        previousStorage = storage
        fullParseCount += 1
    }

    func discardUnownedParseTree() {
        if previousStorage == nil { discardParseTree() }
    }

    /// Tree-sitter points use UTF-8 byte columns, not UTF-16 offsets.
    private static func point(in bytes: [UInt8], at offset: Int) -> TSPoint {
        var row: UInt32 = 0
        var column: UInt32 = 0
        for byte in bytes.prefix(offset) {
            if byte == 10 { row += 1; column = 0 } else { column += 1 }
        }
        return TSPoint(row: row, column: column)
    }

    /// The tree for `bytes`, and where it differs from the tree before it, as
    /// byte ranges: the edit, and whatever tree-sitter reparsed differently
    /// around it — a quote that opened a string runs to the end of the file.
    /// Nil for those when there was no tree before to differ from.
    private func parse(_ nextBytes: [UInt8],
                       storage: NSTextStorage) -> (tree: OpaquePointer, changed: [Range<Int>]?)? {
        if previousStorage !== storage { discardParseTree() }
        if let previousTree, previousBytes.count == nextBytes.count,
           previousBytes.withUnsafeBytes({ old in
               nextBytes.withUnsafeBytes { new in
                   memcmp(old.baseAddress!, new.baseAddress!, old.count) == 0
               }
           }) {
            return (previousTree, [])
        }
        var edited: Range<Int>?
        if let previousTree {
            var start = 0
            let sharedCount = min(previousBytes.count, nextBytes.count)
            while start < sharedCount && previousBytes[start] == nextBytes[start] { start += 1 }
            // A changed scalar may share leading bytes with the old scalar.
            while start > 0 && start < nextBytes.count && nextBytes[start] & 0xC0 == 0x80 {
                start -= 1
            }
            var oldEnd = previousBytes.count
            var newEnd = nextBytes.count
            while oldEnd > start && newEnd > start && previousBytes[oldEnd - 1] == nextBytes[newEnd - 1] {
                oldEnd -= 1; newEnd -= 1
            }
            while newEnd < nextBytes.count && nextBytes[newEnd] & 0xC0 == 0x80 {
                oldEnd += 1; newEnd += 1
            }
            var edit = TSInputEdit(start_byte: UInt32(start), old_end_byte: UInt32(oldEnd),
                new_end_byte: UInt32(newEnd), start_point: Self.point(in: previousBytes, at: start),
                old_end_point: Self.point(in: previousBytes, at: oldEnd),
                new_end_point: Self.point(in: nextBytes, at: newEnd))
            ts_tree_edit(previousTree, &edit)
            edited = start..<newEnd
            incrementalParseCount += 1
        } else {
            fullParseCount += 1
        }
        let started = CFAbsoluteTimeGetCurrent()
        let tree = nextBytes.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                ts_parser_parse_string(parser, previousTree, $0, UInt32(buffer.count))
            }
        }
        lastParseDuration = CFAbsoluteTimeGetCurrent() - started
        var changed: [Range<Int>]?
        if let previousTree, let tree, let edited {
            var ranges = [edited]
            var count: UInt32 = 0
            if let reparsed = ts_tree_get_changed_ranges(previousTree, tree, &count) {
                for range in UnsafeBufferPointer(start: reparsed, count: Int(count)) {
                    ranges.append(Int(range.start_byte)..<Int(range.end_byte))
                }
                TreeSitterAllocator.free(reparsed)
            }
            changed = ranges
        }
        if let previousTree { ts_tree_delete(previousTree) }
        previousTree = tree
        previousBytes = tree == nil ? [] : nextBytes
        previousStorage = tree == nil ? nil : storage
        previousMapper = nil
        return tree.map { ($0, changed) }
    }

    // MARK: Brackets

    /// The bracket pair the syntax tree has beside `caret` — the character
    /// before it, or failing that the one after — in UTF-16 offsets of the
    /// text last parsed for `storage`. Nil when this holds no tree for it.
    ///
    /// A bracket in code is a token of its own, and its pair is the token
    /// that closes it among the same node's children. A bracket in a string,
    /// a comment or JSX text is only a character of that leaf: it has no
    /// pair, and the empty answer is the tree's, not a failure to find one.
    /// Guessing those from the text alone took `#{item.name}` in JSX text,
    /// `#header {` in CSS and `#selector(` in Swift for comments.
    func bracketPair(beside caret: Int, in storage: NSTextStorage) -> [NSRange]? {
        guard holdsTree(for: storage), let tree = previousTree else { return nil }
        let mapper: ByteMapper
        if let previousMapper {
            mapper = previousMapper
        } else {
            mapper = previousBytes.withUnsafeBufferPointer { ByteMapper(bytes: $0) }
            previousMapper = mapper
        }
        let root = ts_tree_root_node(tree)
        for offset in [caret - 1, caret] where offset >= 0 {
            let byte = mapper.byte(forUTF16: offset)
            guard byte < previousBytes.count, Self.brackets[previousBytes[byte]] != nil,
                  let pair = Self.pair(of: byte, under: root) else { continue }
            return pair.map { NSRange(location: mapper.utf16(atOrBefore: $0), length: 1) }
        }
        return []
    }

    /// Each bracket, and whether it opens a pair.
    private static let brackets: [UInt8: Bool] = [
        0x28: true, 0x5B: true, 0x7B: true, 0x29: false, 0x5D: false, 0x7D: false,
    ]
    private static let closer: [UInt8: UInt8] = [0x28: 0x29, 0x5B: 0x5D, 0x7B: 0x7D]

    /// The bracket a token is: one of its own, or the last character of a
    /// short one that opens like one — `${` in a template, `#{` in Ruby,
    /// `\(` in a Swift string.
    private static func bracket(of node: TSNode) -> (character: UInt8, opens: Bool)? {
        guard !ts_node_is_null(node), !ts_node_is_named(node), !ts_node_is_missing(node),
              let type = ts_node_type(node) else { return nil }
        let text = Array(String(cString: type).utf8)
        guard let last = text.last, let opens = brackets[last],
              text.count == 1 || (opens && text.count <= 3) else { return nil }
        return (last, opens)
    }

    /// The bytes of the pair the bracket token ending at `byte` belongs to,
    /// found among its node's children; nil when the character there is no
    /// bracket token, or has nothing to pair with.
    private static func pair(of byte: Int, under root: TSNode) -> [Int]? {
        let node = ts_node_descendant_for_byte_range(root, UInt32(byte), UInt32(byte + 1))
        guard bracket(of: node) != nil, Int(ts_node_end_byte(node)) == byte + 1 else { return nil }
        let parent = ts_node_parent(node)
        guard !ts_node_is_null(parent) else { return nil }
        // A cursor, not child(at:): a child found by its index is a walk
        // from the first, and an array literal can have thousands.
        var cursor = ts_tree_cursor_new(parent)
        defer { ts_tree_cursor_delete(&cursor) }
        guard ts_tree_cursor_goto_first_child(&cursor) else { return nil }
        var open: [(byte: Int, character: UInt8)] = []
        repeat {
            let child = ts_tree_cursor_current_node(&cursor)
            guard let found = bracket(of: child) else { continue }
            let at = Int(ts_node_end_byte(child)) - 1
            if found.opens {
                open.append((at, found.character))
            } else if let last = open.last, closer[last.character] == found.character {
                open.removeLast()
                if last.byte == byte || at == byte { return [last.byte, at] }
            }
        } while ts_tree_cursor_goto_next_sibling(&cursor)
        return nil
    }

    var treeDescriptionForTesting: String? {
        guard let previousTree, let string = ts_node_string(ts_tree_root_node(previousTree)) else { return nil }
        defer { TreeSitterAllocator.free(string) }
        return String(cString: string)
    }

    private let parser: OpaquePointer
    private let definition: LanguageDefinition
    private var queries: [OpaquePointer] = []
    /// Colour and specificity per capture id, per query.
    ///
    /// These used to be derived inside the capture loop, which meant building a
    /// Swift String from the capture name — and counting its dots — once for
    /// *every capture in the file*. Capture ids are fixed when the query is
    /// compiled, so both are resolved here, once.
    /// The colour is a place in `palette`, every colour the queries can give
    /// once each, and 0 for none: a pass paints these small numbers, not the
    /// colours themselves.
    private var capturePalette: [[UInt8]] = []
    private var captureSpecificity: [[Int]] = []
    private var palette: [NSColor] = [Theme.foreground]

    init?(definition: LanguageDefinition) {
        guard let p = ts_parser_new() else { return nil }
        guard ts_parser_set_language(p, definition.language) else {
            ts_parser_delete(p); return nil
        }
        self.parser = p
        self.definition = definition
        for source in definition.querySources {
            source.withCString { cstr in
                var errOffset: UInt32 = 0
                var errType: TSQueryError = TSQueryErrorNone
                if let q = ts_query_new(definition.language, cstr,
                                        UInt32(strlen(cstr)), &errOffset, &errType) {
                    queries.append(q)
                    var colors: [NSColor?] = []
                    var specificity: [Int] = []
                    for id in 0..<ts_query_capture_count(q) {
                        var len: UInt32 = 0
                        guard let namePtr = ts_query_capture_name_for_id(q, id, &len) else {
                            colors.append(nil); specificity.append(0); continue
                        }
                        let name = String(decoding: UnsafeBufferPointer(
                            start: UnsafeRawPointer(namePtr).assumingMemoryBound(to: UInt8.self),
                            count: Int(len)), as: UTF8.self)
                        colors.append(Self.color(for: name))
                        specificity.append(name.reduce(0) { $1 == "." ? $0 + 1 : $0 })
                    }
                    captureSpecificity.append(specificity)
                    capturePalette.append(colors.map { color in
                        guard let color else { return 0 }
                        if let index = palette.firstIndex(of: color) { return UInt8(index) }
                        guard palette.count < Int(UInt8.max) else { return 0 }
                        palette.append(color)
                        return UInt8(palette.count - 1)
                    })
                } else {
                    FileHandle.standardError.write(Data(
                        "puzzle: query compile failed for \(definition.name) at \(errOffset) (err \(errType.rawValue))\n".utf8))
                }
            }
        }
    }

    deinit {
        discardParseTree()
        queries.forEach { ts_query_delete($0) }
        ts_parser_delete(parser)
    }

    var isUsable: Bool { !queries.isEmpty }

    // MARK: Highlighting

    /// A text brought up to date for colouring.
    struct Parse {
        /// Where the parse changed anything, in UTF-16 offsets: the edit, and
        /// whatever was reparsed differently around it. Nil when there was no
        /// tree before to compare with, which leaves everything in question.
        let changed: [NSRange]?
        let tagMatches: [JSXTagMatch]
    }

    /// Parse `text`, as an edit of the tree for `owner` when this holds it.
    /// Nil for an empty text, or one past `maximumBytes`, which has no tree.
    func parse(text: String, owner: NSTextStorage) -> Parse? {
        let bytes = Self.utf8(text)
        guard !bytes.isEmpty, bytes.count <= Self.maximumBytes else {
            discardParseTree()
            return nil
        }
        guard let parsed = parse(bytes, storage: owner) else { return nil }
        return bytes.withUnsafeBufferPointer { bytes in
            let mapper = previousMapper ?? ByteMapper(bytes: bytes)
            previousMapper = mapper
            let changed = parsed.changed?.map { range in
                let start = mapper.utf16(atOrBefore: range.lowerBound)
                let end = mapper.utf16(atOrAfter: range.upperBound)
                return NSRange(location: start, length: max(0, end - start))
            }
            let tagMatches = definition.name == "tsx"
                ? JSXTagMatcher.matches(in: ts_tree_root_node(parsed.tree),
                                        bytes: bytes, mapper: mapper)
                : []
            return Parse(changed: changed, tagMatches: tagMatches)
        }
    }

    /// `text` as UTF-8. A buffer's text is an `NSString` under the `String`,
    /// and Swift's own conversion of one cost a long file 18 ms a pass, nine
    /// times what Core Foundation's does.
    static func utf8(_ text: String) -> [UInt8] {
        if let bytes = text.utf8.withContiguousStorageIfAvailable({ Array($0) }) {
            return bytes
        }
        let string = text as NSString as CFString
        let whole = CFRange(location: 0, length: CFStringGetLength(string))
        let encoding = CFStringBuiltInEncodings.UTF8.rawValue
        var count: CFIndex = 0
        CFStringGetBytes(string, whole, encoding, 0, false, nil, 0, &count)
        var bytes = [UInt8](repeating: 0, count: count)
        CFStringGetBytes(string, whole, encoding, 0, false, &bytes, count, nil)
        return bytes
    }

    /// The colours over each of `ranges` — UTF-16 offsets of the text last
    /// parsed, in order, not overlapping — as runs in order that do not
    /// overlap either. Where no run is, the text has no colour of its own.
    ///
    /// Only the captures that reach into a range are asked for, so colouring
    /// a few lines of a long file costs a few lines. A capture that reaches
    /// out of the range is cut to it; whichever capture wins at a character is
    /// the one that would have won had the whole text been coloured.
    func colours(in ranges: [NSRange]) -> [(range: NSRange, color: NSColor)] {
        guard let tree = previousTree, let mapper = previousMapper else { return [] }
        let root = ts_tree_root_node(tree)
        var runs: [(range: NSRange, color: NSColor)] = []
        previousBytes.withUnsafeBufferPointer { bytes in
            for range in ranges where range.length > 0 {
                let low = range.location, high = NSMaxRange(range)
                let lowByte = mapper.byte(forUTF16: low)
                let highByte = mapper.byte(forUTF16: high)
                guard highByte > lowByte else { continue }
                var spans: [Span] = []
                for (queryIndex, query) in queries.enumerated() {
                    guard let cursor = ts_query_cursor_new() else { continue }
                    defer { ts_query_cursor_delete(cursor) }
                    ts_query_cursor_set_byte_range(cursor, UInt32(lowByte), UInt32(highByte))
                    ts_query_cursor_exec(cursor, query, root)
                    var match = TSQueryMatch()
                    while ts_query_cursor_next_match(cursor, &match) {
                        if !predicatesPass(query: query, match: match, bytes: bytes) { continue }
                        let captures = UnsafeBufferPointer(start: match.captures,
                                                           count: Int(match.capture_count))
                        for capture in captures {
                            let id = Int(capture.index)
                            guard id < capturePalette[queryIndex].count else { continue }
                            let colour = capturePalette[queryIndex][id]
                            guard colour != 0 else { continue }
                            let startByte = Int(ts_node_start_byte(capture.node))
                            let endByte = Int(ts_node_end_byte(capture.node))
                            guard endByte > startByte,
                                  let u0 = mapper.utf16(forByte: startByte),
                                  let u1 = mapper.utf16(forByte: endByte) else { continue }
                            let start = max(u0, low), end = min(u1, high)
                            guard end > start else { continue }
                            spans.append(Span(
                                start: start, end: end, colour: colour,
                                length: endByte - startByte,
                                specificity: captureSpecificity[queryIndex][id],
                                rank: queryIndex * 100_000 + Int(match.pattern_index)))
                        }
                    }
                }
                Self.paint(spans, from: low, to: high, palette: palette, into: &runs)
            }
        }
        return runs
    }

    /// A capture as it lands in a range being coloured.
    private struct Span {
        let start: Int, end: Int
        let colour: UInt8
        /// The whole capture's length in bytes, not just its part in the range:
        /// the bigger capture is painted first, under the smaller.
        let length: Int
        let specificity: Int
        let rank: Int
    }

    /// Lay `spans` over `low..<high` so the winner at each character lands
    /// last — largest first; for equal ranges the more specific capture, then
    /// the later query pattern — and append the result as runs.
    private static func paint(_ spans: [Span], from low: Int, to high: Int,
                              palette: [NSColor],
                              into runs: inout [(range: NSRange, color: NSColor)]) {
        guard !spans.isEmpty else { return }
        let ordered = spans.sorted { a, b in
            if a.length != b.length { return a.length > b.length }
            if a.specificity != b.specificity { return a.specificity < b.specificity }
            return a.rank < b.rank
        }
        var canvas = [UInt8](repeating: 0, count: high - low)
        canvas.withUnsafeMutableBufferPointer { cells in
            guard let base = cells.baseAddress else { return }
            for span in ordered {
                memset(base + (span.start - low), Int32(span.colour), span.end - span.start)
            }
            var index = 0
            while index < cells.count {
                let colour = cells[index]
                var end = index + 1
                while end < cells.count && cells[end] == colour { end += 1 }
                if colour != 0 {
                    runs.append((NSRange(location: low + index, length: end - index),
                                 palette[Int(colour)]))
                }
                index = end
            }
        }
    }

    /// Parse `text` and paint colors onto `storage` over `fullRange`.
    /// Base font/foreground/paragraph are assumed already applied by the caller.
    @discardableResult
    func highlight(text: String, storage: NSTextStorage,
                   fullRange: NSRange, parseOwner: NSTextStorage? = nil) -> [JSXTagMatch] {
        guard let parsed = parse(text: text, owner: parseOwner ?? storage) else { return [] }
        let runs = colours(in: [NSRange(location: 0,
                                        length: min(fullRange.length, text.utf16.count))])
        // In order and apart, so each lands at the end of what is set so far:
        // painted biggest first, every capture split a run somewhere in the
        // middle, and a long file took most of a second to paint.
        storage.beginEditing()
        for run in runs {
            storage.addAttribute(.foregroundColor, value: run.color, range: run.range)
        }
        storage.endEditing()
        return parsed.tagMatches
    }

    // MARK: Predicate evaluation (#eq? #match? #any-of? and negations)

    private func predicatesPass(query: OpaquePointer, match: TSQueryMatch,
                                bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        var count: UInt32 = 0
        guard let steps = ts_query_predicates_for_pattern(query, UInt32(match.pattern_index), &count),
              count > 0 else { return true }
        let stepBuf = UnsafeBufferPointer(start: steps, count: Int(count))

        func captureText(_ captureIndex: UInt32) -> String? {
            let captures = UnsafeBufferPointer(start: match.captures, count: Int(match.capture_count))
            for cap in captures where cap.index == captureIndex {
                let s = Int(ts_node_start_byte(cap.node)), e = Int(ts_node_end_byte(cap.node))
                guard e <= bytes.count, s <= e else { return nil }
                return String(decoding: bytes[s..<e], as: UTF8.self)
            }
            return nil
        }
        func stringValue(_ id: UInt32) -> String {
            var len: UInt32 = 0
            guard let p = ts_query_string_value_for_id(query, id, &len) else { return "" }
            return String(decoding: UnsafeBufferPointer(
                start: UnsafeRawPointer(p).assumingMemoryBound(to: UInt8.self), count: Int(len)), as: UTF8.self)
        }

        // Split steps into individual predicates on the Done sentinel.
        var group: [TSQueryPredicateStep] = []
        for step in stepBuf {
            if step.type == TSQueryPredicateStepTypeDone {
                if !evaluate(group, captureText: captureText, stringValue: stringValue) { return false }
                group.removeAll(keepingCapacity: true)
            } else {
                group.append(step)
            }
        }
        return true
    }

    private func evaluate(_ steps: [TSQueryPredicateStep],
                          captureText: (UInt32) -> String?,
                          stringValue: (UInt32) -> String) -> Bool {
        guard let first = steps.first, first.type == TSQueryPredicateStepTypeString else { return true }
        let op = stringValue(first.value_id)
        let args = Array(steps.dropFirst())

        func arg(_ i: Int) -> (isCapture: Bool, value: String)? {
            guard i < args.count else { return nil }
            let a = args[i]
            if a.type == TSQueryPredicateStepTypeCapture {
                return (true, captureText(a.value_id) ?? "")
            } else {
                return (false, stringValue(a.value_id))
            }
        }

        switch op {
        case "eq?", "not-eq?":
            guard let a = arg(0), let b = arg(1) else { return true }
            let equal = a.value == b.value
            return op == "eq?" ? equal : !equal
        case "match?", "not-match?":
            guard let a = arg(0), let b = arg(1) else { return true }
            let matched = Self.regex(b.value)?.firstMatch(
                in: a.value, range: NSRange(a.value.startIndex..., in: a.value)) != nil
            return op == "match?" ? matched : !matched
        case "any-of?", "not-any-of?":
            guard let a = arg(0) else { return true }
            let options = (1..<args.count).compactMap { arg($0)?.value }
            let member = options.contains(a.value)
            return op == "any-of?" ? member : !member
        default:
            return true  // unknown predicate: don't filter
        }
    }

    /// Compiled `#match?` patterns, cached by pattern text.
    ///
    /// These were previously rebuilt on *every* predicate evaluation — i.e. per
    /// matching node, per file. Compiling an ICU regex is expensive and each one
    /// drags in a RegexPattern/BMPSet/UnicodeSet cluster, so a heap snapshot
    /// showed ~900 of them live at once. The patterns come from the grammar's
    /// query file, so the set is small and fixed for the life of the process.
    private static var regexCache: [String: NSRegularExpression] = [:]
    private static let regexCacheLock = NSLock()

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        regexCacheLock.lock()
        defer { regexCacheLock.unlock() }
        if let hit = regexCache[pattern] { return hit }
        guard let made = try? NSRegularExpression(pattern: pattern) else { return nil }
        regexCache[pattern] = made
        return made
    }

    // MARK: Capture name -> color

    /// Rebuilt on demand rather than stored: the colours differ per theme, and a
    /// theme change evicts every cached highlighter, so this is consulted only
    /// while compiling a query.
    private static var colorMap: [String: NSColor] { [
        "comment": Theme.comment,
        "keyword": Theme.syntaxKeyword,
        "string": Theme.syntaxString,
        "string.escape": Theme.cyan,
        "string.special": Theme.cyan,
        "string.special.key": Theme.red,
        "escape": Theme.cyan,
        "number": Theme.syntaxConstant,
        "boolean": Theme.syntaxConstant,
        "constant": Theme.syntaxConstant,
        "constant.builtin": Theme.syntaxConstant,
        "type": Theme.syntaxType,
        "type.builtin": Theme.syntaxType,
        "constructor": Theme.syntaxType,
        "function": Theme.syntaxFunction,
        "function.method": Theme.syntaxFunction,
        "function.builtin": Theme.syntaxFunction,
        "property": Theme.syntaxProperty,
        "attribute": Theme.yellow,
        "label": Theme.red,
        "tag": Theme.red,
        "variable.parameter": Theme.syntaxConstant,
        "variable.builtin": Theme.red,
        "operator": Theme.cyan,
        "punctuation": Theme.punct,
        "punctuation.bracket": Theme.punct,
        "punctuation.delimiter": Theme.punct,
        "punctuation.special": Theme.cyan,
        "text.title": Theme.yellow,
        "text.literal": Theme.syntaxString,
        "text.uri": Theme.blue,
        "text.reference": Theme.blue,
        // HTML / CSS / Swift additions
        "tag.error": Theme.red,
        "character": Theme.cyan,          // character.special
        "charset": Theme.syntaxKeyword,   // CSS at-rules read as keywords
        "import": Theme.syntaxKeyword,
        "keyframes": Theme.syntaxKeyword,
        "media": Theme.syntaxKeyword,
        "namespace": Theme.syntaxKeyword,
        "supports": Theme.syntaxKeyword,
    ] }

    static func color(for capture: String) -> NSColor? {
        // Try progressively shorter dotted prefixes.
        var name = capture
        while true {
            if let c = colorMap[name] { return c }
            guard let dot = name.range(of: ".", options: .backwards) else { return nil }
            name = String(name[..<dot.lowerBound])
        }
    }
}

/// Maps UTF-8 byte offsets to UTF-16 offsets, and back.
///
/// Only the characters outside ASCII are recorded — where each starts and
/// ends, and the UTF-16 count at its end — since between two of them both
/// counts move together. Source that is ASCII but for a few names and comments
/// costs a few entries, not a table as long as the text.
struct ByteMapper {
    /// Each non-ASCII character's first byte, in order.
    private var starts: [Int32] = []
    /// The byte just past it.
    private var ends: [Int32] = []
    /// The UTF-16 offset just past it.
    private var utf16Ends: [Int32] = []
    private let byteCount: Int

    init(bytes: UnsafeBufferPointer<UInt8>) {
        byteCount = bytes.count
        var byte = 0, utf16 = 0
        while byte < bytes.count {
            let lead = bytes[byte]
            if lead < 0x80 {
                byte += 1
                utf16 += 1
                continue
            }
            let width = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
            starts.append(Int32(byte))
            byte = min(byte + width, bytes.count)
            utf16 += width == 4 ? 2 : 1
            ends.append(Int32(byte))
            utf16Ends.append(Int32(utf16))
        }
    }

    init(text: String, utf8Count: Int) {
        var text = text
        self = text.withUTF8 { ByteMapper(bytes: $0) }
    }

    /// Nil for a byte inside a character rather than at its start.
    func utf16(forByte b: Int) -> Int? {
        guard b >= 0, b <= byteCount else { return nil }
        // The last non-ASCII character that starts before `b`.
        var low = 0, high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if Int(starts[mid]) < b { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return b }
        let end = Int(ends[low - 1])
        guard b >= end else { return nil }
        return Int(utf16Ends[low - 1]) + (b - end)
    }

    /// The character boundary at or before `b`, in UTF-16.
    func utf16(atOrBefore b: Int) -> Int {
        var b = min(max(b, 0), byteCount)
        while b > 0, utf16(forByte: b) == nil { b -= 1 }
        return utf16(forByte: b) ?? 0
    }

    /// The character boundary at or after `b`, in UTF-16.
    func utf16(atOrAfter b: Int) -> Int {
        var b = min(max(b, 0), byteCount)
        while b < byteCount, utf16(forByte: b) == nil { b += 1 }
        return utf16(forByte: b) ?? b
    }

    /// The byte where the character at UTF-16 offset `u` starts — for an
    /// offset inside a surrogate pair, where the pair starts.
    func byte(forUTF16 u: Int) -> Int {
        // The last non-ASCII character that ends at or before `u`.
        var low = 0, high = utf16Ends.count
        while low < high {
            let mid = (low + high) / 2
            if Int(utf16Ends[mid]) <= u { low = mid + 1 } else { high = mid }
        }
        let byte = low > 0 ? Int(ends[low - 1]) + (u - Int(utf16Ends[low - 1])) : u
        if low < starts.count { return min(byte, Int(starts[low]), byteCount) }
        return min(byte, byteCount)
    }
}

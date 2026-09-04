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
    private(set) var incrementalParseCount = 0
    private(set) var fullParseCount = 0
    private(set) var lastParseDuration: TimeInterval = 0

    func discardParseTree() {
        if let previousTree { ts_tree_delete(previousTree) }
        previousTree = nil
        previousBytes = []
        previousStorage = nil
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

    private func parse(bytes: UnsafeBufferPointer<UInt8>, cstr: UnsafePointer<CChar>,
                       storage: NSTextStorage) -> OpaquePointer? {
        if previousStorage !== storage { discardParseTree() }
        if let previousTree, previousBytes.elementsEqual(bytes) { return previousTree }
        let nextBytes = Array(bytes)
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
            incrementalParseCount += 1
        } else {
            fullParseCount += 1
        }
        let started = CFAbsoluteTimeGetCurrent()
        let tree = ts_parser_parse_string(parser, previousTree, cstr, UInt32(bytes.count))
        lastParseDuration = CFAbsoluteTimeGetCurrent() - started
        if let previousTree { ts_tree_delete(previousTree) }
        previousTree = tree
        previousBytes = tree == nil ? [] : nextBytes
        previousStorage = tree == nil ? nil : storage
        return tree
    }

    var treeDescriptionForTesting: String? {
        guard let previousTree, let string = ts_node_string(ts_tree_root_node(previousTree)) else { return nil }
        defer { free(string) }
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
    private var captureColors: [[NSColor?]] = []
    private var captureSpecificity: [[Int]] = []

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
                    captureColors.append(colors)
                    captureSpecificity.append(specificity)
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

    /// Parse `text` and paint colors onto `storage` over `fullRange`.
    /// Base font/foreground/paragraph are assumed already applied by the caller.
    @discardableResult
    func highlight(text: String, storage: NSTextStorage,
                   fullRange: NSRange) -> [JSXTagMatch] {
        let byteCount = text.utf8.count
        guard byteCount > 0, byteCount <= 500_000 else {
            discardParseTree()
            return []
        }
        var tagMatches: [JSXTagMatch] = []
        // Queries share the parser's UTF-8 buffer. Only the last parsed source
        // is retained, bounded by the highlighting limit, for the next edit.
        text.withCString { cstr in
            cstr.withMemoryRebound(to: UInt8.self, capacity: byteCount) { raw in
                let bytes = UnsafeBufferPointer(start: raw, count: byteCount)
                tagMatches = highlight(text: text, bytes: bytes, cstr: cstr,
                                       storage: storage, fullRange: fullRange)
            }
        }
        return tagMatches
    }

    private func highlight(text: String, bytes: UnsafeBufferPointer<UInt8>,
                           cstr: UnsafePointer<CChar>,
                           storage: NSTextStorage,
                           fullRange: NSRange) -> [JSXTagMatch] {
        let byteCount = bytes.count
        guard let tree = parse(bytes: bytes, cstr: cstr, storage: storage) else { return [] }
        let rootNode = ts_tree_root_node(tree)

        // byte-offset -> UTF-16 offset mapping (identity fast-path for ASCII).
        let mapper = ByteMapper(text: text, utf8Count: byteCount)
        let tagMatches = definition.name == "tsx"
            ? JSXTagMatcher.matches(in: rootNode, bytes: bytes, mapper: mapper)
            : []

        // Collect spans, then apply so the winning capture ends up on top.
        var spans: [(range: NSRange, color: NSColor, len: Int, spec: Int, rank: Int)] = []

        for (queryIndex, query) in queries.enumerated() {
            guard let cursor = ts_query_cursor_new() else { continue }
            defer { ts_query_cursor_delete(cursor) }
            ts_query_cursor_exec(cursor, query, rootNode)

            var match = TSQueryMatch()
            while ts_query_cursor_next_match(cursor, &match) {
                if !predicatesPass(query: query, match: match, bytes: bytes) { continue }
                let captures = UnsafeBufferPointer(start: match.captures, count: Int(match.capture_count))
                for cap in captures {
                    let node = cap.node
                    let startByte = Int(ts_node_start_byte(node))
                    let endByte = Int(ts_node_end_byte(node))
                    guard endByte > startByte else { continue }
                    let id = Int(cap.index)
                    guard id < captureColors[queryIndex].count,
                          let color = captureColors[queryIndex][id] else { continue }
                    guard let u0 = mapper.utf16(forByte: startByte),
                          let u1 = mapper.utf16(forByte: endByte) else { continue }
                    let r = NSRange(location: u0, length: u1 - u0)
                    if NSMaxRange(r) <= fullRange.length {
                        let spec = captureSpecificity[queryIndex][id]
                        let rank = queryIndex * 100_000 + Int(match.pattern_index)
                        spans.append((r, color, endByte - startByte, spec, rank))
                    }
                }
            }
        }

        // Apply so the winner lands last: largest range first; for equal ranges,
        // the more specific capture (then the later query pattern) wins.
        spans.sort { a, b in
            if a.len != b.len { return a.len > b.len }      // bigger first
            if a.spec != b.spec { return a.spec < b.spec }  // more specific later
            return a.rank < b.rank                          // later pattern later
        }
        storage.beginEditing()
        for span in spans {
            storage.addAttribute(.foregroundColor, value: span.color, range: span.range)
        }
        storage.endEditing()
        return tagMatches
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
        "string": Theme.green,
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
        "property": Theme.red,
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
        "text.literal": Theme.green,
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

/// Maps UTF-8 byte offsets to UTF-16 offsets. Identity for ASCII/BMP-ASCII text.
struct ByteMapper {
    private let identity: Bool
    /// A dense Int32 table is substantially smaller than a Swift Dictionary
    /// entry per Unicode scalar. Non-boundary byte positions remain `-1`.
    private var table: [Int32] = []

    init(text: String, utf8Count: Int) {
        // If UTF-8 length equals UTF-16 length, the text is pure ASCII and
        // byte offset == UTF-16 offset.
        if utf8Count == text.utf16.count {
            identity = true
            return
        }
        identity = false
        var byte = 0, u16 = 0
        table = [Int32](repeating: -1, count: utf8Count + 1)
        for scalar in text.unicodeScalars {
            table[byte] = Int32(u16)
            byte += UTF8.width(scalar)
            u16 += UTF16.width(scalar)
        }
        table[byte] = Int32(u16)
    }

    func utf16(forByte b: Int) -> Int? {
        if identity { return b }
        guard table.indices.contains(b), table[b] >= 0 else { return nil }
        return Int(table[b])
    }
}

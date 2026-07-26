import AppKit

/// Describes one supported language: its grammar and highlight queries.
struct LanguageDefinition {
    let name: String
    let language: OpaquePointer            // TSLanguage *
    let querySources: [String]             // one or more highlights.scm bodies
    let extensions: Set<String>
    let display: String
}

/// tree-sitter backed highlighter. Parses a document and applies One Dark
/// colors to an NSTextStorage, evaluating #eq?/#match?/#any-of? predicates.
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
        let queryFiles: [String]
        let makeLanguage: () -> OpaquePointer?
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
                     extensions: ["ts", "tsx", "mts", "cts", "js", "mjs", "cjs", "jsx"],
                     queryFiles: ["typescript.scm", "typescript_ecma.scm"],
                     makeLanguage: { tree_sitter_typescript() }),
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
    ]

    /// Materialised definitions, built on demand and cached by name.
    private static var loaded: [String: LanguageDefinition] = [:]

    /// The spec for an extension — cheap, touches no grammar.
    static func spec(forExtension ext: String) -> LanguageSpec? {
        let e = ext.lowercased()
        return specs.first { $0.extensions.contains(e) }
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

    /// Names of grammars currently materialised (for tests / diagnostics).
    static var loadedLanguageNames: [String] { loaded.keys.sorted() }

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

    private let parser: OpaquePointer
    private let definition: LanguageDefinition
    private var queries: [OpaquePointer] = []

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
                } else {
                    FileHandle.standardError.write(Data(
                        "puzzle: query compile failed for \(definition.name) at \(errOffset) (err \(errType.rawValue))\n".utf8))
                }
            }
        }
    }

    deinit {
        queries.forEach { ts_query_delete($0) }
        ts_parser_delete(parser)
    }

    var isUsable: Bool { !queries.isEmpty }

    // MARK: Highlighting

    /// Parse `text` and paint colors onto `storage` over `fullRange`.
    /// Base font/foreground/paragraph are assumed already applied by the caller.
    func highlight(text: String, storage: NSTextStorage, fullRange: NSRange) {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return }
        let parsed: OpaquePointer? = text.withCString { cstr in
            ts_parser_parse_string(parser, nil, cstr, UInt32(bytes.count))
        }
        guard let tree = parsed else { return }
        defer { ts_tree_delete(tree) }
        let rootNode = ts_tree_root_node(tree)

        // byte-offset -> UTF-16 offset mapping (identity fast-path for ASCII).
        let mapper = ByteMapper(text: text, utf8Count: bytes.count)

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
                    var nameLen: UInt32 = 0
                    guard let namePtr = ts_query_capture_name_for_id(query, cap.index, &nameLen) else { continue }
                    let capName = String(decoding: UnsafeBufferPointer(
                        start: UnsafeRawPointer(namePtr).assumingMemoryBound(to: UInt8.self),
                        count: Int(nameLen)), as: UTF8.self)
                    guard let color = Self.color(for: capName) else { continue }
                    guard let u0 = mapper.utf16(forByte: startByte),
                          let u1 = mapper.utf16(forByte: endByte) else { continue }
                    let r = NSRange(location: u0, length: u1 - u0)
                    if NSMaxRange(r) <= fullRange.length {
                        let spec = capName.reduce(0) { $1 == "." ? $0 + 1 : $0 }
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
    }

    // MARK: Predicate evaluation (#eq? #match? #any-of? and negations)

    private func predicatesPass(query: OpaquePointer, match: TSQueryMatch, bytes: [UInt8]) -> Bool {
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
            let matched = (try? NSRegularExpression(pattern: b.value))?.firstMatch(
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

    // MARK: Capture name -> color

    private static let colorMap: [String: NSColor] = [
        "comment": Theme.comment,
        "keyword": Theme.purple,
        "string": Theme.green,
        "string.escape": Theme.cyan,
        "string.special": Theme.cyan,
        "string.special.key": Theme.red,
        "escape": Theme.cyan,
        "number": Theme.orange,
        "boolean": Theme.orange,
        "constant": Theme.orange,
        "constant.builtin": Theme.orange,
        "type": Theme.yellow,
        "type.builtin": Theme.yellow,
        "constructor": Theme.yellow,
        "function": Theme.blue,
        "function.method": Theme.blue,
        "function.builtin": Theme.blue,
        "property": Theme.red,
        "attribute": Theme.orange,
        "label": Theme.red,
        "tag": Theme.red,
        "variable.parameter": Theme.orange,
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
        "charset": Theme.purple,          // CSS at-rules read as keywords
        "import": Theme.purple,
        "keyframes": Theme.purple,
        "media": Theme.purple,
        "namespace": Theme.purple,
        "supports": Theme.purple,
    ]

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
private struct ByteMapper {
    private let identity: Bool
    private var table: [Int: Int] = [:]

    init(text: String, utf8Count: Int) {
        // If UTF-8 length equals UTF-16 length, the text is pure ASCII and
        // byte offset == UTF-16 offset.
        if utf8Count == text.utf16.count {
            identity = true
            return
        }
        identity = false
        var byte = 0, u16 = 0
        table.reserveCapacity(text.unicodeScalars.count + 1)
        for scalar in text.unicodeScalars {
            table[byte] = u16
            byte += UTF8.width(scalar)
            u16 += UTF16.width(scalar)
        }
        table[byte] = u16
    }

    func utf16(forByte b: Int) -> Int? {
        if identity { return b }
        return table[b]
    }
}

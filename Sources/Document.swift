import AppKit

/// An open file's buffer. Shared between editor panes so the same file opened in
/// two panes edits one buffer (Zed behavior) while each pane keeps its own tabs.
final class Document {
    let url: URL
    let storage: NSTextStorage
    /// Cheap language *spec* — describes the language without loading its
    /// grammar. The heavy `LanguageDefinition` is materialised only when the
    /// document is actually highlighted.
    let languageSpec: SyntaxHighlighter.LanguageSpec?
    var isModified = false

    /// True when the file isn't displayable text (binary: images, archives,
    /// object files…). Such documents show a placeholder and are read-only.
    private(set) var isUnsupported = false

    /// A generated, read-only buffer (a git diff) rather than a file on disk.
    /// Never saved, and coloured by the diff painter instead of tree-sitter.
    private(set) var isVirtual = false

    /// Build an in-memory document (used for git diffs).
    init(virtualURL: URL, text: String) {
        self.url = virtualURL
        self.languageSpec = nil
        self.isVirtual = true
        storage = NSTextStorage(string: text)
        storage.setAttributes(Theme.textAttributes(color: Theme.foreground),
                              range: NSRange(location: 0, length: storage.length))
    }

    init(url: URL) {
        self.url = url
        self.languageSpec = SyntaxHighlighter.spec(forExtension: url.pathExtension)

        let data = (try? Data(contentsOf: url)) ?? Data()
        let text: String
        if let utf8 = String(data: data, encoding: .utf8), !Self.looksBinary(data) {
            text = utf8
        } else if let latin = String(data: data, encoding: .isoLatin1), !Self.looksBinary(data) {
            text = latin
        } else {
            isUnsupported = true
            text = Self.unsupportedMessage(for: url, byteCount: data.count)
        }
        storage = NSTextStorage(string: text)
        storage.setAttributes(Theme.textAttributes(color: Theme.foreground),
                              range: NSRange(location: 0, length: storage.length))
    }

    /// A NUL byte in the first 8 KB is the classic "this is binary" signal —
    /// it's what git and grep use, and no valid source file contains one.
    private static func looksBinary(_ data: Data) -> Bool {
        data.prefix(8192).contains(0)
    }

    private static func unsupportedMessage(for url: URL, byteCount: Int) -> String {
        let ext = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension.lowercased())"
        let size = ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
        return """
        Unsupported file type

        \(url.lastPathComponent)
        \(ext.isEmpty ? "No extension" : ext) · \(size)

        This file isn't text, so it can't be shown in the editor.
        """
    }

    var name: String { url.lastPathComponent }
    var text: String { storage.string }

    func save() throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        isModified = false
    }
}

/// Registry of open documents, keyed by URL.
final class DocumentStore {
    static let shared = DocumentStore()
    private var docs: [URL: Document] = [:]

    static let diffScheme = "puzzle-diff"

    func document(for url: URL) -> Document {
        if let existing = docs[url] { return existing }
        // A diff tab whose buffer was released must not be read from disk —
        // its URL is synthetic. Hand back an empty virtual doc instead.
        if url.scheme == Self.diffScheme {
            return setVirtualDocument(url: url, text: "No diff available.\n")
        }
        let doc = Document(url: url)
        docs[url] = doc
        HighlightService.shared.highlight(doc)
        return doc
    }

    /// Register (or replace) an in-memory document, e.g. a git diff. Replacing
    /// matters because re-clicking a file should show its *current* diff.
    @discardableResult
    func setVirtualDocument(url: URL, text: String) -> Document {
        let doc = Document(virtualURL: url, text: text)
        docs[url] = doc
        HighlightService.shared.highlight(doc)
        return doc
    }

    /// Drop a document once no pane has it open, and release any grammar that
    /// no remaining document needs (parser tables + compiled queries are large).
    func release(_ url: URL, stillOpen: Bool) {
        guard !stillOpen else { return }
        HighlightService.shared.cancelPending(for: url)
        docs.removeValue(forKey: url)
        let stillNeeded = Set(docs.values.compactMap { $0.languageSpec?.name })
        HighlightService.shared.evictUnused(keeping: stillNeeded)
    }

    /// Re-apply font / line-height settings to every open buffer.
    func reapplyDisplaySettings() {
        for doc in docs.values { HighlightService.shared.highlight(doc) }
    }
}

/// Applies tree-sitter highlighting to a document's storage, reusing one
/// highlighter (and parser) per language.
final class HighlightService {
    static let shared = HighlightService()
    private var cache: [String: SyntaxHighlighter] = [:]
    private var pending: [URL: DispatchWorkItem] = [:]
    private let maxBytes = 500_000

    private func highlighter(for lang: LanguageDefinition) -> SyntaxHighlighter? {
        if let hit = cache[lang.name] { return hit }
        guard let hl = SyntaxHighlighter(definition: lang), hl.isUsable else { return nil }
        cache[lang.name] = hl
        return hl
    }

    func highlight(_ doc: Document) {
        let storage = doc.storage
        // Generated diff buffers get the diff painter, not tree-sitter.
        if doc.isVirtual {
            DiffHighlighter.apply(to: storage)
            return
        }
        let full = NSRange(location: 0, length: storage.length)
        storage.setAttributes(Theme.textAttributes(color: Theme.foreground), range: full)

        // Check size and skip-conditions BEFORE materialising the grammar, so a
        // huge (or unsupported) file never pages in parser tables it won't use.
        guard let spec = doc.languageSpec, !doc.isUnsupported else { return }
        let text = storage.string
        guard text.utf8.count <= maxBytes,
              let lang = SyntaxHighlighter.definition(for: spec),
              let hl = highlighter(for: lang) else { return }
        hl.highlight(text: text, storage: storage, fullRange: full)
    }

    /// Release parsers/queries for languages nothing has open any more. Each
    /// cached `SyntaxHighlighter` holds a TSParser plus compiled TSQuery objects.
    func evictUnused(keeping languages: Set<String>) {
        for key in cache.keys where !languages.contains(key) { cache.removeValue(forKey: key) }
        SyntaxHighlighter.unloadDefinitions(keeping: languages)
    }

    /// Cancel any queued re-highlight for a document that's going away.
    func cancelPending(for url: URL) {
        pending[url]?.cancel()
        pending.removeValue(forKey: url)
    }

    /// Debounced re-highlight after edits.
    func scheduleHighlight(_ doc: Document) {
        pending[doc.url]?.cancel()
        let work = DispatchWorkItem { [weak self, weak doc] in
            guard let self, let doc else { return }
            self.highlight(doc)
            self.pending[doc.url] = nil
        }
        pending[doc.url] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }
}

import AppKit

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
        doc.refreshCodeBlocks()
        // Generated diff buffers get the diff painter, not tree-sitter.
        if doc.isVirtual {
            doc.updateJSXTagMatches([])
            doc.updateMarkdownPresentation(MarkdownPresentation())
            doc.diffBands = DiffHighlighter.apply(to: storage)
            doc.diffLineNumbers = DiffHighlighter.lineNumbers(in: storage.string)
            return
        }
        let full = NSRange(location: 0, length: storage.length)
        storage.setAttributes(Theme.textAttributes(color: Theme.foreground), range: full)

        // Check size and skip-conditions BEFORE materialising the grammar, so a
        // huge (or unsupported) file never pages in parser tables it won't use.
        guard let spec = doc.languageSpec, !doc.isUnsupported else {
            doc.updateJSXTagMatches([])
            doc.updateMarkdownPresentation(MarkdownPresentation())
            return
        }
        let text = storage.string
        guard text.utf8.count <= maxBytes else {
            cache[spec.name]?.discardParseTree()
            doc.updateJSXTagMatches([])
            doc.updateMarkdownPresentation(MarkdownPresentation())
            return
        }
        // The same limit, applied before the grammar runs at all: the syntax
        // highlighter parses Markdown with the very scanner that asserts, so
        // guarding only the live styler would leave the abort in place one
        // call earlier. Such a file is shown as plain text.
        if spec.name == "markdown",
           MarkdownSyntaxTree.containerDepth(of: storage.string)
            > MarkdownSyntaxTree.maxContainerDepth {
            cache[spec.name]?.discardParseTree()
            doc.updateJSXTagMatches([])
            doc.updateMarkdownPresentation(MarkdownPresentation())
            return
        }
        let tags: [JSXTagMatch]
        if let lang = SyntaxHighlighter.definition(for: spec),
           let hl = highlighter(for: lang) {
            tags = hl.highlight(text: text, storage: storage, fullRange: full)
        } else {
            tags = []
        }
        if spec.name == "markdown" {
            doc.updateMarkdownPresentation(
                MarkdownLiveStyler.apply(text: text, to: storage,
                                         documentURL: doc.url))
        } else {
            doc.updateMarkdownPresentation(MarkdownPresentation())
        }
        doc.updateJSXTagMatches(tags)
    }

    /// Memory pressure can discard incremental state without changing text.
    func discardParseTrees() {
        cache.values.forEach { $0.discardParseTree() }
    }

    /// Release parsers/queries for languages nothing has open any more.
    func evictUnused(keeping languages: Set<String>) {
        for key in cache.keys where !languages.contains(key) { cache.removeValue(forKey: key) }
        cache.values.forEach { $0.discardUnownedParseTree() }
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
        // Markdown is formatted in-place, so publish its visual syntax on the
        // next run-loop turn. Other grammars retain the typing debounce because
        // their full tree-sitter parse has no visible read/edit mode transition.
        let delay = doc.languageSpec?.name == "markdown" ? 0 : 0.18
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

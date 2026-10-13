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
        let plain = Theme.textAttributes(color: Theme.foreground)

        // Check size and skip-conditions BEFORE materialising the grammar, so a
        // huge (or unsupported) file never pages in parser tables it won't use.
        guard let spec = doc.languageSpec, !doc.isUnsupported else {
            storage.setAttributes(plain, range: full)
            doc.updateJSXTagMatches([])
            doc.updateMarkdownPresentation(MarkdownPresentation())
            return
        }
        let text = storage.string
        guard text.utf8.count <= maxBytes else {
            storage.setAttributes(plain, range: full)
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
            storage.setAttributes(plain, range: full)
            cache[spec.name]?.discardParseTree()
            doc.updateJSXTagMatches([])
            doc.updateMarkdownPresentation(MarkdownPresentation())
            return
        }
        // Painted on a copy, then written back only where it differs. Painting
        // the buffer itself rewrote every character's attributes on every
        // keystroke, and TextKit regenerated the glyphs and layout of the
        // whole document for it — the most of a second a keystroke took in a
        // long Markdown file. A copy no layout manager holds costs nothing to
        // paint.
        let painted = NSTextStorage(string: text)
        painted.setAttributes(plain, range: full)
        let tags: [JSXTagMatch]
        if let lang = SyntaxHighlighter.definition(for: spec),
           let hl = highlighter(for: lang) {
            tags = hl.highlight(text: text, storage: painted, fullRange: full,
                                parseOwner: storage)
        } else {
            tags = []
        }
        let presentation = spec.name == "markdown"
            ? MarkdownLiveStyler.apply(text: text, to: painted, documentURL: doc.url)
            : MarkdownPresentation()
        Self.copyAttributes(from: painted, to: storage)
        // Character edits shift or remove pane-local hidden ranges and metrics,
        // even when the newly parsed presentation is equal to the old one.
        doc.updateMarkdownPresentation(presentation, synchronize: spec.name == "markdown")
        doc.updateJSXTagMatches(tags)
    }

    func parseCountsForTesting(language: String) -> (full: Int, incremental: Int)? {
        cache[language].map { ($0.fullParseCount, $0.incrementalParseCount) }
    }

    /// Make `storage`'s attributes `painted`'s, setting only the runs that
    /// differ — so TextKit lays out again only where something changed.
    ///
    /// Compared through Core Foundation: bridging each run's attributes into
    /// a Swift dictionary, and back into one to compare, cost more than the
    /// painting did.
    static func copyAttributes(from painted: NSAttributedString, to storage: NSTextStorage) {
        let length = storage.length
        guard painted.length == length else { return }
        let wantedText = painted as CFAttributedString
        let currentText = storage as CFAttributedString
        var changes: [(range: NSRange, attributes: CFDictionary)] = []
        var location = 0
        while location < length {
            var wantedRun = CFRange(), currentRun = CFRange()
            let wanted = CFAttributedStringGetAttributes(wantedText, location, &wantedRun)
            let current = CFAttributedStringGetAttributes(currentText, location, &currentRun)
            let end = min(wantedRun.location + wantedRun.length,
                          currentRun.location + currentRun.length)
            if let wanted, !(current.map { CFEqual(wanted, $0) } ?? false) {
                if let last = changes.last, NSMaxRange(last.range) == location,
                   CFEqual(last.attributes, wanted) {
                    changes[changes.count - 1].range.length += end - location
                } else {
                    changes.append((NSRange(location: location, length: end - location), wanted))
                }
            }
            location = max(end, location + 1)
        }
        guard !changes.isEmpty else { return }
        storage.beginEditing()
        for change in changes {
            storage.setAttributes(change.attributes as? [NSAttributedString.Key: Any],
                                  range: change.range)
        }
        storage.endEditing()
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

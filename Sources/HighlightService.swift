import AppKit

/// Applies tree-sitter highlighting to a document's storage, reusing one
/// highlighter (and parser) per language.
///
/// Code is coloured a part at a time: what an edit changed, and whatever of
/// the document is still waiting — what is on screen first — in passes short
/// enough that nobody typing or scrolling waits on one. A long file's first
/// parse runs on another thread. Markdown is still restyled whole each pass.
final class HighlightService {
    static let shared = HighlightService()
    private var cache: [String: SyntaxHighlighter] = [:]
    private var pending: [URL: DispatchWorkItem] = [:]
    /// Documents whose first parse is running on another thread, with the
    /// number of the parse: one cancelled, or overtaken, is not adopted.
    private var detachedParses: [URL: Int] = [:]
    private var detachedParseCount = 0

    /// Markdown is restyled whole on every pass, so it keeps the limit all
    /// highlighting had while every pass coloured the whole document.
    static let markdownMaximumBytes = 500_000
    /// From this length a document's first parse runs on another thread: it
    /// costs a few tens of milliseconds by now, past what a frame can spare.
    static let detachedParseLength = 256 * 1024
    /// How many characters one pass colours, beyond whole lines — about a
    /// frame's work. Whatever is left waits for the next.
    static let passLength = 32 * 1024
    /// Between one pass and the next while a document is still being
    /// coloured: long enough that the run loop sleeps, and so draws, between.
    static let passInterval: TimeInterval = 0.008

    private(set) var passCountForTesting = 0
    private(set) var lastPaintedForTesting: [NSRange] = []

    private func highlighter(for lang: LanguageDefinition) -> SyntaxHighlighter? {
        if let hit = cache[lang.name] { return hit }
        guard let hl = SyntaxHighlighter(definition: lang), hl.isUsable else { return nil }
        cache[lang.name] = hl
        return hl
    }

    /// Colour all of `doc` again: it is new, its text was replaced, or what
    /// it is drawn with changed.
    func highlight(_ doc: Document) {
        doc.refreshCodeBlocks()
        doc.markUnhighlighted()
        paint(doc)
    }

    /// One pass: whatever `doc` has waiting, or as much of it as one pass
    /// takes, and another pass queued for the rest.
    private func paint(_ doc: Document) {
        let storage = doc.storage
        doc.refreshCodeBlocksIfEdited()
        // Generated diff buffers get the diff painter, not tree-sitter.
        if doc.isVirtual {
            doc.updateJSXTagMatches([])
            doc.updateMarkdownPresentation(MarkdownPresentation())
            doc.diffBands = DiffHighlighter.apply(to: storage)
            doc.diffLineNumbers = DiffHighlighter.lineNumbers(in: storage.string)
            return
        }

        // Check size and skip-conditions BEFORE materialising the grammar, so a
        // huge (or unsupported) file never pages in parser tables it won't use.
        // (No UTF-16 character is less than a byte of UTF-8.)
        guard let spec = doc.languageSpec, !doc.isUnsupported,
              storage.length <= SyntaxHighlighter.maximumBytes else {
            paintPlain(doc)
            return
        }
        if spec.name == "markdown" {
            paintMarkdown(doc)
            return
        }
        // Its first parse is on its way, and paints when it arrives.
        guard detachedParses[doc.url] == nil else { return }
        guard let lang = SyntaxHighlighter.definition(for: spec),
              let hl = highlighter(for: lang) else {
            paintPlain(doc)
            return
        }
        let text = storage.string
        if storage.length >= Self.detachedParseLength, !hl.holdsTree(for: storage) {
            let bytes = SyntaxHighlighter.utf8(text)
            if bytes.count <= SyntaxHighlighter.maximumBytes {
                parseDetached(doc, bytes: bytes, language: lang)
                return
            }
        }
        guard let parsed = hl.parse(text: text, owner: storage) else {
            paintPlain(doc)
            return
        }
        if let changed = parsed.changed {
            changed.forEach { doc.markUnhighlighted($0) }
        } else {
            doc.markUnhighlighted()
        }
        doc.updateJSXTagMatches(parsed.tagMatches)
        doc.updateMarkdownPresentation(MarkdownPresentation())

        let ranges = rangesToPaint(doc)
        passCountForTesting += 1
        lastPaintedForTesting = ranges
        if !ranges.isEmpty {
            Self.apply(hl.colours(in: ranges), over: ranges, to: storage)
            ranges.forEach { doc.markHighlighted($0) }
        }
        if !doc.unhighlighted.isEmpty { paintRest(of: doc) }
    }

    /// Too long, unsupported, or a language with no grammar: one colour.
    private func paintPlain(_ doc: Document) {
        let storage = doc.storage
        storage.setAttributes(Theme.textAttributes(color: Theme.foreground),
                              range: NSRange(location: 0, length: storage.length))
        if let hl = cache[doc.languageSpec?.name ?? ""], hl.holdsTree(for: storage) {
            hl.discardParseTree()
        }
        doc.updateJSXTagMatches([])
        doc.updateMarkdownPresentation(MarkdownPresentation())
        // Should it become code that is coloured, all of it is to be.
        doc.markUnhighlighted()
    }

    private func paintMarkdown(_ doc: Document) {
        let storage = doc.storage
        let full = NSRange(location: 0, length: storage.length)
        let plain = Theme.textAttributes(color: Theme.foreground)
        let text = storage.string
        // The same limit, applied before the grammar runs at all: the syntax
        // highlighter parses Markdown with the very scanner that asserts, so
        // guarding only the live styler would leave the abort in place one
        // call earlier. Such a file is shown as plain text.
        guard text.utf8.count <= Self.markdownMaximumBytes,
              MarkdownSyntaxTree.containerDepth(of: text)
                <= MarkdownSyntaxTree.maxContainerDepth else {
            paintPlain(doc)
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
        if let spec = doc.languageSpec,
           let lang = SyntaxHighlighter.definition(for: spec),
           let hl = highlighter(for: lang) {
            tags = hl.highlight(text: text, storage: painted, fullRange: full,
                                parseOwner: storage)
        } else {
            tags = []
        }
        let presentation = MarkdownLiveStyler.apply(text: text, to: painted, documentURL: doc.url)
        Self.copyAttributes(from: painted, to: storage)
        // Character edits shift or remove pane-local hidden ranges and metrics,
        // even when the newly parsed presentation is equal to the old one.
        doc.updateMarkdownPresentation(presentation, synchronize: true)
        doc.updateJSXTagMatches(tags)
        doc.markHighlighted(full)
    }

    /// What this pass colours, as whole lines: everything waiting, if that is
    /// little enough; otherwise what is waiting on screen, then onward from
    /// the screen, up to `passLength`.
    private func rangesToPaint(_ doc: Document) -> [NSRange] {
        let waiting = doc.unhighlighted
        guard !waiting.isEmpty else { return [] }
        var chosen = IndexSet()
        if waiting.count <= Self.passLength {
            chosen = waiting
        } else {
            let visible = visibleText(of: doc)
            chosen = waiting.intersection(visible)
            var room = Self.passLength - chosen.count
            let rest = waiting.subtracting(chosen)
            let from = visible.first ?? 0
            for part in [from..<Int.max, 0..<from] {
                for range in rest.rangeView(of: part) where room > 0 {
                    let take = range.lowerBound..<min(range.upperBound, range.lowerBound + room)
                    chosen.insert(integersIn: take)
                    room -= take.count
                }
            }
        }
        let text = doc.storage.mutableString
        var lines = IndexSet()
        for range in chosen.rangeView {
            let line = text.lineRange(for: NSRange(location: range.lowerBound,
                                                   length: range.count))
            lines.insert(integersIn: line.location..<NSMaxRange(line))
        }
        return lines.rangeView.map { NSRange(location: $0.lowerBound, length: $0.count) }
    }

    /// The characters `doc` shows in each window it is on screen in.
    private func visibleText(of doc: Document) -> IndexSet {
        var visible = IndexSet()
        for manager in doc.storage.layoutManagers {
            for container in manager.textContainers {
                guard let view = container.textView, view.window != nil else { continue }
                let rect = view.visibleRect.offsetBy(dx: -view.textContainerOrigin.x,
                                                     dy: -view.textContainerOrigin.y)
                let glyphs = manager.glyphRange(forBoundingRectWithoutAdditionalLayout: rect,
                                                in: container)
                let characters = manager.characterRange(forGlyphRange: glyphs,
                                                        actualGlyphRange: nil)
                if characters.length > 0 {
                    visible.insert(integersIn: characters.location..<NSMaxRange(characters))
                }
            }
        }
        return visible
    }

    /// Queue the next pass for what `doc` still has waiting.
    private func paintRest(of doc: Document) {
        pending[doc.url]?.cancel()
        let work = DispatchWorkItem { [weak self, weak doc] in
            guard let self, let doc else { return }
            self.pending[doc.url] = nil
            self.paint(doc)
        }
        pending[doc.url] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.passInterval, execute: work)
    }

    /// Parse a long document on another thread; colour it when the tree
    /// arrives, from whatever the text has become by then.
    private func parseDetached(_ doc: Document, bytes: [UInt8], language: LanguageDefinition) {
        detachedParseCount += 1
        let number = detachedParseCount
        let url = doc.url
        detachedParses[url] = number
        let grammar = language.language
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak doc] in
            let tree = SyntaxHighlighter.parseDetached(bytes, language: grammar)
            DispatchQueue.main.async {
                guard let self, self.detachedParses[url] == number else {
                    if let tree { ts_tree_delete(tree) }
                    return
                }
                self.detachedParses[url] = nil
                guard let doc, let tree, let spec = doc.languageSpec,
                      let lang = SyntaxHighlighter.definition(for: spec),
                      let hl = self.highlighter(for: lang) else {
                    if let tree { ts_tree_delete(tree) }
                    return
                }
                hl.adopt(tree, bytes: bytes, for: doc.storage)
                self.paint(doc)
            }
        }
    }

    func isParsingDetachedForTesting(_ url: URL) -> Bool { detachedParses[url] != nil }

    /// Give each of `ranges` the attributes `runs` describe — the plain ones
    /// where no run is — writing only where the storage differs, so TextKit
    /// lays out again only where something changed.
    static func apply(_ runs: [(range: NSRange, color: NSColor)], over ranges: [NSRange],
                      to storage: NSTextStorage) {
        let plain = Theme.textAttributes(color: Theme.foreground) as NSDictionary
        var byColour: [ObjectIdentifier: NSDictionary] = [:]
        func attributes(_ colour: NSColor) -> NSDictionary {
            let key = ObjectIdentifier(colour)
            if let hit = byColour[key] { return hit }
            let made = Theme.textAttributes(color: colour) as NSDictionary
            byColour[key] = made
            return made
        }
        let current = storage as CFAttributedString
        var changes: [(range: NSRange, attributes: NSDictionary)] = []
        func want(_ wanted: NSDictionary, from start: Int, to end: Int) {
            var location = start
            while location < end {
                var run = CFRange()
                let have = CFAttributedStringGetAttributes(current, location, &run)
                let stop = min(run.location + run.length, end)
                if !(have.map { CFEqual(wanted, $0) } ?? false) {
                    if let last = changes.last, NSMaxRange(last.range) == location,
                       last.attributes === wanted {
                        changes[changes.count - 1].range.length += stop - location
                    } else {
                        changes.append((NSRange(location: location, length: stop - location), wanted))
                    }
                }
                location = max(stop, location + 1)
            }
        }
        var next = 0
        for range in ranges {
            var location = range.location
            let end = min(NSMaxRange(range), storage.length)
            while next < runs.count, runs[next].range.location < end {
                let run = runs[next]
                if run.range.location > location {
                    want(plain, from: location, to: run.range.location)
                }
                want(attributes(run.color), from: run.range.location,
                     to: min(NSMaxRange(run.range), end))
                location = NSMaxRange(run.range)
                next += 1
            }
            if location < end { want(plain, from: location, to: end) }
        }
        guard !changes.isEmpty else { return }
        storage.beginEditing()
        for change in changes {
            storage.setAttributes(change.attributes as? [NSAttributedString.Key: Any],
                                  range: change.range)
        }
        storage.endEditing()
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
        detachedParses.removeValue(forKey: url)
    }

    /// Debounced re-highlight after edits: what they changed.
    func scheduleHighlight(_ doc: Document) {
        pending[doc.url]?.cancel()
        let work = DispatchWorkItem { [weak self, weak doc] in
            guard let self, let doc else { return }
            self.pending[doc.url] = nil
            self.paint(doc)
        }
        pending[doc.url] = work
        // Markdown is formatted in-place, so publish its visual syntax on the
        // next run-loop turn. Other grammars retain the typing debounce because
        // their full tree-sitter parse has no visible read/edit mode transition.
        let delay = doc.languageSpec?.name == "markdown" ? 0 : 0.18
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

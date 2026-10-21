import Foundation

/// Writes a project search's replacement into the files it found.
///
/// Every edit goes through the file's `Document`: an open tab shows it at once,
/// one ⌘Z in that file takes it back, and a buffer with unsaved edits is
/// replaced in as it stands rather than as the disk has it. The files are then
/// written the way leaving a tab writes one, which never overwrites a file that
/// changed on disk underneath an edit.
enum ProjectReplace {
    /// What the rows on screen were found with, and what each match becomes.
    struct Request {
        let query: String
        let options: SearchOptions
        let template: String
    }

    /// Why a file the search listed was left as it was.
    enum Skip: Equatable {
        /// Binary, too large or generated: the search would not read it now.
        case notText
        /// A preview, or a buffer laid out for display: writing it back would
        /// rewrite the whole file.
        case readOnly
        /// The line is no longer the one the search found.
        case changedSinceSearch
        /// Undo: the file was edited after the replace.
        case changedSinceReplace
        /// The file could not be written, so the buffer went back to the disk's.
        case notWritten
    }

    /// One file's part in a replace, kept so the panel can take it back.
    struct FileChange {
        let url: URL
        /// Ranges of the text as the replace left it, and what stood there.
        let undo: [Document.Edit]
        /// The text as the replace left it, by its length and hash: undoing
        /// into anything else would put old text in the wrong places.
        let length: Int
        let digest: Int
        /// The buffer that was edited, and its revision just after. While that
        /// buffer still stands at that revision, its own undo is the way back.
        weak var document: Document?
        let revision: Int
    }

    struct Outcome {
        /// Matches replaced — or, for an undo, put back.
        var replacements = 0
        var changes: [FileChange] = []
        var skipped: [(url: URL, reason: Skip)] = []
        /// Replaced in the buffer but not written: the file also changed on
        /// disk, and that is the tab's to settle, as for any edit.
        var unsaved: [URL] = []
        /// Every file whose text changed, in order.
        var touched: [URL] = []
    }

    /// Every match in each of `urls`.
    static func replaceAll(in urls: [URL], _ request: Request,
                           save: (Document) -> Bool) -> Outcome {
        var outcome = Outcome()
        guard let matcher = SearchMatcher(query: request.query, options: request.options)
        else { return outcome }
        for url in urls {
            apply(to: url, save: save, outcome: &outcome) { document in
                edits(in: document.text, matcher: matcher, template: request.template)
            }
        }
        return outcome
    }

    /// The match a result row stands for: the first on `line`, as long as the
    /// line still reads as `preview` did when the search found it. A line that
    /// moved or changed is left alone — replacing whatever now sits there
    /// would edit text nobody looked at.
    static func replace(line: Int, preview: String, in url: URL, _ request: Request,
                        save: (Document) -> Bool) -> Outcome {
        var outcome = Outcome()
        guard let matcher = SearchMatcher(query: request.query, options: request.options)
        else { return outcome }
        apply(to: url, save: save, outcome: &outcome) { document in
            let index = document.lineIndex
            guard line >= 1, line <= index.lineCount else { return nil }
            let whole = document.text
            let text = whole as NSString
            let start = index.start(ofLine: line)
            let next = line < index.lineCount ? index.start(ofLine: line + 1) - 1 : text.length
            let range = NSRange(location: start, length: max(0, next - start))
            let current = text.substring(with: range)
            guard isSearchable(range, in: text),
                  SearchViewController.searchPreview(current, query: request.query,
                                                     options: request.options) == preview,
                  let match = matcher.matches(in: whole, range: range).first
            else { return nil }
            return [Document.Edit(range: match.range, text: matcher.replacement(
                for: match, in: whole, template: request.template))]
        }
        return outcome
    }

    /// Take `changes` back, file by file. A file edited since is left as it is.
    static func undo(_ changes: [FileChange], save: (Document) -> Bool) -> Outcome {
        var outcome = Outcome()
        for change in changes {
            // Untouched since: the file's own history takes the step back, so
            // ⌘Z after this redoes the replace rather than undoing the undo.
            if let document = change.document, document.textRevision == change.revision,
               DocumentStore.shared.cachedDocument(forFileAt: change.url) === document,
               document.undoManager.canUndo {
                document.undoManager.undo()
                guard document.textRevision != change.revision else {
                    outcome.skipped.append((change.url, .changedSinceReplace))
                    continue
                }
                outcome.replacements += change.undo.count
                outcome.touched.append(change.url)
                if !save(document) { outcome.unsaved.append(change.url) }
                continue
            }
            // The buffer has gone — released, or reloaded — so the text itself
            // is the check that nothing has moved since.
            apply(to: change.url, save: save, outcome: &outcome,
                  stale: .changedSinceReplace) { document in
                guard document.storage.length == change.length,
                      document.text.hashValue == change.digest else { return nil }
                return change.undo
            }
        }
        return outcome
    }

    // MARK: - One file

    /// Find the buffer for `url`, make the edits `make` asks for in one undo
    /// step, and write the file. `make` answers nil when the text is no longer
    /// what the edits were meant for.
    private static func apply(to url: URL, save: (Document) -> Bool, outcome: inout Outcome,
                              stale: Skip = .changedSinceSearch,
                              make: (Document) -> [Document.Edit]?) {
        let found: (document: Document, isNew: Bool)
        switch editableDocument(at: url) {
        case .failure(let skip):
            outcome.skipped.append((url, skip.reason))
            return
        case .success(let value):
            found = value
        }
        let (document, isNew) = found
        guard let edits = make(document) else {
            outcome.skipped.append((url, stale))
            return
        }
        guard !edits.isEmpty else { return }
        let wasModified = document.isModified
        if isNew { DocumentStore.shared.adopt(document) }
        let undo = document.replace(edits)
        guard !undo.isEmpty else { return }
        if !save(document) {
            // Nowhere to see an unsaved edit: no tab, and nothing of the
            // user's in the buffer. Put the buffer back to the file rather than
            // keep a change only memory holds.
            if !wasModified, !DocumentStore.shared.isOpenInTab(document.url) {
                document.discardEditsAndReloadFromDisk()
                outcome.skipped.append((url, .notWritten))
                return
            }
            outcome.unsaved.append(url)
        }
        outcome.replacements += edits.count
        outcome.touched.append(url)
        outcome.changes.append(FileChange(
            url: url, undo: undo, length: document.storage.length,
            digest: document.text.hashValue, document: document,
            revision: document.textRevision))
    }

    private struct SkipError: Error { let reason: Skip }

    /// The buffer to edit: the one already held, brought up to date with the
    /// disk unless it holds edits of its own; otherwise one read now, which
    /// joins the store only if something is replaced in it.
    private static func editableDocument(at url: URL)
        -> Result<(Document, isNew: Bool), SkipError> {
        if let held = DocumentStore.shared.cachedDocument(forFileAt: url) {
            // Unsaved edits are the truth for a modified buffer — the search
            // read them, not the disk. A clean one answers to the disk.
            if !held.isModified {
                guard isSearchableOnDisk(url) else { return .failure(SkipError(reason: .notText)) }
                DocumentStore.shared.refreshFromDisk(held)
            }
            guard !held.isReadOnly, !held.isDisplayFormatted else {
                return .failure(SkipError(reason: .readOnly))
            }
            return .success((held, false))
        }
        guard isSearchableOnDisk(url) else { return .failure(SkipError(reason: .notText)) }
        let document = Document(url: url)
        guard !document.isReadOnly, !document.isDisplayFormatted else {
            return .failure(SkipError(reason: .readOnly))
        }
        return .success((document, true))
    }

    /// The files the search reads: text, under its size limit, not build
    /// output. Checked again here because the file may have changed since.
    static func isSearchableOnDisk(_ url: URL) -> Bool {
        guard SearchViewController.shouldLoadForNativeSearch(url),
              !SearchViewController.isGeneratedArtifact(url.lastPathComponent),
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 1024)) ?? Data()
        return !head.contains(0)
    }

    // MARK: - Matching

    /// Every match in `text`, line by line as the search reads it, so `^` and
    /// `$` mean the line's ends and nothing reaches across a newline. Lines
    /// the search passes over are passed over here too.
    static func edits(in text: String, matcher: SearchMatcher,
                      template: String) -> [Document.Edit] {
        let source = text as NSString
        var edits: [Document.Edit] = []
        var start = 0
        while start <= source.length {
            let newline = source.range(of: "\n", options: .literal,
                                       range: NSRange(location: start, length: source.length - start))
            let end = newline.location == NSNotFound ? source.length : newline.location
            let line = NSRange(location: start, length: end - start)
            if line.length > 0, isSearchable(line, in: source) {
                for match in matcher.matches(in: text, range: line) {
                    edits.append(Document.Edit(range: match.range, text: matcher.replacement(
                        for: match, in: text, template: template)))
                }
            }
            guard newline.location != NSNotFound else { break }
            start = end + 1
        }
        return edits
    }

    /// A line short enough for the search to have shown its matches.
    private static func isSearchable(_ line: NSRange, in text: NSString) -> Bool {
        // Counted in characters, as the search counts; UTF-16 units are an
        // upper bound that settles nearly every line without making a String.
        let limit = SearchViewController.maxSearchableLineLength
        return line.length <= limit || text.substring(with: line).count <= limit
    }
}

import AppKit

/// Registry of open documents, keyed by URL.
final class DocumentStore {
    static let shared = DocumentStore()
    private var docs: [URL: Document] = [:]
    /// Pane identities currently holding each URL as an open tab. This is
    /// process-wide, unlike a window's local pane list.
    private var owners: [URL: Set<ObjectIdentifier>] = [:]
    /// Least-recently-used first.
    private var order: [URL] = []

    static let diffScheme = "puzzle-diff"

    /// How many file buffers to keep in memory at once.
    ///
    /// Buffers cost roughly twice their text size and, once allocated, macOS's
    /// allocator never hands the pages back — phys_footprint is a high-water
    /// mark. Leaving every file ever opened in memory meant a long session only
    /// grew. Tabs stay open; their text is re-read from disk on return, which
    /// is far cheaper than the memory it saves.
    var maxCachedDocuments = 12
    /// Count alone is not enough: decoded images and large attributed buffers
    /// can make twelve documents enormous.
    var maxCachedBytes = 24 * 1024 * 1024

    /// Whether a buffer is currently held (tests / diagnostics).
    func documentIsCached(_ url: URL) -> Bool { docs[url] != nil }
    func cachedDocument(for url: URL) -> Document? { docs[url] }

    var cachedBytes: Int { docs.values.reduce(0) { $0 + $1.estimatedMemoryCost } }

    /// Immutable copies of current unsaved text inside a project. Project
    /// search runs off the main thread, so its worker must not read directly
    /// from `NSTextStorage`. Clean files need no copy because disk is current.
    func modifiedTextSnapshots(in directory: URL) -> [(url: URL, text: String)] {
        let root = directory.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return docs.values.compactMap { doc in
            guard doc.isModified, !doc.isReadOnly, doc.url.isFileURL,
                  doc.url.standardizedFileURL.path.hasPrefix(prefix) else { return nil }
            return (doc.url, doc.text)
        }
    }

    /// Reconcile cached documents touched by a coalesced FSEvents batch. An
    /// atomic writer often reports a temporary sibling plus a directory event,
    /// so files sharing that directory are considered candidates as well.
    @discardableResult
    func reloadExternalChanges(at changedURLs: [URL], observedAt: Date = Date()) -> [URL] {
        guard !changedURLs.isEmpty else { return [] }
        let changes = changedURLs.map { $0.standardizedFileURL }
        var reloaded: [URL] = []
        for document in docs.values {
            let file = document.url.standardizedFileURL
            let parent = file.deletingLastPathComponent()
            let affected = changes.contains { change in
                change == file || change == parent
                    || change.deletingLastPathComponent() == parent
                    || file.path.hasPrefix(change.path.hasSuffix("/")
                        ? change.path : change.path + "/")
            }
            guard affected, document.reloadFromDiskIfLatest(observedAt: observedAt) else {
                continue
            }
            HighlightService.shared.highlight(document)
            NotificationCenter.default.post(name: Document.didReloadFromDisk,
                                            object: document)
            reloaded.append(document.url)
        }
        return reloaded
    }

    func registerOpen(_ url: URL, owner: AnyObject) {
        owners[url, default: []].insert(ObjectIdentifier(owner))
    }

    func unregisterOpen(_ url: URL, owner: AnyObject) {
        let identifier = ObjectIdentifier(owner)
        owners[url]?.remove(identifier)
        if owners[url]?.isEmpty == true { owners.removeValue(forKey: url) }
        guard owners[url] == nil else { return }
        releaseUnowned(url)
    }

    func document(for url: URL) -> Document {
        if let existing = docs[url] { touch(url); return existing }
        // A diff tab whose buffer was released must not be read from disk — its
        // URL is synthetic. It is not lost either: the URL names the repository,
        // the path and, for history, the commit, which is everything the diff is
        // made of, so it is built again here.
        if url.scheme == Self.diffScheme {
            guard let content = virtualContentProvider?(url) else {
                return setVirtualDocument(url: url, text: "No diff available.\n",
                                          displayName: url.lastPathComponent + " (diff)")
            }
            let rebuilt = setVirtualDocument(url: url, text: content.text,
                                             displayName: content.displayName)
            // Without this the tab comes back read-only, because what makes a
            // diff editable is this pairing and not the text.
            if let source = content.editableSource {
                rebuilt.makeDiffEditable(directory: source.directory, path: source.path)
            }
            return rebuilt
        }
        let doc = Document(url: url)
        docs[url] = doc
        touch(url)
        HighlightService.shared.highlight(doc)
        // The caller has not attached its layout manager yet, so explicitly
        // protect the document it is about to display from evicting itself.
        evictIfNeeded(excluding: url)
        return doc
    }

    private func touch(_ url: URL) {
        order.removeAll { $0 == url }
        order.append(url)
    }

    /// Drop the least-recently-used buffers once over the cap.
    ///
    /// Three things are never evicted, and each would be a bug if it were:
    ///   * modified documents — the edits exist only in the buffer;
    ///   * virtual documents (git diffs) — synthetic URLs, nothing to re-read;
    ///   * documents whose storage is attached to a layout manager, i.e. the
    ///     buffer a pane is displaying right now.
    private func evictIfNeeded(excluding protectedURL: URL? = nil) {
        guard docs.count > maxCachedDocuments || cachedBytes > maxCachedBytes else { return }
        for url in order {
            guard docs.count > maxCachedDocuments || cachedBytes > maxCachedBytes else { break }
            guard url != protectedURL else { continue }
            guard let doc = docs[url] else { continue }
            guard !doc.isModified else { continue }
            guard !doc.isVirtual || isRegenerable(url) else { continue }
            guard doc.storage.layoutManagers.isEmpty else { continue }
            HighlightService.shared.cancelPending(for: url)
            docs.removeValue(forKey: url)
        }
        order = order.filter { docs[$0] != nil }
        let stillNeeded = Set(docs.values.compactMap { $0.languageSpec?.name })
        HighlightService.shared.evictUnused(keeping: stillNeeded)
    }

    /// Register (or replace) an in-memory document, e.g. a git diff. Replacing
    /// matters because re-clicking a file should show its *current* diff.
    /// What a synthetic URL stands for, rebuilt from the URL alone.
    struct VirtualContent {
        let text: String
        let displayName: String?
        /// Set for a working-tree diff, which is editable and replays into the
        /// file it describes. Nil for a commit diff, which is history.
        let editableSource: (directory: URL, path: String)?
    }

    /// Registered once at launch. Its presence is what allows a virtual buffer
    /// to be evicted at all: a buffer that cannot be rebuilt must not be
    /// dropped, because there is nowhere to read it back from.
    var virtualContentProvider: ((URL) -> VirtualContent?)?

    /// A synthetic buffer may be dropped only if it can be built again. An
    /// edited one never qualifies — the eviction rules keep every modified
    /// document, and an edited diff is the only copy of what the user typed.
    private func isRegenerable(_ url: URL) -> Bool {
        url.scheme == Self.diffScheme && virtualContentProvider != nil
    }

    @discardableResult
    func setVirtualDocument(url: URL, text: String, displayName: String? = nil) -> Document {
        if let existing = docs[url], existing.isVirtual {
            existing.replaceVirtualContent(text, displayName: displayName)
            touch(url)
            HighlightService.shared.highlight(existing)
            return existing
        }
        let doc = Document(virtualURL: url, text: text, displayName: displayName)
        docs[url] = doc
        touch(url)
        HighlightService.shared.highlight(doc)
        return doc
    }

    /// Drop a document once no pane has it open, and release any grammar that
    /// no remaining document needs (parser tables + compiled queries are large).
    func release(_ url: URL, stillOpen: Bool) {
        guard !stillOpen else { return }
        guard owners[url] == nil else { return }
        releaseUnowned(url)
    }

    private func releaseUnowned(_ url: URL) {
        guard docs[url]?.storage.layoutManagers.isEmpty ?? true else { return }
        HighlightService.shared.cancelPending(for: url)
        docs.removeValue(forKey: url)
        order.removeAll { $0 == url }
        let stillNeeded = Set(docs.values.compactMap { $0.languageSpec?.name })
        HighlightService.shared.evictUnused(keeping: stillNeeded)
    }

    /// Re-apply font / line-height settings to every open buffer.
    func reapplyDisplaySettings() {
        for doc in docs.values { HighlightService.shared.highlight(doc) }
    }

    /// Discard every clean, non-virtual buffer not currently displayed. Tabs
    /// retain their URLs and transparently reload these documents when selected.
    func releaseTransientMemory() {
        for (url, doc) in docs {
            guard !doc.isModified, doc.storage.layoutManagers.isEmpty,
                  !doc.isVirtual || isRegenerable(url) else { continue }
            HighlightService.shared.cancelPending(for: url)
            docs.removeValue(forKey: url)
        }
        order = order.filter { docs[$0] != nil }
        HighlightService.shared.discardParseTrees()
        let stillNeeded = Set(docs.values.compactMap { $0.languageSpec?.name })
        HighlightService.shared.evictUnused(keeping: stillNeeded)
    }
}

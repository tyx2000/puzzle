import AppKit

/// One editor pane: its own tab strip + text view + gutter. Panes are
/// independent (own tabs) but share document buffers via DocumentStore.
final class EditorPaneViewController: NSViewController, NSTextViewDelegate {
    var onActiveDocumentChanged: ((URL?) -> Void)?
    var onRequestSplit: (() -> Void)?
    var onBecameActive: ((EditorPaneViewController) -> Void)?
    var onEmptied: ((EditorPaneViewController) -> Void)?
    var onDocumentEdited: (() -> Void)?
    var onDocumentSaved: ((URL) -> Void)?
    var onTabOpened: ((URL) -> Void)?
    /// A tab was closed here. The container decides whether the buffer is still
    /// open elsewhere before releasing it — a pane can't see its siblings.
    var onTabClosed: ((URL) -> Void)?
    /// The markdown preview appeared or disappeared in this pane.
    var onPreviewVisibilityChanged: (() -> Void)?
    var onTabBarHeightChanged: ((CGFloat) -> Void)?
    /// Supplied by the editor container for synthetic file-history tabs.
    var fileHistoryProvider: ((URL) -> FileHistoryModel?)?

    private(set) var openURLs: [URL] = []
    private var activeIndex: Int?
    private var selections: [URL: NSRange] = [:]
    private var lineActivatedURLs: Set<URL> = []
    private var suppressSelectionSideEffects = false
    private var definitionNavigationGeneration = 0

    private let tabBar = EditorTabBar()
    private var scrollView: NSScrollView!
    private var textView: PuzzleTextView!
    private var layoutManager = FoldingLayoutManager()
    /// Empty storage used when the pane has no open file.
    private let blankStorage = NSTextStorage()

    var currentURL: URL? { activeIndex.flatMap { openURLs.indices.contains($0) ? openURLs[$0] : nil } }
    private var currentDocument: Document? { currentURL.map { DocumentStore.shared.document(for: $0) } }

    /// Highlight the tab strip when this pane has focus.
    var isActivePane = false { didSet { tabBar.paneActive = isActivePane } }

    private let findBar = FindBarView()
    private var findBarHeight: NSLayoutConstraint!
    /// Shown instead of the text view when the active document is a picture.
    private var imagePreview: ImagePreviewView?
    /// Shown instead of the text view for a file-history table tab.
    private var fileHistoryView: FileHistoryView?

    /// Live markdown preview, shown to the right of the source.
    private var markdownPreview: MarkdownPreviewView?
    /// Editor trailing edge: to the window edge, or to the preview's leading.
    private var editorTrailingFull: NSLayoutConstraint!
    private var editorTrailingSplit: NSLayoutConstraint?
    /// Remembered per file so toggling tabs doesn't lose the preview state.
    private var previewEnabled: Set<URL> = []
    /// Fold identities are pane-local, but survive switching between tabs.
    private var foldedBlocks: [URL: Set<Int>] = [:]

    var isPreviewVisible: Bool { markdownPreview.map { !$0.isHidden } ?? false }

    override func loadView() {
        let container = FlatView()
        container.fillColor = Theme.editorBackground

        blankStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        textView = PuzzleTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400),
                                  textContainer: textContainer)
        textView.isEditable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = Theme.editorFont()
        textView.backgroundColor = Theme.editorBackground
        textView.insertionPointColor = Theme.cursor
        textView.selectedTextAttributes = [.backgroundColor: Theme.selection]
        textView.textContainerInset = NSSize(width: 6, height: 8)
        // Required for the text view to grow with content (otherwise no scrolling).
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.delegate = self
        textView.onExplicitCaretInteraction = { [weak self] in
            guard let self, let url = self.currentURL else { return }
            self.lineActivatedURLs.insert(url)
            self.textView.showsCurrentLineBand = true
        }
        textView.onCommandClick = { [weak self] location in
            self?.navigateToDefinition(at: location) ?? false
        }
        // Custom find bar (the system one can't be restyled and shows a focus ring).
        textView.usesFindBar = false
        textView.typingAttributes = Theme.textAttributes(color: Theme.foreground)
        // Nothing open yet — no current-line band in the empty area.
        textView.showsCurrentLineBand = false
        NotificationCenter.default.addObserver(
            self, selector: #selector(documentStructureChanged(_:)),
            name: Document.structureDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(documentReloadedFromDisk(_:)),
            name: Document.didReloadFromDisk, object: nil)

        scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.hasVerticalRuler = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.editorBackground
        scrollView.verticalRulerView = LineNumberRulerView(textView: textView)
        scrollView.rulersVisible = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.onSelect = { [weak self] in self?.activate(index: $0) }
        tabBar.onClose = { [weak self] in self?.close(index: $0) }
        tabBar.onCloseOthers = { [weak self] in self?.closeOtherTabs(around: $0) }
        tabBar.onCloseRight = { [weak self] in self?.closeTabsToTheRight(of: $0) }
        tabBar.onSplit = { [weak self] in self?.onRequestSplit?() }
        tabBar.onTogglePreview = { [weak self] in self?.toggleMarkdownPreview() }
        tabBar.onHeightChanged = { [weak self] height in
            self?.onTabBarHeightChanged?(height)
        }

        container.addSubview(tabBar)
        container.addSubview(scrollView)
        findBar.translatesAutoresizingMaskIntoConstraints = false
        findBar.isHidden = true
        findBar.onClose = { [weak self] in self?.hideFindBar() }
        container.addSubview(findBar)

        findBarHeight = findBar.heightAnchor.constraint(equalToConstant: 0)
        editorTrailingFull = scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        editorTrailingFull.isActive = true

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: container.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            findBar.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            findBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            findBarHeight,

            // Height follows the pills (grows when tabs wrap to a second row).
            scrollView.topAnchor.constraint(equalTo: findBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        self.view = container
        reloadTabs()
    }

    private func ensureImagePreview() -> ImagePreviewView {
        if let imagePreview { return imagePreview }
        let preview = ImagePreviewView()
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.isHidden = true
        view.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: findBar.bottomAnchor),
            preview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            preview.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        imagePreview = preview
        return preview
    }

    private func ensureMarkdownPreview() -> MarkdownPreviewView {
        if let markdownPreview { return markdownPreview }
        let preview = MarkdownPreviewView()
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.isHidden = true
        view.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: findBar.bottomAnchor),
            preview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            preview.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            preview.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.5),
        ])
        editorTrailingSplit = scrollView.trailingAnchor.constraint(equalTo: preview.leadingAnchor)
        markdownPreview = preview
        return preview
    }

    private func ensureFileHistoryView() -> FileHistoryView {
        if let fileHistoryView { return fileHistoryView }
        let history = FileHistoryView()
        history.translatesAutoresizingMaskIntoConstraints = false
        history.isHidden = true
        view.addSubview(history)
        NSLayoutConstraint.activate([
            history.topAnchor.constraint(equalTo: findBar.bottomAnchor),
            history.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            history.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            history.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        fileHistoryView = history
        return history
    }

    // MARK: - Find bar

    func showFindBar(seed: String? = nil) {
        findBar.isHidden = false
        findBarHeight.constant = 42
        findBar.attach(to: textView)
        if let seed { findBar.setQuery(seed) }
        findBar.focus()
    }

    func hideFindBar() {
        findBar.clearHighlights()
        findBar.isHidden = true
        findBarHeight.constant = 0
        view.window?.makeFirstResponder(textView)
    }

    var isFindBarVisible: Bool { !findBar.isHidden }

    // MARK: - Tabs / documents

    func open(url: URL, replacingContent: Bool = false) {
        if let existing = openURLs.firstIndex(of: url) {
            // The document behind this URL may have been swapped (a refreshed
            // git diff), so rebind the layout manager rather than just selecting.
            if replacingContent { rebindStorage(for: url) }
            activate(index: existing); return
        }
        openURLs.append(url)
        onTabOpened?(url)
        activate(index: openURLs.count - 1)
    }

    func pathRenamed(from oldBase: URL, to newBase: URL) {
        let oldPath = oldBase.standardizedFileURL.path
        let oldPrefix = oldPath.hasSuffix("/") ? oldPath : oldPath + "/"
        var replacements: [(index: Int, old: URL, new: URL)] = []
        for (index, url) in openURLs.enumerated() {
            let path = url.standardizedFileURL.path
            if path == oldPath {
                replacements.append((index, url, newBase))
            } else if path.hasPrefix(oldPrefix) {
                let suffix = String(path.dropFirst(oldPrefix.count))
                replacements.append((index, url, newBase.appendingPathComponent(suffix)))
            }
        }
        guard !replacements.isEmpty else { return }

        let activeWasReplaced = replacements.contains { $0.index == activeIndex }
        if activeWasReplaced { detachFromDocument() }
        for replacement in replacements {
            moveState(from: replacement.old, to: replacement.new)
            onTabClosed?(replacement.old)
            openURLs[replacement.index] = replacement.new
            onTabOpened?(replacement.new)
        }
        invalidateBlame()
        if activeWasReplaced, let activeIndex {
            activate(index: activeIndex)
        } else {
            reloadTabs()
        }
    }

    func pathDeleted(_ base: URL) {
        let path = base.standardizedFileURL.path
        let prefix = path.hasSuffix("/") ? path : path + "/"
        let matching = openURLs.indices.filter {
            let candidate = openURLs[$0].standardizedFileURL.path
            return candidate == path || candidate.hasPrefix(prefix)
        }
        for index in matching.reversed() { close(index: index) }
    }

    private func moveState(from oldURL: URL, to newURL: URL) {
        if let value = selections.removeValue(forKey: oldURL) { selections[newURL] = value }
        if lineActivatedURLs.remove(oldURL) != nil { lineActivatedURLs.insert(newURL) }
        if previewEnabled.remove(oldURL) != nil { previewEnabled.insert(newURL) }
        if let value = foldedBlocks.removeValue(forKey: oldURL) { foldedBlocks[newURL] = value }
    }

    /// Point this pane's layout manager at the (possibly new) storage for `url`.
    private func rebindStorage(for url: URL) {
        let doc = DocumentStore.shared.document(for: url)
        if layoutManager.textStorage !== doc.storage {
            layoutManager.textStorage?.removeLayoutManager(layoutManager)
            doc.storage.addLayoutManager(layoutManager)
        }
    }

    func activate(index: Int) {
        guard openURLs.indices.contains(index) else { return }
        // Remember where the caret was in the outgoing document.
        if let prev = currentURL {
            selections[prev] = textView.selectedRange()
            foldedBlocks[prev] = layoutManager.foldedBlockIdentities
        }

        activeIndex = index
        let url = openURLs[index]
        let doc = DocumentStore.shared.document(for: url)

        // Move this pane's layout manager onto the document's storage.
        if layoutManager.textStorage !== doc.storage {
            layoutManager.textStorage?.removeLayoutManager(layoutManager)
            doc.storage.addLayoutManager(layoutManager)
        }

        let length = doc.storage.length
        let caret = NSRange(location: min(selections[url]?.location ?? 0, length), length: 0)
        suppressSelectionSideEffects = true
        textView.setSelectedRange(caret)
        suppressSelectionSideEffects = false
        textView.updateJSXTagMatches(doc.jsxTagMatches)
        textView.refreshBracketMatches()
        textView.scrollRangeToVisible(caret)
        textView.typingAttributes = Theme.textAttributes(color: Theme.foreground)
        // Binary files show a placeholder and must not be editable — typing into
        // one and saving would destroy the file.
        // Diffs and binaries are read-only.
        textView.isEditable = !doc.isReadOnly
        let lineIsActive = lineActivatedURLs.contains(url)
        textView.showsCurrentLineBand = lineIsActive
        if !lineIsActive { clearInlineBlameRequest() }
        textView.diffBands = doc.diffBands
        textView.updateCodeBlocks(doc.codeBlocks, resetFolds: false)
        layoutManager.restoreFoldedBlockIdentities(foldedBlocks[url] ?? [])

        // Synthetic file-history tabs use a real four-column table. Keep this
        // check ahead of images/text so only one primary content view is shown.
        if let historyModel = fileHistoryProvider?(url) {
            let history = ensureFileHistoryView()
            history.configure(historyModel)
            history.isHidden = false
            imagePreview?.clear()
            imagePreview?.isHidden = true
            scrollView.isHidden = true
        } else if let image = doc.image {
            fileHistoryView?.isHidden = true
            let imagePreview = ensureImagePreview()
            imagePreview.show(image: image, caption: doc.text)
            imagePreview.isHidden = false
            scrollView.isHidden = true
        } else {
            fileHistoryView?.isHidden = true
            imagePreview?.clear()
            imagePreview?.isHidden = true
            scrollView.isHidden = false
        }

        syncMarkdownPreview(for: doc, url: url, rerender: true)

        reloadTabs()
        scrollView.verticalRulerView?.needsDisplay = true
        textView.needsDisplay = true
        onActiveDocumentChanged?(url)
        onBecameActive?(self)
        if lineIsActive { scheduleInlineBlame() }
    }

    func close(index: Int) {
        guard openURLs.indices.contains(index) else { return }
        let url = openURLs[index]
        guard confirmClose(urls: [url]) else { return }
        openURLs.remove(at: index)
        selections.removeValue(forKey: url)
        lineActivatedURLs.remove(url)
        previewEnabled.remove(url)
        foldedBlocks.removeValue(forKey: url)
        defer { onTabClosed?(url) }
        if openURLs.isEmpty {
            activeIndex = nil
            markdownPreview?.clearContent()
            markdownPreview?.isHidden = true
            editorTrailingSplit?.isActive = false
            editorTrailingFull.isActive = true
            tabBar.showsPreviewToggle = false
            layoutManager.textStorage?.removeLayoutManager(layoutManager)
            blankStorage.addLayoutManager(layoutManager)
            // No document: don't paint a current-line band in the empty area.
            textView.showsCurrentLineBand = false
            textView.updateCodeBlocks([], resetFolds: false)
            textView.updateJSXTagMatches([])
            imagePreview?.clear()
            imagePreview?.isHidden = true
            fileHistoryView?.isHidden = true
            scrollView.isHidden = false
            reloadTabs()
            onActiveDocumentChanged?(nil)
            onEmptied?(self)
            return
        }
        activate(index: min(index, openURLs.count - 1))
    }

    // MARK: - Markdown preview

    /// Whether a document can be previewed at all. Diffs and binaries can't:
    /// a diff is not markdown even when it patches a .md file.
    private func isPreviewable(_ doc: Document) -> Bool {
        doc.languageSpec?.name == "markdown" && !doc.isVirtual && !doc.isUnsupported
            && doc.image == nil && doc.storage.length <= MarkdownPreviewView.maxSourceCharacters
    }

    func toggleMarkdownPreview() {
        guard let url = currentURL else { return }
        let doc = DocumentStore.shared.document(for: url)
        guard isPreviewable(doc) else { return }
        if previewEnabled.contains(url) {
            previewEnabled.remove(url)
        } else {
            previewEnabled.insert(url)
        }
        syncMarkdownPreview(for: doc, url: url, rerender: true)
    }

    /// Bring the preview in line with the active document: hide it entirely for
    /// non-markdown, otherwise show it if this file had it turned on.
    private func syncMarkdownPreview(for doc: Document, url: URL, rerender: Bool) {
        let previewable = isPreviewable(doc)
        tabBar.showsPreviewToggle = previewable

        let shouldShow = previewable && previewEnabled.contains(url) && doc.image == nil
        tabBar.previewActive = shouldShow

        if !shouldShow {
            let wasVisible = markdownPreview.map { !$0.isHidden } ?? false
            markdownPreview?.clearContent()
            markdownPreview?.isHidden = true
            editorTrailingSplit?.isActive = false
            editorTrailingFull.isActive = true
            if wasVisible { onPreviewVisibilityChanged?() }
            return
        }

        let markdownPreview = ensureMarkdownPreview()
        let wasHidden = markdownPreview.isHidden
        markdownPreview.isHidden = false
        editorTrailingFull.isActive = false
        editorTrailingSplit?.isActive = true
        // Switching files must repaint now, not after the typing debounce.
        if rerender { markdownPreview.update(source: doc.text, immediately: true) }
        if wasHidden { onPreviewVisibilityChanged?() }
    }

    /// Close every tab except `index`.
    func closeOtherTabs(around index: Int) {
        guard openURLs.indices.contains(index) else { return }
        closeTabs(openURLs.indices.filter { $0 != index }, anchor: index)
    }

    /// Close the tabs sitting after `index`.
    func closeTabsToTheRight(of index: Int) {
        guard openURLs.indices.contains(index) else { return }
        closeTabs(Array(openURLs.indices.dropFirst(index + 1)), anchor: index)
    }

    /// Remove a batch of tabs in one pass, leaving `anchor` active.
    ///
    /// Deliberately not a loop over `close(index:)`: that reactivates (and so
    /// re-lays-out and re-highlights) a document per removed tab, and every
    /// removal shifts the indices the caller computed.
    private func closeTabs(_ doomed: [Int], anchor: Int) {
        guard !doomed.isEmpty, openURLs.indices.contains(anchor) else { return }
        let anchorURL = openURLs[anchor]
        let doomedSet = Set(doomed)
        let closed = doomed.compactMap { openURLs.indices.contains($0) ? openURLs[$0] : nil }
        guard confirmClose(urls: closed) else { return }
        closed.forEach {
            selections.removeValue(forKey: $0)
            lineActivatedURLs.remove($0)
            previewEnabled.remove($0)
            foldedBlocks.removeValue(forKey: $0)
        }
        defer { closed.forEach { onTabClosed?($0) } }
        openURLs = openURLs.enumerated()
            .filter { !doomedSet.contains($0.offset) }
            .map { $0.element }
        guard let kept = openURLs.firstIndex(of: anchorURL) else { return }
        activate(index: kept)
    }

    func save() {
        guard let doc = currentDocument, !doc.isReadOnly else { return }
        persist(doc, notify: true, presentErrors: true)
    }

    @discardableResult
    private func persist(_ document: Document, notify: Bool,
                         presentErrors: Bool) -> Bool {
        guard document.isModified, !document.isReadOnly else { return true }
        do {
            try document.save()
            reloadTabs()
            if notify { onDocumentSaved?(document.url) }
            return true
        } catch {
            if presentErrors { self.presentError(error) }
            return false
        }
    }


    /// Ask about all modified documents before mutating tab ownership. A
    /// successful save is the only choice that clears the modified marker;
    /// choosing Don't Save lets DocumentStore discard the buffer once its last
    /// pane unregisters it.
    func confirmClose(urls: [URL]) -> Bool {
        var seen = Set<URL>()
        for url in urls where seen.insert(url).inserted {
            guard let document = DocumentStore.shared.cachedDocument(for: url),
                  document.isModified, !document.isReadOnly else { continue }

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Save changes to “\(document.name)”?"
            alert.informativeText = "File:\n\(document.url.path)\n\nSave writes the current editor contents to this file. Don’t Save closes the tab and permanently discards the unsaved editor contents. Cancel leaves the tab open."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Don’t Save")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                guard persist(document, notify: true, presentErrors: true) else { return false }
            case .alertSecondButtonReturn:
                continue
            default:
                return false
            }
        }
        return true
    }

    func jumpToLine(_ line: Int) {
        let ns = textView.string as NSString
        var current = 1, location = 0
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: .byLines) { _, range, _, stop in
            if current == line { location = range.location; stop.pointee = true }
            current += 1
        }
        let target = NSRange(location: min(location, ns.length), length: 0)
        if let url = currentURL { lineActivatedURLs.insert(url) }
        textView.showsCurrentLineBand = true
        textView.setSelectedRange(target)
        textView.scrollRangeToVisible(target)
        view.window?.makeFirstResponder(textView)
        scheduleInlineBlame()
    }

    @discardableResult
    private func navigateToDefinition(at location: Int) -> Bool {
        guard let sourceURL = currentURL,
              sourceURL.isFileURL,
              let root = repositoryRoot,
              let document = currentDocument,
              !document.isVirtual, !document.isUnsupported, document.image == nil else {
            return false
        }
        let source = textView.string
        guard DefinitionNavigator.hasNavigableToken(in: source,
                                                     utf16Location: location) else {
            return false
        }
        definitionNavigationGeneration += 1
        let generation = definitionNavigationGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let destination = DefinitionNavigator.resolve(
                text: source, sourceURL: sourceURL, projectRoot: root,
                utf16Location: location)
            DispatchQueue.main.async {
                guard let self, self.definitionNavigationGeneration == generation else { return }
                guard let destination else {
                    NSSound.beep()
                    return
                }
                self.open(url: destination.url)
                guard self.currentURL == destination.url else { return }
                let length = self.textView.string.utf16.count
                let target = NSRange(location: min(destination.utf16Location, length), length: 0)
                self.selections[destination.url] = target
                self.lineActivatedURLs.insert(destination.url)
                self.textView.showsCurrentLineBand = true
                self.suppressSelectionSideEffects = true
                self.textView.setSelectedRange(target)
                self.suppressSelectionSideEffects = false
                self.textView.scrollRangeToVisible(target)
                self.view.window?.makeFirstResponder(self.textView)
                self.scheduleInlineBlame()
            }
        }
        return true
    }

    /// Detach this pane's layout manager from whatever buffer it shows.
    ///
    /// `NSTextStorage` retains its layout managers, so without this a closed
    /// pane leaves its layout manager attached to the document — leaking it,
    /// and pinning that document against eviction forever.
    func detachFromDocument() {
        layoutManager.textStorage?.removeLayoutManager(layoutManager)
        blankStorage.addLayoutManager(layoutManager)
    }

    /// Tear down asynchronous/cached state and surrender this pane's tab
    /// ownership. Callers must run confirmClose(urls:) first.
    func prepareForClose() {
        blameGeneration += 1
        blameWork?.cancel()
        blameWork = nil
        blameCache.removeAll()
        blameOrder.removeAll()
        markdownPreview?.clearContent()
        imagePreview?.clear()
        textView.updateCodeBlocks([], resetFolds: false)
        textView.updateJSXTagMatches([])
        detachFromDocument()
        let urls = openURLs
        openURLs.removeAll()
        activeIndex = nil
        selections.removeAll()
        lineActivatedURLs.removeAll()
        previewEnabled.removeAll()
        foldedBlocks.removeAll()
        urls.forEach { onTabClosed?($0) }
    }

    /// Release view-owned payloads that are not currently visible. Documents
    /// themselves are handled separately by `DocumentStore`.
    func releaseTransientMemory() {
        if imagePreview?.isHidden != false { imagePreview?.clear() }
        if markdownPreview?.isHidden != false { markdownPreview?.clearContent() }
        if findBar.isHidden { findBar.clearHighlights() }
    }

    /// Re-apply font / line metrics after settings change.
    func refreshDisplay() {
        for url in openURLs {
            HighlightService.shared.highlight(DocumentStore.shared.document(for: url))
        }
        textView.font = Theme.editorFont()
        textView.typingAttributes = Theme.textAttributes(color: Theme.foreground)
        textView.needsDisplay = true
        scrollView.verticalRulerView?.needsDisplay = true
        reloadTabs()
    }

    func reloadTabs() {
        let infos = openURLs.map { url -> EditorTabBar.TabInfo in
            let doc = DocumentStore.shared.document(for: url)
            let title = doc.displayName
                ?? (doc.isVirtual ? "\(url.lastPathComponent) (diff)" : url.lastPathComponent)
            let path = tabPath(for: url, doc: doc, fallback: title)
            return EditorTabBar.TabInfo(title: title, modified: doc.isModified, path: path)
        }
        tabBar.reload(tabs: infos, active: activeIndex ?? -1)
    }

    /// Full file path for the tab tooltip. Diff previews live behind synthetic
    /// URLs, so their real path is reconstructed from the URL query.
    private func tabPath(for url: URL, doc: Document, fallback: String) -> String {
        if !doc.isVirtual { return url.path }
        guard url.scheme == DocumentStore.diffScheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let relative = components.queryItems?.first(where: { $0.name == "path" })?.value,
              !relative.isEmpty else { return fallback }
        let directory = (url.path as NSString).deletingLastPathComponent
        return (directory as NSString).appendingPathComponent(relative)
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard let doc = currentDocument else { return }
        guard !doc.isApplyingExternalChange else { return }
        if let url = currentURL { lineActivatedURLs.insert(url) }
        textView.showsCurrentLineBand = true
        let wasModified = doc.isModified
        doc.markLocalEdit()
        if !wasModified { onDocumentEdited?() }
        // Blame is computed from the committed file. Once the buffer changes,
        // its line mapping is no longer authoritative; clear it immediately
        // even when AppKit emits no accompanying selection notification.
        clearInlineBlameRequest()
        // Parsed JSX ranges belong to the previous text revision. Remove them
        // immediately; the debounced TSX parse publishes current ranges.
        doc.updateJSXTagMatches([])
        HighlightService.shared.scheduleHighlight(doc)
        textView.refreshBracketMatches()
        // The preview debounces internally, so this is cheap per keystroke.
        if let markdownPreview, !markdownPreview.isHidden {
            markdownPreview.update(source: doc.text)
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !suppressSelectionSideEffects else { return }
        textView.refreshBracketMatches()
        if let url = currentURL { selections[url] = textView.selectedRange() }
        guard let url = currentURL, lineActivatedURLs.contains(url) else {
            textView.showsCurrentLineBand = false
            textView.inlineBlame = nil
            return
        }
        textView.showsCurrentLineBand = true
        textView.needsDisplay = true
        scrollView.verticalRulerView?.needsDisplay = true
        scheduleInlineBlame()
    }

    var tabBarHeight: CGFloat { tabBar.currentHeight }
    func setTabRowHeight(_ height: CGFloat) { tabBar.setRowHeight(height) }
    var hasActiveLineForTesting: Bool { textView.showsCurrentLineBand }
    var inlineBlameForTesting: String? { textView.inlineBlame }
    var currentLineHeightForTesting: CGFloat? {
        layoutManager.ensureLayout(for: textView.textContainer!)
        return textView.currentLineBandRect()?.height
    }

    @objc private func documentStructureChanged(_ notification: Notification) {
        guard let document = notification.object as? Document,
              document.url == currentURL else { return }
        textView.updateCodeBlocks(document.codeBlocks, resetFolds: false)
        textView.updateJSXTagMatches(document.jsxTagMatches)
    }

    @objc private func documentReloadedFromDisk(_ notification: Notification) {
        guard let document = notification.object as? Document,
              openURLs.contains(document.url) else { return }
        reloadTabs()
        guard document.url == currentURL else { return }

        let location = min(textView.selectedRange().location, document.storage.length)
        suppressSelectionSideEffects = true
        textView.setSelectedRange(NSRange(location: location, length: 0))
        suppressSelectionSideEffects = false
        textView.undoManager?.removeAllActions()
        clearInlineBlameRequest()
        textView.updateCodeBlocks(document.codeBlocks, resetFolds: false)
        textView.updateJSXTagMatches(document.jsxTagMatches)
        textView.refreshBracketMatches()
        textView.needsDisplay = true
        scrollView.verticalRulerView?.needsDisplay = true
        if let markdownPreview, !markdownPreview.isHidden {
            markdownPreview.update(source: document.text)
        }
    }

    // MARK: - Inline blame

    /// Project root, needed to run `git blame` in the right repository.
    var repositoryRoot: URL?

    private var blameWork: DispatchWorkItem?
    private var blameGeneration = 0
    private var requestedBlameKey: String?
    private var displayedBlameKey: String?
    /// Blame results keyed by file + line, so revisiting a line is free.
    private var blameCache: [String: String] = [:]
    private var blameOrder: [String] = []
    private let maxBlameEntries = 500

    private func cacheBlame(_ text: String, for key: String) {
        blameCache[key] = text
        blameOrder.removeAll { $0 == key }
        blameOrder.append(key)
        while blameOrder.count > maxBlameEntries {
            blameCache.removeValue(forKey: blameOrder.removeFirst())
        }
    }

    private func caretLine() -> Int {
        let ns = textView.string as NSString
        let caret = min(textView.selectedRange().location, ns.length)
        guard caret > 0 else { return 1 }
        // At EOF without a trailing newline, probing at `caret` asks TextKit
        // for the next (empty) line. Probe the final character instead.
        let probe = min(caret - 1, ns.length - 1)
        let lineStart = ns.lineRange(for: NSRange(location: probe, length: 0)).location
        var line = 1
        var index = 0
        while index < lineStart {
            if ns.character(at: index) == 0x0A { line += 1 }
            index += 1
        }
        return line
    }

    private func scheduleInlineBlame() {
        guard Settings.shared.showInlineBlame,
              let url = currentURL,
              let root = repositoryRoot,
              lineActivatedURLs.contains(url) else {
            clearInlineBlameRequest()
            return
        }
        let doc = DocumentStore.shared.document(for: url)
        // A modified buffer has line numbers that no longer match what git
        // knows about, so any annotation would be attributed to the wrong line.
        guard !doc.isVirtual, !doc.isUnsupported, doc.image == nil, !doc.isModified else {
            clearInlineBlameRequest()
            return
        }

        let line = caretLine()
        let key = "\(url.path):\(line)"
        if let hit = blameCache[key] {
            if requestedBlameKey != key {
                blameGeneration += 1
                blameWork?.cancel()
                blameWork = nil
                requestedBlameKey = key
            }
            blameOrder.removeAll { $0 == key }
            blameOrder.append(key)
            let visible = hit.isEmpty ? nil : hit
            let visibleKey = hit.isEmpty ? nil : key
            if displayedBlameKey != visibleKey || textView.inlineBlame != visible {
                displayedBlameKey = visibleKey
                textView.inlineBlame = visible
            }
            return
        }

        // Selection notifications can arrive repeatedly for the same caret
        // (focus changes and caret blinking included). Keep one request alive;
        // cancelling/restarting it made the annotation visibly flash.
        if requestedBlameKey == key, blameWork != nil { return }

        blameGeneration += 1
        let generation = blameGeneration
        blameWork?.cancel()
        requestedBlameKey = key
        // A different line must not retain the previous line's author. For
        // repeated notifications on this same line, leave the rendered value
        // untouched so it never flashes nil between identical requests.
        if displayedBlameKey != key {
            displayedBlameKey = nil
            textView.inlineBlame = nil
        }

        let work = DispatchWorkItem { [weak self] in
            let blame = GitService.blame(file: url, line: line, in: root)
            DispatchQueue.main.async {
                guard let self, self.blameGeneration == generation else { return }
                // The caret may have moved on while git ran.
                guard self.currentURL == url, self.caretLine() == line else { return }
                let text = blame?.inlineText ?? ""
                self.cacheBlame(text, for: key)
                self.blameWork = nil
                self.displayedBlameKey = text.isEmpty ? nil : key
                self.textView.inlineBlame = text.isEmpty ? nil : text
            }
        }
        blameWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func clearInlineBlameRequest() {
        blameGeneration += 1
        blameWork?.cancel()
        blameWork = nil
        requestedBlameKey = nil
        displayedBlameKey = nil
        textView.inlineBlame = nil
    }

    /// Drop cached blame for a file whose contents changed on disk.
    func invalidateBlame(for url: URL? = nil) {
        if let url {
            blameCache = blameCache.filter { !$0.key.hasPrefix(url.path + ":") }
            blameOrder.removeAll { $0.hasPrefix(url.path + ":") }
        } else {
            blameCache.removeAll()
            blameOrder.removeAll()
        }
        requestedBlameKey = nil
        scheduleInlineBlame()
    }

    func textViewDidChangeTypingAttributes(_ notification: Notification) {}

    /// Track focus so the container knows which pane is active.
    override func viewDidAppear() {
        super.viewDidAppear()
        NotificationCenter.default.addObserver(
            self, selector: #selector(focusChanged),
            name: NSWindow.didUpdateNotification, object: view.window)
    }

    @objc private func focusChanged() {
        guard let responder = view.window?.firstResponder as? NSView else { return }
        if responder === textView && !isActivePane { onBecameActive?(self) }
    }
}

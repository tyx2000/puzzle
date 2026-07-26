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

    private(set) var openURLs: [URL] = []
    private var activeIndex: Int?
    private var selections: [URL: NSRange] = [:]

    private let tabBar = EditorTabBar()
    private var scrollView: NSScrollView!
    private var textView: PuzzleTextView!
    private var layoutManager = NSLayoutManager()
    /// Empty storage used when the pane has no open file.
    private let blankStorage = NSTextStorage()

    var currentURL: URL? { activeIndex.flatMap { openURLs.indices.contains($0) ? openURLs[$0] : nil } }
    private var currentDocument: Document? { currentURL.map { DocumentStore.shared.document(for: $0) } }

    /// Highlight the tab strip when this pane has focus.
    var isActivePane = false { didSet { tabBar.paneActive = isActivePane } }

    private let findBar = FindBarView()
    private var findBarHeight: NSLayoutConstraint!

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
        // Custom find bar (the system one can't be restyled and shows a focus ring).
        textView.usesFindBar = false
        textView.typingAttributes = Theme.textAttributes(color: Theme.foreground)
        // Nothing open yet — no current-line band in the empty area.
        textView.showsCurrentLineBand = false

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
        tabBar.onSplit = { [weak self] in self?.onRequestSplit?() }

        container.addSubview(tabBar)
        container.addSubview(scrollView)
        findBar.translatesAutoresizingMaskIntoConstraints = false
        findBar.isHidden = true
        findBar.onClose = { [weak self] in self?.hideFindBar() }
        container.addSubview(findBar)

        findBarHeight = findBar.heightAnchor.constraint(equalToConstant: 0)
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
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        self.view = container
        reloadTabs()
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
        activate(index: openURLs.count - 1)
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
        if let prev = currentURL { selections[prev] = textView.selectedRange() }

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
        textView.setSelectedRange(caret)
        textView.scrollRangeToVisible(caret)
        textView.typingAttributes = Theme.textAttributes(color: Theme.foreground)
        // Binary files show a placeholder and must not be editable — typing into
        // one and saving would destroy the file.
        // Diffs and binaries are read-only.
        textView.isEditable = !doc.isUnsupported && !doc.isVirtual
        textView.showsCurrentLineBand = true

        reloadTabs()
        scrollView.verticalRulerView?.needsDisplay = true
        textView.needsDisplay = true
        onActiveDocumentChanged?(url)
        onBecameActive?(self)
    }

    func close(index: Int) {
        guard openURLs.indices.contains(index) else { return }
        let url = openURLs.remove(at: index)
        selections.removeValue(forKey: url)
        if openURLs.isEmpty {
            activeIndex = nil
            layoutManager.textStorage?.removeLayoutManager(layoutManager)
            blankStorage.addLayoutManager(layoutManager)
            // No document: don't paint a current-line band in the empty area.
            textView.showsCurrentLineBand = false
            reloadTabs()
            onActiveDocumentChanged?(nil)
            onEmptied?(self)
            return
        }
        activate(index: min(index, openURLs.count - 1))
    }

    func save() {
        guard let doc = currentDocument, !doc.isUnsupported else { return }
        do {
            try doc.save()
            reloadTabs()
            onDocumentSaved?(doc.url)
        } catch { presentError(error) }
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
        textView.setSelectedRange(target)
        textView.scrollRangeToVisible(target)
        view.window?.makeFirstResponder(textView)
    }

    /// Re-apply font / line metrics after settings change.
    func refreshDisplay() {
        textView.font = Theme.editorFont()
        textView.typingAttributes = Theme.textAttributes(color: Theme.foreground)
        textView.needsDisplay = true
        scrollView.verticalRulerView?.needsDisplay = true
        reloadTabs()
    }

    func reloadTabs() {
        let infos = openURLs.map { url -> EditorTabBar.TabInfo in
            let doc = DocumentStore.shared.document(for: url)
            let title = doc.isVirtual ? "\(url.lastPathComponent) (diff)" : url.lastPathComponent
            return EditorTabBar.TabInfo(title: title, modified: doc.isModified)
        }
        tabBar.reload(tabs: infos, active: activeIndex ?? -1)
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard let doc = currentDocument else { return }
        if !doc.isModified { doc.isModified = true; onDocumentEdited?() }
        HighlightService.shared.scheduleHighlight(doc)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        if let url = currentURL { selections[url] = textView.selectedRange() }
        textView.needsDisplay = true
        scrollView.verticalRulerView?.needsDisplay = true
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

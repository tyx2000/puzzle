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
    var onTabBarHeightChanged: ((CGFloat) -> Void)?
    /// Supplied by the editor container for synthetic file-history tabs.
    var fileHistoryProvider: ((URL) -> FileHistoryModel?)?

    private(set) var openURLs: [URL] = []
    private var activeIndex: Int?
    private var selections: [URL: NSRange] = [:]
    private var lineActivatedURLs: Set<URL> = []
    private var suppressSelectionSideEffects = false
    private var definitionNavigationGeneration = 0
    private var definitionHoverGeneration = 0
    private var definitionHoverWork: DispatchWorkItem?
    private var definitionHoverURL: URL?
    private var definitionHoverCandidateRange: NSRange?
    private let definitionHoverQueue = DispatchQueue(
        label: "app.puzzle.definition-hover", qos: .userInitiated)

    /// How far back ⌘Z reaches. Deep enough for real editing, bounded so a long
    /// session cannot accumulate every edit ever made.
    static let undoLevels = 200

    private let tabBar = EditorTabBar()
    private var scrollView: NSScrollView!
    private var textView: PuzzleTextView!
    private var layoutManager = FoldingLayoutManager()
    /// Empty storage used when the pane has no open file.
    private let blankStorage = NSTextStorage()

    /// Index of the tab on screen, for commands that act on "the current tab".
    var activeTabIndex: Int? { activeIndex }

    var currentURL: URL? { activeIndex.flatMap { openURLs.indices.contains($0) ? openURLs[$0] : nil } }
    private var currentDocument: Document? { currentURL.map { DocumentStore.shared.document(for: $0) } }

    /// Highlight the tab strip when this pane has focus.
    var isActivePane = false { didSet { tabBar.paneActive = isActivePane } }

    private let findBar = FindBarView()
    private var findBarHeight: NSLayoutConstraint!
    /// Shown above a git diff: its file path, and the controls that step through
    /// its changes.
    private let diffHeader = DiffHeaderView()
    private var diffHeaderHeight: NSLayoutConstraint!
    /// Side-by-side diffs, built the first time the mode is used.
    private var sideBySideDiff: SideBySideDiffView?
    /// The mode is a preference, not a property of the file: it sticks for the
    /// session so stepping between diffs does not keep switching layout.
    private static var diffMode: DiffHeaderView.Mode = .unified
    /// Shown instead of the text view when the active document is a picture.
    private var imagePreview: ImagePreviewView?
    /// Shown instead of the text view for a file-history table tab.
    private var fileHistoryView: FileHistoryView?

    /// Fold identities are pane-local, but survive switching between tabs.
    private var foldedBlocks: [URL: Set<Int>] = [:]

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
        // Deferred: the responder change is still in flight, and a window being
        // torn down resigns its responder too — by the time this runs, a closed
        // pane has no window and nothing is written. That matters because
        // closing a tab may have just asked the user, who answered Don't Save.
        textView.onLostFocus = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.view.window != nil else { return }
                self.autosaveIfNeeded()
            }
        }
        textView.onExplicitCaretInteraction = { [weak self] in
            guard let self, let url = self.currentURL else { return }
            self.lineActivatedURLs.insert(url)
            self.textView.showsCurrentLineBand = self.currentDocument?.languageSpec?.name
                != "markdown"
        }
        textView.onCommandClick = { [weak self] location in
            self?.navigateToDefinition(at: location) ?? false
        }
        textView.onCommandHover = { [weak self] location in
            self?.updateDefinitionHover(at: location)
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
        PuzzleScroller.adopt(scrollView)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.hasVerticalRuler = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.editorBackground
        let ruler = LineNumberRulerView(textView: textView)
        ruler.lineIndexProvider = { [weak self] in self?.currentDocument?.lineIndex }
        ruler.onChangeClicked = { [weak self] change, rect in
            self?.showGitChange(change, from: rect)
        }
        scrollView.verticalRulerView = ruler
        scrollView.rulersVisible = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.onSelect = { [weak self] in self?.activate(index: $0) }
        tabBar.onClose = { [weak self] in self?.close(index: $0) }
        tabBar.onCloseOthers = { [weak self] in self?.closeOtherTabs(around: $0) }
        tabBar.onCloseRight = { [weak self] in self?.closeTabsToTheRight(of: $0) }
        tabBar.onSplit = { [weak self] in self?.onRequestSplit?() }
        tabBar.onHeightChanged = { [weak self] height in
            self?.onTabBarHeightChanged?(height)
        }

        container.addSubview(tabBar)
        container.addSubview(scrollView)
        findBar.translatesAutoresizingMaskIntoConstraints = false
        findBar.isHidden = true
        findBar.onClose = { [weak self] in self?.hideFindBar() }
        findBar.onHeightChanged = { [weak self] in
            guard let self else { return }
            self.findBarHeight.constant = self.findBar.preferredHeight
        }
        container.addSubview(findBar)

        diffHeader.translatesAutoresizingMaskIntoConstraints = false
        diffHeader.isHidden = true
        diffHeader.onPrevious = { [weak self] in self?.stepThroughDiff(forward: false) }
        diffHeader.onNext = { [weak self] in self?.stepThroughDiff(forward: true) }
        diffHeader.onToggleMode = { [weak self] in self?.toggleDiffMode() }
        container.addSubview(diffHeader)

        findBarHeight = findBar.heightAnchor.constraint(equalToConstant: 0)
        diffHeaderHeight = diffHeader.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: container.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            findBar.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            findBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            findBarHeight,

            diffHeader.topAnchor.constraint(equalTo: findBar.bottomAnchor),
            diffHeader.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            diffHeader.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            diffHeaderHeight,

            // Height follows the pills (grows when tabs wrap to a second row).
            scrollView.topAnchor.constraint(equalTo: diffHeader.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        self.view = container
        reloadTabs()
    }

    // MARK: - Uncommitted change marks

    /// Reload HEAD's copy of the file on screen and re-mark against it. Runs
    /// off the main thread: it shells out to Git, and the editor must not wait
    /// for it. Called when the file, the repository, or HEAD itself changes —
    /// the marks in between come from the baseline this leaves behind.
    func refreshGitLineChanges() {
        // The repository can be handed to a pane before its views exist.
        guard isViewLoaded else { return }
        liveMarkWork?.cancel()
        guard let url = currentURL, url.isFileURL,
              let document = currentDocument, !document.isVirtual,
              let root = repositoryRoot else {
            gitBaseline = nil
            gitBaselineURL = nil
            applyGitLineChanges([], for: nil)
            return
        }
        let generation = gitLineChangeGeneration + 1
        gitLineChangeGeneration = generation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let baseline = GitLineChanges.baseline(for: url, in: root)
            DispatchQueue.main.async {
                guard let self, self.gitLineChangeGeneration == generation,
                      self.currentURL == url else { return }
                self.gitBaseline = baseline
                self.gitBaselineURL = url
                self.recomputeGitLineChanges()
            }
        }
    }

    /// Re-mark after an edit. Debounced, because the marks only need to keep up
    /// with the typing, not with each keystroke.
    func scheduleGitLineChanges() {
        guard gitBaselineURL != nil, gitBaselineURL == currentURL else { return }
        liveMarkWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.recomputeGitLineChanges() }
        liveMarkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.liveMarkDelay, execute: work)
    }

    /// Mark the buffer as it stands rather than as it was last saved. The diff
    /// is computed in process against HEAD's copy: running `git diff` per pause
    /// would spawn a subprocess for every burst of typing, and would still only
    /// see the file on disk.
    private func recomputeGitLineChanges() {
        liveMarkWork?.cancel()
        guard let url = currentURL, url == gitBaselineURL,
              let baseline = gitBaseline,
              let document = currentDocument, !document.isVirtual,
              !document.isMinifiedPreview else {
            applyGitLineChanges([], for: gitBaselineURL == currentURL ? currentURL : nil)
            return
        }
        // An immutable copy, because the split and the diff run off the main
        // thread while the user keeps typing into the storage.
        guard let snapshot = (textView.string as NSString).copy() as? NSString else { return }
        let generation = gitLineChangeGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let changes = GitLineChanges.changes(from: baseline,
                                                 to: GitLineChanges.lines(of: snapshot as String))
            DispatchQueue.main.async {
                guard let self, self.gitLineChangeGeneration == generation,
                      self.currentURL == url else { return }
                self.applyGitLineChanges(changes, for: url)
            }
        }
    }

    private func applyGitLineChanges(_ changes: [GitLineChanges.Change], for url: URL?) {
        gitLineChanges = changes
        gitLineChangesURL = url
        (scrollView.verticalRulerView as? LineNumberRulerView)?.gitChanges = changes
    }

    /// The little diff behind a gutter mark.
    private func showGitChange(_ change: GitLineChanges.Change, from rect: NSRect) {
        guard let ruler = scrollView.verticalRulerView else { return }
        gitChangePopover?.close()
        let controller = GitChangePopoverController(change: change)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        _ = controller.view
        popover.contentSize = controller.preferredSize
        popover.show(relativeTo: rect, of: ruler, preferredEdge: .maxX)
        gitChangePopover = popover
    }

    // MARK: - Diff header

    /// The repository-relative path a diff buffer was built from: the Git panel
    /// encodes it in the preview URL, since the buffer itself is synthetic.
    static func diffPath(for url: URL) -> String? {
        guard url.scheme == DocumentStore.diffScheme,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        return items.first { $0.name == "path" }?.value
    }

    private func showDiffHeader(for url: URL?) {
        guard let url, let path = Self.diffPath(for: url) else {
            diffHeader.isHidden = true
            diffHeaderHeight.constant = 0
            hideSideBySideDiff()
            return
        }
        diffHeader.setMode(Self.diffMode)
        diffHeader.configure(path: path, changes: changeBlocks().count)
        diffHeader.isHidden = false
        diffHeaderHeight.constant = DiffHeaderView.height
        applyDiffMode()
    }

    private func toggleDiffMode() {
        Self.diffMode = Self.diffMode.next
        diffHeader.setMode(Self.diffMode)
        applyDiffMode()
    }

    /// Swap the code view for the two-column one (or back), leaving everything
    /// else in the pane — header, tabs, find bar — exactly where it was.
    private func applyDiffMode() {
        guard !diffHeader.isHidden, let doc = currentDocument else {
            hideSideBySideDiff()
            return
        }
        guard Self.diffMode == .sideBySide else {
            hideSideBySideDiff()
            scrollView.isHidden = false
            return
        }
        let view = ensureSideBySideDiff()
        view.configure(diff: doc.text)
        view.isHidden = false
        scrollView.isHidden = true
        diffHeader.configure(path: diffHeader.pathForTesting, changes: view.changeCount)
    }

    private func hideSideBySideDiff() {
        sideBySideDiff?.isHidden = true
    }

    private func ensureSideBySideDiff() -> SideBySideDiffView {
        if let sideBySideDiff { return sideBySideDiff }
        let view = SideBySideDiffView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        self.view.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: diffHeader.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
        ])
        sideBySideDiff = view
        return view
    }

    /// Runs of consecutive added/removed lines — one "change" as a reader sees
    /// it. The bands the diff painter already produced are exactly those lines,
    /// in order, so touching runs are merged rather than parsed again.
    private func changeBlocks() -> [NSRange] {
        var blocks: [NSRange] = []
        for band in textView.diffBands {
            if let last = blocks.last, NSMaxRange(last) >= band.range.location {
                blocks[blocks.count - 1] = NSUnionRange(last, band.range)
            } else {
                blocks.append(band.range)
            }
        }
        return blocks
    }

    /// Move to the next (or previous) block of changed lines, wrapping around at
    /// the ends the way the find bar does.
    private func stepThroughDiff(forward: Bool) {
        if let sideBySideDiff, !sideBySideDiff.isHidden {
            sideBySideDiff.step(forward: forward)
            return
        }
        let blocks = changeBlocks()
        guard !blocks.isEmpty else { return }
        let caret = textView.selectedRange().location
        let target: NSRange
        if forward {
            target = blocks.first { $0.location > caret } ?? blocks[0]
        } else {
            target = blocks.last { NSMaxRange($0) <= caret } ?? blocks[blocks.count - 1]
        }
        textView.setSelectedRange(NSRange(location: target.location, length: 0))
        textView.scrollRangeToVisible(target)
        scrollView.verticalRulerView?.needsDisplay = true
    }

    // MARK: - Regression-test surface

    var gitLineChangesForTesting: [GitLineChanges.Change] { gitLineChanges }
    var editorBackgroundForTesting: NSColor { textView.backgroundColor }
    var diffHeaderForTesting: DiffHeaderView { diffHeader }
    var verticalScrollerForTesting: NSScroller? { scrollView.verticalScroller }
    var lineNumberRulerForTesting: LineNumberRulerView? {
        scrollView.verticalRulerView as? LineNumberRulerView
    }
    var currentLineBandRectForTesting: NSRect? { textView.currentLineBandRect() }
    func selectAllForTesting() {
        textView.setSelectedRange(NSRange(location: 0, length: textView.string.count))
    }
    var caretLocationForTesting: Int { textView.selectedRange().location }
    func refreshBracketMatchesForTesting() { textView.refreshBracketMatches() }
    @discardableResult
    func focusEditorForTesting() -> Bool { view.window?.makeFirstResponder(textView) ?? false }
    func insertTextForTesting(_ text: String) {
        textView.insertText(text, replacementRange: textView.selectedRange())
    }
    func setCaretForTesting(_ location: Int) {
        textView.setSelectedRange(NSRange(location: location, length: 0))
    }
    func scrollToForTesting(_ location: Int) {
        textView.scrollRangeToVisible(NSRange(location: location, length: 0))
    }
    func lineIndexForTesting() -> LineIndex? { currentDocument?.lineIndex }
    func disableWrappingForTesting() {
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.size = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                              height: CGFloat.greatestFiniteMagnitude)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
    }
    func visibleGlyphRangeForTesting() -> NSRange {
        guard let container = textView.textContainer else { return NSRange() }
        return layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: container)
    }
    var findBarForTesting: FindBarView { findBar }
    var textForTesting: String { textView.string }
    var isModifiedForTesting: Bool { currentDocument?.isModified == true }
    func undoForTesting() { textView.undoManager?.undo() }
    var undoLevelsForTesting: Int? { textView.undoManager?.levelsOfUndo }
    func isCharacterHiddenForTesting(_ location: Int) -> Bool {
        layoutManager.isCharacterHidden(at: location)
    }
    var nonContiguousLayoutForTesting: Bool { layoutManager.allowsNonContiguousLayout }
    func foldAllForTesting() {
        textView.codeBlocks.forEach { textView.toggleFold($0) }
    }
    var diffHeaderIsVisibleForTesting: Bool { !diffHeader.isHidden }
    var sideBySideVisibleForTesting: Bool { sideBySideDiff.map { !$0.isHidden } ?? false }
    var sideBySideBlockForTesting: Int { sideBySideDiff?.currentBlockForTesting ?? -1 }
    var sideBySideGeometryForTesting: (rows: Int, contentHeight: CGFloat, scrollOffset: CGFloat)? {
        sideBySideDiff?.geometryForTesting
    }
    var sideBySideCurrentRowForTesting: Int? { sideBySideDiff?.currentRowForTesting }
    func toggleDiffModeForTesting() { toggleDiffMode() }
    var changeBlockCountForTesting: Int { changeBlocks().count }

    private func ensureImagePreview() -> ImagePreviewView {
        if let imagePreview { return imagePreview }
        let preview = ImagePreviewView()
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.isHidden = true
        view.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: diffHeader.bottomAnchor),
            preview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            preview.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        imagePreview = preview
        return preview
    }

    private func ensureFileHistoryView() -> FileHistoryView {
        if let fileHistoryView { return fileHistoryView }
        let history = FileHistoryView()
        history.translatesAutoresizingMaskIntoConstraints = false
        history.isHidden = true
        view.addSubview(history)
        NSLayoutConstraint.activate([
            history.topAnchor.constraint(equalTo: diffHeader.bottomAnchor),
            history.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            history.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            history.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        fileHistoryView = history
        return history
    }

    // MARK: - Find bar

    func showFindBar(seed: String? = nil, replacing: Bool = false) {
        findBar.isHidden = false
        findBar.attach(to: textView)
        findBar.setReplaceVisible(replacing)
        findBarHeight.constant = findBar.preferredHeight
        if let seed { findBar.setQuery(seed) }
        if !replacing { findBar.focus() }
    }

    func hideFindBar() {
        findBar.finish()
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
        // Remember where the caret was in the outgoing document, and write it
        // out: moving to another tab is leaving this one.
        if let prev = currentURL {
            selections[prev] = textView.selectedRange()
            foldedBlocks[prev] = layoutManager.foldedBlockIdentities
            if prev != openURLs[index] { autosaveIfNeeded() }
        }

        activeIndex = index
        clearDefinitionHover()
        let url = openURLs[index]
        let doc = DocumentStore.shared.document(for: url)

        // Lay out only what is asked for. A full layout of a multi-megabyte file
        // cost ~34 MB of fragment storage before its first line was drawn; on
        // demand that is ~16 MB.
        //
        // Not for Markdown or diffs: both decorate ranges across the whole
        // document (code-block boxes, full-width change bands), and geometry
        // for a range that has not been laid out yet comes back at the origin —
        // measured, a fenced block's box landed at the top of the file.
        layoutManager.allowsNonContiguousLayout =
            !doc.isVirtual && doc.languageSpec?.name != "markdown"

        // Move this pane's layout manager onto the document's storage.
        if layoutManager.textStorage !== doc.storage {
            layoutManager.textStorage?.removeLayoutManager(layoutManager)
            doc.storage.addLayoutManager(layoutManager)
        }

        // Undo records hold the replaced text, so an unbounded stack grows with
        // every edit for as long as the window lives.
        textView.undoManager?.levelsOfUndo = Self.undoLevels

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
            && doc.languageSpec?.name != "markdown"
        if !lineIsActive { clearInlineBlameRequest() }
        textView.diffBands = doc.diffBands
        textView.diffLineNumbers = doc.diffLineNumbers
        textView.updateCodeBlocks(doc.codeBlocks, resetFolds: false)
        layoutManager.restoreFoldedBlockIdentities(foldedBlocks[url] ?? [])
        let markdownReveal = markdownRevealRange(for: doc)
        layoutManager.updateMarkdownSyntaxRanges(
            doc.markdownSyntaxRanges,
            collapsedLines: doc.markdownCollapsedLineRanges,
            replacements: doc.markdownGlyphReplacements,
            revealing: markdownReveal)
        textView.updateMarkdownDecorations(
            codeBlocks: doc.markdownCodeBlocks, tables: doc.markdownTables,
            tasks: doc.markdownTasks,
            lineMarkers: doc.markdownLineMarkers, rules: doc.markdownRules,
            images: doc.markdownImages,
            activeSourceRange: markdownReveal)

        // Synthetic file-history tabs use a real four-column table. Keep this
        // check ahead of images/text so only one primary content view is shown.
        if let historyModel = fileHistoryProvider?(url) {
            let history = ensureFileHistoryView()
            history.configure(historyModel)
            history.isHidden = false
            imagePreview?.clear()
            imagePreview?.isHidden = true
            scrollView.isHidden = true
            showDiffHeader(for: nil)
        } else if let image = doc.image {
            fileHistoryView?.isHidden = true
            let imagePreview = ensureImagePreview()
            imagePreview.show(image: image, caption: doc.text)
            imagePreview.isHidden = false
            scrollView.isHidden = true
            showDiffHeader(for: nil)
        } else {
            fileHistoryView?.isHidden = true
            imagePreview?.clear()
            imagePreview?.isHidden = true
            scrollView.isHidden = false
            // Rendered Markdown reads like a document, not a source listing.
            scrollView.rulersVisible = doc.languageSpec?.name != "markdown"
            showDiffHeader(for: doc.diffLineNumbers.isEmpty ? nil : url)
        }

        reloadTabs()
        refreshGitLineChanges()
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
        foldedBlocks.removeValue(forKey: url)
        defer { onTabClosed?(url) }
        if openURLs.isEmpty {
            activeIndex = nil
            layoutManager.textStorage?.removeLayoutManager(layoutManager)
            blankStorage.addLayoutManager(layoutManager)
            // No document: don't paint a current-line band in the empty area.
            textView.showsCurrentLineBand = false
            textView.updateCodeBlocks([], resetFolds: false)
            textView.updateJSXTagMatches([])
            layoutManager.updateMarkdownSyntaxRanges([], revealing: nil)
            textView.updateMarkdownDecorations(
                codeBlocks: [], tables: [], tasks: [], activeSourceRange: nil)
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

    /// Write the buffer the user is leaving, the way Zed's
    /// `autosave: on_focus_change` does: switching tabs or panes, clicking into
    /// another part of the window, or leaving the app.
    ///
    /// Silent by design. A save that cannot go through — the file changed on
    /// disk underneath the edit — leaves the document dirty and says nothing,
    /// rather than throwing a modal at someone who has already looked away.
    /// They get the question the next time they save or close it deliberately.
    func autosaveIfNeeded() {
        guard let document = currentDocument, document.isModified,
              !document.isReadOnly, !document.isVirtual else { return }
        persist(document, notify: true, presentErrors: false)
    }

    @discardableResult
    private func persist(_ document: Document, notify: Bool,
                         presentErrors: Bool) -> Bool {
        guard document.isModified, !document.isReadOnly else { return true }
        // Something else wrote this file while it was being edited. Saving would
        // replace their version; reloading would replace the user's edits. Only
        // the user can choose, so ask before either.
        if document.hasDiskConflict || document.diskChangedSinceLastSync {
            guard presentErrors else { return false }
            switch resolveDiskConflict(for: document) {
            case .overwrite: document.resolveDiskConflict()
            case .reload:
                document.discardEditsAndReloadFromDisk()
                reloadTabs()
                return true
            case .cancel: return false
            }
        }
        do {
            try document.save()
            reloadTabs()
            refreshGitLineChanges()
            if notify { onDocumentSaved?(document.url) }
            return true
        } catch {
            if presentErrors { self.presentError(error) }
            return false
        }
    }


    private enum DiskConflictChoice { case overwrite, reload, cancel }

    private func resolveDiskConflict(for document: Document) -> DiskConflictChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(document.name)” changed on disk since you started editing"
        alert.informativeText = "File:\n\(document.url.path)\n\n"
            + "Saving replaces the version on disk with what is in this editor. "
            + "Reloading replaces what is in this editor with the version on disk, "
            + "discarding your unsaved edits. Neither can be undone."
        alert.addButton(withTitle: "Save Anyway")
        alert.addButton(withTitle: "Reload from Disk")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .overwrite
        case .alertSecondButtonReturn: return .reload
        default: return .cancel
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

    func jumpToLine(_ line: Int, column: Int? = nil) {
        // Through the document's line index: enumerating by lines walked the
        // whole file, which on a minified bundle — one line, megabytes long —
        // stalled every jump for hundreds of milliseconds.
        let length = textView.textStorage?.length ?? 0
        guard let index = currentDocument?.lineIndex else { return }
        let location = index.start(ofLine: line)
        let nextLine = line + 1 <= index.lineCount ? index.start(ofLine: line + 1) : length
        let lineLength = max(0, nextLine - location - (nextLine > location ? 1 : 0))
        // A column past the end of the line lands at its end rather than
        // spilling into the next one.
        let offset = column.map { min(max(0, $0 - 1), lineLength) } ?? 0
        let target = NSRange(location: min(location + offset, length), length: 0)
        if let url = currentURL { lineActivatedURLs.insert(url) }
        textView.showsCurrentLineBand = currentDocument?.languageSpec?.name != "markdown"
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
                self.textView.showsCurrentLineBand = self.currentDocument?.languageSpec?.name
                    != "markdown"
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

    private func updateDefinitionHover(at location: Int?) {
        guard let location,
              let sourceURL = currentURL,
              let root = repositoryRoot,
              let document = currentDocument,
              !document.isVirtual, !document.isUnsupported, document.image == nil else {
            clearDefinitionHover()
            return
        }
        let source = textView.string
        guard let range = DefinitionNavigator.targetRange(
            in: source, utf16Location: location) else {
            clearDefinitionHover()
            return
        }
        if definitionHoverURL == sourceURL,
           definitionHoverCandidateRange == range { return }

        definitionHoverGeneration += 1
        let generation = definitionHoverGeneration
        definitionHoverWork?.cancel()
        definitionHoverURL = sourceURL
        definitionHoverCandidateRange = range
        textView.setCommandHoverRange(nil)

        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  let activeWork = self.definitionHoverWork,
                  !activeWork.isCancelled,
                  self.definitionHoverGeneration == generation else { return }
            let destination = DefinitionNavigator.resolve(
                text: source, sourceURL: sourceURL, projectRoot: root,
                utf16Location: location)
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.definitionHoverGeneration == generation,
                      self.definitionHoverURL == sourceURL,
                      self.definitionHoverCandidateRange == range else { return }
                self.textView.setCommandHoverRange(destination == nil ? nil : range)
            }
        }
        definitionHoverWork = work
        definitionHoverQueue.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func clearDefinitionHover() {
        guard definitionHoverURL != nil || definitionHoverCandidateRange != nil
                || textView?.commandHoverRange != nil else { return }
        definitionHoverGeneration += 1
        definitionHoverWork?.cancel()
        definitionHoverWork = nil
        definitionHoverURL = nil
        definitionHoverCandidateRange = nil
        textView?.setCommandHoverRange(nil)
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
        clearDefinitionHover()
        blameGeneration += 1
        blameWork?.cancel()
        blameWork = nil
        blameCache.removeAll()
        blameOrder.removeAll()
        imagePreview?.clear()
        textView.updateCodeBlocks([], resetFolds: false)
        textView.updateJSXTagMatches([])
        detachFromDocument()
        let urls = openURLs
        openURLs.removeAll()
        activeIndex = nil
        selections.removeAll()
        lineActivatedURLs.removeAll()
        foldedBlocks.removeAll()
        urls.forEach { onTabClosed?($0) }
    }

    /// Release view-owned payloads that are not currently visible. Documents
    /// themselves are handled separately by `DocumentStore`.
    func releaseTransientMemory() {
        if imagePreview?.isHidden != false { imagePreview?.clear() }
        if findBar.isHidden { findBar.clearHighlights() }
    }

    /// Re-apply font / line metrics after settings change.
    func refreshDisplay() {
        for url in openURLs {
            HighlightService.shared.highlight(DocumentStore.shared.document(for: url))
        }
        textView.font = Theme.editorFont()
        textView.typingAttributes = Theme.textAttributes(color: Theme.foreground)
        // Colours set when the views were built are captured values, so a new
        // theme has to be pushed back into them.
        (view as? FlatView)?.fillColor = Theme.editorBackground
        textView.backgroundColor = Theme.editorBackground
        textView.insertionPointColor = Theme.cursor
        textView.selectedTextAttributes = [.backgroundColor: Theme.selection]
        scrollView.backgroundColor = Theme.editorBackground
        findBar.refreshAppearance()
        diffHeader.refreshAppearance()
        sideBySideDiff?.refreshAppearance()
        imagePreview?.refreshFonts()
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
        clearDefinitionHover()
        if let url = currentURL { lineActivatedURLs.insert(url) }
        textView.showsCurrentLineBand = doc.languageSpec?.name != "markdown"
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
        let reveal = markdownRevealRange(for: doc)
        layoutManager.revealMarkdownSyntax(in: reveal)
        textView.updateMarkdownDecorations(
            codeBlocks: doc.markdownCodeBlocks, tables: doc.markdownTables,
            tasks: doc.markdownTasks,
            lineMarkers: doc.markdownLineMarkers, rules: doc.markdownRules,
            images: doc.markdownImages,
            activeSourceRange: reveal)
        textView.refreshBracketMatches()
        scheduleGitLineChanges()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !suppressSelectionSideEffects else { return }
        textView.refreshBracketMatches()
        if let url = currentURL { selections[url] = textView.selectedRange() }
        if let document = currentDocument {
            let reveal = markdownRevealRange(for: document)
            layoutManager.revealMarkdownSyntax(in: reveal)
            textView.updateMarkdownDecorations(
                codeBlocks: document.markdownCodeBlocks,
                tables: document.markdownTables,
                tasks: document.markdownTasks,
                lineMarkers: document.markdownLineMarkers,
                rules: document.markdownRules,
                images: document.markdownImages,
                activeSourceRange: reveal)
        }
        guard let url = currentURL, lineActivatedURLs.contains(url) else {
            textView.showsCurrentLineBand = false
            textView.inlineBlame = nil
            return
        }
        textView.showsCurrentLineBand = currentDocument?.languageSpec?.name != "markdown"
        textView.needsDisplay = true
        scrollView.verticalRulerView?.needsDisplay = true
        scheduleInlineBlame()
    }

    var tabBarHeight: CGFloat { tabBar.currentHeight }
    func setTabRowHeight(_ height: CGFloat) { tabBar.setRowHeight(height) }
    var hasActiveLineForTesting: Bool { textView.showsCurrentLineBand }
    var inlineBlameForTesting: String? { textView.inlineBlame }
    var markdownDecorationCountsForTesting: (codeBlocks: Int, tables: Int) {
        textView.markdownDecorationCountsForTesting
    }
    var markdownTaskCountForTesting: Int { textView.markdownTaskCountForTesting }
    var showsLineNumbersForTesting: Bool { scrollView.rulersVisible }
    var currentLineHeightForTesting: CGFloat? {
        layoutManager.ensureLayout(for: textView.textContainer!)
        return textView.currentLineBandRect()?.height
    }

    @objc private func documentStructureChanged(_ notification: Notification) {
        guard let document = notification.object as? Document,
              document.url == currentURL else { return }
        textView.updateCodeBlocks(document.codeBlocks, resetFolds: false)
        textView.updateJSXTagMatches(document.jsxTagMatches)
        let reveal = markdownRevealRange(for: document)
        layoutManager.updateMarkdownSyntaxRanges(
            document.markdownSyntaxRanges,
            collapsedLines: document.markdownCollapsedLineRanges,
            replacements: document.markdownGlyphReplacements,
            revealing: reveal)
        textView.updateMarkdownDecorations(
            codeBlocks: document.markdownCodeBlocks, tables: document.markdownTables,
            tasks: document.markdownTasks,
            lineMarkers: document.markdownLineMarkers, rules: document.markdownRules,
            images: document.markdownImages,
            activeSourceRange: reveal)
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
        let reveal = markdownRevealRange(for: document)
        layoutManager.updateMarkdownSyntaxRanges(
            document.markdownSyntaxRanges,
            collapsedLines: document.markdownCollapsedLineRanges,
            replacements: document.markdownGlyphReplacements,
            revealing: reveal)
        textView.updateMarkdownDecorations(
            codeBlocks: document.markdownCodeBlocks, tables: document.markdownTables,
            tasks: document.markdownTasks,
            lineMarkers: document.markdownLineMarkers, rules: document.markdownRules,
            images: document.markdownImages,
            activeSourceRange: reveal)
        textView.refreshBracketMatches()
        textView.needsDisplay = true
        scrollView.verticalRulerView?.needsDisplay = true
    }

    /// Reveal source markers only on lines the user explicitly entered. Merely
    /// opening a Markdown file leaves the document in its rendered appearance.
    private func markdownRevealRange(for document: Document) -> NSRange? {
        guard document.languageSpec?.name == "markdown",
              let url = currentURL, lineActivatedURLs.contains(url) else { return nil }
        let source = document.storage.string as NSString
        let selection = textView.selectedRange()
        let location = min(selection.location, source.length)
        let length = min(selection.length, source.length - location)
        return source.lineRange(for: NSRange(location: location, length: length))
    }

    // MARK: - Inline blame

    /// Project root, needed to run `git blame` in the right repository.
    var repositoryRoot: URL? {
        didSet { refreshGitLineChanges() }
    }
    /// Uncommitted changes for the file on screen, per line.
    private var gitLineChanges: [GitLineChanges.Change] = []
    private var gitLineChangesURL: URL?
    private var gitChangePopover: NSPopover?
    private var gitLineChangeGeneration = 0
    /// HEAD's copy of the file on screen, kept so an edit can be marked without
    /// asking Git again.
    private var gitBaseline: [String]?
    private var gitBaselineURL: URL?
    private var liveMarkWork: DispatchWorkItem?
    /// Long enough that a burst of typing is one diff, short enough that the
    /// ribbon appears while the line is still the one being written.
    static let liveMarkDelay: TimeInterval = 0.25

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

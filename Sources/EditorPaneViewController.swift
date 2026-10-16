import AppKit

/// One editor pane: its own tab strip + text view + gutter. Panes are
/// independent (own tabs) but share document buffers via DocumentStore.
final class EditorPaneViewController: NSViewController, NSTextViewDelegate {
    var onActiveDocumentChanged: ((URL?) -> Void)?
    var onEmptied: ((EditorPaneViewController) -> Void)?
    var onDocumentEdited: (() -> Void)?
    var onDocumentSaved: ((URL) -> Void)?
    var onTabOpened: ((URL) -> Void)?
    /// A tab was closed here. The container decides whether the buffer is still
    /// open elsewhere before releasing it — a pane can't see its siblings.
    var onTabClosed: ((URL) -> Void)?
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

    /// Step to the next or previous tab, wrapping at the ends: with a handful
    /// of files open, wrapping is what makes the shortcut usable without
    /// looking at which tab is where.
    func stepTab(by offset: Int) {
        guard openURLs.count > 1, let current = activeIndex else { return }
        let count = openURLs.count
        activate(index: ((current + offset) % count + count) % count)
    }

    /// Files closed in this pane, most recent last, so ⇧⌘T can put one back.
    /// Bounded: this is an undo affordance for a slip of the hand, not a
    /// session history.
    private var closedURLs: [URL] = []
    static let reopenableTabs = 10

    @discardableResult
    func reopenLastClosedTab() -> Bool {
        while let url = closedURLs.popLast() {
            // A file that has since been deleted, or that is already open
            // again, is not what the user meant to get back.
            guard FileManager.default.fileExists(atPath: url.path),
                  !openURLs.contains(url) else { continue }
            open(url: url)
            return true
        }
        return false
    }

    var currentURL: URL? { activeIndex.flatMap { openURLs.indices.contains($0) ? openURLs[$0] : nil } }
    private var currentDocument: Document? { currentURL.map { DocumentStore.shared.document(for: $0) } }

    /// Highlight the tab strip when this pane has focus.
    /// The strip's height as laid out, which follows the window's traffic-light
    /// geometry. Read by the tests that check that alignment.
    var tabBarHeight: CGFloat { tabBar.currentHeight }
    var isActivePane = false { didSet { tabBar.paneActive = isActivePane } }

    private let findBar = FindBarView()
    /// The three round buttons that ride beside the text while a search has
    /// results. The bar itself is at the top of the pane, a long way from what
    /// is being read.
    private let searchNavigator = SearchNavigatorView()
    private var findBarHeight: NSLayoutConstraint!
    private var findStates: [URL: FindBarView.State] = [:]
    /// The document actually bound to the shared bar, even while tab indices change.
    private var findBarURL: URL?
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
    private var svgPreview: SVGPreviewView?
    private var svgRenderWork: DispatchWorkItem?
    /// The last picture that rendered, kept so a half-typed edit shows the
    /// drawing it is being made from rather than an empty pane.
    private var lastRenderedSVG: NSImage?
    /// The text view starts under the header, or under the SVG preview when
    /// there is one. Exactly one of these is active.
    private lazy var scrollTopBelowHeader =
        scrollView.topAnchor.constraint(equalTo: diffHeader.bottomAnchor)
    /// Rebuilt with the preview: the view it pins to is released when the pane
    /// shows something else, and a constraint to a released view pins nothing.
    private var scrollTopBelowSVGPreview: NSLayoutConstraint?
    /// Shown instead of the text view when the active document is audio/video.
    private var mediaPreview: MediaPreviewView?
    /// Shown instead of the text view when the active document is an EPUB.
    private var epubReader: EPUBReaderView?
    /// Shown instead of the text view when the buffer is only an explanation.
    private var placeholder: PlaceholderView?
    private var pdfPreview: PDFPreviewView?
    private var pdfThumbnailsVisible = true
    private var epubContentsVisible = true
    /// Shown instead of the text view for a file-history table tab.
    private var fileHistoryView: FileHistoryView?

    /// Fold identities are pane-local, but survive switching between tabs.
    private var foldedBlocks: [URL: Set<Int>] = [:]

    override func loadView() {
        let container = FlatView()
        container.fillColor = Theme.editorBackground

        blankStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(size: NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = false
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
        // No padding above the first line: the code starts where the editor
        // starts, as it does in VS Code, Zed and Xcode. The horizontal inset
        // stays — without it the first character sits against the gutter.
        textView.textContainerInset = NSSize(width: 6, height: 0)
        textView.rememberBaseInset()
        // Required for the text view to grow with content (otherwise no scrolling).
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
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
            self.textView.searchResultLineLocation = nil
            self.lineActivatedURLs.insert(url)
            self.textView.showsCurrentLineBand = self.currentDocument?.languageSpec?.name
                != "markdown"
        }
        textView.onCommandClick = { [weak self] location in
            self?.navigateToDefinition(at: location) ?? false
        }
        textView.onOpenLink = { [weak self] link in self?.openMarkdownLink(link) }
        textView.onEditLink = { [weak self] link in self?.showMarkdownSource(link.fullRange) }
        textView.onShowMarkdownSource = { [weak self] range in self?.showMarkdownSource(range) }
        textView.onToggleMarkdownSource = { [weak self] in self?.toggleMarkdownSource() }
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
        scrollView.hasHorizontalScroller = true
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
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipViewScrolled(_:)),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.onSelect = { [weak self] in self?.activate(index: $0) }
        tabBar.onClose = { [weak self] in self?.close(index: $0) }
        tabBar.onCloseOthers = { [weak self] in self?.closeOtherTabs(around: $0) }
        tabBar.onCloseRight = { [weak self] in self?.closeTabsToTheRight(of: $0) }
        tabBar.onCloseAll = { [weak self] in self?.closeAllTabs() }
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

        searchNavigator.translatesAutoresizingMaskIntoConstraints = false
        searchNavigator.isHidden = true
        searchNavigator.onPrevious = { [weak self] in self?.findBar.goToPreviousMatch() }
        searchNavigator.onNext = { [weak self] in self?.findBar.goToNextMatch() }
        searchNavigator.onClear = { [weak self] in self?.hideFindBar() }
        searchNavigator.scrollTarget = scrollView
        findBar.onMatchesChanged = { [weak self] in self?.refreshSearchNavigator() }

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
            scrollTopBelowHeader,
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        // Added last so it floats over the text, and pinned to the text's own
        // area rather than the pane's: the bar and the tab strip above it are
        // not what these belong beside.
        container.addSubview(searchNavigator)
        NSLayoutConstraint.activate([
            searchNavigator.trailingAnchor.constraint(
                equalTo: scrollView.trailingAnchor,
                constant: -SearchNavigatorView.trailingInset),
            searchNavigator.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
        self.view = container
        reloadTabs()
    }

    // MARK: - Uncommitted change marks

    /// Reload HEAD's copy of the file on screen and re-mark against it. Runs
    /// off the main thread: it shells out to Git, and the editor must not wait
    /// for it. Called when the file, the repository, or HEAD itself changes —
    /// the marks in between come from the baseline this leaves behind.
    func refreshGitLineChanges(reloadBaseline: Bool = true) {
        // The repository can be handed to a pane before its views exist.
        guard isViewLoaded else { return }
        liveMarkWork?.cancel()
        // Saving a file cannot move HEAD, so the copy already in hand is still
        // the right one to mark against. Asking Git again is ~65 ms, and with
        // autosave a save happens on every focus change.
        if !reloadBaseline, gitBaseline != nil, gitBaselineURL == currentURL {
            recomputeGitLineChanges()
            return
        }
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
        // A re-indented buffer is compared against a re-indented HEAD: the
        // marks answer "what did you change", not "what did the formatter do".
        let formatted = document.isDisplayFormatted
        // Superseded work is abandoned before it starts a subprocess, not after
        // it has finished one: switching through a dozen tabs used to queue a
        // dozen `git show`s and throw away eleven answers.
        gitBaselineToken?.cancel()
        let token = CancellationToken()
        gitBaselineToken = token
        GitService.workQueue.async { [weak self] in
            guard !token.isCancelled else { return }
            var baseline = GitLineChanges.baseline(for: url, in: root)
            if formatted, case .lines(let lines) = baseline, !lines.isEmpty,
               let pretty = JSONFormatter.pretty(lines.joined(separator: "\n")) {
                baseline = .lines(GitLineChanges.lines(of: pretty))
            }
            guard !token.isCancelled else { return }
            DispatchQueue.main.async {
                guard let self, self.gitLineChangeGeneration == generation,
                      self.currentURL == url else { return }
                switch baseline {
                case .lines(let lines):
                    self.gitBaseline = lines
                    self.gitBaselineURL = url
                    self.recomputeGitLineChanges()
                case .untracked:
                    self.gitBaseline = nil
                    self.gitBaselineURL = url
                    self.recomputeGitLineChanges()
                case .unavailable:
                    // Not an answer, so it must not be shown as "no changes".
                    // Marks already up for this same file stay; anything left
                    // over from another file goes, and no baseline is recorded,
                    // so the next refresh asks again.
                    guard self.gitBaselineURL != url else { return }
                    self.gitBaseline = nil
                    self.gitBaselineURL = nil
                    self.applyGitLineChanges([], for: url)
                }
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
        // Same rule as the baseline lookup and the project search: superseded
        // work is stopped, not merely ignored when it finishes. No subprocess
        // here, but a buffer's worth of lines is copied and walked twice over.
        liveMarkToken?.cancel()
        let token = CancellationToken()
        liveMarkToken = token
        Self.liveMarkQueue.async { [weak self] in
            guard !token.isCancelled,
                  let changes = GitLineChanges.changes(
                    from: baseline, to: GitLineChanges.lines(of: snapshot as String),
                    cancellation: token)
            else { return }
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
    /// Put one gutter mark's lines back the way HEAD has them.
    ///
    /// Edited through the text view rather than the storage, so this is one
    /// ⌘Z away like any other edit, and the marks, the tab's modified dot and
    /// the autosave that follows all behave as they do for typing.
    @discardableResult
    func revertGitChange(_ change: GitLineChanges.Change) -> Bool {
        guard let document = currentDocument, !document.isReadOnly else { return false }
        let text = textView.string as NSString
        let index = document.lineIndex
        func start(ofLine line: Int) -> Int {
            index.start(ofLine: max(1, min(line, index.lineCount + 1)))
        }
        let target: NSRange
        switch change.kind {
        case .added, .modified:
            let from = start(ofLine: change.lines.lowerBound)
            let to = start(ofLine: change.lines.upperBound + 1)
            target = NSRange(location: from, length: max(0, to - from))
        case .deleted:
            // The removed lines belonged above the line the mark is pinned to,
            // so this is an insertion, not a replacement.
            target = NSRange(location: start(ofLine: change.lines.lowerBound), length: 0)
        }
        guard NSMaxRange(target) <= text.length else { return false }
        var replacement = change.removed.joined(separator: "\n")
        // Keep the file's line structure: a replaced run of whole lines ends
        // with a terminator, unless it was the last line and that line had
        // none of its own.
        if !replacement.isEmpty {
            let replacedTerminator = target.length > 0
                && text.character(at: NSMaxRange(target) - 1) == 0x0A
            if replacedTerminator || target.length == 0 { replacement += "\n" }
        }
        // Through `insertText`, the same door typing comes through: it asks the
        // delegate, opens and closes one undo group, marks the document, and
        // leaves the caret where a person editing that line would have left it.
        // Calling `shouldChangeText` as well would register the change twice
        // and the undo would put the lines back twice over.
        guard textView.isEditable else { return false }
        textView.insertText(replacement, replacementRange: target)
        textView.setSelectedRange(NSRange(location: target.location, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        return true
    }

    /// Follow a link from a rendered Markdown document, at the reader's
    /// request. A Markdown file next to this one opens in a tab — leaving the
    /// editor to read the notes it links to would be absurd — and everything
    /// else is handed to whatever the system opens it with.
    private func openMarkdownLink(_ link: MarkdownLinkDecoration) {
        guard let url = link.url else { return }
        if url.isFileURL {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path,
                                                 isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                return
            }
            open(url: url)
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func showGitChange(_ change: GitLineChanges.Change, from rect: NSRect) {
        guard let ruler = scrollView.verticalRulerView, let window = view.window else { return }
        let gutter = ruler as? LineNumberRulerView
        // The mark of the change already showing puts it away again.
        if let open = gitChangePopover, open.isShown, open.controller.change == change {
            open.dismiss()
            return
        }
        let sourceURL = currentURL
        let controller = GitChangePopoverController(change: change)
        controller.canRevert = currentDocument.map { !$0.isReadOnly } ?? false
        controller.onRevert = { [weak self] in
            guard let self, self.currentURL == sourceURL else { return }
            self.gitChangePopover?.close()
            self.revertGitChange(change)
        }
        let anchor = window.convertToScreen(ruler.convert(rect, to: nil))
        // Another change while one is showing: the same panel flows there.
        if let open = gitChangePopover, open.isVisible, open.parent === window {
            open.move(to: controller, below: anchor, codeArea: visibleCodeAreaOnScreen)
            gutter?.linkChange(change, to: open)
            return
        }
        gitChangePopover?.close()
        let popover = GitChangePanel(controller: controller)
        popover.onFrameChange = { [weak gutter] in gutter?.needsDisplay = true }
        popover.ignoresClick = { [weak gutter] event in gutter?.isChangeMark(event) ?? false }
        popover.show(below: anchor, codeArea: visibleCodeAreaOnScreen, in: window)
        gitChangePopover = popover
        // The gutter joins the clicked mark to the panel while it is up.
        gutter?.linkChange(change, to: popover)
        popover.onClose = { [weak gutter] in gutter?.linkChange(nil, to: nil) }
    }

    /// The clip includes the ruler in its content insets. Subtract those,
    /// rather than using the text document's potentially very wide frame.
    private var visibleCodeAreaOnScreen: NSRect {
        guard let window = view.window else { return .zero }
        let clip = scrollView.contentView
        let insets = clip.contentInsets
        let rect = NSRect(x: clip.bounds.minX + insets.left,
                          y: clip.bounds.minY + insets.top,
                          width: max(0, clip.bounds.width - insets.left - insets.right),
                          height: max(0, clip.bounds.height - insets.top - insets.bottom))
        return window.convertToScreen(clip.convert(rect, to: nil))
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
    var gitChangePopoverSizeForTesting: NSSize? { gitChangePopover?.frame.size }
    var gitChangePanelForTesting: NSPanel? { gitChangePopover }
    var gitChangeCodeAreaForTesting: NSRect { visibleCodeAreaOnScreen }
    var gitChangePopoverControllerForTesting: GitChangePopoverController? {
        gitChangePopover?.controller
    }
    var gitChangePopoverContentForTesting: String? {
        gitChangePopover?.controller.contentForTesting
    }
    var placeholderForTesting: PlaceholderView? { placeholder }
    var textIsHiddenForTesting: Bool { scrollView.isHidden }
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
    var textViewForTesting: PuzzleTextView { textView }
    var svgPreviewForTesting: SVGPreviewView? { svgPreview }
    @discardableResult
    func focusEditorForTesting() -> Bool { view.window?.makeFirstResponder(textView) ?? false }
    func insertTextForTesting(_ text: String) {
        textView.insertText(text, replacementRange: textView.selectedRange())
    }
    func setCaretForTesting(_ location: Int) {
        textView.setSelectedRange(NSRange(location: location, length: 0))
    }
    /// A click at a character: the explicit interaction a mouse-down reports,
    /// then the caret where the click lands.
    func clickForTesting(at location: Int) {
        textView.onExplicitCaretInteraction?()
        textView.setSelectedRange(NSRange(location: location, length: 0))
    }
    var textInsetForTesting: CGFloat { textView.textContainerInset.width }
    var textViewWidthForTesting: CGFloat { textView.bounds.width }
    /// Whether a silent write goes through — false when the file changed on
    /// disk and only the user can choose a side.
    var autosaveWritesForTesting: Bool {
        guard let document = currentDocument else { return false }
        return persistForTesting(document)
    }
    var findBarForTesting: FindBarView { findBar }
    var searchNavigatorForTesting: SearchNavigatorView { searchNavigator }
    /// The code area itself, which the navigator is measured against.
    var scrollViewForTesting: NSScrollView { scrollView }
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

    /// The picture an SVG file describes, above the source. Just under half the
    /// pane: enough to see the drawing, with the file still the thing being
    /// worked on.
    private func ensureSVGPreview() -> SVGPreviewView {
        if let svgPreview { return svgPreview }
        let preview = SVGPreviewView()
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.isHidden = true
        view.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: diffHeader.bottomAnchor),
            preview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            preview.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.45),
        ])
        scrollTopBelowSVGPreview = scrollView.topAnchor.constraint(
            equalTo: preview.bottomAnchor)
        svgPreview = preview
        return preview
    }

    /// Draw what the buffer currently describes, and say so when it does not.
    ///
    /// An edit mid-tag leaves the source undrawable for a keystroke or two.
    /// The last picture that rendered stays on screen, marked, rather than the
    /// pane going blank every time a `<` is typed.
    private func refreshSVGPreview(for document: Document) {
        let preview = ensureSVGPreview()
        if let sides = document.svgDiffSides {
            let before = SVGPreviewView.render(sides.before)
            let after = SVGPreviewView.render(sides.after)
            // Two versions only when there are two. A file this change adds has
            // nothing to compare against, so it is shown the way an ordinary
            // SVG file is: one picture, over the source below it.
            func pane(_ title: String?, _ image: NSImage?, _ data: Data?) -> SVGPreviewView.Pane {
                SVGPreviewView.Pane(
                    title: title, image: image,
                    caption: SVGPreviewView.caption(name: nil, image: image,
                                                    bytes: data?.count ?? 0),
                    note: image == nil ? "Nothing to draw" : nil)
            }
            switch (before, after) {
            case (nil, _): preview.show([pane(nil, after, sides.after)])
            case (_, nil): preview.show([pane("Deleted", before, sides.before)])
            default:
                preview.show([pane("Before", before, sides.before),
                              pane("After", after, sides.after)])
            }
            return
        }
        // The buffer, not the file: the caption describes what is on screen.
        let bytes = document.text.utf8.count
        let name = document.url.lastPathComponent
        if let image = SVGPreviewView.render(document.text) {
            lastRenderedSVG = image
            preview.show([SVGPreviewView.Pane(
                title: nil, image: image,
                caption: SVGPreviewView.caption(name: name, image: image, bytes: bytes),
                note: nil)])
        } else {
            preview.show([SVGPreviewView.Pane(
                title: nil, image: lastRenderedSVG,
                caption: SVGPreviewView.caption(name: name, image: lastRenderedSVG,
                                                bytes: bytes),
                note: lastRenderedSVG == nil
                    ? "Nothing to draw yet"
                    : "Showing the last version that rendered")])
        }
    }

    /// Redraw once the typing settles, not on every keystroke: rendering an SVG
    /// is cheap but not free, and a picture that flickers between half-typed
    /// states is harder to read than one that lands a moment later.
    private func scheduleSVGRender(for document: Document) {
        svgRenderWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak document] in
            guard let self, let document, document === self.currentDocument else { return }
            self.refreshSVGPreview(for: document)
        }
        svgRenderWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.svgRenderDelay, execute: work)
    }

    static let svgRenderDelay: TimeInterval = 0.25

    private func releaseSVGPreview() {
        svgRenderWork?.cancel()
        svgRenderWork = nil
        lastRenderedSVG = nil
        guard let svgPreview else { return }
        scrollTopBelowSVGPreview?.isActive = false
        scrollTopBelowSVGPreview = nil
        scrollTopBelowHeader.isActive = true
        svgPreview.clear()
        svgPreview.isHidden = true
        svgPreview.removeFromSuperview()
        self.svgPreview = nil
    }

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

    private func ensurePlaceholder() -> PlaceholderView {
        if let placeholder { return placeholder }
        let view = PlaceholderView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        self.view.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: diffHeader.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
        ])
        placeholder = view
        return view
    }

    private func ensureMediaPreview() -> MediaPreviewView {
        if let mediaPreview { return mediaPreview }
        let preview = MediaPreviewView()
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.isHidden = true
        view.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: diffHeader.bottomAnchor),
            preview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            preview.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        mediaPreview = preview
        return preview
    }

    private func ensureEPUBReader() -> EPUBReaderView {
        if let epubReader { return epubReader }
        let reader = EPUBReaderView()
        reader.contentsVisible = epubContentsVisible
        reader.translatesAutoresizingMaskIntoConstraints = false
        reader.isHidden = true
        view.addSubview(reader)
        NSLayoutConstraint.activate([
            reader.topAnchor.constraint(equalTo: diffHeader.bottomAnchor),
            reader.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            reader.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            reader.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        epubReader = reader
        return reader
    }

    private func ensurePDFPreview() -> PDFPreviewView {
        if let pdfPreview { return pdfPreview }
        let preview = PDFPreviewView()
        preview.thumbnailsVisible = pdfThumbnailsVisible
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.isHidden = true
        view.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: diffHeader.bottomAnchor),
            preview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            preview.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        pdfPreview = preview
        return preview
    }

    var pdfPreviewForTesting: PDFPreviewView? { pdfPreview }

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
        guard let currentURL else { return }
        // Capture the selection before attaching/recomputing: an empty query
        // collapses the old selection, and a previous query can move it.
        let selected = textView.selectedRange()
        let source = textView.string as NSString
        let selectionSeed: String? = selected.length > 0 && NSMaxRange(selected) <= source.length
            ? source.substring(with: selected) : nil
        let query = seed ?? selectionSeed.flatMap {
            $0.rangeOfCharacter(from: .newlines) == nil ? $0 : nil
        } ?? findBar.state.query
        findBar.isHidden = false
        findBarURL = currentURL
        var state = findBar.state
        state.query = query
        state.currentRange = nil
        findBar.restore(state, to: textView)
        findBar.setQuery(query)
        findBar.setReplaceVisible(replacing)
        findBarHeight.constant = findBar.preferredHeight
        if !replacing { findBar.focus() }
        refreshSearchNavigator()
    }

    /// The buttons are there only while a search has something to step through:
    /// an empty query, or one that finds nothing, has nothing for them to do.
    private func refreshSearchNavigator() {
        searchNavigator.isHidden = findBar.isHidden || !findBar.hasMatches
    }

    private func saveFindState() {
        guard let url = findBarURL, openURLs.contains(url) else { return }
        findStates[url] = findBar.state
    }

    private func restoreFindState(for url: URL?) {
        if findBarURL != url && findBar.hasKeyboardFocus {
            view.window?.makeFirstResponder(textView)
        }
        findBarURL = url
        findBar.restore(url.flatMap { findStates[$0] } ?? .init(), to: textView)
        findBarHeight.constant = findBar.isHidden ? 0 : findBar.preferredHeight
        refreshSearchNavigator()
    }

    func hideFindBar() {
        findBar.finish()
        findBar.clearHighlights()
        findBar.isHidden = true
        findBarHeight.constant = 0
        refreshSearchNavigator()
        view.window?.makeFirstResponder(textView)
    }

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
        saveFindState()
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
        if let value = findStates.removeValue(forKey: oldURL) { findStates[newURL] = value }
        if findBarURL == oldURL { findBarURL = newURL }
        if let value = selections.removeValue(forKey: oldURL) { selections[newURL] = value }
        if lineActivatedURLs.remove(oldURL) != nil { lineActivatedURLs.insert(newURL) }
        if markdownSourceURLs.remove(oldURL) != nil { markdownSourceURLs.insert(newURL) }
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

    /// Source and diffs keep their hard line breaks. Only rendered Markdown
    /// follows the reading column; a wide source tab must not leave that
    /// column (or the next short file) with a stale document width.
    private func configureLineWrapping(for document: Document) {
        guard let container = textView.textContainer else { return }
        let wraps = document.languageSpec?.name == "markdown"
        scrollView.rulersVisible = !wraps
        scrollView.hasHorizontalScroller = !wraps
        textView.isHorizontallyResizable = !wraps
        container.widthTracksTextView = wraps
        textView.readingColumn = wraps ? Theme.markdownColumn() : nil
        scrollView.tile()
        let clip = scrollView.contentView
        let width = max(0, clip.bounds.width - clip.contentInsets.left - clip.contentInsets.right)
        textView.minSize = NSSize(width: width, height: 0)
        textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
        container.containerSize = NSSize(
            width: wraps ? max(0, width - 2 * textView.textContainerInset.width)
                : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        textView.sizeToFit()
        clip.scroll(to: NSPoint(x: -clip.contentInsets.left, y: clip.bounds.minY))
        scrollView.reflectScrolledClipView(clip)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard let scrollView, let textView else { return }
        let clip = scrollView.contentView
        let width = max(0, clip.bounds.width - clip.contentInsets.left - clip.contentInsets.right)
        // NSTextView otherwise shrinks a short source buffer to its last
        // glyph. Refit only when the viewport width changes, never on typing
        // or ordinary layout passes.
        if abs(textView.minSize.width - width) > 0.5 {
            textView.minSize = NSSize(width: width, height: 0)
            textView.sizeToFit()
        }
        if let panel = gitChangePopover, panel.isVisible,
           abs(panel.frame.width - visibleCodeAreaOnScreen.width) > 0.5 {
            panel.close()
        }
    }

    func activate(index: Int) {
        guard openURLs.indices.contains(index) else { return }
        gitChangePopover?.close()
        saveFindState()
        // These character offsets belong to the outgoing storage only.
        findBar.clearHighlights()
        // Remember where the caret was in the outgoing document, and write it
        // out: moving to another tab is leaving this one.
        if let prev = currentURL {
            selections[prev] = textView.selectedRange()
            foldedBlocks[prev] = layoutManager.foldedBlockIdentities
            if prev != openURLs[index] { autosaveIfNeeded() }
        }

        let previousURL = currentURL
        activeIndex = index
        clearDefinitionHover()
        let url = openURLs[index]
        if url != previousURL {
            markdownLinkSource = nil
            textView.topSlack = 0
        }
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

        configureLineWrapping(for: doc)

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
        // Brackets open blocks in code. In prose, and in a file with no
        // language at all, a line ending in "(" is just a line ending in "(".
        textView.usesBracketIndent = doc.languageSpec != nil
            && doc.languageSpec?.name != "markdown"
        textView.rendersMarkdown = doc.languageSpec?.name == "markdown"
        textView.commentSyntax = CommentToggle.syntax(forLanguage: doc.languageSpec?.name,
                                                      fileExtension: url.pathExtension)
        if !lineIsActive { clearInlineBlameRequest() }
        textView.diffBands = doc.diffBands
        textView.diffLineNumbers = doc.diffLineNumbers
        textView.updateCodeBlocks(doc.codeBlocks, resetFolds: false)
        layoutManager.restoreFoldedBlockIdentities(foldedBlocks[url] ?? [])
        presentMarkdown(of: doc)

        if !doc.isPDF {
            releasePDFPreview()
        }
        // Synthetic file-history tabs use a real four-column table. Keep this
        // check ahead of images/text so only one primary content view is shown.
        if let historyModel = fileHistoryProvider?(url) {
            let history = ensureFileHistoryView()
            history.configure(historyModel)
            history.isHidden = false
            hidePreviews()
            scrollView.isHidden = true
            showDiffHeader(for: nil)
        } else if let source = doc.previewImage {
            fileHistoryView?.isHidden = true
            releaseMediaPreview()
            releaseEPUBReader()
            let imagePreview = ensureImagePreview()
            imagePreview.show(source: source, caption: doc.text)
            imagePreview.isHidden = false
            scrollView.isHidden = true
            showDiffHeader(for: nil)
        } else if doc.isMedia {
            fileHistoryView?.isHidden = true
            releaseImagePreview()
            releaseEPUBReader()
            let mediaPreview = ensureMediaPreview()
            mediaPreview.show(url: url, caption: doc.text, isVideo: doc.isVideoMedia)
            mediaPreview.isHidden = false
            scrollView.isHidden = true
            showDiffHeader(for: nil)
        } else if doc.isPDF {
            fileHistoryView?.isHidden = true
            releaseImagePreview()
            releaseMediaPreview()
            releaseEPUBReader()
            let preview = ensurePDFPreview()
            preview.show(url: url, caption: doc.text)
            preview.isHidden = false
            scrollView.isHidden = true
            showDiffHeader(for: nil)
        } else if doc.isEPUB, ensureEPUBReader().show(url: url) {
            // A file that claims to be an EPUB but is not a readable archive
            // falls through to the text path, where it reports itself as an
            // unsupported binary instead of showing an empty reader.
            fileHistoryView?.isHidden = true
            releaseImagePreview()
            releaseMediaPreview()
            epubReader?.isHidden = false
            scrollView.isHidden = true
            showDiffHeader(for: nil)
        } else if doc.isPlaceholder {
            fileHistoryView?.isHidden = true
            releaseImagePreview()
            releaseMediaPreview()
            releaseEPUBReader()
            releasePDFPreview()
            releaseSVGPreview()
            let placeholder = ensurePlaceholder()
            placeholder.show(message: doc.text)
            placeholder.isHidden = false
            scrollView.isHidden = true
            showDiffHeader(for: nil)
        } else {
            fileHistoryView?.isHidden = true
            hidePreviews()
            scrollView.isHidden = false
            // An SVG is source with a picture attached: the drawing goes above
            // the text that describes it, and a diff of one shows both
            // versions side by side over the diff itself.
            if doc.isSVG || doc.svgDiffSides != nil {
                let preview = ensureSVGPreview()
                preview.isHidden = false
                scrollTopBelowHeader.isActive = false
                scrollTopBelowSVGPreview?.isActive = true
                refreshSVGPreview(for: doc)
            }
            showDiffHeader(for: doc.diffLineNumbers.isEmpty ? nil : url)
        }

        restoreFindState(for: url)
        reloadTabs()
        refreshGitLineChanges()
        scrollView.verticalRulerView?.needsDisplay = true
        textView.needsDisplay = true
        onActiveDocumentChanged?(url)
        if lineIsActive { scheduleInlineBlame() }
    }

    func close(index: Int) {
        guard openURLs.indices.contains(index) else { return }
        let url = openURLs[index]
        guard confirmClose(urls: [url]) else { return }
        gitChangePopover?.close()
        openURLs.remove(at: index)
        if url.isFileURL {
            closedURLs.removeAll { $0 == url }
            closedURLs.append(url)
            if closedURLs.count > Self.reopenableTabs { closedURLs.removeFirst() }
        }
        selections.removeValue(forKey: url)
        findStates.removeValue(forKey: url)
        lineActivatedURLs.remove(url)
        markdownSourceURLs.remove(url)
        foldedBlocks.removeValue(forKey: url)
        defer { onTabClosed?(url) }
        if openURLs.isEmpty {
            activeIndex = nil
            layoutManager.textStorage?.removeLayoutManager(layoutManager)
            blankStorage.addLayoutManager(layoutManager)
            restoreFindState(for: nil)
            // No document: don't paint a current-line band in the empty area.
            textView.showsCurrentLineBand = false
            textView.updateCodeBlocks([], resetFolds: false)
            textView.updateJSXTagMatches([])
            layoutManager.updateMarkdownSyntaxRanges([], revealing: nil)
            textView.updateMarkdownDecorations(
                codeBlocks: [], tables: [], tasks: [], activeSourceRange: nil)
            hidePreviews()
            fileHistoryView?.isHidden = true
            scrollView.isHidden = false
            reloadTabs()
            onActiveDocumentChanged?(nil)
            onEmptied?(self)
            return
        }
        activate(index: min(index, openURLs.count - 1))
    }

    /// Close every tab, which is what switching projects does: the files of
    /// the project being left have no place in the one being entered.
    ///
    /// Closing one at a time rather than in a batch, because a batch keeps an
    /// anchor tab open by design — and because this is the path that writes
    /// each buffer on the way out. A refused close (a disk conflict the user
    /// cancelled) stops the walk rather than looping on it.
    /// True once every tab has closed; false when one would not, which stops
    /// the rest from closing too.
    @discardableResult
    func closeAllTabs() -> Bool {
        while !openURLs.isEmpty {
            let before = openURLs.count
            close(index: openURLs.count - 1)
            guard openURLs.count < before else { return false }
        }
        return true
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
        saveFindState()
        closed.forEach {
            selections.removeValue(forKey: $0)
            findStates.removeValue(forKey: $0)
            lineActivatedURLs.remove($0)
            markdownSourceURLs.remove($0)
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
        guard let doc = currentDocument else { return }
        saveCoordinator.save(doc, because: .explicit)
    }

    /// Write the buffer the user is leaving, the way Zed's
    /// `autosave: on_focus_change` does: switching tabs or panes, clicking into
    /// another part of the window, or leaving the app.
    ///
    /// Silent by design. A save that cannot go through — the file changed on
    /// disk underneath the edit — leaves the document dirty and says nothing,
    /// rather than throwing a modal at someone who has already looked away.
    /// Explicit Save writes the current buffer; closing can ask about a conflict.
    func autosaveIfNeeded() {
        idleSaveWork?.cancel()
        // Virtual buffers are excluded here and only here: leaving a diff tab
        // is not a reason to replay it into a source file. Closing one is.
        guard let document = currentDocument, !document.isVirtual else { return }
        saveCoordinator.save(document, because: .leaving)
    }

    func persistForTesting(_ document: Document) -> Bool {
        saveCoordinator.save(document, because: .test)
    }

    /// Write every modified document before mutating tab ownership.
    ///
    /// Closing writes the buffer rather than asking about it — the same rule
    /// leaving it does, and the reason there is no "Save changes?" sheet: a
    /// question whose answer we already know is not worth asking. Undo, not a
    /// modal, is how an edit is taken back.
    ///
    /// The one case that still asks is a save that cannot go through on its
    /// own: the file changed on disk under the edit. Choosing between the two
    /// versions is not ours to make, and closing silently would drop one of
    /// them. `persist` puts that question up itself.
    ///
    /// Returns false only when the user cancelled such a question, which
    /// leaves the tab (or the window) open.
    func confirmClose(urls: [URL]) -> Bool {
        var seen = Set<URL>()
        for url in urls where seen.insert(url).inserted {
            guard let document = DocumentStore.shared.cachedDocument(for: url) else { continue }
            guard saveCoordinator.save(document, because: .closing) else { return false }
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
        textView.searchResultLineLocation = nil
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
              !document.isVirtual, !document.isUnsupported, !document.isPreviewOnly else {
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
              !document.isVirtual, !document.isUnsupported, !document.isPreviewOnly else {
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
        gitChangePopover?.close()
        clearDefinitionHover()
        blameGeneration += 1
        blameWork?.cancel()
        blameWork = nil
        blameCache.removeAll()
        blameOrder.removeAll()
        releaseImagePreview()
        releaseMediaPreview()
        releaseEPUBReader()
        textView.updateCodeBlocks([], resetFolds: false)
        releasePDFPreview()
        textView.updateJSXTagMatches([])
        detachFromDocument()
        let urls = openURLs
        openURLs.removeAll()
        activeIndex = nil
        selections.removeAll()
        findStates.removeAll()
        restoreFindState(for: nil)
        lineActivatedURLs.removeAll()
        markdownSourceURLs.removeAll()
        foldedBlocks.removeAll()
        urls.forEach { onTabClosed?($0) }
    }

    /// Tear down inactive previews, including framework-owned view caches.
    private func releaseImagePreview() {
        imagePreview?.clear()
        imagePreview?.isHidden = true
        imagePreview?.removeFromSuperview()
        imagePreview = nil
    }

    private func releasePlaceholder() {
        placeholder?.clear()
        placeholder?.isHidden = true
        placeholder?.removeFromSuperview()
        placeholder = nil
    }

    private func releaseMediaPreview() {
        mediaPreview?.clear()
        mediaPreview?.isHidden = true
        mediaPreview?.removeFromSuperview()
        mediaPreview = nil
    }

    private func releaseEPUBReader() {
        if let epubReader { epubContentsVisible = epubReader.contentsVisible }
        epubReader?.clear()
        epubReader?.isHidden = true
        epubReader?.removeFromSuperview()
        epubReader = nil
    }

    private func releasePDFPreview() {
        if let pdfPreview { pdfThumbnailsVisible = pdfPreview.thumbnailsVisible }
        pdfPreview?.clear()
        pdfPreview?.isHidden = true
        pdfPreview?.removeFromSuperview()
        pdfPreview = nil
    }

    private func hidePreviews() {
        releasePlaceholder()
        releasePDFPreview()
        releaseImagePreview()
        releaseMediaPreview()
        releaseEPUBReader()
        releaseSVGPreview()
    }

    /// Release view-owned payloads that are not currently visible. Documents
    /// themselves are handled separately by `DocumentStore`.
    func releaseTransientMemory() {
        if placeholder?.isHidden != false { releasePlaceholder() }
        if svgPreview?.isHidden != false { releaseSVGPreview() }
        if imagePreview?.isHidden != false { releaseImagePreview() }
        if mediaPreview?.isHidden != false { releaseMediaPreview() }
        if epubReader?.isHidden != false { releaseEPUBReader() }
        if pdfPreview?.isHidden != false { releasePDFPreview() }
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
        mediaPreview?.refreshFonts()
        pdfPreview?.refreshFonts()
        epubReader?.refreshFonts()
        placeholder?.refreshFonts()
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
        gitChangePopover?.close()
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
        // An edit is what shows a line's source: the line the caret is on now.
        if doc.languageSpec?.name == "markdown", let url = currentURL {
            let caret = min(textView.selectedRange().location, doc.storage.length)
            markdownEditLine = (url, (doc.storage.string as NSString)
                .lineRange(for: NSRange(location: caret, length: 0)).location)
        }
        applyMarkdownReveal(for: doc)
        textView.refreshBracketMatches()
        scheduleGitLineChanges()
        scheduleIdleSave(for: doc)
        if doc.isSVG { scheduleSVGRender(for: doc) }
    }

    /// Write the buffer once the typing stops.
    ///
    /// Focus changes and ⌘S still save; this covers the case neither of them
    /// does — a long editing session in one window, where the file on disk
    /// stays as it was when the tab was opened.
    ///
    /// The document is captured rather than looked up when the timer fires: by
    /// then the pane may be showing a different tab, and the buffer that was
    /// edited is the one that has to be written.
    private func scheduleIdleSave(for document: Document) {
        idleSaveWork?.cancel()
        // Diff buffers are excluded here for the same reason `autosaveIfNeeded`
        // excludes them: pausing is not a decision to replay a diff into a
        // source file. Closing the tab, or ⌘S, is.
        guard document.isModified, !document.isReadOnly, !document.isVirtual else { return }
        let work = DispatchWorkItem { [weak self, weak document] in
            guard let self, let document else { return }
            // The same reason as the focus-change save: the user is still at
            // the keyboard, so nothing interrupts them.
            self.saveCoordinator.save(document, because: .leaving)
        }
        idleSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleSaveDelay, execute: work)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !suppressSelectionSideEffects else { return }
        textView.refreshBracketMatches()
        if let url = currentURL { selections[url] = textView.selectedRange() }
        if let document = currentDocument {
            // Leaving the line being edited ends its editing: it goes back to
            // being read.
            let selection = textView.selectedRange()
            if let editing = markdownEditLine {
                let caret = min(selection.location, document.storage.length)
                let line = (document.storage.string as NSString)
                    .lineRange(for: NSRange(location: caret, length: 0))
                if editing.url != currentURL || editing.start != line.location {
                    markdownEditLine = nil
                }
            }
            // And a link shown as written goes back to being a link.
            if let link = markdownLinkSource,
               link.url != currentURL || selection.location < link.range.location
                || NSMaxRange(selection) > NSMaxRange(link.range) {
                markdownLinkSource = nil
            }
            applyMarkdownReveal(for: document)
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
        keepingCaretInPlace { presentMarkdown(of: document) }
    }

    @objc private func documentReloadedFromDisk(_ notification: Notification) {
        guard let document = notification.object as? Document,
              openURLs.contains(document.url) else { return }
        reloadTabs()
        guard document.url == currentURL else { return }
        gitChangePopover?.close()

        let location = min(textView.selectedRange().location, document.storage.length)
        suppressSelectionSideEffects = true
        textView.setSelectedRange(NSRange(location: location, length: 0))
        suppressSelectionSideEffects = false
        textView.undoManager?.removeAllActions()
        // The reload re-decides whether this file can be shown in full, so the
        // buffer may have just become a read-only preview — or stopped being one.
        textView.isEditable = !document.isReadOnly
        // The whole buffer was replaced, so every range the find bar is holding
        // belongs to text that is gone.
        findBar.invalidateMatches()
        clearInlineBlameRequest()
        textView.updateCodeBlocks(document.codeBlocks, resetFolds: false)
        textView.updateJSXTagMatches(document.jsxTagMatches)
        keepingCaretInPlace { presentMarkdown(of: document) }
        textView.refreshBracketMatches()
        textView.needsDisplay = true
        scrollView.verticalRulerView?.needsDisplay = true
    }

    /// The line of a rendered Markdown document being edited, by where it
    /// starts — until the caret leaves the line.
    private var markdownEditLine: (url: URL, start: Int)?

    /// A link whose source the reader asked to edit, from the bar under it:
    /// shown as written until the caret leaves it. Kept in step with every
    /// edit to the buffer, which is what moves its end as the address is
    /// typed into.
    private var markdownLinkSource: (url: URL, range: NSRange)? {
        didSet {
            // Moving the range is done from inside the observer itself; only
            // a different link — or none — changes what is observed.
            guard markdownLinkSource?.url != oldValue?.url
                    || (markdownLinkSource == nil) != (oldValue == nil) else { return }
            if let observer = linkSourceObserver {
                NotificationCenter.default.removeObserver(observer)
                linkSourceObserver = nil
            }
            guard markdownLinkSource != nil, let storage = currentDocument?.storage else { return }
            linkSourceObserver = NotificationCenter.default.addObserver(
                forName: NSTextStorage.didProcessEditingNotification,
                object: storage, queue: nil) { [weak self] notification in
                guard let storage = notification.object as? NSTextStorage,
                      storage.editedMask.contains(.editedCharacters) else { return }
                self?.shiftMarkdownLinkSource(edited: storage.editedRange,
                                              delta: storage.changeInLength)
            }
        }
    }
    private var linkSourceObserver: NSObjectProtocol?

    private func shiftMarkdownLinkSource(edited: NSRange, delta: Int) {
        guard var source = markdownLinkSource else { return }
        let removedEnd = edited.location + edited.length - delta
        if removedEnd <= source.range.location {
            source.range.location += delta
        } else if edited.location < NSMaxRange(source.range) {
            // An edit that reaches back before the link has taken its start
            // with it: there is no link left to show.
            guard edited.location >= source.range.location else {
                markdownLinkSource = nil
                return
            }
            source.range.length = max(0, source.range.length + delta)
        }
        markdownLinkSource = source
    }

    /// What of a rendered Markdown document shows its source.
    private struct MarkdownReveal {
        /// Shown in the text as written — laid out again, so only ever what
        /// cannot be edited any other way: a line that draws nothing (a code
        /// fence, a table's divider, a link definition), a table row or a
        /// picture being edited — both are drawn over their source — a link
        /// the reader asked to edit, an entity the caret is inside.
        var text: NSRange?
        /// The line being edited: its lead is shown in the margin as written.
        var editLine: NSRange?
        /// A block's lead — a heading's `#`, a list's marker — while the caret
        /// is inside it.
        var lead: NSRange?
        /// What the decorations treat as source: the line being edited, or
        /// whatever line-sized thing the text shows.
        var source: NSRange? { editLine ?? text }
    }

    /// Editing a line leaves its inline syntax hidden: showing it moved the
    /// text being edited sideways and, for a long link, pushed every line
    /// under it down. The caret's place among hidden syntax is shown instead
    /// by marks that take no room, and a link's address by the bar under it.
    private func markdownReveal(for document: Document) -> MarkdownReveal {
        guard document.languageSpec?.name == "markdown", let url = currentURL else {
            return MarkdownReveal()
        }
        let source = document.storage.string as NSString
        // The whole document as written, when the reader asked for it.
        if markdownSourceURLs.contains(url) {
            let all = NSRange(location: 0, length: source.length)
            return MarkdownReveal(text: all, editLine: nil, lead: all)
        }
        let selection = textView.selectedRange()
        let location = min(selection.location, source.length)
        let line = source.lineRange(for: NSRange(location: location, length: 0))
        var reveal = MarkdownReveal()
        if let editing = markdownEditLine, editing.url == url, editing.start == line.location {
            reveal.editLine = line
            if isMarkdownDrawnLine(line, in: document) { reveal.text = line }
        }
        // Merely opening a file leaves it rendered: the caret starts at the
        // top, which may well be inside a heading's `#`.
        guard lineActivatedURLs.contains(url) else { return reveal }
        if reveal.text == nil, isMarkdownControlLine(line, in: document) {
            reveal.text = line
        }
        if reveal.text == nil, let link = markdownLinkSource, link.url == url,
           link.range.location <= location, location <= NSMaxRange(link.range) {
            reveal.text = link.range
        }
        if reveal.text == nil, selection.length == 0,
           let entity = document.markdownGlyphReplacements.first(where: {
               $0.sourceRange.location < location && location < NSMaxRange($0.sourceRange)
           }) {
            reveal.text = entity.sourceRange
        }
        reveal.lead = document.markdownLeadRanges.first {
            NSLocationInRange(location, $0) && selection.length == 0
        }
        return reveal
    }

    /// A table row or a picture: drawn over its source, so editing one shows
    /// the source instead.
    private func isMarkdownDrawnLine(_ line: NSRange, in document: Document) -> Bool {
        let content = MarkdownLiveStyler.lineContentRange(
            line, in: document.storage.string as NSString)
        guard content.length > 0 else { return false }
        return document.markdownTables.contains(where: { table in
            table.rows.contains { NSLocationInRange(content.location, $0.lineRange) }
        }) || document.markdownImages.contains(where: {
            NSLocationInRange(content.location, $0.lineRange)
        })
    }

    /// A line whose every character is hidden — and which is not a table row
    /// or a picture, which draw themselves.
    private func isMarkdownControlLine(_ line: NSRange, in document: Document) -> Bool {
        let source = document.storage.string as NSString
        let content = MarkdownLiveStyler.lineContentRange(line, in: source)
        guard content.length > 0, !isMarkdownDrawnLine(line, in: document) else { return false }
        let hidden = document.markdownSyntaxRanges + document.markdownLeadRanges
        var covered = content.location
        for range in hidden.sorted(by: { $0.location < $1.location })
        where range.location <= covered && NSMaxRange(range) > covered {
            covered = NSMaxRange(range)
            if covered >= NSMaxRange(content) { return true }
        }
        return false
    }

    /// Hand the layout and the text view the document's Markdown, and what
    /// of it the caret shows.
    private func presentMarkdown(of document: Document) {
        let reveal = markdownReveal(for: document)
        layoutManager.updateMarkdownSyntaxRanges(
            document.markdownSyntaxRanges,
            leads: document.markdownLeadRanges,
            collapsedLines: document.markdownCollapsedLineRanges,
            replacements: document.markdownGlyphReplacements,
            revealing: reveal.text,
            revealingLead: reveal.lead)
        updateMarkdownDecorations(of: document, reveal: reveal)
    }

    /// Apply what `markdownReveal` says, holding the caret's line in place.
    private func applyMarkdownReveal(for document: Document) {
        keepingCaretInPlace {
            let reveal = markdownReveal(for: document)
            layoutManager.revealMarkdownSyntax(in: reveal.text, lead: reveal.lead)
            updateMarkdownDecorations(of: document, reveal: reveal)
        }
    }

    private func updateMarkdownDecorations(of document: Document, reveal: MarkdownReveal) {
        textView.updateMarkdownDecorations(
            codeBlocks: document.markdownCodeBlocks,
            tables: document.markdownTables,
            tasks: document.markdownTasks,
            lineMarkers: document.markdownLineMarkers,
            rules: document.markdownRules,
            images: document.markdownImages,
            links: document.markdownLinks,
            activeSourceRange: reveal.source,
            revealedLead: reveal.lead)
        textView.markdownSpans = document.markdownSpans
        updateMarkdownCaretCues(for: document, reveal: reveal)
    }

    /// The marks at the edges of the formatting the caret is in, and the bar
    /// under the link it is in.
    private func updateMarkdownCaretCues(for document: Document, reveal: MarkdownReveal) {
        guard document.languageSpec?.name == "markdown", let url = currentURL,
              lineActivatedURLs.contains(url) else {
            textView.setMarkdownSpanMarks([])
            textView.setCaretLink(nil, editable: false)
            return
        }
        let selection = textView.selectedRange()
        let location = selection.location
        // At either edge as well as inside: that is where a `**` is on one
        // side of the caret or the other, and where the marks are wanted.
        let spans = selection.length > 0 ? [] : document.markdownSpans.filter { span in
            span.range.location <= location && location <= NSMaxRange(span.range)
                && reveal.text.map { NSIntersectionRange($0, span.range).length > 0 } != true
        }
        textView.setMarkdownSpanMarks(spans)
        let link = selection.length > 0 ? nil : document.markdownLinks.first {
            $0.fullRange.location < location && location < NSMaxRange($0.fullRange)
        }
        guard let link, Self.hidesDestination(link, in: document),
              reveal.text.map({ NSIntersectionRange($0, link.fullRange).length > 0 }) != true
        else {
            textView.setCaretLink(nil, editable: false)
            return
        }
        // Brackets alone are not worth showing: a `[label]` defined elsewhere
        // has nothing here to edit.
        textView.setCaretLink(link, editable: link.fullRange.length - link.sourceRange.length > 2)
    }

    /// Whether the reader cannot see where a link goes — its text is a label,
    /// not the address. An autolink or a bare URL shows its own.
    private static func hidesDestination(_ link: MarkdownLinkDecoration,
                                         in document: Document) -> Bool {
        let source = document.storage.string as NSString
        guard NSMaxRange(link.sourceRange) <= source.length else { return false }
        let label = source.substring(with: link.sourceRange)
        return label != link.destination && "mailto:" + label != link.destination
    }

    /// Show `range` — a link, from the bar's Edit or ⌘K — as written, caret
    /// where it was.
    private func showMarkdownSource(_ range: NSRange) {
        guard let url = currentURL, let document = currentDocument else { return }
        markdownLinkSource = (url, range)
        applyMarkdownReveal(for: document)
    }

    /// Documents shown as source rather than rendered, at the reader's asking.
    private var markdownSourceURLs: Set<URL> = []
    var showsMarkdownSourceForTesting: Bool {
        currentURL.map { markdownSourceURLs.contains($0) } ?? false
    }

    /// ⇧⌘M. The line being read stays where it is: the caret's, when it is on
    /// screen, or the one at the top of the view.
    private func toggleMarkdownSource() {
        guard let url = currentURL, let document = currentDocument,
              document.languageSpec?.name == "markdown" else { return }
        let caret = min(textView.selectedRange().location, max(0, document.storage.length - 1))
        var anchor = caret
        if let container = textView.textContainer, document.storage.length > 0 {
            let caretLine = layoutManager.lineFragmentRect(
                forGlyphAt: layoutManager.glyphIndexForCharacter(at: caret), effectiveRange: nil)
                .offsetBy(dx: 0, dy: textView.textContainerOrigin.y)
            if !textView.visibleRect.intersects(caretLine) {
                let top = NSPoint(x: 0, y: max(0, textView.visibleRect.minY
                                                - textView.textContainerOrigin.y))
                anchor = layoutManager.characterIndexForGlyph(
                    at: layoutManager.glyphIndex(for: top, in: container))
            }
        }
        keepingCaretInPlace(anchor: anchor) {
            if markdownSourceURLs.remove(url) == nil { markdownSourceURLs.insert(url) }
            let reveal = markdownReveal(for: document)
            layoutManager.revealMarkdownSyntax(in: reveal.text, lead: reveal.lead)
            updateMarkdownDecorations(of: document, reveal: reveal)
        }
    }

    /// Keep the caret's line where it is on screen while `change` lays the
    /// text out again. Showing a line's source, or hiding it again once the
    /// caret has left it, changes heights — and a line above the one just
    /// clicked growing or shrinking moved the clicked line from under the
    /// pointer. The view scrolls by whatever the change moved the caret's line.
    ///
    /// `anchor` holds another line instead — the one being read, when the
    /// whole document changes at once.
    ///
    /// Near the top of the document there may be nothing left to scroll: the
    /// text above shrank by more than the view is scrolled down. The page
    /// takes the shortfall as room above the text instead, which it gives up
    /// again once it is scrolled out of sight — or as soon as anything above
    /// the caret, or the caret's own line, grows back into it.
    private func keepingCaretInPlace(anchor: Int? = nil, _ change: () -> Void) {
        guard currentDocument?.languageSpec?.name == "markdown",
              let storage = textView.textStorage, storage.length > 0 else {
            change()
            return
        }
        let clip = scrollView.contentView
        // On screen — measured against the visible area, not the text: when
        // the change is above what is visible, AppKit scrolls to make up for it
        // itself, and making up for it again moved the line twice as far.
        func caretLineOnScreen() -> (top: CGFloat, height: CGFloat) {
            let caret = min(anchor ?? textView.selectedRange().location, storage.length - 1)
            let glyph = layoutManager.glyphIndexForCharacter(at: caret)
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            return (line.minY + textView.textContainerOrigin.y - clip.bounds.minY, line.height)
        }
        let before = caretLineOnScreen()
        change()
        let after = caretLineOnScreen()
        var moved = after.top - before.top
        // The caret's own line growing — a fence the caret came onto — grows
        // up into the room rather than pushing everything under it down: the
        // room was left by that very line shrinking. The line moving up by as
        // much is the point, so that is not made up for below.
        let grown = after.height - before.height
        if grown > 0.5, textView.topSlack > 0 {
            textView.topSlack -= min(textView.topSlack, grown)
        }
        guard abs(moved) > 0.5 else { return }
        // Text above that grows back takes back the room it left first.
        if moved > 0, textView.topSlack > 0 {
            let taken = min(textView.topSlack, moved)
            textView.topSlack -= taken
            moved -= taken
        }
        var origin = clip.bounds.minY + moved
        if origin < 0 {
            textView.topSlack += -origin
            origin = 0
        }
        guard abs(origin - clip.bounds.minY) > 0.5 else { return }
        let target = NSRect(origin: NSPoint(x: clip.bounds.minX, y: origin),
                            size: clip.bounds.size)
        clip.setBoundsOrigin(clip.constrainBoundsRect(target).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    /// The room `keepingCaretInPlace` left above the text goes as soon as it
    /// is out of sight, with the view moved by as much, so nothing on screen
    /// moves.
    @objc private func clipViewScrolled(_ notification: Notification) {
        gitChangePopover?.close()
        let slack = textView.topSlack
        let clip = scrollView.contentView
        guard slack > 0, clip.bounds.minY >= slack else { return }
        textView.topSlack = 0
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: clip.bounds.minY - slack))
        scrollView.reflectScrolledClipView(clip)
    }
    var topSlackForTesting: CGFloat { textView.topSlack }

    // MARK: - Inline blame

    /// Project root, needed to run `git blame` in the right repository.
    var repositoryRoot: URL? {
        didSet { refreshGitLineChanges() }
    }
    /// Uncommitted changes for the file on screen, per line.
    private var gitLineChanges: [GitLineChanges.Change] = []
    private var gitLineChangesURL: URL?
    private var gitChangePopover: GitChangePanel?
    private var gitLineChangeGeneration = 0
    /// Stops a baseline lookup that is already running, which the generation
    /// counter alone cannot: it only decides whether to keep the answer.
    private var gitBaselineToken: CancellationToken?
    private var liveMarkToken: CancellationToken?
    /// Serial: marking the buffer twice at once holds two copies of its lines
    /// and only the newer answer is ever shown.
    private static let liveMarkQueue = DispatchQueue(label: "app.puzzle.line-marks",
                                                     qos: .utility)
    /// HEAD's copy of the file on screen, kept so an edit can be marked without
    /// asking Git again.
    private var gitBaseline: [String]?
    private var gitBaselineURL: URL?
    private var liveMarkWork: DispatchWorkItem?
    private var idleSaveWork: DispatchWorkItem?
    /// The one place that decides when a buffer is written and what it asks.
    private lazy var saveCoordinator: DocumentSaveCoordinator = {
        let coordinator = DocumentSaveCoordinator()
        coordinator.host = self
        return coordinator
    }()
    /// Long enough that a burst of typing is one diff, short enough that the
    /// ribbon appears while the line is still the one being written.
    static let liveMarkDelay: TimeInterval = 0.25
    /// How long the typing has to stop before the buffer is written.
    ///
    /// One second, which is what VS Code writes on (`files.autoSaveDelay`) and
    /// what Zed's `after_delay` is usually set to. Shorter turns a pause mid
    /// sentence into a write; much longer and the file on disk lags behind what
    /// the user is looking at, which is the thing autosave exists to prevent.
    /// JetBrains' 15 seconds is the outlier, and it leans on save-on-focus-loss
    /// the way this editor did before this.
    static let idleSaveDelay: TimeInterval = 1

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
        guard !doc.isVirtual, !doc.isUnsupported, !doc.isPreviewOnly,
              !doc.isModified else {
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
}

extension EditorPaneViewController: DocumentSaveHost {
    func presentSaveError(_ error: Error) { presentError(error) }

    func documentDidPersist(_ document: Document, writtenTo url: URL) {
        reloadTabs()
        // The gutter follows the buffer that was written, and a diff buffer has
        // no gutter of its own — the file it was replayed into refreshes when
        // the container hands the save on.
        if !document.isVirtual { refreshGitLineChanges(reloadBaseline: false) }
        onDocumentSaved?(url)
    }

    func documentDidReloadFromDisk(_ document: Document) { reloadTabs() }
}

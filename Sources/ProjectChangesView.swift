import AppKit

/// The changed files of one project, under a line to commit them from.
///
/// Clicking a row opens that file's diff; right-clicking it offers the rest —
/// copying its path, showing it in Finder, and discarding it. ⌘↩ / ⇧⌘↩ in the
/// message commit and push.
final class ProjectChangesViewController: NSViewController {
    /// A changed file was clicked: show its diff.
    var onOpenDiff: ((GitService.Status.Entry, URL) -> Void)?
    /// A commit, a push or a discard ran in `directory`, whether or not it worked:
    /// whatever shows that repository's state has to read it again.
    var onChanged: ((URL) -> Void)?

    private let table = GitTableView()
    private var entries: [GitService.Status.Entry] = []
    private var directory: URL?
    /// Where the branch stands against its remote. `nil` until the refresh
    /// that follows a project switch says, and Push stays off until then.
    private var remote: (ahead: Int, hasUpstream: Bool)?
    /// A message typed for one project stays with that project. Without this
    /// a half-written message followed the switch to another project and was
    /// one ⌘↩ away from committing that project's changes under it.
    private var drafts: [URL: String] = [:]
    /// The commit or push running now, and the project it runs in — which is
    /// not the one on screen once the user has moved on.
    private var operation: (id: UUID, directory: URL, locksMessage: Bool)?

    private let commitBar = ProjectCommitBar()

    private var message: String {
        commitBar.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Something changed, and something said about it.
    private var commitIsPossible: Bool { !entries.isEmpty && !message.isEmpty }
    /// Something waiting to go up, or a branch with nowhere to go yet — pushing
    /// is what sets its upstream.
    private var pushIsPossible: Bool {
        guard let remote else { return false }
        return remote.ahead > 0 || !remote.hasUpstream
    }

    override func loadView() {
        let root = FlatView()
        root.fillColor = Theme.panelBackground

        table.headerView = nil
        // `.automatic` insets the first row by 10pt; the list starts right
        // under the commit line.
        table.style = .plain
        table.rowSizeStyle = .custom
        table.backgroundColor = Theme.panelBackground
        table.gridStyleMask = []
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.usesAlternatingRowBackgroundColors = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.contextMenuProvider = { [weak self] row in self?.contextMenu(forRow: row) }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("change"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        let scroll = NSScrollView()
        GiftScroller.adopt(scroll)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.panelBackground
        scroll.translatesAutoresizingMaskIntoConstraints = false

        commitBar.field.onTextChange = { [weak self] in self?.refreshButtons() }
        commitBar.field.onCommitShortcut = { [weak self] in self?.commitAction() }
        commitBar.field.onPushShortcut = { [weak self] in self?.pushAction() }
        commitBar.commitButton.onClick = { [weak self] in self?.commitAction() }
        commitBar.pushButton.onClick = { [weak self] in self?.pushAction() }
        commitBar.field.stringValue = directory.flatMap { drafts[$0] } ?? ""
        commitBar.translatesAutoresizingMaskIntoConstraints = false

        // The commit line is the column's only strip, and the list starts
        // under it.
        root.addSubview(commitBar)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            commitBar.topAnchor.constraint(equalTo: root.topAnchor),
            commitBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            commitBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            commitBar.heightAnchor.constraint(equalToConstant: ProjectCommitBar.height),
            scroll.topAnchor.constraint(equalTo: commitBar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        refreshButtons()
    }

    /// The project's changes, as the window's own Git refresh found them, and
    /// where its branch stands against the remote. Leaving `remote` out means
    /// not known yet.
    func setEntries(_ entries: [GitService.Status.Entry], in directory: URL?,
                    ahead: Int? = nil, hasUpstream: Bool = false) {
        let remote = ahead.map { (ahead: $0, hasUpstream: hasUpstream) }
        let remoteChanged = self.remote?.ahead != remote?.ahead
            || self.remote?.hasUpstream != remote?.hasUpstream
        self.remote = remote
        guard self.entries != entries || self.directory != directory else {
            if remoteChanged, isViewLoaded { refreshButtons() }
            return
        }
        if self.directory != directory { switchDraft(from: self.directory, to: directory) }
        self.entries = entries
        self.directory = directory
        guard isViewLoaded else { return }
        table.reloadData()
        refreshButtons()
    }

    /// Put away what was typed for the project leaving, and bring back what
    /// was typed for the one arriving.
    private func switchDraft(from old: URL?, to new: URL?) {
        guard isViewLoaded else { return }
        let field = commitBar.field
        if let old {
            drafts[old] = field.stringValue.isEmpty ? nil : field.stringValue
        }
        // A field still being typed in keeps the field editor's copy of the
        // text; setting the value underneath it would not reach the screen.
        if field.currentEditor() != nil { field.abortEditing() }
        field.stringValue = new.flatMap { drafts[$0] } ?? ""
    }

    @objc private func rowClicked() {
        guard let directory, entries.indices.contains(table.clickedRow) else { return }
        onOpenDiff?(entries[table.clickedRow], directory)
    }

    func refreshFonts() {
        guard isViewLoaded else { return }
        commitBar.refreshAppearance()
        table.reloadData()
    }

    // MARK: - Commit and push

    private func refreshButtons() {
        guard isViewLoaded else { return }
        let idle = operation == nil
        commitBar.commitButton.isEnabled = idle && commitIsPossible
        commitBar.commitButton.toolTip = Self.commitHint(
            possible: commitIsPossible, hasChanges: !entries.isEmpty)
        commitBar.pushButton.isEnabled = idle && pushIsPossible
        commitBar.pushButton.badge = (remote?.ahead ?? 0) > 0 ? "\(remote!.ahead)" : ""
        commitBar.pushButton.toolTip = Self.pushHint(ahead: remote?.ahead ?? 0)
        commitBar.needsLayout = true
    }

    /// What Commit says about itself.
    static func commitHint(possible: Bool, hasChanges: Bool) -> String {
        possible ? "Commit  (⌘↩)"
            : (hasChanges ? "Describe the change to commit it" : "Nothing to commit")
    }

    /// What Push says about itself, with how many commits it would send.
    static func pushHint(ahead: Int) -> String {
        ahead > 0
            ? "Push \(ahead) commit\(ahead == 1 ? "" : "s")  (⇧⌘↩)"
            : "Push the current branch  (⇧⌘↩)"
    }

    /// ⌘↩ and the Commit button: the same rule for both, and a beep for a
    /// shortcut the disabled button would not have taken either.
    private func commitAction() {
        guard let directory, operation == nil, commitIsPossible else {
            NSSound.beep()
            return
        }
        let message = self.message
        let id = begin("Committing", in: directory, locksMessage: true)
        GitService.operationQueue.async { [weak self] in
            let result = GitService.commit(message, in: directory)
            DispatchQueue.main.async {
                guard let self, self.operation?.id == id else { return }
                if result.code == 0 {
                    // The message has been used; it is nobody's draft now.
                    self.drafts[directory] = nil
                    if self.directory == directory { self.commitBar.field.stringValue = "" }
                }
                self.finish(id)
                self.onChanged?(directory)
                if result.code != 0 {
                    self.presentError(title: "Commit failed",
                                      message: result.err.isEmpty ? result.out : result.err)
                }
            }
        }
    }

    /// ⇧⌘↩ and the Push button.
    private func pushAction() {
        guard let directory, operation == nil, pushIsPossible else {
            NSSound.beep()
            return
        }
        let id = begin("Pushing", in: directory, locksMessage: false)
        GitService.operationQueue.async { [weak self] in
            let result = GitService.push(in: directory)
            DispatchQueue.main.async {
                guard let self, self.operation?.id == id else { return }
                self.finish(id)
                self.onChanged?(directory)
                if !result.ok {
                    self.presentError(title: "Push failed", message: result.message)
                }
            }
        }
    }

    private func begin(_ label: String, in directory: URL, locksMessage: Bool) -> UUID {
        let id = UUID()
        operation = (id, directory, locksMessage)
        // A commit takes the message as it stands; a push leaves it alone.
        if locksMessage { commitBar.field.isEditable = false }
        commitBar.progress.start(label: label)
        refreshButtons()
        return id
    }

    private func finish(_ id: UUID) {
        guard let operation, operation.id == id else { return }
        self.operation = nil
        if operation.locksMessage { commitBar.field.isEditable = true }
        commitBar.progress.stop()
        refreshButtons()
    }

    // MARK: - Context menu

    /// Right-click on a changed file. The row is not selected by it: the diff
    /// on the right stays what it was.
    private func contextMenu(forRow row: Int) -> NSMenu? {
        guard let directory, entries.indices.contains(row) else { return nil }
        let entry = entries[row]
        let fileURL = directory.appendingPathComponent(entry.path)
        let menu = NSMenu()
        menu.autoenablesItems = false
        add(to: menu, title: "Show Changes") { [weak self] in
            self?.onOpenDiff?(entry, directory)
        }
        menu.addItem(.separator())
        add(to: menu, title: "Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.path, forType: .string)
        }
        add(to: menu, title: "Reveal in Finder",
            enabled: FileManager.default.fileExists(atPath: fileURL.path)) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        }
        menu.addItem(.separator())
        let idle = operation == nil
        add(to: menu, title: "Discard Changes…", enabled: idle) { [weak self] in
            self?.discardChanges(entry, in: directory)
        }
        add(to: menu, title: entries.count == 1 ? "Discard All Changes…"
                : "Discard All \(entries.count) Changes…", enabled: idle) { [weak self] in
            self?.discardAllChanges(in: directory)
        }
        return menu
    }

    private func add(to menu: NSMenu, title: String, enabled: Bool = true,
                     action: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(runMenuAction(_:)),
                              keyEquivalent: "")
        item.target = self
        item.representedObject = MenuAction(run: action)
        item.isEnabled = enabled
        menu.addItem(item)
    }

    /// Boxes a closure so it can ride on an `NSMenuItem`.
    private final class MenuAction {
        let run: () -> Void
        init(run: @escaping () -> Void) { self.run = run }
    }

    @objc private func runMenuAction(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuAction)?.run()
    }

    /// Put one file back as HEAD has it. Confirmed first, and the alert says
    /// what cannot be recovered: a file Git has never committed goes to the
    /// Trash rather than back to an earlier version.
    private func discardChanges(_ entry: GitService.Status.Entry, in directory: URL) {
        let removesFile = GitService.discardRemovesFile(entry, in: directory)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard changes to “\(entry.path)”?"
        var affected = "File:\n\(directory.appendingPathComponent(entry.path).path)"
        if entry.code.contains("R"), let originalPath = entry.originalPath {
            affected += "\nOriginal path:\n\(directory.appendingPathComponent(originalPath).path)"
        }
        let consequence = removesFile
            ? "This file has no committed version. It will be removed from Git and moved to Trash. Gift cannot undo the action; recovery is possible only while the item remains in Trash."
            : "All uncommitted changes to this file, including staged changes, will be replaced with the version in HEAD. Git cannot restore the discarded edits."
        alert.informativeText = "\(affected)\n\n\(consequence)"
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        guard confirm(alert), operation == nil else { return }
        let id = begin("Discarding changes", in: directory, locksMessage: false)
        GitService.operationQueue.async { [weak self] in
            let result = GitService.discard(entry, in: directory)
            DispatchQueue.main.async {
                guard let self, self.operation?.id == id else { return }
                self.finish(id)
                self.onChanged?(directory)
                if !result.ok {
                    self.presentError(title: "Discard changes failed", message: result.message)
                }
            }
        }
    }

    /// Throw away every change in the project, on the same terms.
    private func discardAllChanges(in directory: URL) {
        let entries = self.entries
        guard !entries.isEmpty else { return }
        let newFiles = entries.filter { GitService.discardRemovesFile($0, in: directory) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = entries.count == 1
            ? "Discard the 1 change in this project?"
            : "Discard all \(entries.count) changes in this project?"
        var detail = "Project:\n\(directory.path)\n\n"
        detail += "Every uncommitted change, staged included, will be replaced with the "
            + "version in HEAD. Git cannot restore the discarded edits."
        if !newFiles.isEmpty {
            detail += "\n\n\(newFiles.count) file\(newFiles.count == 1 ? "" : "s") "
                + "never committed will be removed from Git and moved to Trash; "
                + "recovery is possible only while the item remains in Trash:\n"
            detail += newFiles.prefix(10).map { "• \($0.path)" }.joined(separator: "\n")
            if newFiles.count > 10 { detail += "\n• …and \(newFiles.count - 10) more" }
        }
        alert.informativeText = detail
        alert.addButton(withTitle: "Discard All Changes")
        alert.addButton(withTitle: "Cancel")
        guard confirm(alert), operation == nil else { return }
        let id = begin("Discarding all changes", in: directory, locksMessage: false)
        GitService.operationQueue.async { [weak self] in
            let result = GitService.discardAll(entries, in: directory)
            DispatchQueue.main.async {
                guard let self, self.operation?.id == id else { return }
                self.finish(id)
                self.onChanged?(directory)
                if let failure = result.failure {
                    self.presentError(
                        title: "Discard all changes failed",
                        message: "\(result.discarded) of \(entries.count) discarded.\n\(failure)")
                }
            }
        }
    }

    /// Asks before a discard. A test answers in place of the alert.
    var confirmDiscard: (NSAlert) -> Bool = { $0.runModal() == .alertFirstButtonReturn }
    private func confirm(_ alert: NSAlert) -> Bool { confirmDiscard(alert) }

    private func presentError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Regression-test surface

    var entriesForTesting: [GitService.Status.Entry] { entries }
    var commitBarForTesting: ProjectCommitBar {
        _ = view
        return commitBar
    }
    var isBusyForTesting: Bool { operation != nil }
    /// Where the commit line starts, measured from the window's top.
    var commitBarTopInsetInWindowForTesting: CGFloat? {
        _ = view
        guard let window = view.window else { return nil }
        let rect = commitBar.convert(commitBar.bounds, to: nil)
        return window.frame.height - rect.maxY
    }
    var rowCountForTesting: Int {
        _ = view
        return table.numberOfRows
    }
    /// Where the first row starts, measured from the window's top.
    var firstRowTopInsetInWindowForTesting: CGFloat? {
        _ = view
        guard table.numberOfRows > 0, let window = view.window else { return nil }
        table.layoutSubtreeIfNeeded()
        let rect = table.convert(table.rect(ofRow: 0), to: nil)
        return window.frame.height - rect.maxY
    }
    /// The name a row draws, which is what the reader picks it out by.
    func rowNameForTesting(_ row: Int) -> String? {
        _ = view
        return (tableView(table, viewFor: nil, row: row) as? GitChangeCell)?.nameForTesting
    }
    /// The row as the list draws it, laid out and ready to be rendered.
    func rowViewForTesting(_ row: Int) -> GitRowView? {
        _ = view
        table.layoutSubtreeIfNeeded()
        guard row >= 0, row < table.numberOfRows else { return nil }
        return table.rowView(atRow: row, makeIfNecessary: true) as? GitRowView
    }
    /// The menu a right-click on a row brings up.
    func contextMenuForTesting(row: Int) -> NSMenu? {
        _ = view
        return contextMenu(forRow: row)
    }
    /// Choose an item from that menu by its title.
    @discardableResult
    func runMenuItemForTesting(_ title: String, row: Int) -> Bool {
        guard let item = contextMenuForTesting(row: row)?.items
                .first(where: { $0.title == title }), item.isEnabled else { return false }
        runMenuAction(item)
        return true
    }
    /// Wait for a commit, push or discard to finish.
    func settleForTesting(timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while operation != nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }
    /// A click on a row, through the same path a real one takes.
    func clickRowForTesting(_ row: Int) {
        guard let directory, entries.indices.contains(row) else { return }
        onOpenDiff?(entries[row], directory)
    }
}

extension ProjectChangesViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        Theme.treeRowHeight()
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("project-change-row")
        let view = (tableView.makeView(withIdentifier: id, owner: self) as? GitRowView)
            ?? GitRowView()
        view.identifier = id
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let id = NSUserInterfaceItemIdentifier("project-change-cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? GitChangeCell)
            ?? GitChangeCell()
        cell.identifier = id
        cell.configure(entry: entries[row])
        return cell
    }
}

/// The strip over a project's changes: a one-line message, then Commit and
/// Push. Laid out by hand so a column dragged narrower than the two buttons
/// squeezes the message to nothing rather than breaking a constraint.
///
/// The message is set apart by its fill alone, no frame, running out to the edges of the region it sits in. The
/// fill is the whole strip's, buttons included; they draw no shape of their
/// own, only the area a click lands in when the pointer is over them.
final class ProjectCommitBar: NSView {
    /// The height of a project row, so the strip reads as one more of them.
    static let height: CGFloat = 32
    static let inset: CGFloat = 6
    static let gap: CGFloat = 6

    let field = CommitLineField()
    let commitButton = BadgeButton()
    let pushButton = BadgeButton()
    /// The progress band, along the strip's lower edge.
    let progress = GitProgressShimmerView()
    private let box = CommitLineBox()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        box.addSubview(field)
        commitButton.title = "Commit"
        pushButton.title = "Push"
        commitButton.style = .plain
        pushButton.style = .plain
        progress.isHidden = true
        [box, commitButton, pushButton, progress].forEach(addSubview)
        refreshAppearance()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func refreshAppearance() {
        field.refreshAppearance()
        commitButton.invalidateIntrinsicContentSize()
        pushButton.invalidateIntrinsicContentSize()
        needsDisplay = true
        needsLayout = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.activeTab.setFill()
        bounds.fill()
    }

    override func layout() {
        super.layout()
        let height = BadgeButton.height
        let top = ((bounds.height - height) / 2).rounded()
        // Right to left: Push at the edge, Commit before it, the message in
        // whatever is left — from the region's left edge, top to bottom.
        var x = bounds.width - Self.inset
        for button in [pushButton, commitButton] {
            let width = button.intrinsicContentSize.width
            x -= width
            button.frame = NSRect(x: x, y: top, width: width, height: height)
            x -= Self.gap
        }
        box.frame = NSRect(x: 0, y: 0, width: max(0, x), height: bounds.height)
        progress.frame = NSRect(x: 0, y: bounds.height - 2, width: bounds.width, height: 2)
    }

    var messageBoxFrameForTesting: NSRect { box.frame }
    var messageBoxForTesting: NSView { box }
}

/// Where the one-line message sits. It draws nothing: the strip under it is
/// the message's fill, and nothing is drawn around it.
final class CommitLineBox: NSView {
    /// Where the text starts: a 4pt inset and 5pt of padding; the field
    /// editor adds its 2pt to this.
    static let textInset: CGFloat = 7

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        guard let field = subviews.first else { return }
        // The field fills the box and its cell centres the line: a field sized
        // to its own fitting height is a point shorter than Monaco's line, and
        // AppKit then sets the placeholder lower than the typed text.
        let padding = Self.textInset
        field.frame = NSRect(x: padding, y: 0,
                             width: max(0, bounds.width - padding * 2), height: bounds.height)
    }

    override func mouseDown(with event: NSEvent) {
        // The padding around the text is part of the box: a click there
        // starts typing, as a click on the text would.
        guard let field = subviews.first as? NSTextField else { return }
        window?.makeFirstResponder(field)
    }
}

/// The one-line commit message. A field's keys go to the window's shared field
/// editor rather than to the field, so this one takes ⌘↩ and ⇧⌘↩ as key
/// equivalents — and only while it is the field being typed in.
final class CommitLineField: NSTextField, NSTextFieldDelegate {
    var onCommitShortcut: (() -> Void)?
    var onPushShortcut: (() -> Void)?
    var onTextChange: (() -> Void)?

    static let placeholder = "Commit message"

    override class var cellClass: AnyClass? {
        get { CenteredTextFieldCell.self }
        set { }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        lineBreakMode = .byClipping
        cell?.usesSingleLineMode = true
        cell?.wraps = false
        cell?.isScrollable = true
        setAccessibilityLabel(Self.placeholder)
        delegate = self
        refreshAppearance()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func refreshAppearance() {
        font = Theme.uiFont(11)
        textColor = Theme.foreground
        needsDisplay = true
    }

    /// The hint drawn in the empty field. AppKit's own placeholder sits at the
    /// top of the frame while the field is idle and lower than the typed text
    /// while it is focused; drawn here, it sits where the first character
    /// will, in both.
    private var placeholderText: NSAttributedString {
        NSAttributedString(string: Self.placeholder, attributes: [
            .font: font ?? Theme.uiFont(11), .foregroundColor: Theme.dimText,
        ])
    }

    /// What is in the field right now, read from the field editor while
    /// typing: asking the field would have it take the edit in first, and this
    /// is asked from inside a draw.
    private var currentText: String { currentEditor()?.string ?? stringValue }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard currentText.isEmpty, let cell else { return }
        let line = cell.titleRect(forBounds: bounds)
        // The field editor sets its text in from the line's edge by its
        // container's padding.
        let padding = (currentEditor() as? NSTextView)?.textContainer?.lineFragmentPadding
            ?? CenteredTextFieldCell.textPadding
        placeholderText.draw(with: line.insetBy(dx: padding, dy: 0),
                             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    var drawsPlaceholderForTesting: Bool { currentText.isEmpty }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard currentEditor() != nil, let shortcut = CommitShortcut(event) else {
            return super.performKeyEquivalent(with: event)
        }
        perform(shortcut)
        return true
    }

    /// A window that is not key is never offered key equivalents, and the
    /// field editor, having no binding for ⌘↩, turns it into `noop:` — so the
    /// shortcut is picked up there too rather than lost to a beep.
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        guard selector == Selector(("noop:")),
              let event = NSApp.currentEvent, let shortcut = CommitShortcut(event) else {
            return false
        }
        perform(shortcut)
        return true
    }

    private func perform(_ shortcut: CommitShortcut) {
        switch shortcut {
        case .commit: onCommitShortcut?()
        case .push: onPushShortcut?()
        }
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        // The hint goes with the first character and comes back with the last.
        needsDisplay = true
        onTextChange?()
    }

    /// Setting the text in code — clearing it after a commit, bringing back
    /// another project's draft — is not an edit, so AppKit says nothing. The
    /// buttons still have to hear about it.
    override var stringValue: String {
        didSet {
            needsDisplay = true
            onTextChange?()
        }
    }
}

/// A text cell that sets its one line in the middle of its frame — typing,
/// selecting and at rest alike — where AppKit's own starts at the top.
final class CenteredTextFieldCell: NSTextFieldCell {
    /// Where the field editor starts its text inside the line, which is where
    /// the text at rest (and the placeholder) must start too.
    static let textPadding: CGFloat = 2

    /// At rest the cell draws the text itself, in the line `titleRect` gives:
    /// AppKit's own drawing ignores it and set a draft at the top of the box.
    /// While typing, the field editor draws it, and the cell draws nothing.
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard (controlView as? NSTextField)?.currentEditor() == nil, !stringValue.isEmpty else {
            return
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        NSAttributedString(string: stringValue, attributes: [
            .font: font ?? Theme.uiFont(11),
            .foregroundColor: textColor ?? Theme.foreground,
            .paragraphStyle: paragraph,
        ]).draw(with: titleRect(forBounds: cellFrame).insetBy(dx: Self.textPadding, dy: 0),
                options: [.usesLineFragmentOrigin])
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        let natural = super.titleRect(forBounds: rect)
        let height = min(natural.height, cellSize(forBounds: rect).height)
        return NSRect(x: natural.minX, y: natural.minY + ((natural.height - height) / 2).rounded(),
                      width: natural.width, height: height)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                       delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: titleRect(forBounds: rect), in: controlView, editor: textObj,
                   delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                         delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: titleRect(forBounds: rect), in: controlView, editor: textObj,
                     delegate: delegate, start: selStart, length: selLength)
    }
}

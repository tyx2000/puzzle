import AppKit

/// The views the Git panel draws with: one cell per row kind, the flat tab
/// strip above the list, and the table/scroll subclasses that carry the
/// panel's borders and row geometry.
///
/// Split out of `GitPanelViewController` because none of it touches the
/// panel's state — they are handed what to draw and draw it — and the
/// controller is easier to read without 500 lines of drawing under it.

final class GitCommitCell: DrawnSidebarCell {
    private var subject = ""
    private var author = ""
    private var date = ""
    private var branch = ""
    private var commitID = ""
    private var metaColor = NSColor.clear
    /// Between every column in the row.
    static let columnGap: CGFloat = 15
    /// How much room the row gets. A narrow column cannot hold a subject, a
    /// branch, a name and a time on one line without losing the subject, which
    /// is what the row is read for; given a second line the subject has the
    /// first to itself.
    enum Layout { case oneLine, twoLine }
    private var layout: Layout = .oneLine
    static func height(for layout: Layout) -> CGFloat {
        layout == .oneLine ? Theme.treeRowHeight() : Theme.treeRowHeight() + 14
    }

    /// Where the last draw put each column, so the gaps between them can be
    /// measured rather than eyeballed.
    private(set) var drawnBranchRectForTesting: NSRect = .zero
    private(set) var drawnSubjectXForTesting: CGFloat = 0
    private(set) var drawnSubjectRectForTesting: NSRect = .zero
    private(set) var drawnAuthorRectForTesting: NSRect = .zero
    private(set) var drawnDateRectForTesting: NSRect = .zero
    private(set) var drawnHashRectForTesting: NSRect = .zero

    /// The width every row in the list gives its branch, so the id and the
    /// message start at the same place on each — they are columns, and a
    /// longer branch name on one row must not push that row's out of line.
    private var branchColumnWidth: CGFloat?

    /// The width a list of these rows should give the branch column: its
    /// widest name.
    static func branchColumnWidth(for names: some Sequence<String>) -> CGFloat {
        let font = Theme.uiFont(9.5)
        return names.reduce(0) { widest, name in
            max(widest, ceil((name as NSString).size(withAttributes: [.font: font]).width) + 2)
        }
    }

    func configure(commit: GitService.Commit, pending: Bool, branch: String = "",
                   layout: Layout = .oneLine, branchColumnWidth: CGFloat? = nil) {
        self.branch = branch
        self.branchColumnWidth = branchColumnWidth
        self.layout = layout
        commitID = commit.shortHash
        subject = commit.subject
        // The name gives way before the timestamp does: a truncated name still
        // reads, a truncated date does not.
        author = pending ? "↑  " + commit.author : commit.author
        date = commit.absoluteDate
        // Unpushed commits are the reason Push is enabled, so they still have
        // to be tellable apart at a glance — the arrow rides with the metadata
        // rather than taking room from the subject.
        metaColor = pending ? Theme.cursor : Theme.dimText
        // One line can only carry so much. Everything the row had to drop —
        // the commit id, where a branch or tag points — is one hover away.
        var details = [commit.shortHash, commit.subject, commit.blameSummary]
        if !branch.isEmpty { details.insert(branch, at: 1) }
        if !commit.refLabels.isEmpty { details.insert(commit.refLabels.joined(separator: ", "), at: 1) }
        if pending { details.append("not pushed") }
        // No bubble: the row carries the branch, the id, the message, the name
        // and the time itself, and a tip over every row is then only something
        // that follows the pointer down the list.
        _ = details
        toolTip = nil
        exposeToAccessibility("\(pending ? "Unpushed " : "")commit \(commit.shortHash), "
                                + (branch.isEmpty ? "" : "on \(branch), ")
                                + "\(commit.subject), \(commit.author), \(commit.absoluteDate)")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        drawnBranchRectForTesting = .zero
        drawnAuthorRectForTesting = .zero
        drawnDateRectForTesting = .zero
        drawnHashRectForTesting = .zero
        guard layout == .oneLine else {
            drawTwoLines()
            return
        }
        var content = NSRect(x: 8, y: 0, width: max(0, bounds.width - 16),
                             height: bounds.height)
        // The branch the commit sits on, first: a list of everything behind
        // HEAD holds commits made on branches that were merged in, and the
        // subject alone does not say which.
        // Branch, then the commit's id, each a column of its own ahead of the
        // message: the list holds commits merged in from other branches, and
        // the id is what names one to Git.
        let metaFont = Theme.uiFont(9.5)
        let baseline = SidebarCellDrawing.centeredBaseline(for: Theme.uiFont(11), in: content)
        func leadingColumn(_ text: String, color: NSColor, share: CGFloat,
                           lineBreak: NSLineBreakMode, width fixed: CGFloat? = nil) -> NSRect? {
            guard !text.isEmpty else { return nil }
            let natural = fixed ?? ceil((text as NSString)
                                            .size(withAttributes: [.font: metaFont]).width) + 2
            let width = min(natural, floor(content.width * share))
            let box = NSRect(x: content.minX, y: content.minY,
                             width: width, height: content.height)
            SidebarCellDrawing.text(text, font: metaFont, color: color,
                                    baseline: baseline, in: box, lineBreak: lineBreak)
            let taken = width + Self.columnGap
            content = NSRect(x: content.minX + taken, y: content.minY,
                             width: max(0, content.width - taken), height: content.height)
            return box
        }
        // A quarter at most for the branch: the message is what the row is
        // read for, and a long branch name must not take the whole line.
        drawnBranchRectForTesting = leadingColumn(
            branch, color: Theme.cursor, share: 0.25, lineBreak: .byTruncatingTail,
            width: branchColumnWidth) ?? .zero
        drawnHashRectForTesting = leadingColumn(
            commitID, color: Theme.dimText, share: 0.25, lineBreak: .byClipping) ?? .zero
        drawnSubjectXForTesting = content.minX
        drawnSubjectRectForTesting = content
        SidebarCellDrawing.leadingAndTrailing(
            leading: subject, leadingFont: Theme.uiFont(11), leadingColor: Theme.foreground,
            trailing: author, trailingFont: Theme.uiFont(9.5), trailingColor: metaColor,
            trailingPinned: date, in: content, gap: Self.columnGap,
            // With a branch ahead of it the subject is down to whatever the
            // other three leave; the name and the date give way first.
            trailingShare: branch.isEmpty ? 0.6 : 0.5)
    }

    /// The subject on its own line, and under it the branch, the name and the
    /// time — each column a gap from the next, the time against the trailing
    /// edge where a list of them lines up.
    private func drawTwoLines() {
        let content = NSRect(x: 8, y: 2, width: max(0, bounds.width - 16),
                             height: max(0, bounds.height - 4))
        guard content.width > 0, content.height > 0 else { return }
        let subjectFont = Theme.uiFont(11)
        let metaFont = Theme.uiFont(9.5)
        let top = NSRect(x: content.minX, y: content.minY,
                         width: content.width, height: content.height / 2)
        let bottom = NSRect(x: content.minX, y: content.midY,
                            width: content.width, height: content.height / 2)
        var message = top
        // The commit's id first, so a row can be named to Git without hunting
        // for it: `git show <id>` starts here.
        if !commitID.isEmpty {
            let idFont = Theme.uiFont(9.5)
            let idWidth = min(ceil((commitID as NSString)
                                    .size(withAttributes: [.font: idFont]).width) + 2,
                              floor(top.width / 3))
            let box = NSRect(x: top.minX, y: top.minY, width: idWidth, height: top.height)
            drawnHashRectForTesting = box
            SidebarCellDrawing.text(
                commitID, font: idFont, color: Theme.dimText,
                baseline: SidebarCellDrawing.centeredBaseline(for: subjectFont, in: top),
                in: box, lineBreak: .byClipping)
            let taken = idWidth + Self.columnGap
            message = NSRect(x: top.minX + taken, y: top.minY,
                             width: max(0, top.width - taken), height: top.height)
        }
        drawnSubjectRectForTesting = message
        drawnSubjectXForTesting = message.minX
        SidebarCellDrawing.text(
            subject, font: subjectFont, color: Theme.foreground,
            baseline: SidebarCellDrawing.centeredBaseline(for: subjectFont, in: message),
            in: message, lineBreak: .byTruncatingTail)

        func width(_ string: String) -> CGFloat {
            // A point of slack: the measured advance rounds a hair under what
            // is drawn, which clipped the last digit of a timestamp.
            ceil((string as NSString).size(withAttributes: [.font: metaFont]).width) + 2
        }
        let baseline = SidebarCellDrawing.centeredBaseline(for: metaFont, in: bottom)
        var trailing = bottom.maxX
        if !date.isEmpty {
            let box = NSRect(x: max(bottom.minX, trailing - width(date)), y: bottom.minY,
                             width: min(width(date), bottom.width), height: bottom.height)
            drawnDateRectForTesting = box
            SidebarCellDrawing.text(date, font: metaFont, color: metaColor,
                                    baseline: baseline, in: box,
                                    lineBreak: .byClipping, alignment: .right)
            trailing = box.minX
        }
        if !author.isEmpty {
            let room = max(0, trailing - Self.columnGap - bottom.minX)
            let box = NSRect(x: trailing - Self.columnGap - min(width(author), room),
                             y: bottom.minY, width: min(width(author), room),
                             height: bottom.height)
            drawnAuthorRectForTesting = box
            SidebarCellDrawing.text(author, font: metaFont, color: metaColor,
                                    baseline: baseline, in: box,
                                    lineBreak: .byTruncatingTail, alignment: .right)
            trailing = box.minX
        }
        guard !branch.isEmpty else { return }
        let box = NSRect(x: bottom.minX, y: bottom.minY,
                         width: max(0, trailing - Self.columnGap - bottom.minX),
                         height: bottom.height)
        drawnBranchRectForTesting = box
        SidebarCellDrawing.text(branch, font: metaFont, color: Theme.cursor,
                                baseline: baseline, in: box, lineBreak: .byTruncatingTail)
    }

    var subjectForTesting: String { subject }
    var branchForTesting: String { branch }
    var metaForTesting: String { "\(author)  ·  \(date)" }
    var toolTipForTesting: String { toolTip ?? "" }
}

final class GitHistoryFileCell: DrawnSidebarCell {
    private var status = ""
    private var name = ""
    private var folder = ""
    private var statusColor = NSColor.clear
    func configure(file: GitService.CommitFile) {
        status = file.status
        statusColor = GitPanelViewController.statusColor(file.status)
        name = (file.path as NSString).lastPathComponent
        folder = (file.path as NSString).deletingLastPathComponent
        toolTip = file.path
        exposeToAccessibility("\(file.status), \(file.path)")
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        // Indented under the commit it belongs to, which is what says these
        // rows are its files now that no lane is drawn behind them.
        SidebarCellDrawing.text(status, font: Theme.uiFont(10), color: statusColor,
                                in: NSRect(x: 18, y: 0, width: 14, height: bounds.height),
                                alignment: .center)
        let textX: CGFloat = 38
        SidebarCellDrawing.primaryAndSecondary(
            primary: name, primaryFont: Theme.uiFont(11), primaryColor: Theme.foreground,
            secondary: folder, secondaryFont: Theme.uiFont(9.5), secondaryColor: Theme.dimText,
            in: NSRect(x: textX, y: 0, width: max(0, bounds.width - textX - 6),
                       height: bounds.height))
    }
}

/// Test seam: the row type is private, so expose a probe that builds one.
final class GitChangeCellProbe: NSView {
    private let cell = GitChangeCell()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(cell)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        cell.frame = bounds
        cell.layoutSubtreeIfNeeded()
    }

    func configureProbe(path: String) {
        cell.configure(entry: GitService.Status.Entry(code: " M", path: path, originalPath: nil))
    }

    var nameForTesting: String { cell.nameForTesting }
}

final class GitChangeCell: DrawnSidebarCell {
    private var status = ""
    private var icon: SidebarIcon?
    private var name = ""
    private var folder = ""
    private var statusColor = NSColor.clear

    func configure(entry: GitService.Status.Entry) {
        status = entry.displayCode
        statusColor = entry.isUntracked ? Theme.green : Theme.yellow
        icon = .file(URL(fileURLWithPath: entry.path))
        name = (entry.path as NSString).lastPathComponent
        folder = (entry.path as NSString).deletingLastPathComponent
        toolTip = entry.path
        exposeToAccessibility("Automatically staged \(entry.displayCode), \(entry.path)")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        SidebarCellDrawing.text(status, font: Theme.uiFont(10), color: statusColor,
                                in: NSRect(x: 6, y: 0, width: 18, height: bounds.height),
                                alignment: .center)
        SidebarCellDrawing.icon(icon,
                                in: NSRect(x: 26, y: floor((bounds.height - 13) / 2),
                                           width: 13, height: 13))
        // The whole row is the name's now that the buttons have moved to the
        // context menu.
        SidebarCellDrawing.primaryAndSecondary(
            primary: name, primaryFont: Theme.uiFont(11), primaryColor: Theme.foreground,
            secondary: folder, secondaryFont: Theme.uiFont(9.5), secondaryColor: Theme.dimText,
            in: NSRect(x: 44, y: 0, width: max(0, bounds.width - 52), height: bounds.height),
            gap: 5, primaryLineBreak: .byTruncatingMiddle)
    }

    var nameForTesting: String { name }
}

final class GitBranchCell: DrawnSidebarCell {
    private var name = ""
    private var author = ""
    private var date = ""
    private var metadata = ""
    private var isCurrent = false

    func configure(branch: GitService.Branch) {
        name = branch.isCurrent ? "\(branch.name)  · current" : branch.name
        author = branch.author
        date = branch.createdAt
        metadata = "\(branch.author)  ·  \(branch.createdAt)"
        isCurrent = branch.isCurrent
        // A name that had to be truncated is worth reading in full.
        toolTip = "\(branch.name)\n\(metadata)"
        exposeToAccessibility("Branch \(branch.name), \(metadata)")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Switch and delete moved to the row's context menu, so the name has
        // the full width up to its metadata.
        SidebarCellDrawing.leadingAndTrailing(
            leading: name, leadingFont: Theme.uiFont(11),
            leadingColor: isCurrent ? Theme.cursor : Theme.foreground,
            trailing: author, trailingFont: Theme.uiFont(9.5),
            trailingColor: Theme.dimText, trailingPinned: date,
            in: NSRect(x: 8, y: 0, width: max(0, bounds.width - 16), height: bounds.height),
            leadingLineBreak: .byTruncatingMiddle)
    }

    var nameForTesting: String { name }
    var metadataForTesting: String { metadata }
}

/// Two-state tab strip with the same full-height selection treatment as the
/// bottom action bar. Native buttons preserve keyboard and VoiceOver behavior.
final class FlatPanelTabBar: NSView {
    override var isFlipped: Bool { true }
    var onChange: (() -> Void)?
    var selectedSegment = 0 { didSet { updateSelection() } }

    private var buttons: [FlatPanelTabButton] = []

    init(labels: [String]) {
        super.init(frame: .zero)
        buttons = labels.enumerated().map { index, label in
            let button = FlatPanelTabButton(title: label)
            button.setAccessibilityRole(.radioButton)
            button.onSelect = { [weak self] in self?.selectTab(index) }
            addSubview(button)
            return button
        }
        updateSelection()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        guard !buttons.isEmpty else { return }
        let width = bounds.width / CGFloat(buttons.count)
        for (index, button) in buttons.enumerated() {
            let minX = (CGFloat(index) * width).rounded()
            let maxX = (CGFloat(index + 1) * width).rounded()
            button.frame = NSRect(x: minX, y: 0, width: maxX - minX,
                                  height: bounds.height)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.barBackground.setFill()
        bounds.fill()
    }

    func setLabel(_ label: String, badge: String = "", forSegment index: Int) {
        guard buttons.indices.contains(index) else { return }
        buttons[index].title = label
        buttons[index].badge = badge
        buttons[index].needsDisplay = true
    }

    func refreshAppearance() {
        needsDisplay = true
        buttons.forEach { $0.needsDisplay = true }
    }

    func labelForTesting(at index: Int) -> String {
        buttons.indices.contains(index) ? buttons[index].title : ""
    }
    func badgeForTesting(at index: Int) -> String {
        buttons.indices.contains(index) ? buttons[index].badge : ""
    }

    private func updateSelection() {
        for (index, button) in buttons.enumerated() {
            button.isSelected = index == selectedSegment
        }
    }

    private func selectTab(_ index: Int) {
        guard index != selectedSegment else { return }
        selectedSegment = index
        onChange?()
    }
}

final class FlatPanelTabButton: NSView {
    override var isFlipped: Bool { true }
    var onSelect: (() -> Void)?
    var title: String {
        didSet { setAccessibilityLabel(accessibilityText); needsDisplay = true }
    }
    /// Count shown as a pill after the title. Empty hides it.
    var badge = "" {
        didSet {
            guard badge != oldValue else { return }
            setAccessibilityLabel(accessibilityText)
            needsDisplay = true
        }
    }
    private var accessibilityText: String { badge.isEmpty ? title : "\(title), \(badge)" }
    var isSelected = false {
        didSet {
            setAccessibilityValue(isSelected)
            needsDisplay = true
        }
    }

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityLabel(title)
        setAccessibilityValue(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            Theme.selectedControl.setFill()
            bounds.fill()
        }
        let font = Theme.uiFont(11)
        let ink = isSelected ? Theme.selectedControlText : Theme.dimText
        SidebarCellDrawing.attributedText(
            SidebarCellDrawing.labelWithBadge(
                title, badge: badge, font: font, colour: ink,
                badgeBackground: Theme.activeRow, badgeForeground: Theme.foreground,
                alignment: .center),
            in: bounds)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onSelect?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { // Return or Space
            onSelect?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onSelect?()
        return true
    }
}

/// Thin animated progress band pinned to the commit editor's top border. It is
/// deliberately indeterminate because hooks and network pushes expose no useful
/// percentage through the Git CLI.
final class GitProgressShimmerView: NSView {
    private var timer: Timer?
    private var phase: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
    }

    required init?(coder: NSCoder) { fatalError() }

    func start(label: String) {
        setAccessibilityLabel(label)
        isHidden = false
        guard timer == nil else { return }
        phase = 0
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.phase = (self.phase + 0.015).truncatingRemainder(dividingBy: 1)
            self.needsDisplay = true
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isHidden = true
        needsDisplay = true
    }

    deinit { timer?.invalidate() }

    override func draw(_ dirtyRect: NSRect) {
        Theme.border.setFill()
        bounds.fill()
        let sweepWidth = max(48, bounds.width * 0.24)
        let travel = bounds.width + sweepWidth
        let x = -sweepWidth + travel * phase
        let colors = [
            Theme.cursor.withAlphaComponent(0),
            Theme.cursor.withAlphaComponent(0.95),
            Theme.cursor.withAlphaComponent(0),
        ]
        NSGradient(colors: colors)?.draw(
            in: NSRect(x: x, y: 0, width: sweepWidth, height: bounds.height), angle: 0)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Commit editor chrome with horizontal separators only; the content and hit
/// area run to both panel edges.
final class HorizontalBorderScrollView: NSScrollView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Theme.border.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}


/// Git-panel row: flat background, with the same active-file tint the file tree
/// uses for the document currently shown on the right.
/// The Git panel's list. Tracks the row under the pointer so rows can light up
/// like the file tree's, and hands right-clicks to the panel.
final class GitTableView: NSTableView {
    var contextMenuProvider: ((Int) -> NSMenu?)?
    private var hoverTrackingArea: NSTrackingArea?
    private(set) var hoveredRow = -1

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard hoverTrackingArea == nil else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { updateHoveredRow(with: event) }
    override func mouseMoved(with event: NSEvent) { updateHoveredRow(with: event) }
    override func mouseExited(with event: NSEvent) { setHoveredRow(-1) }

    override func layout() {
        super.layout()
        refreshHoverState()
    }

    func refreshHoverState() {
        guard let window else {
            setHoveredRow(-1)
            return
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setHoveredRow(bounds.contains(point) ? row(at: point) : -1)
    }

    private func updateHoveredRow(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setHoveredRow(bounds.contains(point) ? row(at: point) : -1)
    }

    func setHoveredRowForTesting(_ row: Int) { setHoveredRow(row) }

    private func setHoveredRow(_ row: Int) {
        let next = row >= 0 && row < numberOfRows ? row : -1
        guard next != hoveredRow else { return }
        let previous = hoveredRow
        hoveredRow = next
        // `previous` was recorded when the list was longer. Asking for a row
        // that is gone raises, and this runs from `layout()`, where AppKit
        // turns an exception into a hard crash rather than letting it
        // propagate — so the row that is being let go needs the same bounds
        // check as the one being taken.
        for index in [previous, next] where index >= 0 && index < numberOfRows {
            (rowView(atRow: index, makeIfNecessary: false) as? GitRowView)?
                .isHovered = index == next
        }
    }

    /// Right-click targets the row under the pointer without selecting it.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        guard row >= 0 else { return nil }
        return contextMenuProvider?(row)
    }
}

final class GitRowView: NSTableRowView {
    var isActiveFile = false
    var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            needsDisplay = true
        }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        Theme.panelBackground.setFill()
        bounds.fill()
        if isActiveFile {
            Theme.activeRow.setFill()
            bounds.fill()
        } else if isHovered {
            Theme.hover.setFill()
            bounds.fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard !isActiveFile, selectionHighlightStyle != .none else { return }
        Theme.hover.setFill()
        bounds.fill()
    }

    override var isEmphasized: Bool {
        get { false }        // never the blue system highlight
        set { }
    }
}

/// The commit box. Two things a plain NSTextView does not do: show a hint while
/// it is empty, and treat ⌘↩ as "commit" the way every Git client does.
final class CommitMessageTextView: NSTextView {
    var placeholder = "" { didSet { needsDisplay = true } }
    var onCommitShortcut: (() -> Void)?
    /// ⇧⌘↩, the other half of the pair: commit with ⌘↩, push with shift.
    var onPushShortcut: (() -> Void)?
    /// Typing changes whether there is anything to commit.
    var onTextChange: (() -> Void)?

    override func didChangeText() {
        super.didChangeText()
        onTextChange?()
    }

    /// Setting the text in code — clearing it after a commit — is not a user
    /// edit, so AppKit posts nothing. The panel still has to hear about it.
    override var string: String {
        get { super.string }
        set {
            super.string = newValue
            onTextChange?()
        }
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 36 || event.keyCode == 76 {
            if modifiers == [.command] {
                onCommitShortcut?()
                return
            }
            if modifiers == [.command, .shift] {
                onPushShortcut?()
                return
            }
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? Theme.uiFont(11),
            .foregroundColor: Theme.dimText,
        ]
        let origin = NSPoint(x: textContainerInset.width + 5,
                             y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: attributes)
    }
}

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
    private var metaColor = NSColor.clear

    func configure(commit: GitService.Commit, pending: Bool) {
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
        if !commit.refLabels.isEmpty { details.insert(commit.refLabels.joined(separator: ", "), at: 1) }
        if pending { details.append("not pushed") }
        toolTip = details.joined(separator: "\n")
        exposeToAccessibility("\(pending ? "Unpushed " : "")commit \(commit.shortHash), "
                                + "\(commit.subject), \(commit.author), \(commit.absoluteDate)")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        SidebarCellDrawing.leadingAndTrailing(
            leading: subject, leadingFont: Theme.uiFont(11), leadingColor: Theme.foreground,
            trailing: author, trailingFont: Theme.uiFont(9.5), trailingColor: metaColor,
            trailingPinned: date,
            in: NSRect(x: 8, y: 0, width: max(0, bounds.width - 16), height: bounds.height))
    }

    var subjectForTesting: String { subject }
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
        for index in [previous, next] where index >= 0 {
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

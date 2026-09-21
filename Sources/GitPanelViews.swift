import AppKit

/// The views the Git panel draws with: one cell per row kind, the flat tab
/// strip above the list, and the table/scroll subclasses that carry the
/// panel's borders and row geometry.
///
/// Split out of `GitPanelViewController` because none of it touches the
/// panel's state — they are handed what to draw and draw it — and the
/// controller is easier to read without 500 lines of drawing under it.

/// One commit on one line: graph (where the surface uses one), refs pointing
/// exactly at it, id (in the Git panel), the message, who made it and when.
final class GitCommitCell: DrawnSidebarCell {
    private var subject = ""
    private var author = ""
    private var date = ""
    private var commitID = ""
    private var showsID = true
    private var metaColor = NSColor.clear
    private var graphRow: GitHistoryGraph.Row?
    private var graphWidth: CGFloat = 0
    private var refDecorations: [GitService.Commit.RefLabel] = []
    /// Between every column in the row.
    static let columnGap: CGFloat = 15

    /// Where the last draw put each column, so the gaps between them can be
    /// measured rather than eyeballed.
    private(set) var drawnHashRectForTesting: NSRect = .zero
    private(set) var drawnSubjectXForTesting: CGFloat = 0
    private(set) var drawnSubjectRectForTesting: NSRect = .zero
    private(set) var drawnAuthorRectForTesting: NSRect = .zero
    private(set) var drawnDateRectForTesting: NSRect = .zero
    private(set) var drawnGraphRectForTesting: NSRect = .zero
    private(set) var drawnRefRectsForTesting: [NSRect] = []

    /// Preserve the hash and a readable message beside the graph, accounting
    /// for leadingAndTrailing's 60% metadata budget and the hash's 25% cap.
    static func minimumWidth(for commits: [GitService.Commit], graphWidth: CGFloat) -> CGFloat {
        func width(_ text: String) -> CGFloat {
            guard !text.isEmpty else { return 0 }
            return ceil((text as NSString).size(withAttributes: [.font: Theme.uiFont(9.5)]).width) + 2
        }
        let textWidth = commits.reduce(CGFloat(60)) { widest, commit in
            let idWidth = width(commit.shortHash)
            let refsWidth = refLabelsWidth(commit.refDecorations)
            let metadata = width(commit.absoluteDate) + columnGap
                + min(30, width(commit.author))
            let body = max(ceil(metadata / 0.6), metadata + columnGap + 60)
            let refsGap = refsWidth > 0 ? columnGap : 0
            return max(widest, max(idWidth * 4,
                                   refsWidth + refsGap + idWidth + columnGap + body))
        }
        return 16 + graphWidth + textWidth
    }

    private static let refGap: CGFloat = 4
    private static let refHorizontalPadding: CGFloat = 5
    private static let refHeight: CGFloat = 16

    private static func refLabelsWidth(_ refs: [GitService.Commit.RefLabel]) -> CGFloat {
        let font = Theme.uiFont(9)
        let widths = refs.map {
            ceil(($0.name as NSString).size(withAttributes: [.font: font]).width)
                + refHorizontalPadding * 2
        }
        return widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * refGap
    }

    /// `showsID` puts the commit's id ahead of the message, which is what
    /// names it to Git. The Git panel's list has the width for it; the history
    /// under a project's changes reads message, name and time.
    func configure(commit: GitService.Commit, pending: Bool, showsID: Bool = true,
                   graphRow: GitHistoryGraph.Row? = nil, graphWidth: CGFloat = 0) {
        self.showsID = showsID
        self.graphRow = graphRow
        self.graphWidth = graphWidth
        refDecorations = commit.refDecorations
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
        // No bubble: the row carries everything it has to say itself, and a
        // tip over every row is then only something that follows the pointer
        // down the list.
        toolTip = nil
        let graphDescription = graphRow.map {
            "\($0.isHead ? "HEAD, " : "")\($0.isMerge ? "Merge, " : "")"
        } ?? ""
        let refsDescription = refDecorations.isEmpty
            ? "" : "Refs \(refDecorations.map(\.name).joined(separator: ", ")), "
        exposeToAccessibility(graphDescription + refsDescription
                                + "\(pending ? "Unpushed " : "")commit \(commit.shortHash), "
                                + "\(commit.subject), \(commit.author), \(commit.absoluteDate)")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        bounds.clip()
        defer { NSGraphicsContext.restoreGraphicsState() }
        drawnHashRectForTesting = .zero
        drawnGraphRectForTesting = .zero
        drawnRefRectsForTesting = []
        if let graphRow, graphWidth > 0 {
            let graphRect = NSRect(x: 8, y: 0,
                                   width: graphWidth - GitHistoryGraphDrawing.trailingGap,
                                   height: bounds.height)
            GitHistoryGraphDrawing.draw(graphRow, in: graphRect)
            drawnGraphRectForTesting = graphRect
        }
        var content = NSRect(x: 8 + graphWidth, y: 0,
                             width: max(0, bounds.width - 16 - graphWidth),
                             height: bounds.height)
        if !refDecorations.isEmpty, content.width > 0 {
            let naturalWidth = Self.refLabelsWidth(refDecorations)
            // Refs identify the commit, but on a narrow project sidebar they
            // must not erase the subject. The horizontal Git history can grow
            // to its minimum width and normally renders every label in full.
            let available = min(naturalWidth, floor(content.width * 0.42))
            var x = content.minX
            let end = x + available
            let font = Theme.uiFont(9)
            for ref in refDecorations where x < end {
                let natural = ceil((ref.name as NSString)
                    .size(withAttributes: [.font: font]).width)
                    + Self.refHorizontalPadding * 2
                let width = min(natural, end - x)
                guard width >= Self.refHorizontalPadding * 2 + 4 else { break }
                let rect = NSRect(x: x, y: floor(content.midY - Self.refHeight / 2),
                                  width: width, height: Self.refHeight)
                let color: NSColor
                switch ref.kind {
                case .localBranch: color = ref.isCurrent ? Theme.cursor : Theme.blue
                case .remoteBranch: color = Theme.purple
                case .tag: color = Theme.yellow
                case .detachedHead: color = Theme.orange
                }
                color.withAlphaComponent(0.14).setFill()
                let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
                path.fill()
                color.withAlphaComponent(0.7).setStroke()
                path.lineWidth = 1
                path.stroke()
                SidebarCellDrawing.text(
                    ref.name, font: font, color: color,
                    in: rect.insetBy(dx: Self.refHorizontalPadding, dy: 0),
                    lineBreak: .byTruncatingMiddle)
                drawnRefRectsForTesting.append(rect)
                x = rect.maxX + Self.refGap
            }
            if !drawnRefRectsForTesting.isEmpty {
                let used = drawnRefRectsForTesting.last!.maxX - content.minX
                let taken = used + Self.columnGap
                content = NSRect(x: content.minX + taken, y: content.minY,
                                 width: max(0, content.width - taken), height: content.height)
            }
        }
        if showsID, !commitID.isEmpty {
            let idFont = Theme.uiFont(9.5)
            // A quarter at most: the message is what the row is read for.
            let idWidth = min(ceil((commitID as NSString)
                                    .size(withAttributes: [.font: idFont]).width) + 2,
                              floor(content.width * 0.25))
            let box = NSRect(x: content.minX, y: content.minY,
                             width: idWidth, height: content.height)
            drawnHashRectForTesting = box
            SidebarCellDrawing.text(
                commitID, font: idFont, color: Theme.dimText,
                baseline: SidebarCellDrawing.centeredBaseline(for: Theme.uiFont(11), in: content),
                in: box, lineBreak: .byClipping)
            let taken = idWidth + Self.columnGap
            content = NSRect(x: content.minX + taken, y: content.minY,
                             width: max(0, content.width - taken), height: content.height)
        }
        drawnSubjectXForTesting = content.minX
        let drawn = SidebarCellDrawing.leadingAndTrailing(
            leading: subject, leadingFont: Theme.uiFont(11), leadingColor: Theme.foreground,
            trailing: author, trailingFont: Theme.uiFont(9.5), trailingColor: metaColor,
            trailingPinned: date, in: content, gap: Self.columnGap)
        drawnSubjectRectForTesting = drawn.leading
        drawnAuthorRectForTesting = drawn.trailing
        drawnDateRectForTesting = drawn.pinned
    }

    var subjectForTesting: String { subject }
    var metaForTesting: String { "\(author)  ·  \(date)" }
    var toolTipForTesting: String { toolTip ?? "" }
    var graphWidthForTesting: CGFloat { graphWidth }
    var graphRowForTesting: GitHistoryGraph.Row? { graphRow }
    var refLabelsForTesting: [String] { refDecorations.map(\.name) }
}

final class GitHistoryFileCell: GitFileActionCell {
    private var status = ""
    private var name = ""
    private var folder = ""
    private var statusColor = NSColor.clear
    private var graphLanes: [GitHistoryGraph.Lane] = []
    private var graphWidth: CGFloat = 0
    func configure(file: GitService.CommitFile, directory: URL?,
                   graphLanes: [GitHistoryGraph.Lane] = [], graphWidth: CGFloat = 0,
                   openFile: @escaping (URL) -> Void) {
        self.graphLanes = graphLanes
        self.graphWidth = graphWidth
        status = file.status
        statusColor = GitPanelViewController.statusColor(file.status)
        name = (file.path as NSString).lastPathComponent
        folder = (file.path as NSString).deletingLastPathComponent
        toolTip = file.path
        exposeToAccessibility("\(file.status), \(file.path)")
        // History describes an old commit; opening the source means its
        // current working-tree file. Deleted paths and submodules have no
        // source file to open. Always replace a recycled cell's callback.
        onOpenFile = nil
        if let url = directory?.appendingPathComponent(file.path), Self.isSourceFile(url) {
            onOpenFile = { [weak self] in
                // The file may have disappeared since this row was drawn.
                guard Self.isSourceFile(url) else {
                    self?.onOpenFile = nil
                    return
                }
                openFile(url)
            }
        }
        needsDisplay = true
    }

    private static func isSourceFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        bounds.clip()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if graphWidth > 0 {
            GitHistoryGraphDrawing.drawContinuation(graphLanes,
                in: NSRect(x: 8, y: 0,
                           width: graphWidth - GitHistoryGraphDrawing.trailingGap,
                           height: bounds.height))
        }
        // Indent beneath the commit text, leaving the graph lanes connected.
        SidebarCellDrawing.text(status, font: Theme.uiFont(10), color: statusColor,
                                in: NSRect(x: 18 + graphWidth, y: 0,
                                           width: 14, height: bounds.height),
                                alignment: .center)
        let textX: CGFloat = 38 + graphWidth
        let nameBox = NSRect(x: textX, y: 0,
                             width: max(0, bounds.width - textX - 6 - actionsWidth),
                             height: bounds.height)
        drawnNameRectForTesting = nameBox
        SidebarCellDrawing.primaryAndSecondary(
            primary: name, primaryFont: Theme.uiFont(11), primaryColor: Theme.foreground,
            secondary: folder, secondaryFont: Theme.uiFont(9.5), secondaryColor: Theme.dimText,
            in: nameBox)
        drawActions()
    }

    private(set) var drawnNameRectForTesting: NSRect = .zero
    var graphLanesForTesting: [GitHistoryGraph.Lane] { graphLanes }
    var graphWidthForTesting: CGFloat { graphWidth }
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

/// What a changed file's row offers at its trailing edge.
enum ChangeRowAction: CaseIterable {
    /// Put the file back the way it was committed.
    case discard
    /// Open the file itself, rather than the diff a click on the row shows.
    case open

    var symbolName: String {
        switch self {
        case .discard: return "arrow.uturn.backward"
        // A page: the file itself, as against the diff a click on the row
        // shows.
        case .open: return "doc.text"
        }
    }
    var label: String {
        switch self {
        case .discard: return "Discard changes"
        case .open: return "Open file"
        }
    }
}

/// A cell that is told when the pointer is on its row, so it can show what it
/// offers only then.
protocol RowHoverAware: AnyObject {
    var isRowHovered: Bool { get set }
}

/// Shared drawing and hit testing for the trailing file actions in Changes
/// and History. History only supplies open; Changes also supplies discard.
class GitFileActionCell: DrawnSidebarCell, RowHoverAware {
    /// Unset actions are not drawn, including after a cell is reused.
    var onDiscard: (() -> Void)? { didSet { actionsChanged() } }
    var onOpenFile: (() -> Void)? { didSet { actionsChanged() } }

    private func actionsChanged() {
        hoveredAction = nil
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    /// Both actions appear with the pointer and go with it: a row that showed
    /// them always would put two marks against every name in the list.
    var isRowHovered = false {
        didSet {
            guard isRowHovered != oldValue else { return }
            if !isRowHovered { hoveredAction = nil }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    private var hoveredAction: ChangeRowAction?
    private var actionTracking: NSTrackingArea?

    /// The hit area of one action, and the mark drawn inside it.
    static let actionSize: CGFloat = 20
    static let actionGlyph: CGFloat = 13
    static let actionGap: CGFloat = 2
    static let actionInset: CGFloat = 6

    private var shownActions: [ChangeRowAction] {
        guard isRowHovered else { return [] }
        return ChangeRowAction.allCases.filter { action in
            switch action {
            case .discard: return onDiscard != nil
            case .open: return onOpenFile != nil
            }
        }
    }

    /// The room the actions take at the trailing edge, nothing when none show.
    var actionsWidth: CGFloat {
        let count = CGFloat(shownActions.count)
        guard count > 0 else { return 0 }
        return count * Self.actionSize + (count - 1) * Self.actionGap + Self.actionInset
    }

    /// Where an action sits, from the trailing edge inwards in the order they
    /// are listed. `.zero` when it is not being shown.
    func rect(of action: ChangeRowAction) -> NSRect {
        let shown = shownActions
        guard let place = shown.firstIndex(of: action) else { return .zero }
        let fromEnd = CGFloat(shown.count - 1 - place)
        let x = bounds.maxX - Self.actionInset - Self.actionSize
            - fromEnd * (Self.actionSize + Self.actionGap)
        return NSRect(x: x, y: ((bounds.height - Self.actionSize) / 2).rounded(),
                      width: Self.actionSize, height: Self.actionSize)
    }

    func drawActions() {
        for action in shownActions { draw(action) }
    }

    private func draw(_ action: ChangeRowAction) {
        let box = rect(of: action)
        let lit = hoveredAction == action
        if lit {
            Theme.activeRow.setFill()
            NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        }
        let glyph = NSRect(x: box.midX - Self.actionGlyph / 2,
                           y: box.midY - Self.actionGlyph / 2,
                           width: Self.actionGlyph, height: Self.actionGlyph)
        SidebarCellDrawing.image(
            Theme.symbol(action.symbolName, accessibilityDescription: action.label,
                         pointSize: 11),
            tint: lit ? Theme.foreground : Theme.dimText, in: glyph)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let actionTracking { removeTrackingArea(actionTracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        actionTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        setHoveredAction(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredAction(at: nil)
    }

    private func setHoveredAction(at point: NSPoint?) {
        let next = point.flatMap { location in
            shownActions.first { rect(of: $0).contains(location) }
        }
        guard next != hoveredAction else { return }
        hoveredAction = next
        needsDisplay = true
    }

    /// What the last `resetCursorRects` claimed, so a test can hold the
    /// actions to the hand that says they can be clicked.
    private(set) var cursorRectsForTesting: [NSRect] = []

    override func resetCursorRects() {
        super.resetCursorRects()
        // Only while they are there to be clicked.
        cursorRectsForTesting = shownActions.map { rect(of: $0) }
        for box in cursorRectsForTesting {
            addCursorRect(box, cursor: .pointingHand)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let action = shownActions.first(where: { rect(of: $0).contains(point) }) else {
            // Anywhere else is the row's own click, which shows the diff.
            super.mouseDown(with: event)
            return
        }
        perform(action)
    }

    private func perform(_ action: ChangeRowAction) {
        performedActionForTesting = action
        switch action {
        case .discard: onDiscard?()
        case .open: onOpenFile?()
        }
    }

    /// Where an action is drawn, and whether it is lit under the pointer.
    func actionRectForTesting(_ action: ChangeRowAction) -> NSRect { rect(of: action) }
    var hoveredActionForTesting: ChangeRowAction? { hoveredAction }
    func moveMouseForTesting(to point: NSPoint?) { setHoveredAction(at: point) }
    /// A click at a point in the cell, through the mouse-down a real one
    /// arrives as. Answers with the action it ran, if any.
    @discardableResult
    func clickForTesting(at point: NSPoint) -> ChangeRowAction? {
        performedActionForTesting = nil
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown, location: convert(point, to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window?.windowNumber ?? 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1) else { return nil }
        mouseDown(with: event)
        return performedActionForTesting
    }
    private(set) var performedActionForTesting: ChangeRowAction?
}

final class GitChangeCell: GitFileActionCell {
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
        // Leave room for the actions only while the pointer is on the row.
        let nameBox = NSRect(x: 44, y: 0, width: max(0, bounds.width - 52 - actionsWidth),
                             height: bounds.height)
        drawnNameRectForTesting = nameBox
        SidebarCellDrawing.primaryAndSecondary(
            primary: name, primaryFont: Theme.uiFont(11), primaryColor: Theme.foreground,
            secondary: folder, secondaryFont: Theme.uiFont(9.5), secondaryColor: Theme.dimText,
            in: nameBox, gap: 5, primaryLineBreak: .byTruncatingMiddle)
        drawActions()
    }

    var nameForTesting: String { name }
    private(set) var drawnNameRectForTesting: NSRect = .zero
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
        // No bubble: the row already says all of it, and one popping up over
        // the list as the pointer passes was in the way of the rows under it.
        // A screen reader still hears the whole of it.
        toolTip = nil
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
        // The sweep deliberately starts and ends outside this view. AppKit
        // views do not otherwise promise to clip custom drawing to their own
        // bounds, so a narrow Projects column could paint into its neighbour.
        clipsToBounds = true
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
            // The row lights up, and the cell in it shows what it offers.
            (view(atColumn: 0, row: index, makeIfNecessary: false) as? RowHoverAware)?
                .isRowHovered = index == next
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
    /// One of the alternate rows of a striped list. Set with the row's index
    /// every time the list hands the view out; every list that stripes
    /// reloads whole, so no row keeps the parity of a place it has left.
    var isStriped = false {
        didSet {
            guard isStriped != oldValue else { return }
            needsDisplay = true
        }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        (isStriped ? Theme.stripedRow : Theme.panelBackground).setFill()
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

/// The keys that commit and push from wherever a commit message is typed:
/// ⌘↩ commits, ⇧⌘↩ pushes. Both the Git panel's box and the one-line field
/// over a project's changes read them here, so the two cannot drift apart.
enum CommitShortcut {
    case commit
    case push

    init?(_ event: NSEvent) {
        // Return, or the keypad's Enter.
        guard event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76 else {
            return nil
        }
        // Only the keys a person holds down count: Caps Lock, or the keypad
        // flag Enter carries, must not turn ⌘↩ into something else.
        switch event.modifierFlags.intersection([.command, .shift, .option, .control]) {
        case [.command]: self = .commit
        case [.command, .shift]: self = .push
        default: return nil
        }
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
        switch CommitShortcut(event) {
        case .commit?: onCommitShortcut?()
        case .push?: onPushShortcut?()
        case nil: super.keyDown(with: event)
        }
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

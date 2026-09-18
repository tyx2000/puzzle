import AppKit

/// The views the Git lists draw with: one cell per row kind, and the table
/// and row subclasses that carry their hover and stripes. None of it touches
/// a list's state — they are handed what to draw and draw it.

final class GitCommitCell: DrawnSidebarCell {
    private var subject = ""
    private var author = ""
    private var date = ""
    private var branch = ""
    private var commitID = ""
    private var metaColor = NSColor.clear
    /// Between every column in the row.
    static let columnGap: CGFloat = 15
    static var height: CGFloat { Theme.treeRowHeight() }

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

    /// `now` is when "3 hours ago" is measured from — the moment the list was
    /// read, so every row in it agrees.
    func configure(commit: GitService.Commit, pending: Bool, branch: String = "",
                   branchColumnWidth: CGFloat? = nil, now: Date = Date()) {
        self.branch = branch
        self.branchColumnWidth = branchColumnWidth
        commitID = commit.shortHash
        subject = commit.subject
        // The name gives way before the timestamp does: a truncated name still
        // reads, a truncated date does not.
        author = pending ? "↑  " + commit.author : commit.author
        date = commit.relativeDate(now: now)
        // Unpushed commits are the reason Push is enabled, so they still have
        // to be tellable apart at a glance — the arrow rides with the metadata
        // rather than taking room from the subject.
        metaColor = pending ? Theme.accent : Theme.dimText
        // No bubble: the row carries the branch, the id, the message, the name
        // and the time itself, and a tip over every row is then only something
        // that follows the pointer down the list.
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
        var content = NSRect(x: 8, y: 0, width: max(0, bounds.width - 16),
                             height: bounds.height)
        // Branch, then the commit's id, each a column of its own ahead of the
        // message: the list holds commits merged in from other branches, and
        // the id is what names one to Git.
        let metaFont = Theme.uiFont(9.5)
        let baseline = SidebarCellDrawing.centeredBaseline(for: Theme.uiFont(11), in: content)
        /// A column of its own. With a width shared down the list it is kept
        /// even for a row that has nothing to put in it — a commit no branch
        /// contains — or that row's later columns start out of line.
        func leadingColumn(_ text: String, color: NSColor, share: CGFloat,
                           lineBreak: NSLineBreakMode, width fixed: CGFloat? = nil) -> NSRect? {
            let reserved = (fixed ?? 0) > 0
            guard !text.isEmpty || reserved else { return nil }
            let natural = fixed ?? ceil((text as NSString)
                                            .size(withAttributes: [.font: metaFont]).width) + 2
            let width = min(natural, floor(content.width * share))
            let box = NSRect(x: content.minX, y: content.minY,
                             width: width, height: content.height)
            if !text.isEmpty {
                SidebarCellDrawing.text(text, font: metaFont, color: color,
                                        baseline: baseline, in: box, lineBreak: lineBreak)
            }
            let taken = width + Self.columnGap
            content = NSRect(x: content.minX + taken, y: content.minY,
                             width: max(0, content.width - taken), height: content.height)
            return text.isEmpty ? nil : box
        }
        // A quarter at most for the branch: the message is what the row is
        // read for, and a long branch name must not take the whole line.
        drawnBranchRectForTesting = leadingColumn(
            branch, color: Theme.accent, share: 0.25, lineBreak: .byTruncatingTail,
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
        statusColor = Self.statusColor(file.status)
        name = (file.path as NSString).lastPathComponent
        folder = (file.path as NSString).deletingLastPathComponent
        toolTip = file.path
        exposeToAccessibility("\(file.status), \(file.path)")
        needsDisplay = true
    }
    /// The colour a commit's file status letter is drawn in.
    static func statusColor(_ status: String) -> NSColor {
        switch status {
        case "A": return Theme.green
        case "D": return Theme.red
        case "R": return Theme.blue
        default:  return Theme.yellow     // M and friends
        }
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

/// Thin animated progress band along the commit line's edge. It is
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
            Theme.accent.withAlphaComponent(0),
            Theme.accent.withAlphaComponent(0.95),
            Theme.accent.withAlphaComponent(0),
        ]
        NSGradient(colors: colors)?.draw(
            in: NSRect(x: x, y: 0, width: sweepWidth, height: bounds.height), angle: 0)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// A Git list. Tracks the row under the pointer so rows can light up, and
/// hands right-clicks to the list's controller.
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
/// ⌘↩ commits, ⇧⌘↩ pushes, read in one place.
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

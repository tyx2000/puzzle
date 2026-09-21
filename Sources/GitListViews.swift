import AppKit

/// The views the Git lists draw with: one cell per row kind, and the table
/// and row subclasses that carry their hover and stripes. None of it touches
/// a list's state — they are handed what to draw and draw it.

/// One commit on one line: graph, refs pointing exactly at it, commit ID,
/// message, author, time.
/// Refs are inline and take only the width used by that row. Commit ID,
/// author and time retain shared widths; the message takes what remains.
///
final class GitCommitCell: DrawnSidebarCell {
    private var subject = ""
    private var author = ""
    private var date = ""
    private var commitID = ""
    private var metaColor = NSColor.clear
    private var columns: Columns?
    private var graphRow: GitHistoryGraph.Row?
    private var graphWidth: CGFloat = 0
    private var refDecorations: [GitService.Commit.RefLabel] = []
    /// Between every column in the row.
    static let columnGap: CGFloat = 10
    /// What the message keeps before the author gives way, on a panel dragged
    /// too narrow for every column.
    static let minimumSubjectWidth: CGFloat = 60
    /// What the author is squeezed to at most.
    static let minimumSqueezedWidth: CGFloat = 30
    static var height: CGFloat { Theme.treeRowHeight() }
    static var subjectFont: NSFont { Theme.uiFont(11) }
    static var metaFont: NSFont { Theme.uiFont(9.5) }

    /// The widths a list of these rows shares. Zero for a column with nothing
    /// in it anywhere in the list, which then takes no room and no gap.
    struct Columns: Equatable {
        var commitID: CGFloat = 0
        var author: CGFloat = 0
        var date: CGFloat = 0

        /// The widest of each, as drawn.
        static func measuring(commitIDs: some Sequence<String>,
                              authors: some Sequence<String>,
                              dates: some Sequence<String>) -> Columns {
            func widest(_ strings: some Sequence<String>) -> CGFloat {
                strings.reduce(0) { max($0, GitCommitCell.width(of: $1)) }
            }
            return Columns(commitID: widest(commitIDs), author: widest(authors),
                           date: widest(dates))
        }
    }

    /// A point of slack over the measured advance, which rounds a hair under
    /// what is drawn and clipped the last digit of a timestamp.
    static func width(of text: String) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return ceil((text as NSString).size(withAttributes: [.font: metaFont]).width) + 2
    }

    /// What the author column says: the name, after an ↑ for a commit that is
    /// not pushed yet — the reason Push is live, so it has to be tellable
    /// apart at a glance.
    static func authorText(_ commit: GitService.Commit, pending: Bool) -> String {
        pending ? "↑ " + commit.author : commit.author
    }

    /// Where the last draw put each column, so the gaps between them can be
    /// measured rather than eyeballed.
    private(set) var drawnHashRectForTesting: NSRect = .zero
    private(set) var drawnSubjectRectForTesting: NSRect = .zero
    private(set) var drawnAuthorRectForTesting: NSRect = .zero
    private(set) var drawnDateRectForTesting: NSRect = .zero
    private(set) var drawnGraphRectForTesting: NSRect = .zero
    private(set) var drawnRefRectsForTesting: [NSRect] = []

    /// `columns` is the list's; left out, the row measures its own.
    func configure(commit: GitService.Commit, pending: Bool, columns: Columns? = nil,
                   graphRow: GitHistoryGraph.Row? = nil, graphWidth: CGFloat = 0) {
        self.columns = columns
        self.graphRow = graphRow
        self.graphWidth = graphWidth
        refDecorations = commit.refDecorations
        commitID = commit.shortHash
        subject = commit.subject
        author = Self.authorText(commit, pending: pending)
        date = commit.absoluteDate
        metaColor = pending ? Theme.accent : Theme.dimText
        // No bubble: the row carries everything it has to say, and a tip over
        // every row is only something that follows the pointer down the list.
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

    /// Each column's rectangle across `content`, message included.
    static func layout(_ columns: Columns, in content: NSRect)
        -> (commitID: NSRect, subject: NSRect, author: NSRect, date: NSRect) {
        let fixed = [columns.commitID, columns.author, columns.date].filter { $0 > 0 }
        let gaps = CGFloat(fixed.count) * columnGap
        // Too narrow for every column: the author gives way before the
        // message goes below its minimum.
        let shortfall = fixed.reduce(0, +) + gaps + minimumSubjectWidth - content.width
        let author = columns.author
            - min(max(0, shortfall), max(0, columns.author - minimumSqueezedWidth))
        func box(_ x: CGFloat, _ width: CGFloat) -> NSRect {
            NSRect(x: x, y: content.minY, width: max(0, width), height: content.height)
        }
        var x = content.minX
        let idBox = box(x, columns.commitID)
        if columns.commitID > 0 { x += columns.commitID + columnGap }
        var right = content.maxX
        let dateBox = box(right - columns.date, columns.date)
        if columns.date > 0 { right -= columns.date + columnGap }
        let authorBox = box(right - author, author)
        if author > 0 { right -= author + columnGap }
        return (idBox, box(x, right - x), authorBox, dateBox)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        bounds.clip()
        defer { NSGraphicsContext.restoreGraphicsState() }
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
            let naturalWidth = GitRefLabelsDrawing.width(refDecorations)
            let available = min(naturalWidth, floor(content.width * 0.42))
            drawnRefRectsForTesting = GitRefLabelsDrawing.draw(
                refDecorations,
                in: NSRect(x: content.minX, y: content.minY,
                           width: available, height: content.height),
                currentColor: Theme.accent)
            if let last = drawnRefRectsForTesting.last {
                let taken = last.maxX - content.minX + Self.columnGap
                content = NSRect(x: content.minX + taken, y: content.minY,
                                 width: max(0, content.width - taken), height: content.height)
            }
        }
        let columns = self.columns ?? Columns.measuring(
            commitIDs: [commitID], authors: [author], dates: [date])
        let boxes = Self.layout(columns, in: content)
        let baseline = SidebarCellDrawing.centeredBaseline(for: Self.subjectFont, in: content)
        func draw(_ text: String, font: NSFont, color: NSColor, in box: NSRect,
                  lineBreak: NSLineBreakMode) -> NSRect {
            guard !text.isEmpty, box.width > 0 else { return .zero }
            SidebarCellDrawing.text(text, font: font, color: color, baseline: baseline,
                                    in: box, lineBreak: lineBreak)
            return box
        }
        drawnHashRectForTesting = draw(commitID, font: Self.metaFont, color: Theme.dimText,
                                       in: boxes.commitID, lineBreak: .byClipping)
        drawnSubjectRectForTesting = draw(subject, font: Self.subjectFont,
                                          color: Theme.foreground, in: boxes.subject,
                                          lineBreak: .byTruncatingTail)
        drawnAuthorRectForTesting = draw(author, font: Self.metaFont, color: metaColor,
                                         in: boxes.author, lineBreak: .byTruncatingTail)
        drawnDateRectForTesting = draw(date, font: Self.metaFont, color: metaColor,
                                       in: boxes.date, lineBreak: .byClipping)
    }

    var subjectForTesting: String { subject }
    var authorForTesting: String { author }
    var dateForTesting: String { date }
    var toolTipForTesting: String { toolTip ?? "" }
    var graphWidthForTesting: CGFloat { graphWidth }
    var graphRowForTesting: GitHistoryGraph.Row? { graphRow }
    var refLabelsForTesting: [String] { refDecorations.map(\.name) }
}

final class GitHistoryFileCell: DrawnSidebarCell {
    private var status = ""
    private var name = ""
    private var folder = ""
    private var statusColor = NSColor.clear
    private var graphLanes: [GitHistoryGraph.Lane] = []
    private var graphWidth: CGFloat = 0
    func configure(file: GitService.CommitFile,
                   graphLanes: [GitHistoryGraph.Lane] = [], graphWidth: CGFloat = 0) {
        self.graphLanes = graphLanes
        self.graphWidth = graphWidth
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
        NSGraphicsContext.saveGraphicsState()
        bounds.clip()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if graphWidth > 0 {
            GitHistoryGraphDrawing.drawContinuation(graphLanes,
                in: NSRect(x: 8, y: 0,
                           width: graphWidth - GitHistoryGraphDrawing.trailingGap,
                           height: bounds.height))
        }
        // Files stay indented under the commit text, clear of every graph lane.
        SidebarCellDrawing.text(status, font: Theme.uiFont(10), color: statusColor,
                                in: NSRect(x: 18 + graphWidth, y: 0,
                                           width: 14, height: bounds.height),
                                alignment: .center)
        let textX: CGFloat = 38 + graphWidth
        SidebarCellDrawing.primaryAndSecondary(
            primary: name, primaryFont: Theme.uiFont(11), primaryColor: Theme.foreground,
            secondary: folder, secondaryFont: Theme.uiFont(9.5), secondaryColor: Theme.dimText,
            in: NSRect(x: textX, y: 0, width: max(0, bounds.width - textX - 6),
                       height: bounds.height))
    }

    var graphLanesForTesting: [GitHistoryGraph.Lane] { graphLanes }
    var graphWidthForTesting: CGFloat { graphWidth }
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

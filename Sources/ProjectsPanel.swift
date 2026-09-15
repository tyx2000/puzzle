import AppKit

/// One project in the Projects panel: its name, the branch it is on, and the
/// button that takes it out of the window. Selecting it expands its file tree
/// underneath.
final class ProjectRowView: NSView {
    static let height: CGFloat = 32
    /// The ✕'s square at the trailing end, held clear of the panel's edge.
    private static let closeWidth: CGFloat = 18
    private static let closeInset: CGFloat = 8
    /// The band down the leading edge of the project being shown. Every row
    /// leaves room for it, so a name does not shift as the selection moves.
    static let markerWidth: CGFloat = 5

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    /// The branch name is its own target: it selects the project and shows
    /// that project's Git panel, which otherwise costs a second trip to the
    /// Git button at the foot of the sidebar.
    var onSelectBranch: (() -> Void)?
    /// Dragging this row: the panel decides whether the list may be reordered
    /// at all, and tracks where the row is going.
    var onDragBegan: (() -> Bool)?
    /// How far the row has travelled *down* the list from where it was picked
    /// up, in points.
    var onDragMoved: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?

    private var name = ""
    private var branch = ""
    /// Who commits here — the repository's `user.name`. Dimmed after the
    /// branch: the branch is the heading, this says whose name the next
    /// commit will carry.
    private var user = ""
    /// How many files the project has changed but not committed. Nothing is
    /// drawn for none: a row of zeroes down the panel says nothing.
    private var changes = 0
    private var path = ""
    private var isActive = false
    private var isHovered = false
    /// A line above the row, so the list reads as rows rather than one block.
    /// The first row has none, and neither does the gap between a project and
    /// the tree that belongs to it.
    var showsDivider = false { didSet { needsDisplay = true } }
    private var closeIsHovered = false
    private var branchIsHovered = false
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(name: String, branch: String, user: String, changes: Int,
                   path: String, isActive: Bool) {
        self.name = name
        self.branch = branch
        self.user = user
        self.changes = changes
        self.path = path
        self.isActive = isActive
        toolTip = path
        // The branch's hit box moved with the name; the pointing hand over it
        // has to be measured again.
        window?.invalidateCursorRects(for: self)
        var label = branch.isEmpty ? name : "\(name), branch \(branch)"
        if !user.isEmpty { label += ", \(user)" }
        if changes > 0 { label += ", \(changes) changed" }
        setAccessibilityLabel(label)
        needsDisplay = true
    }

    private var closeRect: NSRect {
        NSRect(x: bounds.width - Self.closeWidth - Self.closeInset,
               y: (bounds.height - Self.closeWidth) / 2,
               width: Self.closeWidth, height: Self.closeWidth)
    }

    /// Both headings are drawn alike: the branch names the right column the
    /// way the project names the left one, so the row reads as two headings
    /// rather than a name with a note after it.
    private static func nameFont() -> NSFont { Theme.uiFont(12) }
    /// The row is divided: the project's name heads the file tree below it,
    /// the branch heads that project's changes. Both columns carry on down
    /// through the panel, so a row reads as the two headings it is — and the
    /// line moves where the reader drags it, in the lists below.
    var dividerFraction: CGFloat = 0.5 { didSet { needsDisplay = true } }
    var columnDivider: CGFloat {
        ProjectColumnsView.divider(at: dividerFraction, in: bounds.width)
    }
    /// The room the name has: from the marker to the divider.
    private var nameRect: NSRect {
        let x = Self.markerWidth + 6
        return NSRect(x: x, y: 0, width: max(0, columnDivider - x - 6),
                      height: bounds.height)
    }
    /// The room the branch has: from the divider to the ✕.
    private var branchColumnRect: NSRect {
        let x = columnDivider + 8
        return NSRect(x: x, y: 0,
                      width: max(0, bounds.width - Self.closeWidth - Self.closeInset - 4 - x),
                      height: bounds.height)
    }

    /// Where the branch name lands, so a click on it can be told from a click
    /// on the rest of the row. Empty when there is no branch, or when its
    /// column has no room left.
    private var branchRect: NSRect {
        guard !branch.isEmpty else { return .zero }
        let column = branchColumnRect
        let width = (branch as NSString)
            .size(withAttributes: [.font: Self.nameFont()]).width
        guard column.width > 0 else { return .zero }
        return NSRect(x: column.minX, y: 0, width: min(width, column.width),
                      height: bounds.height)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let branch = branchRect
        guard !branch.isEmpty else { return }
        addCursorRect(branch, cursor: .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isActive {
            Theme.selectedControl.setFill()
            bounds.fill()
        } else if isHovered {
            Theme.hover.setFill()
            bounds.fill()
        }
        if showsDivider {
            Theme.border.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        }
        if isActive {
            Theme.cursor.setFill()
            NSRect(x: 0, y: 0, width: Self.markerWidth, height: bounds.height).fill()
        }
        SidebarCellDrawing.attributedText(nameLabel(), in: nameRect)
        // The line between the two columns, carried on down the panel by the
        // pair of lists below.
        if !branch.isEmpty {
            Theme.border.setFill()
            NSRect(x: columnDivider, y: 0, width: 1, height: bounds.height).fill()
            SidebarCellDrawing.attributedText(branchLabel(), in: branchColumnRect)
        }

        // Always there, so the name's room never changes as the pointer moves.
        SidebarCellDrawing.attributedText(
            NSAttributedString(string: "✕", attributes: [
                .font: Theme.uiFont(10),
                .foregroundColor: closeIsHovered ? Theme.foreground
                    : Theme.dimText.withAlphaComponent(0.7),
                .paragraphStyle: Self.centred,
            ]),
            in: closeRect)
    }

    /// The left column's heading: the project's name.
    private func nameLabel() -> NSAttributedString {
        let ink = isActive ? Theme.selectedControlText : Theme.foreground
        return NSAttributedString(string: name, attributes: [
            .font: Self.nameFont(),
            .foregroundColor: ink,
            .paragraphStyle: Self.truncating,
        ])
    }

    /// The right column's heading: the branch, and after it the number of
    /// files changed but not committed, in the badge the sidebar uses for a
    /// count everywhere else.
    private func branchLabel() -> NSAttributedString {
        let ink = isActive ? Theme.selectedControlText : Theme.foreground
        // Underlined under the pointer, the way a link is: it is the one part
        // of the row that goes somewhere else.
        var attributes: [NSAttributedString.Key: Any] = [
            .font: Self.nameFont(),
            .foregroundColor: ink,
            .paragraphStyle: Self.truncating,
        ]
        if branchIsHovered {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        let label = NSMutableAttributedString(string: branch, attributes: attributes)
        if !user.isEmpty {
            label.append(gap())
            label.append(NSAttributedString(string: user, attributes: [
                .font: Self.nameFont(),
                .foregroundColor: Theme.dimText,
                .paragraphStyle: Self.truncating,
            ]))
        }
        if let badge = badgeRun() {
            label.append(gap())
            label.append(badge)
        }
        return label
    }

    /// The one gap the row uses between anything and anything else.
    private func gap() -> NSAttributedString {
        NSAttributedString(string: "  ", attributes: [
            .font: Self.nameFont(),
            .foregroundColor: Theme.dimText,
            .paragraphStyle: Self.truncating,
        ])
    }

    private static let truncating: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    /// The count as the sidebar's round badge, sitting on the label's line.
    private func badgeRun() -> NSAttributedString? {
        // On the row being shown the panel's own selection is already this
        // colour, which left the count as loose digits on it.
        let background = isActive ? Theme.panelBackground : Theme.activeRow
        guard changes > 0,
              let image = SidebarCellDrawing.Badge.image(
                "\(changes)", labelFont: Self.nameFont(),
                background: background, foreground: Theme.foreground)
        else { return nil }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(
            x: 0, y: (Self.nameFont().capHeight - image.size.height) / 2,
            width: image.size.width, height: image.size.height)
        return NSAttributedString(attachment: attachment)
    }

    private static let centred: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return style
    }()

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved,
                                            .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let onClose = closeRect.insetBy(dx: -4, dy: -4).contains(point)
        let onBranch = !onClose && branchRect.contains(point)
        guard !isHovered || onClose != closeIsHovered
                || onBranch != branchIsHovered else { return }
        isHovered = true
        closeIsHovered = onClose
        branchIsHovered = onBranch
        // Back to the project's path once the pointer leaves the ✕. The branch
        // says what it does by underlining itself; a bubble over it as well is
        // one explanation too many.
        toolTip = onClose ? "Close this project" : path
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard isHovered || closeIsHovered || branchIsHovered else { return }
        isHovered = false
        closeIsHovered = false
        branchIsHovered = false
        toolTip = path
        needsDisplay = true
    }

    /// Far enough that a shaky click is not a drag.
    private static let dragThreshold: CGFloat = 4

    /// Selection waits for the release: a press that turns into a drag is
    /// carrying the row to another place in the list, and selecting on the
    /// press made every reorder also expand the project it started from.
    ///
    /// The drag runs in its own event loop — the panel moves this row between
    /// its neighbours as it travels, and touching the view hierarchy mid-
    /// gesture ends AppKit's own tracking.
    override func mouseDown(with event: NSEvent) {
        let start = convert(event.locationInWindow, from: nil)
        // The ✕ takes the click, so closing never also selects.
        if closeRect.insetBy(dx: -4, dy: -4).contains(start) {
            onClose?()
            return
        }
        trackPress(from: start, inWindow: event.locationInWindow) { [weak self] in
            self?.window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp])
        }
    }

    /// The press, from the button going down to what it turns out to have
    /// meant. `nextEvent` hands over the rest of the gesture — the window's
    /// own queue in the app, a scripted sequence in a test.
    ///
    /// The travel is measured in the window's own space, not this row's: the
    /// row changes places under the pointer as it goes, which would otherwise
    /// move the mark the travel is measured from.
    func trackPress(from start: NSPoint, inWindow startInWindow: NSPoint,
                    nextEvent: () -> NSEvent?) {
        var dragging = false
        var tracking = true
        while tracking, let next = nextEvent() {
            switch next.type {
            case .leftMouseDragged:
                // A window's y grows upwards; the list runs down the screen.
                let travelled = startInWindow.y - next.locationInWindow.y
                if !dragging {
                    guard abs(travelled) > Self.dragThreshold,
                          onDragBegan?() == true else { continue }
                    dragging = true
                }
                onDragMoved?(travelled)
            default:
                tracking = false
            }
        }
        // A row that travelled was moved, not clicked; a row that stayed put
        // was clicked, on the branch or beside it.
        guard !dragging else {
            onDragEnded?()
            return
        }
        if branchRect.contains(start), onSelectBranch != nil {
            onSelectBranch?()
        } else {
            onSelect?()
        }
    }

    /// What the row reads as, both columns, with the badge written out as its
    /// number.
    var titleForTesting: String {
        let left = nameLabel().string
        guard !branch.isEmpty else { return left }
        return left + "  " + branchLabel().string.replacingOccurrences(
            of: "\u{FFFC}", with: changes > 0 ? "\(changes)" : "")
    }
    /// Where the row divides its two columns.
    var columnDividerForTesting: CGFloat { columnDivider }
    /// The badge image the count is drawn in, if the row carries one.
    var badgeImageForTesting: NSImage? {
        let label = branchLabel()
        var found: NSImage?
        label.enumerateAttribute(.attachment,
                                 in: NSRange(location: 0, length: label.length)) { value, _, _ in
            if let attachment = value as? NSTextAttachment { found = attachment.image }
        }
        return found
    }
    /// The band's rect when the row is the one being shown, else nil.
    var markerRectForTesting: NSRect? {
        isActive ? NSRect(x: 0, y: 0, width: Self.markerWidth, height: bounds.height) : nil
    }
    var isActiveForTesting: Bool { isActive }
    var closeRectForTesting: NSRect { closeRect }
    var branchRectForTesting: NSRect { branchRect }
    var pathForTesting: String { path }
    /// The left column's label exactly as it is drawn.
    var nameLabelForTesting: NSAttributedString { nameLabel() }
    /// The right column's label exactly as it is drawn, hover and all.
    var labelForTesting: NSAttributedString { branchLabel() }
    /// Move the pointer across the row, the way its tracking area reports it.
    func hoverForTesting(at point: NSPoint) {
        mouseMoved(with: Self.mouseEventForTesting(.mouseMoved, at: convert(point, to: nil)))
    }
    func clickCloseForTesting() { onClose?() }
    func clickForTesting() { onSelect?() }
    /// A whole press, scripted: the button goes down at `point`, travels
    /// through `path`, and is released. Points are the row's own, converted
    /// back the way a real event arrives.
    func pressForTesting(at point: NSPoint, draggingThrough path: [NSPoint] = [],
                         between: (() -> Void)? = nil) {
        var queue = path.map {
            Self.mouseEventForTesting(.leftMouseDragged, at: convert($0, to: nil))
        }
        queue.append(Self.mouseEventForTesting(
            .leftMouseUp, at: convert(path.last ?? point, to: nil)))
        var index = 0
        trackPress(from: point, inWindow: convert(point, to: nil)) {
            // Before each event, so a test can watch the list rearrange while
            // the row is still travelling.
            between?()
            defer { index += 1 }
            return index < queue.count ? queue[index] : nil
        }
    }

    private static func mouseEventForTesting(_ type: NSEvent.EventType,
                                             at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                           timestamp: 0, windowNumber: 0, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }
}

/// What an expanded project shows: its file tree and its changes, side by
/// side under the two headings its row draws. Laid out by hand so the line
/// between the columns lands on exactly the point the row's does.
final class ProjectColumnsView: FlatView {
    var left: NSView?
    var right: NSView?
    /// A project that is not a repository has nothing to put on the right, so
    /// the tree takes the whole width rather than facing an empty half.
    var showsRight = true { didSet { needsLayout = true; needsDisplay = true } }
    /// Where the line sits, as a share of the width. The rows above draw their
    /// own line from the same number, so the headings stay over the columns
    /// they name.
    var fraction: CGFloat = 0.5 {
        didSet {
            guard fraction != oldValue else { return }
            needsLayout = true
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var onFractionChanged: ((CGFloat) -> Void)?

    /// Neither column may be squeezed away; a name needs this much to say
    /// anything at all.
    static let minimumColumn: CGFloat = 90
    /// How far either side of the line answers to a drag.
    private static let grabRadius: CGFloat = 3

    /// The line's place for a given share of a given width, kept inside the
    /// minimums and on a whole point so it draws as one crisp line.
    static func divider(at fraction: CGFloat, in width: CGFloat) -> CGFloat {
        guard width > minimumColumn * 2 + 1 else { return (width / 2).rounded() }
        return min(max((fraction * width).rounded(), minimumColumn),
                   width - minimumColumn - 1)
    }

    var divider: CGFloat {
        showsRight ? Self.divider(at: fraction, in: bounds.width) : bounds.width
    }

    /// The grab band lies over the two lists, so the press that moves the line
    /// has to be claimed before a scroll view swallows it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if showsRight, bounds.contains(local),
           abs(local.x - divider) <= Self.grabRadius {
            return self
        }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard showsRight else { return }
        addCursorRect(NSRect(x: divider - Self.grabRadius, y: 0,
                             width: Self.grabRadius * 2 + 1, height: bounds.height),
                      cursor: .resizeLeftRight)
    }

    /// Tracked in its own event loop, like the rows' own drag: the columns are
    /// laid out as it travels, so what is on screen is the size being chosen.
    override func mouseDown(with event: NSEvent) {
        guard showsRight, let window else { return }
        var tracking = true
        while tracking, let next = window.nextEvent(matching: [.leftMouseDragged,
                                                              .leftMouseUp]) {
            switch next.type {
            case .leftMouseDragged:
                moveDivider(to: convert(next.locationInWindow, from: nil).x)
            default:
                tracking = false
            }
        }
    }

    /// Put the line under `x`, within the minimums, and tell the panel so the
    /// rows above can follow.
    func moveDivider(to x: CGFloat) {
        guard bounds.width > 0 else { return }
        let next = Self.divider(at: x / bounds.width, in: bounds.width) / bounds.width
        guard next != fraction else { return }
        fraction = next
        layoutSubtreeIfNeeded()
        onFractionChanged?(next)
    }

    override func layout() {
        super.layout()
        left?.frame = NSRect(x: 0, y: 0, width: divider, height: bounds.height)
        right?.isHidden = !showsRight
        guard showsRight else { return }
        right?.frame = NSRect(x: divider + 1, y: 0,
                              width: max(0, bounds.width - divider - 1),
                              height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard showsRight else { return }
        Theme.border.setFill()
        NSRect(x: divider, y: 0, width: 1, height: bounds.height).fill()
    }
}

/// The Projects panel: the window's projects listed down the side, with the
/// selected one's file tree and changes expanded directly underneath its row.
///
/// The tree is the same controller the panel always used; only where it sits
/// changes, so nothing about browsing a project moves.
final class ProjectsPanelViewController: NSViewController {
    let fileTree: FileTreeViewController
    /// The right-hand column: what the expanded project has changed.
    let changes = ProjectChangesViewController()
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    /// The branch name on a row was clicked: show that project's Git panel.
    var onSelectBranch: ((Int) -> Void)?
    /// A row was dragged to another place in the list.
    var onReorder: ((Int, Int) -> Void)?

    private let stack = NSStackView()
    private let columns = ProjectColumnsView()
    /// Where the reader last put the line between the two columns. Remembered
    /// across launches: it is a deliberate choice about a window's shape, not
    /// a passing state.
    private static let dividerKey = "projects_panel_divider"
    /// Where that choice is kept. Injectable, so a test moving the line does
    /// not reach into the user's own defaults.
    var dividerDefaults: UserDefaults = .standard
    private var dividerFraction: CGFloat = 0.5

    private static func storedDividerFraction(_ defaults: UserDefaults) -> CGFloat {
        let stored = defaults.object(forKey: dividerKey) as? Double
        guard let stored, stored > 0.05, stored < 0.95 else { return 0.5 }
        return CGFloat(stored)
    }
    /// The row being dragged and where it started, while a drag is running.
    private var draggingRow: ProjectRowView?
    private var dragStartIndex = 0
    private var rows: [ProjectRowView] = []
    private var shown: [String] = []
    private var activeIndex: Int?

    init(fileTree: FileTreeViewController) {
        self.fileTree = fileTree
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = FlatView()
        root.fillColor = Theme.panelBackground
        // Layer-backed for one reason: the rows slide to their new places when
        // a project is picked, which needs implicit animation.
        root.wantsLayer = true
        addChild(fileTree)
        addChild(changes)
        // Both columns live in the container for good: taking a view out of
        // the hierarchy and putting it back leaves an outline view that draws
        // nothing until it is reloaded.
        fileTree.view.translatesAutoresizingMaskIntoConstraints = true
        changes.view.translatesAutoresizingMaskIntoConstraints = true
        columns.left = fileTree.view
        columns.right = changes.view
        dividerFraction = Self.storedDividerFraction(dividerDefaults)
        columns.fraction = dividerFraction
        columns.onFractionChanged = { [weak self] fraction in
            self?.applyDividerFraction(fraction)
        }
        columns.addSubview(fileTree.view)
        columns.addSubview(changes.view)
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        // The columns take whatever the rows leave.
        columns.setContentHuggingPriority(.init(1), for: .vertical)
        columns.setContentCompressionResistancePriority(.init(1), for: .vertical)
        view = root
        // A window with no project still shows the tree — empty, filling the
        // panel — so the panel is never a blank rectangle.
        layOut(active: nil)
    }

    /// Rebuild the list. The tree is moved rather than remade, so switching
    /// projects does not cost a fresh scroll view.
    func configure(projects: [(name: String, branch: String, user: String,
                               changes: Int, path: String)],
                   active: Int?) {
        _ = view
        let identity = projects.map { "\($0.path)|\($0.branch)" }
        if identity != shown {
            shown = identity
            rows.forEach {
                stack.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
            rows = projects.enumerated().map { index, project in
                let row = ProjectRowView()
                row.onSelect = { [weak self] in self?.onSelect?(index) }
                row.onClose = { [weak self] in self?.onClose?(index) }
                row.onSelectBranch = { [weak self] in self?.onSelectBranch?(index) }
                row.onDragBegan = { [weak self, weak row] in
                    guard let self, let row else { return false }
                    return self.beginRowDrag(row)
                }
                row.onDragMoved = { [weak self, weak row] travel in
                    guard let self, let row else { return }
                    self.rowDragMoved(row, by: travel)
                }
                row.onDragEnded = { [weak self] in self?.endRowDrag() }
                return row
            }
        }
        for (index, project) in projects.enumerated() where rows.indices.contains(index) {
            rows[index].dividerFraction = dividerFraction
            rows[index].configure(name: project.name, branch: project.branch,
                                  user: project.user, changes: project.changes,
                                  path: project.path, isActive: index == active)
            // Between rows only: not under the project whose tree follows it,
            // where a line would cut the project off from its own contents.
            rows[index].showsDivider = index > 0
        }
        activeIndex = active
        // A project with no branch is not a repository: nothing to head the
        // right column with, and nothing to put in it.
        columns.showsRight = active.map { projects.indices.contains($0)
            && !projects[$0].branch.isEmpty } ?? false
        layOut(active: active)
    }

    /// Rows in order, with the expanded project's two columns inserted
    /// straight after its row.
    ///
    /// Views are *moved* into place rather than torn down and rebuilt: taking
    /// a list out of the hierarchy and putting it back leaves an outline view
    /// that has to be reloaded before it draws anything, which showed up as an
    /// empty panel after every project switch.
    private func layOut(active: Int?) {
        var desired: [NSView] = []
        for (index, row) in rows.enumerated() {
            desired.append(row)
            if index == active { desired.append(columns) }
        }
        // No project: the tree still fills the panel, empty.
        if active == nil || rows.isEmpty { desired.append(columns) }
        guard desired != stack.arrangedSubviews else { return }
        // Nothing to slide from when the panel is being filled for the first
        // time: a window opening should find its project already there.
        let hadRows = stack.arrangedSubviews.contains { $0 is ProjectRowView }
        for (position, item) in desired.enumerated() {
            guard stack.arrangedSubviews.indices.contains(position),
                  stack.arrangedSubviews[position] === item else {
                stack.insertArrangedSubview(item, at: position)
                continue
            }
        }
        while stack.arrangedSubviews.count > desired.count {
            let extra = stack.arrangedSubviews[desired.count]
            stack.removeArrangedSubview(extra)
            extra.removeFromSuperview()
        }
        // The rows below the chosen project have to travel the height of a
        // whole file tree. Jumping there reads as the list being rebuilt;
        // sliding reads as the one project opening.
        guard hadRows else {
            lastLayoutDurationForTesting = 0
            return
        }
        lastLayoutDurationForTesting = Self.switchDuration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.switchDuration
            context.allowsImplicitAnimation = true
            stack.layoutSubtreeIfNeeded()
        }
    }

    /// Long enough to be followed, short enough not to be waited for.
    static let switchDuration: TimeInterval = 0.3
    private(set) var lastLayoutDurationForTesting: TimeInterval?

    /// The line moved: the headings follow it, and it is where the next
    /// window will find it.
    private func applyDividerFraction(_ fraction: CGFloat) {
        dividerFraction = fraction
        rows.forEach { $0.dividerFraction = fraction }
        dividerDefaults.set(Double(fraction), forKey: Self.dividerKey)
    }

    // MARK: - Reordering

    /// Reordering is offered only when every project is collapsed. With one
    /// expanded, the tree sits between the rows and "where will it land" has
    /// no honest answer.
    private var canReorder: Bool { activeIndex == nil && rows.count > 1 }

    private func beginRowDrag(_ row: ProjectRowView) -> Bool {
        guard canReorder, let index = stack.arrangedSubviews.firstIndex(of: row) else {
            return false
        }
        draggingRow = row
        dragStartIndex = index
        return true
    }

    /// The row follows the pointer by *changing places*: the list it is being
    /// dropped into is the preview, so what is on screen while dragging is
    /// exactly what will be committed.
    ///
    /// Counted in whole rows travelled rather than measured against the other
    /// rows' frames. Reordering is only offered with every project collapsed,
    /// so the rows are a contiguous run of one height; and frames are the one
    /// thing that cannot be trusted here, since a project switch that is still
    /// sliding into place has not settled into its own yet.
    private func rowDragMoved(_ row: ProjectRowView, by travel: CGFloat) {
        guard draggingRow === row else { return }
        let moved = Int((travel / ProjectRowView.height).rounded())
        let slot = max(0, min(rows.count - 1, dragStartIndex + moved))
        guard stack.arrangedSubviews.firstIndex(of: row) != slot else { return }
        stack.insertArrangedSubview(row, at: slot)
        stack.layoutSubtreeIfNeeded()
    }

    private func endRowDrag() {
        guard let row = draggingRow,
              let landed = stack.arrangedSubviews.firstIndex(of: row) else { return }
        draggingRow = nil
        guard landed != dragStartIndex else { return }
        onReorder?(dragStartIndex, landed)
    }

    var rowsForTesting: [ProjectRowView] { rows }
    var columnsForTesting: ProjectColumnsView { columns }
    var dividerFractionForTesting: CGFloat { dividerFraction }
    /// Drag the line to `x`, the way a pointer moves it.
    func dragDividerForTesting(to x: CGFloat) { columns.moveDivider(to: x) }
    var visualOrderForTesting: [String] {
        stack.arrangedSubviews.compactMap { ($0 as? ProjectRowView)?.titleForTesting }
    }
    /// Where the expanded columns sit among the rows, which is what "expanded
    /// underneath" means in layout terms.
    var treePositionForTesting: Int? {
        stack.arrangedSubviews.firstIndex(of: columns)
    }
}

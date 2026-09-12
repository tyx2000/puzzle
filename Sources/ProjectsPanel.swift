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
    var onDragMoved: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?

    private var name = ""
    private var branch = ""
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

    func configure(name: String, branch: String, path: String, isActive: Bool) {
        self.name = name
        self.branch = branch
        self.path = path
        self.isActive = isActive
        toolTip = path
        // The branch's hit box moved with the name; the pointing hand over it
        // has to be measured again.
        window?.invalidateCursorRects(for: self)
        setAccessibilityLabel(branch.isEmpty ? name : "\(name), branch \(branch)")
        needsDisplay = true
    }

    private var closeRect: NSRect {
        NSRect(x: bounds.width - Self.closeWidth - Self.closeInset,
               y: (bounds.height - Self.closeWidth) / 2,
               width: Self.closeWidth, height: Self.closeWidth)
    }

    private static func nameFont() -> NSFont { Theme.uiFont(12) }
    private static func branchFont() -> NSFont { Theme.uiFont(11) }
    /// The room the label has: from the marker to the ✕.
    private var textRect: NSRect {
        var text = bounds.insetBy(dx: Self.markerWidth + 6, dy: 0)
        text.size.width -= Self.closeWidth + Self.closeInset
        return text
    }

    /// Where the branch name lands, so a click on it can be told from a click
    /// on the rest of the row. Empty when there is no branch, or when the name
    /// has already taken every point of the row.
    private var branchRect: NSRect {
        guard !branch.isEmpty else { return .zero }
        let text = textRect
        let nameWidth = (name as NSString)
            .size(withAttributes: [.font: Self.nameFont()]).width
        let gap = ("  " as NSString)
            .size(withAttributes: [.font: Self.branchFont()]).width
        let width = (branch as NSString)
            .size(withAttributes: [.font: Self.branchFont()]).width
        let x = text.minX + nameWidth + gap
        guard x < text.maxX else { return .zero }
        return NSRect(x: x, y: 0, width: min(width, text.maxX - x), height: bounds.height)
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
        SidebarCellDrawing.attributedText(label(), in: textRect)

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

    /// Name then branch on one line, the branch dimmed: the same pairing the
    /// window's own title strip uses.
    private func label() -> NSAttributedString {
        let ink = isActive ? Theme.selectedControlText : Theme.foreground
        let label = NSMutableAttributedString(string: name, attributes: [
            .font: Self.nameFont(),
            .foregroundColor: ink,
        ])
        if !branch.isEmpty {
            // The gap is a run of its own: an underline drawn across it would
            // reach out past the branch name it belongs to.
            label.append(NSAttributedString(string: "  ", attributes: [
                .font: Self.branchFont(),
                .foregroundColor: Theme.dimText,
            ]))
            // Underlined under the pointer, the way a link is: it is the one
            // part of the row that goes somewhere else.
            var attributes: [NSAttributedString.Key: Any] = [
                .font: Self.branchFont(),
                .foregroundColor: branchIsHovered ? ink : Theme.dimText,
            ]
            if branchIsHovered {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            label.append(NSAttributedString(string: branch, attributes: attributes))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        label.addAttribute(.paragraphStyle, value: paragraph,
                           range: NSRange(location: 0, length: label.length))
        return label
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
        trackPress(from: start) { [weak self] in
            self?.window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp])
        }
    }

    /// The press, from the button going down to what it turns out to have
    /// meant. `nextEvent` hands over the rest of the gesture — the window's
    /// own queue in the app, a scripted sequence in a test.
    func trackPress(from start: NSPoint, nextEvent: () -> NSEvent?) {
        var dragging = false
        var tracking = true
        while tracking, let next = nextEvent() {
            switch next.type {
            case .leftMouseDragged:
                let point = convert(next.locationInWindow, from: nil)
                if !dragging {
                    guard abs(point.y - start.y) > Self.dragThreshold,
                          onDragBegan?() == true else { continue }
                    dragging = true
                }
                onDragMoved?(point)
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

    var titleForTesting: String { branch.isEmpty ? name : "\(name)  \(branch)" }
    /// The band's rect when the row is the one being shown, else nil.
    var markerRectForTesting: NSRect? {
        isActive ? NSRect(x: 0, y: 0, width: Self.markerWidth, height: bounds.height) : nil
    }
    var isActiveForTesting: Bool { isActive }
    var closeRectForTesting: NSRect { closeRect }
    var branchRectForTesting: NSRect { branchRect }
    var pathForTesting: String { path }
    /// The row's label exactly as it is drawn, hover and all.
    var labelForTesting: NSAttributedString { label() }
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
        trackPress(from: point) {
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

/// The Projects panel: the window's projects listed down the side, with the
/// selected one's file tree expanded directly underneath its row.
///
/// The tree is the same controller the panel always used; only where it sits
/// changes, so nothing about browsing a project moves.
final class ProjectsPanelViewController: NSViewController {
    let fileTree: FileTreeViewController
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    /// The branch name on a row was clicked: show that project's Git panel.
    var onSelectBranch: ((Int) -> Void)?
    /// A row was dragged to another place in the list.
    var onReorder: ((Int, Int) -> Void)?

    private let stack = NSStackView()
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
        addChild(fileTree)
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
        // The tree takes whatever the rows leave.
        fileTree.view.setContentHuggingPriority(.init(1), for: .vertical)
        fileTree.view.setContentCompressionResistancePriority(.init(1), for: .vertical)
        view = root
        // A window with no project still shows the tree — empty, filling the
        // panel — so the panel is never a blank rectangle.
        layOut(active: nil)
    }

    /// Rebuild the list. The tree is moved rather than remade, so switching
    /// projects does not cost a fresh scroll view.
    func configure(projects: [(name: String, branch: String, path: String)],
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
                row.onDragMoved = { [weak self, weak row] point in
                    guard let self, let row else { return }
                    self.rowDragMoved(row, to: point)
                }
                row.onDragEnded = { [weak self] in self?.endRowDrag() }
                return row
            }
        }
        for (index, project) in projects.enumerated() where rows.indices.contains(index) {
            rows[index].configure(name: project.name, branch: project.branch,
                                  path: project.path, isActive: index == active)
            // Between rows only: not under the project whose tree follows it,
            // where a line would cut the project off from its own contents.
            rows[index].showsDivider = index > 0
        }
        activeIndex = active
        layOut(active: active)
    }

    /// Rows in order, with the tree inserted straight after the active one.
    ///
    /// Views are *moved* into place rather than torn down and rebuilt: taking
    /// the tree out of the hierarchy and putting it back leaves an outline view
    /// that has to be reloaded before it draws anything, which showed up as an
    /// empty panel after every project switch.
    private func layOut(active: Int?) {
        var desired: [NSView] = []
        for (index, row) in rows.enumerated() {
            desired.append(row)
            if index == active { desired.append(fileTree.view) }
        }
        // No project: the tree still fills the panel, empty.
        if active == nil || rows.isEmpty { desired.append(fileTree.view) }
        guard desired != stack.arrangedSubviews else { return }
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
    private func rowDragMoved(_ row: ProjectRowView, to point: NSPoint) {
        guard draggingRow === row else { return }
        let pointer = topDown(stack.convert(point, from: row).y)
        // Measured against the other rows' middles rather than by dividing the
        // stack's height into slots: a vertical stack is not flipped, so
        // counting from its origin numbers the list from the bottom up and a
        // row would only ever travel one way.
        var slot = 0
        for candidate in stack.arrangedSubviews.compactMap({ $0 as? ProjectRowView })
        where candidate !== row {
            if topDown(candidate.frame.midY) < pointer { slot += 1 }
        }
        guard stack.arrangedSubviews.firstIndex(of: row) != slot else { return }
        stack.insertArrangedSubview(row, at: slot)
        stack.layoutSubtreeIfNeeded()
    }

    /// How far down the stack a point is, whichever way the stack's own axis
    /// runs.
    private func topDown(_ y: CGFloat) -> CGFloat {
        stack.isFlipped ? y : stack.bounds.height - y
    }

    private func endRowDrag() {
        guard let row = draggingRow,
              let landed = stack.arrangedSubviews.firstIndex(of: row) else { return }
        draggingRow = nil
        guard landed != dragStartIndex else { return }
        onReorder?(dragStartIndex, landed)
    }

    var rowsForTesting: [ProjectRowView] { rows }
    var visualOrderForTesting: [String] {
        stack.arrangedSubviews.compactMap { ($0 as? ProjectRowView)?.titleForTesting }
    }
    /// Where the tree sits among the rows, which is what "expanded underneath"
    /// means in layout terms.
    var treePositionForTesting: Int? {
        stack.arrangedSubviews.firstIndex(of: fileTree.view)
    }
}

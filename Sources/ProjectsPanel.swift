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
    /// Dragging this row: the panel decides whether the list may be reordered
    /// at all, and tracks where the row is going.
    var onDragBegan: (() -> Bool)?
    var onDragMoved: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?

    private var name = ""
    private var branch = ""
    private var isActive = false
    private var isHovered = false
    /// A line above the row, so the list reads as rows rather than one block.
    /// The first row has none, and neither does the gap between a project and
    /// the tree that belongs to it.
    var showsDivider = false { didSet { needsDisplay = true } }
    private var closeIsHovered = false
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
        self.isActive = isActive
        toolTip = path
        setAccessibilityLabel(branch.isEmpty ? name : "\(name), branch \(branch)")
        needsDisplay = true
    }

    private var closeRect: NSRect {
        NSRect(x: bounds.width - Self.closeWidth - Self.closeInset,
               y: (bounds.height - Self.closeWidth) / 2,
               width: Self.closeWidth, height: Self.closeWidth)
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
        let ink = isActive ? Theme.selectedControlText : Theme.foreground
        // Name then branch on one line, the branch dimmed: the same pairing the
        // window's own title strip uses.
        let label = NSMutableAttributedString(string: name, attributes: [
            .font: Theme.uiFont(12),
            .foregroundColor: ink,
        ])
        if !branch.isEmpty {
            label.append(NSAttributedString(string: "  \(branch)", attributes: [
                .font: Theme.uiFont(11),
                .foregroundColor: Theme.dimText,
            ]))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        label.addAttribute(.paragraphStyle, value: paragraph,
                           range: NSRange(location: 0, length: label.length))
        var text = bounds.insetBy(dx: Self.markerWidth + 6, dy: 0)
        text.size.width -= Self.closeWidth + Self.closeInset
        SidebarCellDrawing.attributedText(label, in: text)

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
        guard onClose != closeIsHovered || !isHovered else { return }
        isHovered = true
        closeIsHovered = onClose
        toolTip = onClose ? "Close this project" : toolTip
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard isHovered || closeIsHovered else { return }
        isHovered = false
        closeIsHovered = false
        needsDisplay = true
    }

    /// Far enough that a shaky click is not a drag.
    private static let dragThreshold: CGFloat = 4

    /// Selection happens on the press. A drag that follows reorders the list,
    /// tracked in its own event loop: the panel moves this row between its
    /// neighbours as it travels, and touching the view hierarchy mid-gesture
    /// ends AppKit's own tracking.
    override func mouseDown(with event: NSEvent) {
        let start = convert(event.locationInWindow, from: nil)
        // The ✕ takes the click, so closing never also selects.
        if closeRect.insetBy(dx: -4, dy: -4).contains(start) {
            onClose?()
            return
        }
        onSelect?()
        guard let window else { return }
        var dragging = false
        var tracking = true
        while tracking, let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            switch next.type {
            case .leftMouseDragged:
                let point = convert(next.locationInWindow, from: nil)
                if !dragging {
                    guard abs(point.y - start.y) > Self.dragThreshold,
                          onDragBegan?() == true else { continue }
                    dragging = true
                }
                onDragMoved?(convert(next.locationInWindow, from: nil))
            default:
                tracking = false
            }
        }
        if dragging { onDragEnded?() }
    }

    var titleForTesting: String { branch.isEmpty ? name : "\(name)  \(branch)" }
    /// The band's rect when the row is the one being shown, else nil.
    var markerRectForTesting: NSRect? {
        isActive ? NSRect(x: 0, y: 0, width: Self.markerWidth, height: bounds.height) : nil
    }
    var isActiveForTesting: Bool { isActive }
    var closeRectForTesting: NSRect { closeRect }
    func clickCloseForTesting() { onClose?() }
    func clickForTesting() { onSelect?() }
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
        let inStack = stack.convert(point, from: row)
        let slot = max(0, min(rows.count - 1,
                              Int((inStack.y / max(1, ProjectRowView.height)).rounded(.down))))
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
    /// Drive a reorder without a pointer: the same path a drag takes.
    func dragRowForTesting(_ index: Int, toY y: CGFloat) -> Bool {
        guard rows.indices.contains(index), beginRowDrag(rows[index]) else { return false }
        let row = rows[index]
        rowDragMoved(row, to: row.convert(NSPoint(x: 0, y: y), from: stack))
        endRowDrag()
        return true
    }
    var visualOrderForTesting: [String] {
        stack.arrangedSubviews.compactMap { ($0 as? ProjectRowView)?.titleForTesting }
    }
    /// Where the tree sits among the rows, which is what "expanded underneath"
    /// means in layout terms.
    var treePositionForTesting: Int? {
        stack.arrangedSubviews.firstIndex(of: fileTree.view)
    }
}

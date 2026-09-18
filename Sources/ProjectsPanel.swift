import AppKit

/// One project in the Projects panel: its name, the branch it is on, and the
/// button that takes it out of the window. Selecting it expands its changes
/// and history underneath.
final class ProjectRowView: NSView {
    static let height: CGFloat = 32
    /// The ✕'s square at the trailing end, held clear of the panel's edge.
    private static let closeWidth: CGFloat = 18
    private static let closeInset: CGFloat = 8
    /// The band down the leading edge of the project being shown. Every row
    /// leaves room for it, so a name does not shift as the selection moves.
    static let markerWidth: CGFloat = 5
    /// A mark before each heading saying what it is: the folder for the
    /// project, Git's own for the branch. The two headings are otherwise set
    /// alike, and these carry their own colours.
    static let iconSize: CGFloat = 14
    private static let iconGap: CGFloat = 5
    private static let nameIcon = "folder-base"
    private static let branchIcon = "git"

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    /// The branch name is its own target: it selects the project and drops
    /// the menu of branches to switch to, create or delete. The rectangle is
    /// the branch's, in this row's coordinates, for the menu to hang from.
    var onSelectBranch: ((NSRect) -> Void)?
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
    /// the lists that belong to it.
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

    /// Both headings are drawn alike, so the row reads as two headings rather
    /// than a name with a note after it.
    private static func nameFont() -> NSFont { Theme.uiFont(12) }
    /// Where the name gives way to the branch: after the name, but never past
    /// half the row — the branch, who commits and the count need the rest.
    var columnDivider: CGFloat {
        let start = Self.markerWidth + 6 + Self.iconSize + Self.iconGap
        let natural = ceil((name as NSString).size(withAttributes: [.font: Self.nameFont()]).width)
        return min(start + natural + 14, (bounds.width / 2).rounded())
    }
    /// Where each column's mark sits: at the head of its own column.
    private var nameIconRect: NSRect {
        Self.centred(x: Self.markerWidth + 6, in: bounds)
    }
    private var branchIconRect: NSRect {
        Self.centred(x: columnDivider + 8, in: bounds)
    }
    private static func centred(x: CGFloat, in bounds: NSRect) -> NSRect {
        NSRect(x: x, y: (bounds.height - iconSize) / 2,
               width: iconSize, height: iconSize)
    }

    /// The room the name has: from its mark to the divider.
    private var nameRect: NSRect {
        let x = nameIconRect.maxX + Self.iconGap
        return NSRect(x: x, y: 0, width: max(0, columnDivider - x - 6),
                      height: bounds.height)
    }
    /// The room the branch has: from its mark to the ✕.
    private var branchColumnRect: NSRect {
        let x = branchIconRect.maxX + Self.iconGap
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
        // The project being shown carries a band; the row under the pointer
        // does not — a wash that follows the mouse across the headings read as
        // a third list laid over the two they head.
        if isActive {
            Theme.selectedControl.setFill()
            bounds.fill()
        }
        if showsDivider {
            Theme.border.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        }
        if isActive {
            Theme.accent.setFill()
            NSRect(x: 0, y: 0, width: Self.markerWidth, height: bounds.height).fill()
        }
        SidebarCellDrawing.icon(.material(Self.nameIcon), in: nameIconRect)
        SidebarCellDrawing.attributedText(nameLabel(), in: nameRect)
        if !branch.isEmpty {
            SidebarCellDrawing.icon(.material(Self.branchIcon), in: branchIconRect)
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
        return NSAttributedString(string: name, attributes: [
            .font: Self.nameFont(),
            .foregroundColor: ink,
            .paragraphStyle: Self.truncating,
        ])
    }

    /// The ink both headings are written in: the project being shown is read
    /// against its own band.
    private var ink: NSColor {
        isActive ? Theme.selectedControlText : Theme.foreground
    }

    /// The right column's heading: the branch, and after it the number of
    /// files changed but not committed, in the badge the sidebar uses for a
    /// count everywhere else.
    private func branchLabel() -> NSAttributedString {
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
        // On the row being shown the panel's own band is already this colour,
        // which left the count as loose digits on it.
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
        var released: NSPoint?
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
                released = convert(next.locationInWindow, from: nil)
                tracking = false
            }
        }
        // A row that travelled was moved, not clicked; a row that stayed put
        // was clicked, on the branch or beside it.
        guard !dragging else {
            onDragEnded?()
            return
        }
        // A press that could not become a drag — the list cannot be reordered
        // while a project is open — and was let go somewhere else was not a
        // click either. Selecting then closed every tab of the project being
        // left, for a press the reader had already abandoned.
        guard let released, bounds.contains(released) else { return }
        if branchRect.contains(start), onSelectBranch != nil {
            onSelectBranch?(branchRect)
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
    /// Where each column's mark is drawn, and which icon it is.
    var columnIconsForTesting: (name: (String, NSRect), branch: (String, NSRect)) {
        ((Self.nameIcon, nameIconRect), (Self.branchIcon, branchIconRect))
    }
    static var columnIconNamesForTesting: [String] { [nameIcon, branchIcon] }
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

/// Two panes split by a line the reader can drag: under an expanded project,
/// its changes over its history. Laid out by hand so the line lands on a
/// whole point.
final class ProjectColumnsView: FlatView {
    /// Which way the pair is split: side by side, or one above the other.
    enum Axis { case horizontal, vertical }
    var axis: Axis = .horizontal { didSet { needsLayout = true; needsDisplay = true } }
    /// The left pane, or the top one.
    var first: NSView?
    var second: NSView?
    /// A pane that has nothing to show is not given half the room: the other
    /// takes the whole of it rather than facing an empty half.
    var showsSecond = true { didSet { needsLayout = true; needsDisplay = true } }
    /// Where the line sits, as a share of the length along the axis. A project
    /// row draws its own line from the same number, so the headings stay over
    /// the columns they name.
    var fraction: CGFloat = 0.5 {
        didSet {
            guard fraction != oldValue else { return }
            needsLayout = true
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var onFractionChanged: ((CGFloat) -> Void)?

    /// A border drawn inside a pane, in the colour that says which region it
    /// is. The pane's content is inset by the width, so the border sits inside
    /// the region rather than over its first row.
    var firstBorder: NSColor? { didSet { needsLayout = true; needsDisplay = true } }
    var secondBorder: NSColor? { didSet { needsLayout = true; needsDisplay = true } }
    static let borderWidth: CGFloat = 1
    /// The hues are the panel's own, taken right down: at full strength three
    /// saturated frames are the loudest thing in a sidebar whose whole palette
    /// is two steps off black.
    static func regionBorder(_ hue: NSColor) -> NSColor { hue.withAlphaComponent(0.4) }

    /// Neither pane may be squeezed away. A column needs this much to say a
    /// name; a list stacked on another needs only a couple of rows.
    static let minimumColumn: CGFloat = 90
    /// A stacked pane keeps a couple of rows.
    static let minimumRow: CGFloat = 44
    var minimumPane: CGFloat = minimumColumn
    /// How far either side of the line answers to a drag.
    private static let grabRadius: CGFloat = 3

    /// The line's place for a given share of a given length, kept inside the
    /// minimums and on a whole point so it draws as one crisp line.
    static func divider(at fraction: CGFloat, in length: CGFloat,
                        minimum: CGFloat = minimumColumn) -> CGFloat {
        guard length > minimum * 2 + 1 else { return (length / 2).rounded() }
        return min(max((fraction * length).rounded(), minimum), length - minimum - 1)
    }

    /// The length the line divides: the width across, the height down.
    private var span: CGFloat { axis == .horizontal ? bounds.width : bounds.height }

    /// How far along the axis the line sits — from the left, or from the top.
    var divider: CGFloat {
        showsSecond ? Self.divider(at: fraction, in: span, minimum: minimumPane) : span
    }

    /// The grab band lies over the two lists, so the press that moves the line
    /// has to be claimed before a scroll view swallows it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if isOnGrabBand(local) { return self }
        return super.hitTest(point)
    }

    /// Whether a point (in this view's own coordinates) is on the band that
    /// moves the line. Everything else that lands on this view — the 1pt
    /// borders the panes are inset from — is not the line's to act on.
    private func isOnGrabBand(_ point: NSPoint) -> Bool {
        showsSecond && bounds.contains(point)
            && abs(position(of: point) - divider) <= Self.grabRadius
    }

    /// Where a point falls along the axis, measured the way `divider` is: from
    /// the leading edge across, or from the top down. This view is not
    /// flipped, so down means subtracting.
    private func position(of point: NSPoint) -> CGFloat {
        axis == .horizontal ? point.x : bounds.height - point.y
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard showsSecond else { return }
        addCursorRect(dividerRect(radius: Self.grabRadius),
                      cursor: axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
    }

    /// The line itself at radius 0, the band that answers to a drag above it.
    private func dividerRect(radius: CGFloat) -> NSRect {
        let thickness = radius * 2 + 1
        switch axis {
        case .horizontal:
            return NSRect(x: divider - radius, y: 0, width: thickness, height: bounds.height)
        case .vertical:
            // The gap the panes leave is the point *below* the first one, so
            // the line goes there rather than under the pane's own bottom row.
            return NSRect(x: 0, y: bounds.height - divider - 1 - radius,
                          width: bounds.width, height: thickness)
        }
    }

    /// A scroll that lands on the grab band belongs to the list under it. The
    /// band lies over both panes so the line can be caught anywhere along it,
    /// which quietly swallowed the wheel wherever the pointer crossed it.
    ///
    /// Only a scroll that was delivered *here* is handed down. One that
    /// arrives by climbing the responder chain came up out of a pane — a list
    /// passing on a scroll it could not use — and sending it back down into
    /// that same pane would bring it straight back, until the stack ran out.
    override func scrollWheel(with event: NSEvent) {
        handleScroll(event, at: convert(event.locationInWindow, from: nil))
    }

    func handleScroll(_ event: NSEvent, at point: NSPoint) {
        guard !forwardingScroll, isOnGrabBand(point) else {
            super.scrollWheel(with: event)
            return
        }
        let pane = position(of: point) <= divider ? first : second
        guard let target = pane?.hitTest(point), target !== self else {
            super.scrollWheel(with: event)
            return
        }
        forwardingScroll = true
        defer { forwardingScroll = false }
        target.scrollWheel(with: event)
    }
    private var forwardingScroll = false

    /// Tracked in its own event loop, like the rows' own drag: the panes are
    /// laid out as it travels, so what is on screen is the size being chosen.
    override func mouseDown(with event: NSEvent) {
        let tracked = trackDivider(from: convert(event.locationInWindow, from: nil)) {
            [weak self] in
            self?.window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp])
        }
        if !tracked { super.mouseDown(with: event) }
    }

    /// The press, from the button going down to its release. A press on a
    /// pane's border lands on this view too, having no subview of its own to
    /// land on; only a press on the band moves the line. Returns whether it
    /// did.
    @discardableResult
    func trackDivider(from start: NSPoint, nextEvent: () -> NSEvent?) -> Bool {
        guard isOnGrabBand(start) else { return false }
        var tracking = true
        while tracking, let next = nextEvent() {
            switch next.type {
            case .leftMouseDragged:
                moveDivider(to: position(of: convert(next.locationInWindow, from: nil)))
            default:
                tracking = false
            }
        }
        return true
    }

    /// A whole press, scripted in this view's own points.
    @discardableResult
    func pressForTesting(at point: NSPoint, draggingTo end: NSPoint) -> Bool {
        let events = [NSEvent.EventType.leftMouseDragged, .leftMouseUp].map {
            NSEvent.mouseEvent(with: $0, location: convert(end, to: nil),
                               modifierFlags: [], timestamp: 0, windowNumber: 0,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        var index = 0
        return trackDivider(from: point) {
            defer { index += 1 }
            return index < events.count ? events[index] : nil
        }
    }

    /// Put the line at `along` — points from the leading edge, or from the top
    /// — within the minimums, and tell the panel so the rows above can follow.
    func moveDivider(to along: CGFloat) {
        guard span > 0 else { return }
        let next = Self.divider(at: along / span, in: span, minimum: minimumPane) / span
        guard next != fraction else { return }
        fraction = next
        layoutSubtreeIfNeeded()
        onFractionChanged?(next)
    }

    /// The room each pane is given, before its own border is taken out of it.
    var firstPaneRect: NSRect {
        switch axis {
        case .horizontal:
            return NSRect(x: 0, y: 0, width: divider, height: bounds.height)
        case .vertical:
            // Unflipped: the first pane is the top one, so it starts a
            // divider's worth below the view's own top edge.
            return NSRect(x: 0, y: bounds.height - divider,
                          width: bounds.width, height: divider)
        }
    }
    var secondPaneRect: NSRect {
        switch axis {
        case .horizontal:
            return NSRect(x: divider + 1, y: 0,
                          width: max(0, bounds.width - divider - 1), height: bounds.height)
        case .vertical:
            return NSRect(x: 0, y: 0, width: bounds.width,
                          height: max(0, bounds.height - divider - 1))
        }
    }

    /// The pane less its border, never less than nothing. `insetBy` on a pane
    /// smaller than its two borders — a column that has not been given any
    /// room yet — returns the null rect, whose origin is infinite, and every
    /// constraint inside the pane then asked for an infinite constant.
    private func content(of pane: NSRect, bordered: Bool) -> NSRect {
        guard bordered else { return pane }
        let inset = Self.borderWidth
        return NSRect(x: pane.minX + inset, y: pane.minY + inset,
                      width: max(0, pane.width - inset * 2),
                      height: max(0, pane.height - inset * 2))
    }

    /// A pane is positioned by hand, and everything inside it by constraints.
    /// Handing it a new frame only marks its own subtree as needing layout, so
    /// a scroll view inside it keeps the size it had until some later pass —
    /// and a list whose clip view is still the old size scrolls by the wrong
    /// amount, or not at all. Settle each pane before leaving.
    override func layout() {
        super.layout()
        second?.isHidden = !showsSecond
        first?.frame = content(of: firstPaneRect, bordered: firstBorder != nil)
        first?.layoutSubtreeIfNeeded()
        guard showsSecond else { return }
        second?.frame = content(of: secondPaneRect, bordered: secondBorder != nil)
        second?.layoutSubtreeIfNeeded()
    }

    /// A resize that does not come through the layout engine — an animated
    /// frame change, a window growing — still moves the line, so the panes
    /// have to be placed again.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        draw(border: firstBorder, around: firstPaneRect)
        guard showsSecond else { return }
        draw(border: secondBorder, around: secondPaneRect)
        // Two coloured borders meeting already separate the panes; a grey line
        // between them is a third edge saying the same thing.
        guard firstBorder == nil, secondBorder == nil else { return }
        Theme.border.setFill()
        dividerRect(radius: 0).fill()
    }

    private func draw(border: NSColor?, around pane: NSRect) {
        guard let border, pane.width > 0, pane.height > 0 else { return }
        border.setStroke()
        let path = NSBezierPath(rect: pane.insetBy(dx: Self.borderWidth / 2,
                                                   dy: Self.borderWidth / 2))
        path.lineWidth = Self.borderWidth
        path.stroke()
    }
}

/// The Projects panel: the window's projects listed down the side, with the
/// selected one's changes and history expanded directly underneath its row.
final class ProjectsPanelViewController: NSViewController {
    /// What the expanded project has changed, over the commits behind it.
    let changes = ProjectChangesViewController()
    let history = ProjectHistoryViewController()
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    /// The branch name on a row was clicked: the row's index, and where the
    /// branch sits in this panel's coordinates, for its menu to hang from.
    var onSelectBranch: ((Int, NSRect) -> Void)?
    /// A row was dragged to another place in the list.
    var onReorder: ((Int, Int) -> Void)?

    private let stack = NSStackView()
    /// Everything under the expanded project's row: the Git lists, or the
    /// note saying the folder is not a repository.
    private let detail = FlatView()
    /// The changes over the history, split by a line the reader can move.
    private let gitColumn = ProjectColumnsView()
    private let notRepository = NSTextField(labelWithString: "Not a Git repository")
    /// The line between the changes and the history. Remembered across
    /// launches: it is a deliberate choice about a window's shape, not a
    /// passing state.
    private static let gitDividerKey = "projects_panel_git_divider"
    /// Where that choice is kept. Injectable, so a test moving the line does
    /// not reach into the user's own defaults.
    var dividerDefaults: UserDefaults = .standard

    private static func storedFraction(_ key: String, in defaults: UserDefaults) -> CGFloat {
        let stored = defaults.object(forKey: key) as? Double
        guard let stored, stored > 0.05, stored < 0.95 else { return 0.5 }
        return CGFloat(stored)
    }
    /// The row being dragged and where it started, while a drag is running.
    private var draggingRow: ProjectRowView?
    private var dragStartIndex = 0
    /// What a refresh asked the list to show while a row was being dragged.
    private var pendingConfiguration: (projects: [(name: String, branch: String,
                                                   user: String, changes: Int,
                                                   path: String)],
                                       active: Int?, isRepository: Bool?)?
    private var rows: [ProjectRowView] = []
    private var shown: [String] = []
    private var activeIndex: Int?

    override func loadView() {
        let root = FlatView()
        root.fillColor = Theme.panelBackground
        // Layer-backed for one reason: the rows slide to their new places when
        // a project is picked, which needs implicit animation.
        root.wantsLayer = true
        addChild(changes)
        addChild(history)
        // Both lists live in the container for good: taking a view out of the
        // hierarchy and putting it back leaves a table that draws nothing
        // until it is reloaded.
        changes.view.translatesAutoresizingMaskIntoConstraints = true
        history.view.translatesAutoresizingMaskIntoConstraints = true
        gitColumn.translatesAutoresizingMaskIntoConstraints = false
        gitColumn.axis = .vertical
        gitColumn.minimumPane = ProjectColumnsView.minimumRow
        gitColumn.first = changes.view
        gitColumn.second = history.view
        gitColumn.addSubview(changes.view)
        gitColumn.addSubview(history.view)
        // One hue per region, drawn inside it: what has changed, and what has
        // been committed.
        gitColumn.firstBorder = ProjectColumnsView.regionBorder(Theme.orange)
        gitColumn.secondBorder = ProjectColumnsView.regionBorder(Theme.purple)
        gitColumn.fraction = Self.storedFraction(Self.gitDividerKey, in: dividerDefaults)
        gitColumn.onFractionChanged = { [weak self] fraction in
            guard let self else { return }
            self.dividerDefaults.set(Double(fraction), forKey: Self.gitDividerKey)
        }
        notRepository.font = Theme.uiFont(12)
        notRepository.textColor = Theme.dimText
        notRepository.alignment = .center
        notRepository.translatesAutoresizingMaskIntoConstraints = false
        detail.fillColor = Theme.panelBackground
        detail.addSubview(gitColumn)
        detail.addSubview(notRepository)
        NSLayoutConstraint.activate([
            gitColumn.topAnchor.constraint(equalTo: detail.topAnchor),
            gitColumn.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            gitColumn.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            gitColumn.bottomAnchor.constraint(equalTo: detail.bottomAnchor),
            notRepository.centerXAnchor.constraint(equalTo: detail.centerXAnchor),
            notRepository.topAnchor.constraint(equalTo: detail.topAnchor, constant: 24),
        ])

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
        // The lists take whatever the rows leave.
        detail.setContentHuggingPriority(.init(1), for: .vertical)
        detail.setContentCompressionResistancePriority(.init(1), for: .vertical)
        view = root
        // Nothing open yet: the space below the rows is the panel's own ground.
        showRegions(forRepository: nil)
        layOut(active: nil)
    }

    /// The lists, and the frames that name them, belong to a repository that
    /// is open. With none open the space stays in the stack, since it is what
    /// takes up the height the rows leave, but draws nothing.
    ///
    /// `forRepository` is nil for no open project — or one whose first Git
    /// read has not landed yet — and otherwise whether the open one is a
    /// repository.
    private func showRegions(forRepository isRepository: Bool?) {
        gitColumn.isHidden = isRepository != true
        notRepository.isHidden = isRepository != false
    }

    /// Rebuild the list. `isRepository` speaks for the active project: nil
    /// while that is not known yet.
    func configure(projects: [(name: String, branch: String, user: String,
                               changes: Int, path: String)],
                   active: Int?, isRepository: Bool? = nil) {
        _ = view
        // A refresh can land in the middle of a row drag — the drag's own
        // event loop still runs the main queue. Rearranging then put the row
        // back where it started, or rebuilt the rows out from under it; the
        // newest state waits until the row is put down.
        guard draggingRow == nil else {
            pendingConfiguration = (projects, active, isRepository)
            return
        }
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
                row.onSelectBranch = { [weak self, weak row] rect in
                    guard let self, let row else { return }
                    self.onSelectBranch?(index, row.convert(rect, to: self.view))
                }
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
            rows[index].configure(name: project.name, branch: project.branch,
                                  user: project.user, changes: project.changes,
                                  path: project.path, isActive: index == active)
            // Between rows only: not under the project whose lists follow it,
            // where a line would cut the project off from its own contents.
            rows[index].showsDivider = index > 0
        }
        activeIndex = active
        showRegions(forRepository: active == nil ? nil : isRepository)
        layOut(active: active)
    }

    /// Rows in order, with the expanded project's lists inserted straight
    /// after its row.
    ///
    /// Views are *moved* into place rather than torn down and rebuilt: taking
    /// a list out of the hierarchy and putting it back leaves an outline view
    /// that has to be reloaded before it draws anything, which showed up as an
    /// empty panel after every project switch.
    private func layOut(active: Int?) {
        var desired: [NSView] = []
        for (index, row) in rows.enumerated() {
            desired.append(row)
            if index == active { desired.append(detail) }
        }
        // No project: the space under the rows is still taken, empty.
        if active == nil || rows.isEmpty { desired.append(detail) }
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
        // whole list. Jumping there reads as the list being rebuilt;
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

    // MARK: - Reordering

    /// Reordering is offered only when every project is collapsed. With one
    /// expanded, its lists sit between the rows and "where will it land" has
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
        let row = draggingRow
        draggingRow = nil
        let pending = pendingConfiguration
        pendingConfiguration = nil
        if let row, let landed = stack.arrangedSubviews.firstIndex(of: row),
           landed != dragStartIndex {
            // The reorder redraws the list from the model, which already holds
            // anything the deferred refresh would have said.
            onReorder?(dragStartIndex, landed)
            return
        }
        if let pending {
            configure(projects: pending.projects, active: pending.active,
                      isRepository: pending.isRepository)
        }
    }

    var rowsForTesting: [ProjectRowView] { rows }
    /// Start carrying a row, as a press that has travelled far enough does.
    func beginDragForTesting(_ index: Int) -> Bool {
        rows.indices.contains(index) && beginRowDrag(rows[index])
    }
    func moveDragForTesting(_ index: Int, by travel: CGFloat) {
        rowDragMoved(rows[index], by: travel)
    }
    func endDragForTesting() { endRowDrag() }
    var gitColumnForTesting: ProjectColumnsView { gitColumn }
    /// Drag the line inside the Git column, the way a pointer moves it.
    func dragGitDividerForTesting(to y: CGFloat) { gitColumn.moveDivider(to: y) }
    var notRepositoryVisibleForTesting: Bool { !notRepository.isHidden }
    var gitListsVisibleForTesting: Bool { !gitColumn.isHidden }
    var visualOrderForTesting: [String] {
        stack.arrangedSubviews.compactMap { ($0 as? ProjectRowView)?.titleForTesting }
    }
    /// Where the expanded lists sit among the rows, which is what "expanded
    /// underneath" means in layout terms.
    var detailPositionForTesting: Int? {
        stack.arrangedSubviews.firstIndex(of: detail)
    }
}

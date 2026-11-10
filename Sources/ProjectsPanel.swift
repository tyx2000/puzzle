import AppKit

/// One project in the Projects panel: its name, the branch it is on, and the
/// button that takes it out of the window. Selecting it expands its file tree
/// underneath.
final class ProjectRowView: NSView, PointerHoverRefreshing {
    static let height: CGFloat = 32
    /// The ✕'s square at the trailing end, held clear of the panel's edge.
    private static let closeWidth: CGFloat = 18
    private static let closeInset: CGFloat = 8
    /// The band down the leading edge of the project being shown. Every row
    /// leaves room for it, so a name does not shift as the selection moves.
    static let markerWidth: CGFloat = 5
    /// A mark at the head of each column saying what it holds: the folder the
    /// tree below it lists, Git's own for the changes. The two headings are
    /// otherwise set alike, and these carry their own colours.
    static let iconSize: CGFloat = 14
    private static let iconGap: CGFloat = 5
    private static let nameIcon = "folder-base"
    private static let branchIcon = "git"

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    /// A panel lends all its project headings one moving background. A row
    /// drawn on its own still lights directly under the pointer.
    var hoverBackground: (() -> NSRect?)?
    var onHoverChanged: ((Bool, NSPoint?) -> Void)?
    /// The Git mark is a button of its own: it pulls this project.
    var onPull: (() -> Void)? {
        didSet { refreshAccessibilityActions() }
    }
    /// A fetch or a pull is running for this project. The Git mark says so
    /// with a band of light running down through it — the way the commits
    /// come, from the remote down.
    var isSyncing = false {
        didSet {
            guard isSyncing != oldValue else { return }
            syncingChanged()
        }
    }
    /// One sweep of the band down the mark.
    static let sweepPeriod: TimeInterval = 1.0
    private var sweepStarted: Date?
    private var sweepTimer: Timer?
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
    /// A line under the row: the last one, while every project is collapsed,
    /// closes the list off from the empty panel below it.
    var showsBottomLine = false { didSet { needsDisplay = true } }
    private var closeIsHovered = false
    private var pullIsHovered = false
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

    /// Where a press closes the project: a little more than the ✕ itself,
    /// shown as a round ground under the pointer.
    private var closeTarget: NSRect { closeRect.insetBy(dx: -4, dy: -4) }

    /// Both headings are drawn alike: the branch names the right column the
    /// way the project names the left one, so the row reads as two headings
    /// rather than a name with a note after it.
    static func nameFont() -> NSFont { Theme.uiFont(12) }
    /// The row is divided: the project's name heads the file tree below it,
    /// the branch heads that project's changes. Both columns carry on down
    /// through the panel, so a row reads as the two headings it is — and the
    /// line moves where the reader drags it, in the lists below.
    var dividerFraction: CGFloat = 0.5 { didSet { needsDisplay = true } }
    var columnDivider: CGFloat {
        ProjectColumnsView.divider(at: dividerFraction, in: bounds.width)
    }
    /// Where each column's mark sits: at the head of its own column.
    private var nameIconRect: NSRect {
        Self.centred(x: Self.markerWidth + 6, in: bounds)
    }
    private var branchIconRect: NSRect {
        Self.centred(x: columnDivider + 8, in: bounds)
    }
    /// What a click on the Git mark lands in: the mark, and a little round
    /// it — short of the branch name, a click on which is a click on the
    /// row. Nothing for a folder that is not a repository, which draws no
    /// mark.
    private var pullRect: NSRect {
        guard !branch.isEmpty, onPull != nil else { return .zero }
        return branchIconRect.insetBy(dx: -3, dy: -5)
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

    /// Where the branch name lands. Empty when there is no branch, or when
    /// its column has no room left. Only shown: a click on it is a click on
    /// the row.
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
        if !pullRect.isEmpty { addCursorRect(pullRect, cursor: .pointingHand) }
    }

    // MARK: - Syncing

    private var reducesMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func syncingChanged() {
        if isSyncing, window != nil, !reducesMotion { startSweep() } else { stopSweep() }
        if pullIsHovered { toolTip = pullHint }
        setNeedsDisplay(branchIconRect)
    }

    private func startSweep() {
        guard sweepTimer == nil else { return }
        sweepStarted = Date()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.setNeedsDisplay(self.branchIconRect)
        }
        RunLoop.main.add(timer, forMode: .common)
        sweepTimer = timer
    }

    private func stopSweep() {
        sweepTimer?.invalidate()
        sweepTimer = nil
        sweepStarted = nil
    }

    /// How far down the mark the band is, 0 at the top to 1 past the bottom.
    private var sweepPhase: CGFloat? {
        guard let sweepStarted else { return nil }
        let elapsed = Date().timeIntervalSince(sweepStarted)
        return CGFloat(elapsed.truncatingRemainder(dividingBy: Self.sweepPeriod)
                        / Self.sweepPeriod)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A row taken out of the list stops its clock; one put back in picks
        // up where its project stands.
        syncingChanged()
        if window == nil { clearHover(notifying: true) }
    }

    deinit { sweepTimer?.invalidate() }

    /// The Git mark as it stands: itself, or — while its project syncs —
    /// dimmed, with a band of light at `phase` of the way down. No band when
    /// the system asks for less motion: the dimmed mark says it on its own.
    /// `base` draws the mark; a test hands in a shape of its own.
    static func gitMark(syncingAt phase: CGFloat?, syncing: Bool,
                        base: @escaping (NSRect) -> Void = {
                            SidebarCellDrawing.icon(.material(branchIcon), in: $0)
                        }) -> NSImage {
        let size = NSSize(width: iconSize, height: iconSize)
        return NSImage(size: size, flipped: true) { rect in
            base(rect)
            guard syncing, let context = NSGraphicsContext.current else { return true }
            // Only where the mark is: the rest of the square stays clear.
            context.compositingOperation = .sourceAtop
            NSColor.black.withAlphaComponent(0.3).setFill()
            rect.fill(using: .sourceAtop)
            guard let phase else { return true }
            let band = rect.height * 0.8
            let light = Theme.cursor.blended(withFraction: 0.55, of: .white) ?? Theme.cursor
            NSGradient(colors: [light.withAlphaComponent(0),
                                light.withAlphaComponent(0.9),
                                light.withAlphaComponent(0)])?
                .draw(in: NSRect(x: 0, y: -band + (rect.height + band) * phase,
                                 width: rect.width, height: band),
                      angle: 90)
            return true
        }
    }

    private var pullHint: String {
        isSyncing ? "Syncing with the remote…" : "Pull from the remote (fast-forward only)"
    }

    private func refreshAccessibilityActions() {
        guard onPull != nil else {
            setAccessibilityCustomActions(nil)
            return
        }
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Pull") { [weak self] in
                self?.onPull?()
                return true
            },
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.panelBackground.setFill()
        bounds.fill()
        let hoveredShape: NSRect?
        if let hoverBackground {
            hoveredShape = hoverBackground()
        } else {
            hoveredShape = isHovered ? bounds : nil
        }
        // One fill for the complete shapes keeps hover over the active
        // project at the same strength as either highlight on its own.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        Theme.drawRowHighlights(in: [isActive ? bounds : nil, hoveredShape].compactMap { $0 })
        NSGraphicsContext.restoreGraphicsState()
        if showsDivider {
            Theme.divider.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        }
        if showsBottomLine {
            Theme.divider.setFill()
            NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        }
        if isActive {
            NSGraphicsContext.saveGraphicsState()
            Theme.rowHighlightPath(in: bounds).addClip()
            Theme.cursor.setFill()
            NSRect(x: 0, y: 0, width: Self.markerWidth, height: bounds.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        SidebarCellDrawing.icon(.material(Self.nameIcon), in: nameIconRect)
        SidebarCellDrawing.attributedText(nameLabel(), in: nameRect)
        // The line between the two columns, carried on down the panel by the
        // pair of lists below.
        if !branch.isEmpty {
            Theme.divider.setFill()
            NSRect(x: columnDivider, y: 0, width: 1, height: bounds.height).fill()
            Self.gitMark(syncingAt: sweepPhase, syncing: isSyncing).draw(in: branchIconRect)
            SidebarCellDrawing.attributedText(branchLabel(), in: branchColumnRect)
        }

        // Under the pointer, the ground a press there closes on.
        if closeIsHovered {
            Theme.selectedControl.setFill()
            NSBezierPath(ovalIn: closeTarget).fill()
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

    /// The same ink reads over the code highlight and the panel's ground.
    private var ink: NSColor { Theme.foreground }

    /// The right column's heading: the branch, and after it the number of
    /// files changed but not committed, in the badge the sidebar uses for a
    /// count everywhere else.
    private func branchLabel() -> NSAttributedString {
        let label = NSMutableAttributedString(string: branch, attributes: [
            .font: Self.nameFont(),
            .foregroundColor: ink,
            .paragraphStyle: Self.truncating,
        ])
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
        // The active project's count keeps its own quiet pill over the band.
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
        guard !DividerGrip.isLit(in: window) else { return }
        isHovered = true
        onHoverChanged?(true, event.locationInWindow)
        needsDisplay = true
    }

    /// The line beside the panel lit, or gone out, with the pointer still: the
    /// heading lets go of its hover while it is lit, and takes it back after.
    func refreshHoverState() {
        guard let window else { return }
        let pointer = window.pointerLocation
        if !DividerGrip.isLit(in: window), bounds.contains(convert(pointer, from: nil)) {
            guard !isHovered else { return }
            isHovered = true
            onHoverChanged?(true, pointer)
            needsDisplay = true
        } else {
            clearHover(notifying: true)
        }
    }
    var isHoveredForTesting: Bool { isHovered }

    override func mouseMoved(with event: NSEvent) {
        guard !DividerGrip.isLit(in: window) else { return }
        let point = convert(event.locationInWindow, from: nil)
        let onClose = closeTarget.contains(point)
        let onPull = !onClose && pullRect.contains(point)
        guard !isHovered || onClose != closeIsHovered
                || onPull != pullIsHovered else { return }
        let entered = !isHovered
        isHovered = true
        closeIsHovered = onClose
        pullIsHovered = onPull
        // Back to the project's path once the pointer leaves the ✕. The Git
        // mark does not look like a button, so it says what it does.
        toolTip = onClose ? "Close this project" : (onPull ? pullHint : path)
        if entered { onHoverChanged?(true, event.locationInWindow) }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        clearHover()
        onHoverChanged?(false, event.locationInWindow)
    }

    /// A reorder or a project switch changes which heading is under the
    /// pointer before AppKit has sent another tracking event.
    func clearHover(notifying: Bool = false) {
        guard isHovered || closeIsHovered || pullIsHovered else { return }
        isHovered = false
        closeIsHovered = false
        pullIsHovered = false
        toolTip = path
        if notifying { onHoverChanged?(false, nil) }
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
        if closeTarget.contains(start) {
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
        // was clicked.
        guard !dragging else {
            onDragEnded?()
            return
        }
        // A press that could not become a drag — a list of one cannot be
        // reordered — and was let go somewhere else was not a click either. Selecting then closed every tab of the project being
        // left, for a press the reader had already abandoned.
        guard let released, bounds.contains(released) else { return }
        if pullRect.contains(start), onPull != nil {
            onPull?()
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
    var closeTargetForTesting: NSRect { closeTarget }
    var closeIsHoveredForTesting: Bool { closeIsHovered }
    var pullRectForTesting: NSRect { pullRect }
    var isSyncingForTesting: Bool { isSyncing }
    /// Whether the band is moving — it is not for a row off screen.
    var isSweepingForTesting: Bool { sweepTimer != nil }
    var toolTipForTesting: String? { toolTip }
    var branchRectForTesting: NSRect { branchRect }
    /// Where each column's mark is drawn, and which icon it is.
    var columnIconsForTesting: (name: (String, NSRect), branch: (String, NSRect)) {
        ((Self.nameIcon, nameIconRect), (Self.branchIcon, branchIconRect))
    }
    static var columnIconNamesForTesting: [String] { [nameIcon, branchIcon] }
    /// The project this row stands for.
    var projectPath: String { path }
    var pathForTesting: String { path }
    /// The left column's label exactly as it is drawn.
    var nameLabelForTesting: NSAttributedString { nameLabel() }
    /// The right column's label exactly as it is drawn.
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

/// A project row being carried: a picture of it, raised over the list on a
/// soft shadow, with room round it for the shadow. It never takes the pointer.
private final class LiftedRowView: NSView {
    private static let margin: CGFloat = 12
    private let image: CGImage
    /// How dark the shadow is: full while carried, gone as it settles.
    var shadowAlpha: CGFloat = 0.22 {
        didSet { if shadowAlpha != oldValue { needsDisplay = true } }
    }

    init(image: CGImage, row: NSRect) {
        self.image = image
        super.init(frame: row.insetBy(dx: -Self.margin, dy: -Self.margin))
        // Moved by its frame, drawn once: the picture is not drawn again as
        // it follows the pointer.
        wantsLayer = true
        layer?.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull()]
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Where the row's picture is, in the superview.
    var rowRect: NSRect {
        get { frame.insetBy(dx: Self.margin, dy: Self.margin) }
        set { frame = newValue.insetBy(dx: -Self.margin, dy: -Self.margin) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(shadowAlpha)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSGraphicsContext.current?.cgContext.draw(
            image, in: bounds.insetBy(dx: Self.margin, dy: Self.margin))
        NSGraphicsContext.restoreGraphicsState()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// What an expanded project shows: its file tree and its changes, side by
/// side under the two headings its row draws. Laid out by hand so the line
/// between the columns lands on exactly the point the row's does.
final class ProjectColumnsView: FlatView, ScrollerCursorRebuilding {
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
    var fraction: CGFloat = defaultFraction {
        didSet {
            guard fraction != oldValue else { return }
            needsLayout = true
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var onFractionChanged: ((CGFloat) -> Void)?
    /// Halves: where a pair starts, and where a double-click on the line
    /// puts it back.
    static let defaultFraction: CGFloat = 0.5

    /// Neither pane may be squeezed away. A column needs this much to say a
    /// name; a list stacked on another needs only a couple of rows.
    static let minimumColumn: CGFloat = 90
    /// A stacked pane keeps a couple of rows.
    static let minimumRow: CGFloat = 44
    var minimumPane: CGFloat = minimumColumn
    /// How far either side of the line answers to a drag (see `DividerGrip`).
    private static let grabRadius: CGFloat = DividerGrip.radius

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
    /// moves the line. Anything else that lands on this view is not the
    /// line's to act on.
    /// A scroller showing under the band — the left list's, against the
    /// line — is the scroller's, or it could not be caught.
    private func isOnGrabBand(_ point: NSPoint) -> Bool {
        showsSecond && band.contains(point)
            && !PuzzleScroller.isShowing(at: convert(point, to: nil), in: window)
    }

    /// The band either side of the line, its whole length.
    private var band: NSRect { dividerRect(radius: Self.grabRadius).intersection(bounds) }

    /// Where a point falls along the axis, measured the way `divider` is: from
    /// the leading edge across, or from the top down. This view is not
    /// flipped, so down means subtracting.
    private func position(of point: NSPoint) -> CGFloat {
        axis == .horizontal ? point.x : bounds.height - point.y
    }

    /// A line down the panel moves from side to side, one across it up and down.
    private var cursor: NSCursor { DividerGrip.cursor(lineIsVertical: axis == .horizontal) }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard showsSecond else { return }
        for rect in PuzzleScroller.uncovered(band, in: self) {
            addCursorRect(rect, cursor: cursor)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        PuzzleScroller.rebuildCursors(of: self)
    }

    @objc func scrollersMoved() {
        window?.invalidateCursorRects(for: self)
        refreshLight()
    }

    /// Rebuilt whenever the line moves, since the band goes with it.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let lightArea { removeTrackingArea(lightArea) }
        lightArea = nil
        guard showsSecond else { return }
        let area = NSTrackingArea(rect: band,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        lightArea = area
    }
    private var lightArea: NSTrackingArea?

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        refreshLight()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        refreshLight()
    }

    /// The line is lit while it is held, or while the pointer is where a press
    /// would take hold of it.
    private func refreshLight() {
        let shown: Bool
        if isDraggingDivider {
            shown = true
        } else if let window, !isHiddenOrHasHiddenAncestor {
            shown = isOnGrabBand(convert(window.pointerLocation, from: nil))
        } else {
            shown = false
        }
        light.lineIsVertical = axis == .horizontal
        light.frame = DividerGrip.lightRect(over: line.frame, lineIsVertical: axis == .horizontal)
        light.show(shown)
    }
    private var isDraggingDivider = false

    var showsLightForTesting: Bool { light.isShown }
    var lightFadeForTesting: CAAnimation? { light.fadeForTesting }
    var lightRectForTesting: NSRect { light.frame }
    var bandForTesting: NSRect { band }
    func refreshLightForTesting() { refreshLight() }

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
    /// A double-click on the line puts it back at halves first.
    override func mouseDown(with event: NSEvent) {
        let tracked = press(at: convert(event.locationInWindow, from: nil),
                            clicks: event.clickCount) { [weak self] in
            self?.window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp])
        }
        if !tracked { super.mouseDown(with: event) }
    }

    /// A press, the `clicks`th in a row, and what follows it. Returns whether
    /// it took hold of the line.
    private func press(at start: NSPoint, clicks: Int, nextEvent: () -> NSEvent?) -> Bool {
        guard clicks == 2, isOnGrabBand(start) else {
            return trackDivider(from: start, nextEvent: nextEvent)
        }
        resetDivider()
        // The line went back, out from under the pointer: what is left of
        // this press is only its release.
        while let next = nextEvent(), next.type != .leftMouseUp {}
        return true
    }

    /// The line back at halves, and the panel told, as after a drag.
    func resetDivider() {
        guard fraction != Self.defaultFraction else { return }
        fraction = Self.defaultFraction
        layoutSubtreeIfNeeded()
        onFractionChanged?(fraction)
    }

    /// The press, from the button going down to its release. Only a press on
    /// the band moves the line. Returns whether it did.
    @discardableResult
    func trackDivider(from start: NSPoint, nextEvent: () -> NSEvent?) -> Bool {
        guard isOnGrabBand(start) else { return false }
        isDraggingDivider = true
        cursor.push()
        refreshLight()
        defer {
            isDraggingDivider = false
            NSCursor.pop()
            refreshLight()
        }
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

    /// A double-click let go where it went down, scripted in this view's own
    /// points.
    @discardableResult
    func doubleClickForTesting(at point: NSPoint) -> Bool {
        var up = [NSEvent.mouseEvent(with: .leftMouseUp, location: convert(point, to: nil),
                                     modifierFlags: [], timestamp: 0, windowNumber: 0,
                                     context: nil, eventNumber: 0, clickCount: 2, pressure: 1)!]
        return press(at: point, clicks: 2) { up.isEmpty ? nil : up.removeFirst() }
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

    /// The room each pane is given. The panes run to their edges: the line
    /// between them is the only thing drawn there.
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

    /// The line the panes are dragged apart by — the one edge drawn between
    /// them; the regions carry no frames of their own. A view of its own: drawn
    /// by the splitter, one point of line cost a bitmap the size of the panel.
    private let line = DividerLine()

    private final class DividerLine: FlatView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    /// The line lit, over the panes either side of it.
    private let light = DividerGrip.Light()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        line.fillColor = Theme.divider
        addSubview(line)
        addSubview(light)
    }

    /// The panes are added after the light, which has to stay over them.
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        guard subview !== light else { return }
        addSubview(light, positioned: .above, relativeTo: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// A pane is positioned by hand, and everything inside it by constraints.
    /// Handing it a new frame only marks its own subtree as needing layout, so
    /// a scroll view inside it keeps the size it had until some later pass —
    /// and a list whose clip view is still the old size scrolls by the wrong
    /// amount, or not at all. Settle each pane before leaving.
    /// Geometry keys a layer animates implicitly, which this view and its
    /// panes all refuse.
    ///
    /// The panes are placed by hand in `layout()` below, so they cannot
    /// interpolate along with a parent whose layer is being animated: the
    /// parent would slide smoothly while the lists inside jump between whole
    /// positions, and whatever they painted at the old one stays on screen.
    /// Refusing the actions makes this whole block take its final place in one
    /// step, while the project rows around it still slide.
    private static let geometryKeys = ["bounds", "position", "frame",
                                       "bounds.size", "bounds.origin"]

    /// Set on the layer rather than through `action(for:forKey:)`: that is
    /// `CALayerDelegate`'s, already answered by NSView, and not open to being
    /// overridden from Swift.
    private func refuseAnimations(on view: NSView?) {
        guard let layer = view?.layer else { return }
        var actions = layer.actions ?? [:]
        for key in Self.geometryKeys where actions[key] == nil { actions[key] = NSNull() }
        layer.actions = actions
    }

    override func layout() {
        super.layout()
        refuseAnimations(on: self)
        refuseAnimations(on: first)
        refuseAnimations(on: second)
        refuseAnimations(on: line)
        refuseAnimations(on: light)
        line.isHidden = !showsSecond
        line.frame = dividerRect(radius: 0)
        second?.isHidden = !showsSecond
        first?.frame = firstPaneRect
        first?.layoutSubtreeIfNeeded()
        if showsSecond {
            second?.frame = secondPaneRect
            second?.layoutSubtreeIfNeeded()
        }
        updateTrackingAreas()
        refreshLight()
        window?.invalidateCursorRects(for: self)
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
}

/// The Projects panel: the window's projects listed down the side, with the
/// selected one's file tree and changes expanded directly underneath its row.
///
/// The tree is the same controller the panel always used; only where it sits
/// changes, so nothing about browsing a project moves.
final class ProjectsPanelViewController: NSViewController {
    let fileTree: FileTreeViewController
    /// The right-hand column, itself split: what the expanded project has
    /// changed, over the commits behind it.
    let changes = ProjectChangesViewController()
    let history = ProjectHistoryViewController()
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    /// The Git mark on a row was clicked: pull that project.
    var onPull: ((Int) -> Void)?
    /// The projects, by path, with a fetch or a pull running.
    private var syncingPaths: Set<String> = []

    func setSyncing(_ paths: Set<String>) {
        syncingPaths = paths
        for row in rows { row.isSyncing = paths.contains(row.projectPath) }
    }
    /// A row was dragged to another place in the list.
    var onReorder: ((Int, Int) -> Void)?

    private let stack = NSStackView()
    private let columns = ProjectColumnsView()
    /// The right column's own split, between the changes and the history.
    private let gitColumn = ProjectColumnsView()
    /// Where the reader last put the line between the two columns. Remembered
    /// across launches: it is a deliberate choice about a window's shape, not
    /// a passing state.
    private static let dividerKey = "projects_panel_divider"
    /// The line inside the Git column, between the changes and the history.
    private static let gitDividerKey = "projects_panel_git_divider"
    /// Where that choice is kept. Injectable, so a test moving the line does
    /// not reach into the user's own defaults.
    var dividerDefaults: UserDefaults = .standard
    private var dividerFraction: CGFloat = 0.5

    private static func storedDividerFraction(_ defaults: UserDefaults) -> CGFloat {
        storedFraction(dividerKey, in: defaults)
    }

    private static func storedFraction(_ key: String, in defaults: UserDefaults) -> CGFloat {
        let stored = defaults.object(forKey: key) as? Double
        guard let stored, stored > 0.05, stored < 0.95 else { return ProjectColumnsView.defaultFraction }
        return CGFloat(stored)
    }
    /// The row being dragged and where it started, while a drag is running.
    private var draggingRow: ProjectRowView?
    private var dragStartIndex = 0
    /// What a refresh asked the list to show while a row was being dragged.
    private var pendingConfiguration: (projects: [(name: String, branch: String,
                                                   user: String, changes: Int,
                                                   path: String)],
                                       active: Int?)?
    private var rows: [ProjectRowView] = []
    private var shown: [String] = []
    private var activeIndex: Int?
    private weak var hoveredProjectRow: ProjectRowView?
    private lazy var projectHover = RowHoverFollower(host: stack) { [weak self] _ in
        self?.rows.forEach { $0.needsDisplay = true }
    }

    init(fileTree: FileTreeViewController) {
        self.fileTree = fileTree
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard let row = hoveredProjectRow else { return }
        let rect = row.convert(row.bounds, to: stack)
        if projectHover.targetRect != rect {
            // Resizing the panel changes both columns' widths; a stationary
            // pointer stays on its heading without chasing the old geometry.
            projectHover.setTarget(rect, animated: false)
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        clearProjectHover()
    }

    private func setProjectHovered(_ row: ProjectRowView, hovering: Bool,
                                   at pointInWindow: NSPoint? = nil) {
        if hovering {
            guard draggingRow == nil else { return }
            hoveredProjectRow = row
            projectHover.setTarget(row.convert(row.bounds, to: stack))
        } else if hoveredProjectRow === row {
            // An exit already carries the pointer's new place. Crossing to
            // another heading retargets directly, before its enter arrives.
            if let pointInWindow, let next = rows.first(where: {
                $0 !== row && $0.bounds.contains($0.convert(pointInWindow, from: nil))
            }) {
                setProjectHovered(next, hovering: true)
            } else {
                clearProjectHover()
            }
        }
    }

    private func clearProjectHover() {
        hoveredProjectRow = nil
        projectHover.cancel()
        rows.forEach { $0.clearHover() }
    }

    override func loadView() {
        let root = FlatView()
        root.fillColor = Theme.panelBackground
        // Layer-backed for one reason: the rows slide to their new places when
        // a project is picked, which needs implicit animation.
        root.wantsLayer = true
        addChild(fileTree)
        addChild(changes)
        addChild(history)
        // Both columns live in the container for good: taking a view out of
        // the hierarchy and putting it back leaves an outline view that draws
        // nothing until it is reloaded.
        fileTree.view.translatesAutoresizingMaskIntoConstraints = true
        changes.view.translatesAutoresizingMaskIntoConstraints = true
        history.view.translatesAutoresizingMaskIntoConstraints = true
        gitColumn.translatesAutoresizingMaskIntoConstraints = true
        // The Git column is itself two lists, one over the other.
        gitColumn.axis = .vertical
        gitColumn.minimumPane = ProjectColumnsView.minimumRow
        gitColumn.first = changes.view
        gitColumn.second = history.view
        gitColumn.addSubview(changes.view)
        gitColumn.addSubview(history.view)
        columns.first = fileTree.view
        columns.second = gitColumn
        dividerFraction = Self.storedDividerFraction(dividerDefaults)
        columns.fraction = dividerFraction
        columns.onFractionChanged = { [weak self] fraction in
            self?.applyDividerFraction(fraction)
        }
        gitColumn.fraction = Self.storedFraction(Self.gitDividerKey, in: dividerDefaults)
        gitColumn.onFractionChanged = { [weak self] fraction in
            guard let self else { return }
            self.dividerDefaults.set(Double(fraction), forKey: Self.gitDividerKey)
        }
        columns.addSubview(fileTree.view)
        columns.addSubview(gitColumn)
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
        // Nothing open yet: the space below the rows is left as the panel's
        // own ground.
        showRegions(forRepository: nil)
        layOut(active: nil)
    }

    /// The Git column belongs to an open project that is a repository. The
    /// columns stay in the stack with none open, since they are what takes
    /// up the height the rows leave, but show no second column.
    ///
    /// `forRepository` is nil for no open project, and otherwise whether the
    /// open one is a repository — which is what decides the Git column.
    private func showRegions(forRepository isRepository: Bool?) {
        columns.showsSecond = isRepository == true
    }

    /// Rebuild the list. The tree is moved rather than remade, so switching
    /// projects does not cost a fresh scroll view.
    func configure(projects: [(name: String, branch: String, user: String,
                               changes: Int, path: String)],
                   active: Int?) {
        _ = view
        // A refresh can land in the middle of a row drag — the drag's own
        // event loop still runs the main queue. Rearranging then put the row
        // back where it started, or rebuilt the rows out from under it; the
        // newest state waits until the row is put down.
        guard draggingRow == nil else {
            pendingConfiguration = (projects, active)
            return
        }
        let identity = projects.map { "\($0.path)|\($0.branch)" }
        if identity != shown || activeIndex != active { clearProjectHover() }
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
                row.onPull = { [weak self] in self?.onPull?(index) }
                row.onHoverChanged = { [weak self, weak row] hovering, point in
                    guard let self, let row else { return }
                    self.setProjectHovered(row, hovering: hovering, at: point)
                }
                row.hoverBackground = { [weak self, weak row] in
                    guard let self, let row, let rect = self.projectHover.displayedRect else {
                        return nil
                    }
                    return row.convert(rect, from: self.stack)
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
            rows[index].dividerFraction = dividerFraction
            rows[index].configure(name: project.name, branch: project.branch,
                                  user: project.user, changes: project.changes,
                                  path: project.path, isActive: index == active)
            rows[index].isSyncing = syncingPaths.contains(project.path)
        }
        activeIndex = active
        // A project with no branch is not a repository: nothing to head the
        // right column with, and nothing to put in it.
        showRegions(forRepository: active.flatMap {
            projects.indices.contains($0) ? !projects[$0].branch.isEmpty : nil
        })
        layOut(active: active)
        refreshRowLines()
    }

    /// Lines between rows, in the order they are on screen — which a dragged
    /// row changes as it goes. None over the first row, and none between a
    /// project and the tree under it, where a line would cut the project off
    /// from its own contents. With every project collapsed the list ends
    /// above empty panel, so a line under the last row closes it; with one
    /// open, its tree fills that space and the rows after it sit on the
    /// panel's foot.
    private func refreshRowLines() {
        let order = stack.arrangedSubviews.compactMap { $0 as? ProjectRowView }
        for (position, row) in order.enumerated() {
            row.showsDivider = position > 0
            row.showsBottomLine = openRow == nil && position == order.count - 1
        }
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
        clearProjectHover()
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
            // Only the project rows travel. The file tree and the two Git
            // lists below them veto animation on their own geometry — see
            // ProjectColumnsView — so they appear and disappear at once
            // instead of being resized a frame at a time.
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

    /// Any row can be carried while there is more than one. With a project
    /// open, its tree and Git lists go with its row as one block that the
    /// carried row moves past; the open project's own row is carried without
    /// them, and they fold away until it is put down, to open again under it.
    private var canReorder: Bool { rows.count > 1 }

    private func beginRowDrag(_ row: ProjectRowView) -> Bool {
        guard canReorder, let index = rows.firstIndex(of: row) else { return false }
        clearProjectHover()
        draggingRow = row
        dragStartIndex = index
        // Above its own tree, the open row does not move as the tree folds.
        if let activeIndex, rows.indices.contains(activeIndex), rows[activeIndex] === row {
            foldsOpenProject = true
            layOut(active: nil)
            refreshRowLines()
        }
        dragStartTop = top(of: row)
        lift(row)
        return true
    }

    /// How far down the list `row` starts: the heights of what is above it,
    /// the open project's tree included — known from the arrangement before
    /// the frames are.
    private func top(of row: ProjectRowView) -> CGFloat {
        var above: CGFloat = 0
        for item in stack.arrangedSubviews {
            if item === row { break }
            if item is ProjectRowView {
                above += ProjectRowView.height
            } else if item === columns, openRow != nil {
                above += columns.frame.height
            }
        }
        return above
    }
    private var dragStartTop: CGFloat = 0

    /// The project open on screen, unless it is folded away for a drag.
    private var openRow: ProjectRowView? {
        guard !foldsOpenProject, let activeIndex, rows.indices.contains(activeIndex) else {
            return nil
        }
        return rows[activeIndex]
    }
    /// The open project's tree, folded away while its own row is carried.
    private var foldsOpenProject = false

    /// The row is carried as a picture of itself, raised over the list and
    /// kept under the pointer, while its own place stays open among the rows.
    private func lift(_ row: ProjectRowView) {
        // The picture is of the row alone, without the lines its place draws.
        row.showsDivider = false
        row.showsBottomLine = false
        let rep = row.bitmapImageRepForCachingDisplay(in: row.bounds)
        if let rep { row.cacheDisplay(in: row.bounds, to: rep) }
        refreshRowLines()
        guard let image = rep?.cgImage else { return }
        let start = row.convert(row.bounds, to: view)
        let lifted = LiftedRowView(image: image, row: start)
        view.addSubview(lifted, positioned: .above, relativeTo: nil)
        liftedRow = lifted
        liftedStart = start
        row.alphaValue = 0
    }

    /// The picture follows the pointer the whole way, kept within the run of
    /// places; the row itself *changes places* once the picture's top passes
    /// the middle of what is next to it — a row, or the open project with its
    /// tree — and what it passes slides out of its way. What is on screen
    /// while dragging is exactly what will be committed.
    ///
    /// Measured from the top of the list, as if the carried row had been
    /// taken out of it, so the gap it leaves does not move the line it has to
    /// cross; and by the heights of what is there, which a switch still
    /// sliding into place has already settled even where its frames have not.
    private func rowDragMoved(_ row: ProjectRowView, by travel: CGFloat) {
        guard draggingRow === row else { return }
        let height = ProjectRowView.height
        // Everything but the carried row, top down: each row, and the open
        // project's tree with its row.
        var others: [(row: ProjectRowView, top: CGFloat, height: CGFloat)] = []
        var below: CGFloat = 0
        for item in stack.arrangedSubviews {
            if let other = item as? ProjectRowView, other !== row {
                others.append((other, below, height))
                below += height
            } else if item === columns, let open = openRow, others.last?.row === open {
                others[others.count - 1].height += columns.frame.height
                below += columns.frame.height
            }
        }
        // The picture, under the pointer, kept to the list.
        let top = min(max(dragStartTop + travel, 0), below)
        let carried = top - dragStartTop
        liftedRow?.rowRect.origin.y = liftedStart.minY + (view.isFlipped ? carried : -carried)
        let slot = others.filter { $0.top + $0.height / 2 <= top }.count
        var desired: [NSView] = others.map(\.row)
        desired.insert(row, at: slot)
        if let open = openRow, let place = desired.firstIndex(of: open) {
            desired.insert(columns, at: place + 1)
        } else {
            desired.append(columns)
        }
        guard desired != stack.arrangedSubviews else { return }
        for (position, item) in desired.enumerated()
        where stack.arrangedSubviews[position] !== item {
            stack.insertArrangedSubview(item, at: position)
        }
        refreshRowLines()
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? 0 : Self.slideDuration
        lastSlideDurationForTesting = duration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.allowsImplicitAnimation = duration > 0
            stack.layoutSubtreeIfNeeded()
        }
    }

    private func endRowDrag() {
        clearProjectHover()
        let row = draggingRow
        draggingRow = nil
        let pending = pendingConfiguration
        pendingConfiguration = nil
        let order = stack.arrangedSubviews.compactMap { $0 as? ProjectRowView }
        let landed = row.flatMap { order.firstIndex(of: $0) }
        let folded = foldsOpenProject
        foldsOpenProject = false
        if let landed, landed != dragStartIndex {
            // The reorder redraws the list from the model, which already holds
            // anything the deferred refresh would have said.
            onReorder?(dragStartIndex, landed)
        } else if let pending {
            configure(projects: pending.projects, active: pending.active)
        }
        // The open project's tree opens again under its row, wherever that is.
        if folded, let open = openRow, stack.arrangedSubviews.contains(open) {
            var desired: [NSView] = stack.arrangedSubviews.compactMap { $0 as? ProjectRowView }
            if let place = desired.firstIndex(of: open) { desired.insert(columns, at: place + 1) }
            if desired != stack.arrangedSubviews {
                for (position, item) in desired.enumerated()
                where stack.arrangedSubviews[position] !== item {
                    stack.insertArrangedSubview(item, at: position)
                }
                refreshRowLines()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                        ? 0 : Self.switchDuration
                    context.allowsImplicitAnimation = context.duration > 0
                    stack.layoutSubtreeIfNeeded()
                }
            }
        }
        land(on: landed)
    }

    /// The picture settles into the place the row was put down in, and goes.
    /// The row there may be a new one, if the drop rebuilt the list.
    private func land(on index: Int?) {
        guard let lifted = liftedRow else { return }
        liftedRow = nil
        stack.layoutSubtreeIfNeeded()
        let target = index.flatMap { index -> NSRect? in
            let placed = stack.arrangedSubviews.compactMap { $0 as? ProjectRowView }
            return placed.indices.contains(index)
                ? placed[index].convert(placed[index].bounds, to: view) : nil
        }
        landings += 1
        let finish = { [weak self] in
            lifted.removeFromSuperview()
            guard let self else { return }
            self.landings -= 1
            for row in self.rows where row !== self.draggingRow { row.alphaValue = 1 }
        }
        guard let target, view.window != nil, lifted.rowRect != target,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            finish()
            return
        }
        let from = lifted.rowRect
        let started = CACurrentMediaTime()
        let shadow = lifted.shadowAlpha
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { timer in
            let progress = min(1, (CACurrentMediaTime() - started) / Self.slideDuration)
            let eased = CGFloat(1 - pow(1 - progress, 3))
            lifted.rowRect.origin.y = from.minY + (target.minY - from.minY) * eased
            lifted.shadowAlpha = shadow * (1 - eased)
            guard progress >= 1 else { return }
            timer.invalidate()
            finish()
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// How long the rows take to make way, and the carried one to settle.
    static let slideDuration: TimeInterval = 0.18
    private(set) var lastSlideDurationForTesting: TimeInterval?
    private var liftedRow: LiftedRowView?
    private var liftedStart: NSRect = .zero
    private var landings = 0
    var liftedFrameForTesting: NSRect? { liftedRow?.rowRect }
    var isLiftedOnTopForTesting: Bool { liftedRow != nil && view.subviews.last === liftedRow }
    var isLandingForTesting: Bool { landings > 0 }

    var rowsForTesting: [ProjectRowView] { rows }
    /// The stack top down: each row by its name's first letter, the open
    /// project's tree and Git lists as "+".
    var arrangementForTesting: [String] {
        stack.arrangedSubviews.map {
            ($0 as? ProjectRowView).map { String($0.titleForTesting.prefix(1)) } ?? "+"
        }
    }
    func hoverRowForTesting(_ index: Int) {
        guard rows.indices.contains(index) else { clearProjectHover(); return }
        setProjectHovered(rows[index], hovering: true)
    }
    var hoveredProjectFrameForTesting: NSRect? { projectHover.targetRect }
    var displayedProjectHoverFrameForTesting: NSRect? { projectHover.displayedRect }
    var isProjectHoverMovingForTesting: Bool { projectHover.isFlyingForTesting }
    func advanceProjectHoverForTesting(elapsed: TimeInterval) {
        projectHover.advanceForTesting(elapsed: elapsed)
    }
    var projectHoverReduceMotionForTesting: Bool? {
        get { projectHover.reduceMotionForTesting }
        set { projectHover.reduceMotionForTesting = newValue }
    }
    /// Start carrying a row, as a press that has travelled far enough does.
    func beginDragForTesting(_ index: Int) -> Bool {
        rows.indices.contains(index) && beginRowDrag(rows[index])
    }
    func moveDragForTesting(_ index: Int, by travel: CGFloat) {
        rowDragMoved(rows[index], by: travel)
    }
    func endDragForTesting() { endRowDrag() }
    var columnsForTesting: ProjectColumnsView { columns }
    var gitColumnForTesting: ProjectColumnsView { gitColumn }
    /// Drag the line inside the Git column, the way a pointer moves it.
    func dragGitDividerForTesting(to y: CGFloat) { gitColumn.moveDivider(to: y) }
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

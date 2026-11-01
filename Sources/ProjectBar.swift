import AppKit

/// The light that runs across a project while a fetch or a pull is out: a
/// soft band, left to right, then a rest before the next pass. The project's
/// pebble in the bar and the Git mark over its changes both carry it.
enum SyncShimmer {
    /// One pass and the rest after it.
    static let period: TimeInterval = 1.8
    /// The part of the period the band is crossing.
    static let sweep: TimeInterval = 1.2

    /// How far across the band is, 0 entering at the left to 1 gone past the
    /// right; nil while it rests between passes.
    static func phase(since start: Date, now: Date = Date()) -> CGFloat? {
        let elapsed = now.timeIntervalSince(start).truncatingRemainder(dividingBy: period)
        guard elapsed < sweep else { return nil }
        let t = CGFloat(elapsed / sweep)
        // Eased, so the band drifts in and out rather than starting and
        // stopping at the edges.
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    /// The theme's own accent: across a name, held faint, it reads as a sheen
    /// rather than a smear of grey.
    static var tint: NSColor { Theme.cursor }
    /// Over the Git mark's own colours only light shows: the accent, most of
    /// the way to white.
    static var light: NSColor {
        Theme.cursor.blended(withFraction: 0.55, of: .white) ?? Theme.cursor
    }

    /// The band at `phase` across `rect`, at most `peak` opaque in the middle.
    /// Clipping is the caller's.
    static func draw(in rect: NSRect, phase: CGFloat, colour light: NSColor, peak: CGFloat) {
        let band = max(24, rect.width * 0.45)
        NSGradient(colors: [light.withAlphaComponent(0),
                            light.withAlphaComponent(peak),
                            light.withAlphaComponent(0)])?
            .draw(in: NSRect(x: rect.minX - band + (rect.width + band) * phase,
                             y: rect.minY, width: band, height: rect.height),
                  angle: 0)
    }
}

/// One project in the bar along the window's foot: a pebble with its name
/// over its branch and how many files it has changed, and a ✕ that is always
/// there to take it out of the window. The one on show is marked with the
/// selection's ground and an edge in the accent; a click on another shows
/// that one instead, and a click on the one showing folds it away.
final class ProjectPebbleView: NSView {
    static let height: CGFloat = 42
    /// Rounder up and down than across: a pebble rather than a capsule.
    static let cornerWidth: CGFloat = 16
    static let cornerHeight: CGFloat = 20
    static let leadingPadding: CGFloat = 14
    /// The ✕: its size, the room before it, and its distance from the edge.
    static let closeSide: CGFloat = 16
    static let closeGap: CGFloat = 10
    static let closeInset: CGFloat = 10
    /// The branch is cut past this, so one long name cannot stretch the bar.
    static let branchLimit: CGFloat = 120
    static let lineGap: CGFloat = 1
    /// Far enough that a shaky click is not a drag.
    static let dragThreshold: CGFloat = 4

    private static func nameFont() -> NSFont { Theme.uiFont(11.5) }
    private static func subFont() -> NSFont { Theme.uiFont(10) }

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    /// Nil for a folder that is not a repository: there is nothing to pull.
    var onPull: (() -> Void)? {
        didSet { refreshAccessibilityActions() }
    }
    /// Carrying the pebble to another place: the lane decides whether it may,
    /// and is told where the pointer is, in the lane's own coordinates.
    var onDragBegan: (() -> Bool)?
    var onDragMoved: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?

    private(set) var name = ""
    private(set) var branch = ""
    private(set) var changes = 0
    private(set) var path = ""
    private(set) var isActive = false
    private var isHovered = false
    private var closeIsHovered = false
    private var tracking: NSTrackingArea?

    /// A fetch or a pull is running for this project.
    var isSyncing = false {
        didSet {
            guard isSyncing != oldValue else { return }
            syncingChanged()
        }
    }
    private var shimmerStarted: Date?
    private var shimmerTimer: Timer?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // A soft shadow under it, like a stone resting on the bar.
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        layer?.shadowRadius = 1.5
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { shimmerTimer?.invalidate() }

    func configure(name: String, branch: String, user: String, changes: Int,
                   path: String, isActive: Bool) {
        // The mark moving to another project fades across rather than
        // jumping: it is the one thing a switch changes in the bar.
        if isActive != self.isActive, window != nil,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.2
            layer?.add(fade, forKey: "selection")
        }
        self.name = name
        self.branch = branch
        self.changes = changes
        self.path = path
        self.isActive = isActive
        toolTip = path
        var label = branch.isEmpty ? name : "\(name), branch \(branch)"
        if !user.isEmpty { label += ", \(user)" }
        if changes > 0 { label += ", \(changes) changed" }
        setAccessibilityLabel(label)
        setAccessibilitySelected(isActive)
        needsDisplay = true
    }

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private var ink: NSColor {
        isActive ? Theme.selectedControlText : (isHovered ? Theme.foreground : Theme.dimText)
    }

    private func nameLabel() -> NSAttributedString {
        NSAttributedString(string: name, attributes: [
            .font: Self.nameFont(), .foregroundColor: ink, .paragraphStyle: Self.centredTruncating,
        ])
    }

    private func branchLabel() -> NSAttributedString {
        NSAttributedString(string: branch, attributes: [
            .font: Self.subFont(), .foregroundColor: Theme.dimText, .paragraphStyle: Self.truncating,
        ])
    }

    private var badge: NSImage? {
        guard changes > 0 else { return nil }
        // On the pebble on show the ground is the selection's, which is the
        // colour the badge takes elsewhere; the panel's own sets it apart.
        return SidebarCellDrawing.Badge.image(
            "\(changes)", labelFont: Self.subFont(),
            background: isActive ? Theme.panelBackground : Theme.activeRow,
            foreground: Theme.foreground)
    }

    private static let glyphSide: CGFloat = 9
    private static let subGap: CGFloat = 4

    /// The second line: the branch mark, the branch, and the count.
    private var subLineWidth: CGFloat {
        var width: CGFloat = 0
        if !branch.isEmpty {
            width += Self.glyphSide + Self.subGap
                + min(Self.branchLimit, ceil(branchLabel().size().width))
        }
        if let badge { width += (width > 0 ? Self.subGap : 0) + badge.size.width }
        return width
    }

    private var contentWidth: CGFloat {
        max(ceil(nameLabel().size().width), subLineWidth)
    }

    /// The width that holds both lines and the ✕.
    var naturalWidth: CGFloat {
        Self.leadingPadding + contentWidth + Self.closeGap + Self.closeSide + Self.closeInset
    }

    private var contentRect: NSRect {
        NSRect(x: Self.leadingPadding, y: 0,
               width: max(0, bounds.width - Self.leadingPadding - Self.closeGap
                            - Self.closeSide - Self.closeInset),
               height: bounds.height)
    }

    /// Where the ✕ sits, always.
    private var closeRect: NSRect {
        NSRect(x: bounds.width - Self.closeInset - Self.closeSide,
               y: (bounds.height - Self.closeSide) / 2,
               width: Self.closeSide, height: Self.closeSide)
    }
    /// What a press lands on it in: the button, and a little round it.
    private var closeHitRect: NSRect { closeRect.insetBy(dx: -3, dy: -4) }

    private var shape: NSBezierPath {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                     xRadius: Self.cornerWidth - 0.5, yRadius: Self.cornerHeight - 0.5)
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.cornerWidth,
                                   cornerHeight: Self.cornerHeight, transform: nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        layer?.shadowOpacity = isDark ? 0.35 : 0.07
        let shape = shape
        (isActive || isHovered ? Theme.selectedControl : Theme.hover).setFill()
        shape.fill()
        // A faint light along the top edge.
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSColor.white.withAlphaComponent(isDark ? 0.05 : 0.7).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        if isSyncing {
            if let started = shimmerStarted {
                if let phase = SyncShimmer.phase(since: started) {
                    SyncShimmer.draw(in: bounds, phase: phase, colour: SyncShimmer.tint, peak: 0.22)
                }
            } else {
                // Less motion asked for: a still tint says it.
                SyncShimmer.tint.withAlphaComponent(0.1).setFill()
                bounds.fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        drawContent()
        drawClose()
        if isActive {
            Theme.cursor.setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }
    }

    /// The two lines, centred in the room left of the ✕.
    private func drawContent() {
        let room = contentRect
        let name = nameLabel()
        let nameHeight = ceil(name.size().height)
        let subHeight = max(ceil(Self.subFont().ascender - Self.subFont().descender),
                            badge?.size.height ?? 0)
        let top = ((bounds.height - nameHeight - Self.lineGap - subHeight) / 2).rounded()
        name.draw(with: NSRect(x: room.minX, y: top, width: room.width, height: nameHeight),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        let subTop = top + nameHeight + Self.lineGap
        var x = room.minX + max(0, (room.width - subLineWidth) / 2)
        if !branch.isEmpty {
            SidebarCellDrawing.image(
                Theme.symbol("arrow.triangle.branch"), tint: Theme.dimText,
                in: NSRect(x: x, y: subTop + (subHeight - Self.glyphSide) / 2,
                           width: Self.glyphSide, height: Self.glyphSide))
            x += Self.glyphSide + Self.subGap
            let label = branchLabel()
            let width = min(Self.branchLimit, ceil(label.size().width), room.maxX - x)
            let height = ceil(label.size().height)
            label.draw(with: NSRect(x: x, y: subTop + (subHeight - height) / 2,
                                    width: max(0, width), height: height),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            x += width + Self.subGap
        }
        if let badge, x + badge.size.width <= room.maxX + 0.5 {
            badge.draw(in: NSRect(x: x, y: subTop + (subHeight - badge.size.height) / 2,
                                  width: badge.size.width, height: badge.size.height))
        }
    }

    /// The ✕, dim at rest; over it, a faint red ground and a red cross.
    private func drawClose() {
        let box = closeRect
        if closeIsHovered {
            Theme.red.withAlphaComponent(0.18).setFill()
            NSBezierPath(ovalIn: box).fill()
        }
        let arm: CGFloat = 3.5
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: box.midX - arm, y: box.midY - arm))
        cross.line(to: NSPoint(x: box.midX + arm, y: box.midY + arm))
        cross.move(to: NSPoint(x: box.midX + arm, y: box.midY - arm))
        cross.line(to: NSPoint(x: box.midX - arm, y: box.midY + arm))
        cross.lineWidth = 1.4
        cross.lineCapStyle = .round
        (closeIsHovered ? Theme.red : Theme.dimText).setStroke()
        cross.stroke()
    }

    private static let truncating: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()
    private static let centredTruncating: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = .center
        return style
    }()

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Syncing

    private func syncingChanged() {
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if isSyncing, window != nil, !still { startShimmer() } else { stopShimmer() }
        needsDisplay = true
    }

    private func startShimmer() {
        guard shimmerTimer == nil else { return }
        shimmerStarted = Date()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        shimmerTimer = timer
    }

    private func stopShimmer() {
        shimmerTimer?.invalidate()
        shimmerTimer = nil
        shimmerStarted = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A pebble taken off screen stops its clock; one put back picks up
        // where its project stands.
        syncingChanged()
        if window == nil { setHovered(false) }
    }

    // MARK: - Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: PointerCursor.trackingOptions,
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
        PointerCursor.enter()
    }

    override func mouseMoved(with event: NSEvent) {
        PointerCursor.enter()
        pointerMoved(to: convert(event.locationInWindow, from: nil))
    }

    override func cursorUpdate(with event: NSEvent) { PointerCursor.enter() }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
        PointerCursor.leave(self, event: event)
    }

    private func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        if !hovered { closeIsHovered = false }
        needsDisplay = true
    }

    private func pointerMoved(to point: NSPoint) {
        let onClose = closeHitRect.contains(point)
        guard onClose != closeIsHovered else { return }
        closeIsHovered = onClose
        needsDisplay = true
    }

    /// Selection waits for the release: a press that turns into a drag is
    /// carrying the pebble somewhere else, not choosing it.
    ///
    /// The drag runs in its own event loop — the lane moves the other pebbles
    /// out of the way as this one travels.
    override func mouseDown(with event: NSEvent) {
        trackPress(inWindow: event.locationInWindow) { [weak self] in
            self?.window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp])
        }
    }

    /// The press, from the button going down to what it turns out to have
    /// meant. `nextEvent` hands over the rest of the gesture — the window's
    /// own queue in the app, a scripted sequence in a test.
    func trackPress(inWindow start: NSPoint, nextEvent: () -> NSEvent?) {
        // On the ✕: a click on it, never a drag or a choice.
        if closeHitRect.contains(convert(start, from: nil)) {
            var released: NSPoint?
            while let next = nextEvent() {
                guard next.type == .leftMouseDragged else {
                    released = next.locationInWindow
                    break
                }
            }
            if let released, closeHitRect.contains(convert(released, from: nil)) { onClose?() }
            return
        }
        var dragging = false
        var released: NSPoint?
        while let next = nextEvent() {
            guard next.type == .leftMouseDragged else {
                released = next.locationInWindow
                break
            }
            if !dragging {
                let travelled = hypot(next.locationInWindow.x - start.x,
                                      next.locationInWindow.y - start.y)
                guard travelled > Self.dragThreshold, onDragBegan?() == true else { continue }
                dragging = true
            }
            if let lane = superview {
                onDragMoved?(lane.convert(next.locationInWindow, from: nil))
            }
        }
        guard !dragging else {
            onDragEnded?()
            return
        }
        // Let go somewhere else, the press was abandoned rather than a click.
        guard let released, bounds.contains(convert(released, from: nil)) else { return }
        onSelect?()
    }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenu() }

    /// The pull, and the close the ✕ offers too.
    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        if onPull != nil {
            let pull = NSMenuItem(title: "Pull", action: #selector(pullChosen), keyEquivalent: "")
            pull.target = self
            menu.addItem(pull)
            menu.addItem(.separator())
        }
        let close = NSMenuItem(title: "Close Project", action: #selector(closeChosen),
                               keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        return menu
    }

    @objc private func pullChosen() { onPull?() }
    @objc private func closeChosen() { onClose?() }

    private func refreshAccessibilityActions() {
        var actions = [NSAccessibilityCustomAction(name: "Close Project") { [weak self] in
            self?.onClose?()
            return true
        }]
        if onPull != nil {
            actions.insert(NSAccessibilityCustomAction(name: "Pull") { [weak self] in
                self?.onPull?()
                return true
            }, at: 0)
        }
        setAccessibilityCustomActions(actions)
    }

    override func accessibilityPerformPress() -> Bool {
        onSelect?()
        return true
    }

    // MARK: - Regression-test surface

    /// What the pebble reads as: the name, and the count written out.
    var titleForTesting: String { changes > 0 ? "\(name)  \(changes)" : name }
    var branchForTesting: String { branch }
    var pathForTesting: String { path }
    var isActiveForTesting: Bool { isActive }
    var isSyncingForTesting: Bool { isSyncing }
    /// Whether the light is moving — it is not for a pebble off screen.
    var isShimmeringForTesting: Bool { shimmerTimer != nil }
    var closeRectForTesting: NSRect { closeRect }
    var isCloseHoveredForTesting: Bool { closeIsHovered }
    var menuTitlesForTesting: [String] {
        contextMenu().items.filter { !$0.isSeparatorItem }.map(\.title)
    }
    func chooseMenuItemForTesting(_ title: String) {
        guard let item = contextMenu().items.first(where: { $0.title == title }),
              let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
    }
    func setHoveredForTesting(_ hovered: Bool) { setHovered(hovered) }
    /// The pointer at `point`, in the pebble's own coordinates.
    func pointerMovedForTesting(to point: NSPoint) { pointerMoved(to: point) }
    func clickForTesting() { onSelect?() }
    /// A whole press, scripted: the button goes down at `point`, travels
    /// through `path`, and is released. Points are the pebble's own.
    func pressForTesting(at point: NSPoint, draggingThrough path: [NSPoint] = [],
                         between: (() -> Void)? = nil) {
        func event(_ type: NSEvent.EventType, _ at: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: convert(at, to: nil), modifierFlags: [],
                               timestamp: 0, windowNumber: 0, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        // Converted up front: the pebble moves as it is dragged, and a point
        // read in its own coordinates afterwards would move with it.
        var queue = path.map { event(.leftMouseDragged, $0) }
        queue.append(event(.leftMouseUp, path.last ?? point))
        var index = 0
        trackPress(inWindow: convert(point, to: nil)) {
            between?()
            defer { index += 1 }
            return index < queue.count ? queue[index] : nil
        }
    }
}

/// The window's projects in a row, one pebble each at its own width. Too many
/// for the room, the row scrolls sideways.
///
/// Switching projects moves nothing here: only the mark goes to the project
/// chosen. Opening, closing and reordering move the pebbles that have to make
/// room, which slide there.
final class ProjectLaneView: NSView {
    /// Room before the first pebble and after the last, and between them.
    static let inset: CGFloat = 8
    static let gap: CGFloat = 8
    static let slideDuration: TimeInterval = 0.3

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onPull: ((Int) -> Void)?
    var onReorder: ((Int, Int) -> Void)?
    /// A drag was put down, moved or not.
    var onDragEnded: (() -> Void)?

    /// In the window's order, which is not the order on screen while one is
    /// being dragged.
    private(set) var pebbles: [ProjectPebbleView] = []
    /// The order on screen.
    private var order: [ProjectPebbleView] = []
    /// Pebbles the last refresh added, which fade in where they belong if
    /// the change slides in.
    private var arrivals: [ProjectPebbleView] = []
    private var drag: (pebble: ProjectPebbleView, from: Int, grab: CGFloat)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Projects")
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    var isDragging: Bool { drag != nil }

    /// Where pebbles of `widths` go, left to right, in a row `height` tall.
    static func frames(widths: [CGFloat], height: CGFloat) -> [NSRect] {
        var x = inset
        return widths.map { width in
            defer { x += width + gap }
            return NSRect(x: x, y: ((height - ProjectPebbleView.height) / 2).rounded(),
                          width: width, height: ProjectPebbleView.height)
        }
    }

    private func targetFrames() -> [NSRect] {
        Self.frames(widths: order.map(\.naturalWidth), height: bounds.height)
    }

    /// The width the row needs to show every pebble.
    var contentWidth: CGFloat {
        (targetFrames().last?.maxX ?? 0) + Self.inset
    }

    /// Bring the pebbles in line with the window's projects. Returns whether
    /// any came, went or changed places.
    @discardableResult
    func configure(projects: [(name: String, branch: String, user: String,
                               changes: Int, path: String)],
                   active: Int?) -> Bool {
        let before = pebbles.map(\.path)
        var byPath = Dictionary(pebbles.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var next: [ProjectPebbleView] = []
        var arrived: [ProjectPebbleView] = []
        for (index, project) in projects.enumerated() {
            let pebble = byPath.removeValue(forKey: project.path) ?? {
                let pebble = ProjectPebbleView()
                arrived.append(pebble)
                return pebble
            }()
            pebble.onSelect = { [weak self] in self?.onSelect?(index) }
            pebble.onClose = { [weak self] in self?.onClose?(index) }
            pebble.onPull = project.branch.isEmpty ? nil : { [weak self] in self?.onPull?(index) }
            pebble.onDragBegan = { [weak self, weak pebble] in
                guard let self, let pebble else { return false }
                return self.beginDrag(pebble)
            }
            pebble.onDragMoved = { [weak self, weak pebble] point in
                guard let self, let pebble else { return }
                self.dragMoved(pebble, to: point)
            }
            pebble.onDragEnded = { [weak self] in self?.endDrag() }
            pebble.configure(name: project.name, branch: project.branch, user: project.user,
                             changes: project.changes, path: project.path,
                             isActive: index == active)
            next.append(pebble)
        }
        byPath.values.forEach { $0.removeFromSuperview() }
        pebbles = next
        order = next
        // A pebble that is new arrives where it belongs, fading in, rather
        // than sliding out of the row's corner.
        let frames = targetFrames()
        for pebble in arrived {
            if let index = order.firstIndex(of: pebble) { pebble.frame = frames[index] }
            addSubview(pebble)
        }
        arrivals = arrived
        needsLayout = true
        return pebbles.map(\.path) != before
    }

    /// Inside the bar's slide: the pebbles just added fade in as the others
    /// move over for them.
    func fadeInArrivals() {
        for pebble in arrivals {
            pebble.alphaValue = 0
            pebble.animator().alphaValue = 1
        }
        arrivals = []
    }

    func setSyncing(_ paths: Set<String>) {
        for pebble in pebbles { pebble.isSyncing = paths.contains(pebble.path) }
    }

    /// The UI font changed: every pebble's width with it.
    func refreshFonts() {
        pebbles.forEach { $0.needsDisplay = true }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        for (pebble, frame) in zip(order, targetFrames()) where pebble !== drag?.pebble {
            if pebble.frame != frame { pebble.frame = frame }
        }
    }

    // MARK: - Reordering

    private func beginDrag(_ pebble: ProjectPebbleView) -> Bool {
        guard pebbles.count > 1, let from = pebbles.firstIndex(of: pebble) else { return false }
        drag = (pebble, from, -1)
        // Over its neighbours while it travels.
        addSubview(pebble, positioned: .above, relativeTo: nil)
        return true
    }

    /// The pebble follows the pointer along the row, and the others make room
    /// for it where it would land, sliding there: what is on screen during the
    /// drag is what the drop commits.
    private func dragMoved(_ pebble: ProjectPebbleView, to point: NSPoint) {
        guard var current = drag, current.pebble === pebble else { return }
        if current.grab < 0 {
            current.grab = point.x - pebble.frame.minX
            drag = current
        }
        pebble.setFrameOrigin(NSPoint(x: point.x - current.grab, y: pebble.frame.minY))
        let centre = pebble.frame.midX
        let others = order.filter { $0 !== pebble }
        let frames = targetFrames()
        let slots = Dictionary(uniqueKeysWithValues: zip(order.map(ObjectIdentifier.init), frames))
        let index = others.filter { slots[ObjectIdentifier($0)].map { $0.midX < centre } ?? false }.count
        guard order.firstIndex(of: pebble) != index else { return }
        var reordered = others
        reordered.insert(pebble, at: index)
        order = reordered
        slide { self.layoutSubtreeIfNeeded() }
    }

    private func endDrag() {
        guard let current = drag else { return }
        drag = nil
        let landed = order.firstIndex(of: current.pebble) ?? current.from
        let frames = targetFrames()
        slide { current.pebble.frame = frames[landed] }
        if landed != current.from { onReorder?(current.from, landed) }
        onDragEnded?()
    }

    private func slide(_ changes: @escaping () -> Void) {
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            needsLayout = true
            changes()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.slideDuration * 0.7
            context.allowsImplicitAnimation = true
            changes()
        }
    }

    // MARK: - Regression-test surface

    /// The pebbles' names in the order they are on screen.
    var visualOrderForTesting: [String] { order.map(\.titleForTesting) }
    /// Start carrying a pebble, as a press that has travelled far enough does.
    func beginDragForTesting(_ index: Int) -> Bool {
        pebbles.indices.contains(index) && beginDrag(pebbles[index])
    }
    /// Carry it so its centre is at `x`, in the lane's coordinates.
    func moveDragForTesting(toX x: CGFloat) {
        guard var current = drag else { return }
        if current.grab < 0 {
            current.grab = current.pebble.frame.width / 2
            drag = current
        }
        dragMoved(current.pebble, to: NSPoint(x: x, y: current.pebble.frame.midY))
    }
    func endDragForTesting() { endDrag() }
}

/// The bar along the window's foot: the projects, and at its right end, past
/// a line, the errands that start a session — open a project, go back to a
/// recent one, get a shell in the one on show, open another window.
final class ProjectBarView: NSView {
    static let height: CGFloat = 56

    let lane = ProjectLaneView()
    private let scroll = NSScrollView()
    private let divider = FlatView()
    let openButton = TitleLetterButton(letter: "O", word: "Open", hint: "Open Project",
                                       shortcut: "⌘O", icon: "folder-import")
    let recentButton = TitleLetterButton(letter: "R", word: "Recent",
                                         hint: "Recent Projects", icon: "changelog")
    let terminalButton = TitleLetterButton(letter: "T", word: "Terminal",
                                           hint: "Open in Terminal", icon: "console")
    let windowButton = TitleLetterButton(letter: "W", word: "Window", hint: "New Window",
                                         shortcut: "⌘N", icon: "virtual")
    private var buttons: [TitleLetterButton] {
        [openButton, recentButton, terminalButton, windowButton]
    }

    var onSelect: ((Int) -> Void)? {
        get { lane.onSelect } set { lane.onSelect = newValue }
    }
    var onClose: ((Int) -> Void)? {
        get { lane.onClose } set { lane.onClose = newValue }
    }
    var onPull: ((Int) -> Void)? {
        get { lane.onPull } set { lane.onPull = newValue }
    }
    var onReorder: ((Int, Int) -> Void)?
    var onOpenProject: (() -> Void)?
    var onNewWindow: (() -> Void)?
    /// Carries the button's rect in this view's coordinates.
    var onShowRecent: ((NSRect) -> Void)?
    var onOpenTerminal: (() -> Void)?

    /// What a refresh asked the bar to show while a pebble was being dragged.
    private var pendingConfiguration: (projects: [(name: String, branch: String, user: String,
                                                   changes: Int, path: String)],
                                       active: Int?)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        // The app's own scrollers, though neither is shown: the row scrolls
        // under a swipe, and a bar along the window's foot has no room for one.
        PuzzleScroller.adopt(scroll, alongWindowEdge: true)
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.documentView = lane
        lane.frame = NSRect(x: 0, y: 0, width: 0, height: Self.height - 1)
        addSubview(scroll)
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.fillColor = Theme.border
        addSubview(divider)
        for (button, action) in [(openButton, #selector(openProjectAction)),
                                 (recentButton, #selector(showRecentAction)),
                                 (terminalButton, #selector(openTerminalAction)),
                                 (windowButton, #selector(newWindowAction))] {
            button.target = self
            button.action = action
            // The bar is at the window's foot: the card names it from above.
            button.hintAbove = true
            addSubview(button)
        }
        // Nothing to open a shell in until a project is showing.
        terminalButton.isEnabled = false
        var constraints = [
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: divider.leadingAnchor, constant: -4),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: TitleLetterButton.side),
            divider.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0.5),
            divider.trailingAnchor.constraint(equalTo: openButton.leadingAnchor, constant: -9),
            windowButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ]
        for (left, right) in zip(buttons, buttons.dropFirst()) {
            constraints.append(left.trailingAnchor.constraint(equalTo: right.leadingAnchor,
                                                              constant: -TitleLetterButton.gap))
        }
        for button in buttons {
            constraints += [
                button.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0.5),
                button.widthAnchor.constraint(equalToConstant: TitleLetterButton.side),
                button.heightAnchor.constraint(equalToConstant: TitleLetterButton.side),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        lane.onReorder = { [weak self] from, to in
            // The reorder redraws the bar from the model, which already holds
            // anything a refresh held back during the drag would say.
            self?.pendingConfiguration = nil
            self?.onReorder?(from, to)
        }
        lane.onDragEnded = { [weak self] in
            guard let self, let pending = self.pendingConfiguration else { return }
            self.pendingConfiguration = nil
            self.configure(projects: pending.projects, active: pending.active)
        }
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Bring the pebbles in line with the window's projects.
    func configure(projects: [(name: String, branch: String, user: String,
                               changes: Int, path: String)],
                   active: Int?) {
        // A refresh can land in the middle of a drag — the drag's own event
        // loop still runs the main queue. Rearranging then put the pebble
        // back where it started, or rebuilt the row out from under it; the
        // newest state waits until the pebble is put down.
        guard !lane.isDragging else {
            pendingConfiguration = (projects, active)
            return
        }
        let hadProjects = !lane.pebbles.isEmpty
        let moved = lane.configure(projects: projects, active: active)
        // A project come, gone or moved: the pebbles that make room slide
        // there and a new one fades in. Switching moves nothing, and a window
        // opening finds its projects already in place.
        guard moved, hadProjects, window != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            lastLayoutDurationForTesting = 0
            fitLane()
            return
        }
        lastLayoutDurationForTesting = ProjectLaneView.slideDuration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = ProjectLaneView.slideDuration
            context.allowsImplicitAnimation = true
            lane.fadeInArrivals()
            fitLane()
            lane.layoutSubtreeIfNeeded()
        }
    }
    private(set) var lastLayoutDurationForTesting: TimeInterval?

    /// The lane as wide as its pebbles, and never narrower than the room.
    private func fitLane() {
        let room = scroll.contentView.bounds.width
        lane.setFrameSize(NSSize(width: max(room, lane.contentWidth), height: Self.height - 1))
        lane.needsLayout = true
    }

    override func layout() {
        super.layout()
        fitLane()
    }

    func setSyncing(_ paths: Set<String>) { lane.setSyncing(paths) }

    /// A terminal needs a directory to open in.
    func setHasProject(_ hasProject: Bool) { terminalButton.isEnabled = hasProject }

    func refreshFonts() {
        divider.fillColor = Theme.border
        lane.refreshFonts()
        buttons.forEach { $0.refreshFonts() }
        needsDisplay = true
        needsLayout = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.panelBackground.setFill()
        bounds.fill()
        // The line closing the bar off from the window above it.
        Theme.border.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        divider.fillColor = Theme.border
        needsDisplay = true
    }

    @objc private func openProjectAction() { onOpenProject?() }
    @objc private func newWindowAction() { onNewWindow?() }
    @objc private func openTerminalAction() { onOpenTerminal?() }
    @objc private func showRecentAction() {
        onShowRecent?(recentButton.convert(recentButton.bounds, to: self))
    }

    // MARK: - Regression-test surface

    /// One a project, in the window's order.
    var pebblesForTesting: [ProjectPebbleView] { lane.pebbles }
    var buttonsForTesting: [TitleLetterButton] { buttons }
    /// The projects' names in the order the bar shows them.
    var visualOrderForTesting: [String] { lane.visualOrderForTesting }
    var laneForTesting: ProjectLaneView { lane }
}

import AppKit

/// The light that runs across a project while a fetch or a pull is out: a
/// soft band, left to right, then a rest before the next pass. The project's
/// name in the strip and the Git mark over its changes both carry it.
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

/// One project across the top of the Projects panel: its name, and after it
/// how many files it has changed but not committed. The one on show is marked
/// with the selection's ground and an edge in the accent; a click on another
/// shows that one instead, and a click on the one showing folds it away.
///
/// Under the pointer a remove button slides in over the chip's right end, and
/// a card above gives the branch. The chip keeps its width throughout.
final class ProjectChipView: NSView {
    static let padding: CGFloat = 10
    /// Far enough that a shaky click is not a drag.
    static let dragThreshold: CGFloat = 4
    /// How long the pointer rests before the card above gives the branch.
    static let hintDelay: TimeInterval = 0.25
    /// The remove button: its size, and how far in from the right edge it
    /// comes to rest.
    static let closeSide: CGFloat = 16
    static let closeInset: CGFloat = 5
    /// How far past the edge it starts, and how long it takes to come in.
    static let closeTravel: CGFloat = 22
    static let closeDuration: TimeInterval = 0.18
    /// The fade of the chip's own ground laid under it, which the count and
    /// the end of the name go under. Nothing on the chip moves for it.
    static let veilWidth: CGFloat = 46

    static func height() -> CGFloat {
        let line = NSLayoutManager().defaultLineHeight(for: font())
        return max(26, ceil(line) + 8)
    }
    private static func font() -> NSFont { Theme.uiFont(12) }

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    /// Nil for a folder that is not a repository: there is nothing to pull.
    var onPull: (() -> Void)? {
        didSet { refreshAccessibilityActions() }
    }
    /// Carrying the chip to another place: the strip decides whether it may,
    /// and is told where the pointer is, in the strip's own coordinates.
    var onDragBegan: (() -> Bool)?
    var onDragMoved: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?

    private(set) var name = ""
    private(set) var branch = ""
    private(set) var changes = 0
    private(set) var path = ""
    private(set) var isActive = false
    private var isHovered = false
    private var tracking: NSTrackingArea?
    private var hintWork: DispatchWorkItem?
    /// How far the remove button has come in: 0 away past the edge, 1 at
    /// rest. It slides to `closeTarget` from `closeFrom`.
    private var closeShown: CGFloat = 0
    private var closeFrom: CGFloat = 0
    private var closeTarget: CGFloat = 0
    private var closeStarted: CFTimeInterval = 0
    private var closeTimer: Timer?
    private var closeIsHovered = false

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
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        shimmerTimer?.invalidate()
        closeTimer?.invalidate()
    }

    func configure(name: String, branch: String, user: String, changes: Int,
                   path: String, isActive: Bool) {
        // The mark moving to another project fades across rather than
        // jumping: it is the one thing a switch changes up here.
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
        var label = branch.isEmpty ? name : "\(name), branch \(branch)"
        if !user.isEmpty { label += ", \(user)" }
        if changes > 0 { label += ", \(changes) changed" }
        setAccessibilityLabel(label)
        setAccessibilitySelected(isActive)
        needsDisplay = true
    }

    /// The width that holds the whole name and its count.
    var naturalWidth: CGFloat {
        ceil(label().size().width) + Self.padding * 2
    }

    private var ink: NSColor {
        isActive ? Theme.selectedControlText : (isHovered ? Theme.foreground : Theme.dimText)
    }

    private func label() -> NSAttributedString {
        // On the chip being shown the ground is the selection's, which is the
        // colour the badge takes elsewhere; the panel's own sets it apart.
        SidebarCellDrawing.labelWithBadge(
            name, badge: changes > 0 ? "\(changes)" : "", font: Self.font(), colour: ink,
            badgeBackground: isActive ? Theme.panelBackground : Theme.activeRow,
            badgeForeground: Theme.foreground)
    }

    private var outline: NSBezierPath {
        let radius = bounds.height / 2
        return NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                            xRadius: radius - 0.5, yRadius: radius - 0.5)
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = outline
        let ground = isActive || isHovered ? Theme.selectedControl : Theme.hover
        ground.setFill()
        shape.fill()
        if isSyncing {
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            if let started = shimmerStarted {
                if let phase = SyncShimmer.phase(since: started) {
                    SyncShimmer.draw(in: bounds, phase: phase, colour: SyncShimmer.tint,
                                     peak: 0.22)
                }
            } else {
                // Less motion asked for: a still tint says it.
                SyncShimmer.tint.withAlphaComponent(0.1).setFill()
                bounds.fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        SidebarCellDrawing.attributedText(
            label(), in: bounds.insetBy(dx: Self.padding, dy: 0))
        if closeShown > 0.001 { drawClose(over: ground) }
        // Last, so nothing laid over the chip ever covers its edge.
        if isActive {
            Theme.cursor.setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }
    }

    /// Where the remove button comes to rest.
    private var closeRect: NSRect {
        NSRect(x: bounds.width - Self.closeInset - Self.closeSide,
               y: (bounds.height - Self.closeSide) / 2,
               width: Self.closeSide, height: Self.closeSide)
    }
    /// What a press lands on it in: the button, and a little round it.
    private var closeHitRect: NSRect {
        closeShown > 0.5 ? closeRect.insetBy(dx: -3, dy: -4) : .zero
    }

    /// The button on its way in, `closeShown` of the way from past the right
    /// edge, over a fade of the chip's own ground. Both stay inside the
    /// border, which is drawn after them.
    private func drawClose(over ground: NSColor) {
        let shown = closeShown
        let inner = bounds.insetBy(dx: 1, dy: 1)
        let radius = inner.height / 2
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: inner, xRadius: radius, yRadius: radius).addClip()
        // Solid from just left of the count's badge, so none of its rim is
        // left showing beside the button.
        NSGradient(colorsAndLocations: (ground.withAlphaComponent(0), 0),
                   (ground.withAlphaComponent(shown), 0.4),
                   (ground.withAlphaComponent(shown), 1))?
            .draw(in: NSRect(x: inner.maxX - Self.veilWidth, y: inner.minY,
                             width: Self.veilWidth, height: inner.height),
                  angle: 0)
        let box = closeRect.offsetBy(dx: Self.closeTravel * (1 - shown), dy: 0)
        let alpha = min(1, shown * 1.4)
        let hot = closeIsHovered && shown > 0.5
        if hot {
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
        (hot ? Theme.red : ink).withAlphaComponent(alpha).setStroke()
        cross.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Bring the button in, or send it back out, from wherever it is now.
    private func slideClose(to target: CGFloat) {
        guard target != closeTarget else { return }
        closeFrom = closeShown
        closeTarget = target
        closeStarted = CACurrentMediaTime()
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            settleClose()
            return
        }
        guard closeTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.advanceClose()
        }
        RunLoop.main.add(timer, forMode: .common)
        closeTimer = timer
    }

    private func advanceClose() {
        let t = CGFloat(min(1, (CACurrentMediaTime() - closeStarted) / Self.closeDuration))
        closeShown = closeFrom + (closeTarget - closeFrom) * (1 - pow(1 - t, 3))
        needsDisplay = true
        if t >= 1 { settleClose() }
    }

    private func settleClose() {
        closeTimer?.invalidate()
        closeTimer = nil
        closeShown = closeTarget
        if closeShown == 0 { closeIsHovered = false }
        needsDisplay = true
    }

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
        // A chip taken off screen stops its clock; one put back picks up where
        // its project stands.
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

    private func pointerMoved(to point: NSPoint) {
        let onClose = closeHitRect.contains(point)
        guard onClose != closeIsHovered else { return }
        closeIsHovered = onClose
        needsDisplay = true
    }
    override func cursorUpdate(with event: NSEvent) { PointerCursor.enter() }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
        PointerCursor.leave(self, event: event)
    }

    private func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        needsDisplay = true
        slideClose(to: hovered ? 1 : 0)
        hideHint()
        guard hovered else { return }
        let work = DispatchWorkItem { [weak self] in self?.showHint() }
        hintWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hintDelay, execute: work)
    }

    /// The card above the chip: its branch, and after it how many files are
    /// changed — the count the remove button covers while the pointer is
    /// here. A folder that is not a repository gives its name instead, and
    /// only when there is a count to give.
    private var hint: (text: String, detail: String?)? {
        guard !branch.isEmpty || changes > 0 else { return nil }
        return (branch.isEmpty ? name : branch, changes > 0 ? "· \(changes) changed" : nil)
    }

    private func showHint() {
        guard isHovered, let window, let hint else { return }
        let onScreen = window.convertToScreen(convert(bounds, to: nil))
        TitleButtonHintCard.shared.show(
            hint.text, detail: hint.detail,
            icon: branch.isEmpty ? nil : Theme.symbol("arrow.triangle.branch"),
            above: onScreen, in: window, owner: self)
    }

    private func hideHint() {
        hintWork?.cancel()
        hintWork = nil
        TitleButtonHintCard.shared.hide(owner: self)
    }

    /// Selection waits for the release: a press that turns into a drag is
    /// carrying the chip somewhere else, not choosing it.
    ///
    /// The drag runs in its own event loop — the strip moves the other chips
    /// out of the way as this one travels.
    override func mouseDown(with event: NSEvent) {
        hideHint()
        trackPress(inWindow: event.locationInWindow) { [weak self] in
            self?.window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp])
        }
    }

    /// The press, from the button going down to what it turns out to have
    /// meant. `nextEvent` hands over the rest of the gesture — the window's
    /// own queue in the app, a scripted sequence in a test.
    func trackPress(inWindow start: NSPoint, nextEvent: () -> NSEvent?) {
        // On the remove button: a click on it, never a drag or a choice.
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
            if let strip = superview {
                onDragMoved?(strip.convert(next.locationInWindow, from: nil))
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

    override func menu(for event: NSEvent) -> NSMenu? {
        hideHint()
        return contextMenu()
    }

    /// What a project that is not on show can still be asked for: the pull
    /// and the ✕ the heading row offers the one that is.
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

    /// What the chip reads as: the name, and the count written out.
    var titleForTesting: String { changes > 0 ? "\(name)  \(changes)" : name }
    var branchForTesting: String { branch }
    var pathForTesting: String { path }
    var isActiveForTesting: Bool { isActive }
    var isHoveredForTesting: Bool { isHovered }
    var isSyncingForTesting: Bool { isSyncing }
    /// Whether the light is moving — it is not for a chip off screen.
    var isShimmeringForTesting: Bool { shimmerTimer != nil }
    var hintForTesting: (text: String, detail: String?)? { hint }
    /// How far the remove button has come in, and where it comes to rest.
    var closeShownForTesting: CGFloat { closeShown }
    var closeRectForTesting: NSRect { closeRect }
    var isCloseHoveredForTesting: Bool { closeIsHovered }
    /// Finish the slide now, rather than over its duration.
    func settleCloseForTesting() { settleClose() }
    /// The pointer at `point`, in the chip's own coordinates.
    func pointerMovedForTesting(to point: NSPoint) { pointerMoved(to: point) }
    var menuTitlesForTesting: [String] {
        contextMenu().items.filter { !$0.isSeparatorItem }.map(\.title)
    }
    func chooseMenuItemForTesting(_ title: String) {
        guard let item = contextMenu().items.first(where: { $0.title == title }),
              let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
    }
    func setHoveredForTesting(_ hovered: Bool) { setHovered(hovered) }
    func clickForTesting() { onSelect?() }
    /// A whole press, scripted: the button goes down at `point`, travels
    /// through `path`, and is released. Points are the chip's own.
    func pressForTesting(at point: NSPoint, draggingThrough path: [NSPoint] = [],
                         between: (() -> Void)? = nil) {
        func event(_ type: NSEvent.EventType, _ at: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: convert(at, to: nil), modifierFlags: [],
                               timestamp: 0, windowNumber: 0, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        // Converted up front: the chip moves as it is dragged, and a point
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

/// The window's projects across the top of the Projects panel, one chip each
/// at its own width, running on to another line where the panel runs out of
/// room. Its height is whatever its lines take.
///
/// Switching projects moves nothing here: only the mark goes to the project
/// chosen. Opening, closing and reordering move the chips that have to make
/// room, which slide there.
final class ProjectStripView: NSView {
    /// Room at the panel's sides, above the first line and below the last.
    static let inset: CGFloat = 8
    static let verticalInset: CGFloat = 9
    /// Between chips, and between lines.
    static let gap: CGFloat = 6
    static let slideDuration: TimeInterval = 0.3

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onPull: ((Int) -> Void)?
    var onReorder: ((Int, Int) -> Void)?
    /// A drag was put down, moved or not.
    var onDragEnded: (() -> Void)?

    /// In the window's order, which is not the order on screen while one is
    /// being dragged.
    private(set) var chips: [ProjectChipView] = []
    /// The order on screen.
    private var order: [ProjectChipView] = []
    /// Chips the last refresh added, which fade in where they belong if the
    /// panel slides the change in.
    private var arrivals: [ProjectChipView] = []
    private var drag: (chip: ProjectChipView, from: Int, grab: NSPoint)?
    private var heightConstraint: NSLayoutConstraint!
    private var laidOutWidth: CGFloat = -1

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        heightConstraint = heightAnchor.constraint(equalToConstant: Self.height(lines: 1))
        heightConstraint.isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Projects")
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    var isDragging: Bool { drag != nil }

    static func height(lines: Int) -> CGFloat {
        let lines = CGFloat(max(1, lines))
        return verticalInset * 2 + lines * ProjectChipView.height() + (lines - 1) * gap
    }

    /// Where chips of `widths` go, in order, across a strip `width` wide: each
    /// at its own width, on the line it fits, and a new line when it does not.
    /// One wider than the strip takes a line of its own, cut to fit.
    static func frames(widths: [CGFloat], in width: CGFloat) -> [NSRect] {
        let room = max(0, width - inset * 2)
        let height = ProjectChipView.height()
        var frames: [NSRect] = []
        var x = inset
        var line = 0
        for natural in widths {
            let chip = min(natural, room)
            // Not laid out yet: one line, until there is a width to fill.
            if room > 0, x > inset, x + chip > inset + room {
                line += 1
                x = inset
            }
            frames.append(NSRect(x: x, y: verticalInset + CGFloat(line) * (height + gap),
                                 width: chip, height: height))
            x += chip + gap
        }
        return frames
    }

    private func targetFrames(width: CGFloat) -> [NSRect] {
        Self.frames(widths: order.map(\.naturalWidth), in: width)
    }

    private func lines(in frames: [NSRect]) -> Int {
        Set(frames.map(\.minY)).count
    }

    /// Bring the chips in line with the window's projects. Returns whether any
    /// came, went or changed places — a change the panel slides into place.
    @discardableResult
    func configure(projects: [(name: String, branch: String, user: String,
                               changes: Int, path: String)],
                   active: Int?) -> Bool {
        let before = chips.map(\.path)
        var byPath = Dictionary(chips.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var next: [ProjectChipView] = []
        var arrived: [ProjectChipView] = []
        for (index, project) in projects.enumerated() {
            let chip = byPath.removeValue(forKey: project.path) ?? {
                let chip = ProjectChipView()
                arrived.append(chip)
                return chip
            }()
            chip.onSelect = { [weak self] in self?.onSelect?(index) }
            chip.onClose = { [weak self] in self?.onClose?(index) }
            chip.onPull = project.branch.isEmpty ? nil : { [weak self] in self?.onPull?(index) }
            chip.onDragBegan = { [weak self, weak chip] in
                guard let self, let chip else { return false }
                return self.beginDrag(chip)
            }
            chip.onDragMoved = { [weak self, weak chip] point in
                guard let self, let chip else { return }
                self.dragMoved(chip, to: point)
            }
            chip.onDragEnded = { [weak self] in self?.endDrag() }
            chip.configure(name: project.name, branch: project.branch, user: project.user,
                           changes: project.changes, path: project.path,
                           isActive: index == active)
            next.append(chip)
        }
        byPath.values.forEach { $0.removeFromSuperview() }
        chips = next
        order = next
        // A chip that is new arrives where it belongs, fading in, rather than
        // sliding out of the strip's corner.
        let frames = targetFrames(width: bounds.width)
        for chip in arrived {
            if let index = order.firstIndex(of: chip) { chip.frame = frames[index] }
            addSubview(chip)
        }
        arrivals = arrived
        updateHeight()
        needsLayout = true
        return chips.map(\.path) != before
    }

    /// Inside the panel's slide: the chips just added fade in as the others
    /// move over for them.
    func fadeInArrivals() {
        for chip in arrivals {
            chip.alphaValue = 0
            chip.animator().alphaValue = 1
        }
        arrivals = []
    }

    func setSyncing(_ paths: Set<String>) {
        for chip in chips { chip.isSyncing = paths.contains(chip.path) }
    }

    /// The UI font changed: every chip's width with it.
    func refreshFonts() {
        chips.forEach { $0.needsDisplay = true }
        updateHeight()
        needsLayout = true
    }

    private func updateHeight(width: CGFloat? = nil) {
        let height = Self.height(lines: lines(in: targetFrames(width: width ?? bounds.width)))
        if heightConstraint.constant != height { heightConstraint.constant = height }
    }

    /// The height for the width the strip is about to be given. Its lines
    /// depend on its width, which layout only settles after its height has
    /// been used; the panel says the width first, before it lays out, so one
    /// pass puts everything in place.
    func fit(width: CGFloat) {
        updateHeight(width: width)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let old = frame.size
        super.setFrameSize(newSize)
        // The line along the foot moves with it.
        if newSize != old { needsDisplay = true }
        // The lines depend on the width, and the height on the lines.
        if newSize.width != laidOutWidth {
            laidOutWidth = newSize.width
            updateHeight()
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        let frames = targetFrames(width: bounds.width)
        for (chip, frame) in zip(order, frames) where chip !== drag?.chip {
            if chip.frame != frame { chip.frame = frame }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.panelBackground.setFill()
        bounds.fill()
        // The line closing the projects off from the one opened under them.
        Theme.border.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Reordering

    private func beginDrag(_ chip: ProjectChipView) -> Bool {
        guard chips.count > 1, let from = chips.firstIndex(of: chip) else { return false }
        drag = (chip, from, NSPoint(x: -1, y: -1))
        // Over its neighbours while it travels.
        addSubview(chip, positioned: .above, relativeTo: nil)
        return true
    }

    /// The chip follows the pointer, and the others make room for it where it
    /// would land, sliding there: what is on screen during the drag is what
    /// the drop commits.
    private func dragMoved(_ chip: ProjectChipView, to point: NSPoint) {
        guard var current = drag, current.chip === chip else { return }
        if current.grab.x < 0 {
            current.grab = NSPoint(x: point.x - chip.frame.minX, y: point.y - chip.frame.minY)
            drag = current
        }
        chip.setFrameOrigin(NSPoint(x: point.x - current.grab.x, y: point.y - current.grab.y))
        let centre = NSPoint(x: chip.frame.midX, y: chip.frame.midY)
        let others = order.filter { $0 !== chip }
        let frames = targetFrames(width: bounds.width)
        let slots = Dictionary(uniqueKeysWithValues: zip(order.map(ObjectIdentifier.init), frames))
        let pitch = ProjectChipView.height() + Self.gap
        let line = floor((centre.y - Self.verticalInset + Self.gap / 2) / pitch)
        // Every chip on an earlier line, and those before the pointer on its
        // own, come ahead of it.
        let index = others.filter { other in
            guard let slot = slots[ObjectIdentifier(other)] else { return false }
            let otherLine = ((slot.minY - Self.verticalInset) / pitch).rounded()
            return otherLine < line || (otherLine == line && slot.midX < centre.x)
        }.count
        guard order.firstIndex(of: chip) != index else { return }
        var reordered = others
        reordered.insert(chip, at: index)
        order = reordered
        slide { self.layoutSubtreeIfNeeded() }
    }

    private func endDrag() {
        guard let current = drag else { return }
        drag = nil
        let landed = order.firstIndex(of: current.chip) ?? current.from
        let frames = targetFrames(width: bounds.width)
        slide { current.chip.frame = frames[landed] }
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

    /// The chips' names in the order they are on screen.
    var visualOrderForTesting: [String] { order.map(\.titleForTesting) }
    var heightForTesting: CGFloat { heightConstraint.constant }
    var linesForTesting: Int { lines(in: targetFrames(width: bounds.width)) }
    /// Start carrying a chip, as a press that has travelled far enough does.
    func beginDragForTesting(_ index: Int) -> Bool {
        chips.indices.contains(index) && beginDrag(chips[index])
    }
    /// Carry it so its centre is at `point`, in the strip's coordinates.
    func moveDragForTesting(to point: NSPoint) {
        guard var current = drag else { return }
        if current.grab.x < 0 {
            current.grab = NSPoint(x: current.chip.frame.width / 2,
                                   y: current.chip.frame.height / 2)
            drag = current
        }
        dragMoved(current.chip, to: point)
    }
    func endDragForTesting() { endDrag() }
}

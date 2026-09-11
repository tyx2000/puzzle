import AppKit

/// The window's projects, along the bottom of the editor beside the sidebar's
/// action bar — same height, same flat idiom, so the two read as one strip.
///
/// A window holds several projects and shows one at a time. Switching loads the
/// project afresh: the tabs of the project being left are closed, because the
/// files of one project have no place in another.
final class ProjectTabBar: NSView {
    /// The project at this index was chosen.
    var onSelect: ((Int) -> Void)?
    /// The trailing `+`: open another project and switch to it.
    var onAdd: (() -> Void)?
    /// The ✕ on the hovered tab: the project leaves this window.
    var onClose: ((Int) -> Void)?
    /// A tab was dragged along the strip and dropped at another place.
    var onReorder: ((Int, Int) -> Void)?

    static let height: CGFloat = ActivityBarView.height
    /// The `+` is always reachable, however many projects are open.
    private static let addWidth: CGFloat = 34
    /// Wide enough for a name, narrow enough that several fit.
    private static let maximumTabWidth: CGFloat = 180
    private static let minimumTabWidth: CGFloat = 70

    private var names: [String] = []
    private var paths: [String] = []
    private var activeIndex: Int?
    private var hoveredIndex: Int?
    private var addIsHovered = false
    private var closeIsHovered = false
    private var tracking: NSTrackingArea?
    /// The tab being dragged and where the pointer holds it. Only the dragged
    /// tab moves; the new order is committed on release.
    private var draggingIndex: Int?
    private var dragX: CGFloat = 0
    private var dragGrabOffset: CGFloat = 0
    private var dragStarted = false
    /// The ✕'s square at the trailing end of a hovered tab, held clear of the
    /// tab's own edge so it does not sit against the neighbour.
    private static let closeWidth: CGFloat = 18
    private static let closeInset: CGFloat = 6
    private static let dragThreshold: CGFloat = 4
    /// How long the ✕ takes to appear, matching the gutter's hover.
    static let closeFadeDuration: CGFloat = 0.12
    /// 0 hidden, 1 fully shown — the tab it belongs to is `closeFadeIndex`.
    private var closeFade: CGFloat = 0
    private var closeFadeIndex: Int?
    private var closeFadeTimer: Timer?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Projects")
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(projects: [URL], activeIndex: Int?) {
        names = projects.map(\.lastPathComponent)
        paths = projects.map(\.path)
        self.activeIndex = activeIndex
        toolTip = nil
        needsDisplay = true
    }

    // MARK: - Geometry

    /// Tabs share what the `+` leaves, up to a readable width each.
    private var tabWidth: CGFloat {
        guard !names.isEmpty else { return 0 }
        let available = max(0, bounds.width - Self.addWidth)
        return min(Self.maximumTabWidth,
                   max(Self.minimumTabWidth, available / CGFloat(names.count)))
    }

    private func tabRect(_ index: Int) -> NSRect {
        NSRect(x: tabWidth * CGFloat(index), y: 0, width: tabWidth, height: bounds.height - 1)
    }

    private var addRect: NSRect {
        NSRect(x: max(tabWidth * CGFloat(names.count), bounds.width - Self.addWidth),
               y: 0, width: Self.addWidth, height: bounds.height - 1)
    }

    private func index(at point: NSPoint) -> Int? {
        names.indices.first { tabRect($0).contains(point) }
    }

    /// Where the ✕ sits on a tab, whether or not it is being shown. Measured
    /// from the slot the tab is displayed in, so it follows a tab that has
    /// shifted to make room for one being dragged.
    private func closeRect(_ index: Int) -> NSRect {
        let tab = tabRect(displaySlot(for: index))
        return NSRect(x: tab.maxX - Self.closeWidth - Self.closeInset, y: 0,
                      width: Self.closeWidth, height: tab.height)
    }

    /// Which slot a tab occupies on screen. While a tab is being dragged the
    /// others move aside, so the gap shows where it will land.
    private func displaySlot(for index: Int) -> Int {
        guard dragStarted, let dragging = draggingIndex else { return index }
        let target = dropIndex()
        if index == dragging { return target }
        var order = Array(names.indices)
        order.remove(at: dragging)
        order.insert(dragging, at: target)
        return order.firstIndex(of: index) ?? index
    }

    /// The slot the dragged tab would land in, from where its centre is now.
    private func dropIndex() -> Int {
        guard !names.isEmpty, tabWidth > 0 else { return 0 }
        let left = min(max(0, dragX - dragGrabOffset), max(0, addRect.minX - tabWidth))
        return max(0, min(names.count - 1, Int(((left + tabWidth / 2) / tabWidth).rounded(.down))))
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        Theme.activityBar.setFill()
        bounds.fill()
        Theme.border.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()

        // The dragged tab is drawn last so it travels above its neighbours,
        // which have already moved aside to show where it will land.
        for index in names.indices where !(dragStarted && index == draggingIndex) {
            draw(tab: index, in: tabRect(displaySlot(for: index)))
        }
        if dragStarted, let dragging = draggingIndex {
            var rect = tabRect(0)
            rect.origin.x = min(max(0, dragX - dragGrabOffset),
                                max(0, addRect.minX - rect.width))
            draw(tab: dragging, in: rect)
        }

        let add = addRect
        if addIsHovered {
            Theme.hover.setFill()
            add.fill()
        }
        SidebarCellDrawing.attributedText(
            NSAttributedString(string: "+", attributes: [
                .font: Theme.uiFont(13),
                .foregroundColor: addIsHovered ? Theme.foreground : Theme.dimText,
                .paragraphStyle: Self.centred,
            ]),
            in: add)
    }

    private func draw(tab index: Int, in rect: NSRect) {
        guard rect.maxX <= addRect.minX + 0.5 else { return }
        let isActive = index == activeIndex
        if isActive {
            Theme.selectedControl.setFill()
            rect.fill()
        } else if index == hoveredIndex || index == draggingIndex {
            Theme.hover.setFill()
            rect.fill()
        }
        let ink = isActive ? Theme.selectedControlText : Theme.dimText
        // The ✕ fades in on hover, and the name gives up its room to it as it
        // arrives so a long name is never drawn underneath the button.
        let fade = index == closeFadeIndex && draggingIndex == nil ? closeFade : 0
        var text = rect.insetBy(dx: 6, dy: 0)
        text.size.width -= (Self.closeWidth + Self.closeInset - 6) * fade
        SidebarCellDrawing.attributedText(
            NSAttributedString(string: names[index], attributes: [
                .font: Theme.uiFont(10.5),
                .foregroundColor: ink,
                .paragraphStyle: Self.centred,
            ]),
            in: text)
        guard fade > 0.01 else { return }
        let box = NSRect(x: rect.maxX - Self.closeWidth - Self.closeInset, y: 0,
                         width: Self.closeWidth, height: rect.height)
        let tint = closeIsHovered ? Theme.foreground : ink
        SidebarCellDrawing.attributedText(
            NSAttributedString(string: "✕", attributes: [
                .font: Theme.uiFont(10),
                .foregroundColor: tint.withAlphaComponent(fade),
                .paragraphStyle: Self.centred,
            ]),
            in: box)
    }

    private static let centred: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    // MARK: - Pointer

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

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let tab = index(at: point)
        let add = addRect.contains(point)
        let close = tab.map { closeRect($0).contains(point) } ?? false
        // The path is worth seeing when two projects share a name.
        toolTip = close ? "Close this project"
            : tab.map { paths[$0] } ?? (add ? "Open another project" : nil)
        guard tab != hoveredIndex || add != addIsHovered || close != closeIsHovered else {
            return
        }
        setHovered(tab)
        addIsHovered = add
        closeIsHovered = close
        needsDisplay = true
    }

    /// The ✕ arrives and leaves over `closeFadeDuration` rather than blinking
    /// into place as the pointer crosses the strip.
    private func setHovered(_ index: Int?) {
        guard index != hoveredIndex else { return }
        hoveredIndex = index
        if let index {
            closeFadeIndex = index
            startCloseFade()
        } else {
            startCloseFade()
        }
    }

    private func startCloseFade() {
        closeFadeTimer?.invalidate()
        guard window != nil else {
            closeFade = hoveredIndex == nil ? 0 : 1
            closeFadeIndex = hoveredIndex
            needsDisplay = true
            return
        }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let step = 1 / (Self.closeFadeDuration * 60)
            let arriving = self.hoveredIndex != nil && self.hoveredIndex == self.closeFadeIndex
            self.closeFade = arriving ? min(1, self.closeFade + step)
                                      : max(0, self.closeFade - step)
            self.needsDisplay = true
            if (arriving && self.closeFade >= 1) || (!arriving && self.closeFade <= 0) {
                if !arriving {
                    // Once it has gone, the next hover starts from its own tab.
                    self.closeFadeIndex = self.hoveredIndex
                    if self.hoveredIndex != nil { return }
                }
                timer.invalidate()
                self.closeFadeTimer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        closeFadeTimer = timer
    }

    override func mouseExited(with event: NSEvent) {
        guard hoveredIndex != nil || addIsHovered || closeIsHovered else { return }
        setHovered(nil)
        addIsHovered = false
        closeIsHovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragStarted = false
        guard let index = index(at: point) else {
            if addRect.contains(point) { onAdd?() }
            return
        }
        // The ✕ takes the click, so closing a project never also selects it.
        if closeRect(index).contains(point) {
            onClose?(index)
            return
        }
        onSelect?(index)
        draggingIndex = index
        dragGrabOffset = point.x - tabRect(index).minX
        dragX = point.x
    }

    override func mouseDragged(with event: NSEvent) {
        guard let index = draggingIndex else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !dragStarted {
            guard abs(point.x - (tabRect(index).minX + dragGrabOffset))
                    > Self.dragThreshold else { return }
            dragStarted = true
        }
        dragX = point.x
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            draggingIndex = nil
            dragStarted = false
            needsDisplay = true
        }
        guard dragStarted, let from = draggingIndex else { return }
        let to = dropIndex()
        guard to != from else { return }
        onReorder?(from, to)
    }

    func refreshAppearance() { needsDisplay = true }

    var tabTitlesForTesting: [String] { names }
    var activeIndexForTesting: Int? { activeIndex }
    func clickTabForTesting(_ index: Int) { onSelect?(index) }
    func clickAddForTesting() { onAdd?() }
    func clickCloseForTesting(_ index: Int) { onClose?(index) }
    func dragTabForTesting(from: Int, to: Int) { onReorder?(from, to) }
    func closeRectForTesting(_ index: Int) -> NSRect { closeRect(index) }
    func hoverForTesting(_ index: Int?) {
        setHovered(index)
        // No window to animate in: land on the end state so a test sees the
        // button the pointer would be shown.
        closeFade = index == nil ? 0 : 1
        closeFadeIndex = index
        needsDisplay = true
    }
    /// Hold a drag in place, so a snapshot can show the gap it opens.
    func holdDragForTesting(index: Int, x: CGFloat) {
        draggingIndex = index
        dragGrabOffset = tabWidth / 2
        dragX = x
        dragStarted = true
        needsDisplay = true
    }

    /// Where each tab is drawn while one is being dragged over the strip.
    func displaySlotsForTesting(dragging index: Int, toX x: CGFloat) -> [Int] {
        draggingIndex = index
        dragGrabOffset = 0
        dragX = x
        dragStarted = true
        defer {
            draggingIndex = nil
            dragStarted = false
        }
        return names.indices.map { displaySlot(for: $0) }
    }
    var addRectForTesting: NSRect { addRect }
    func tabRectForTesting(_ index: Int) -> NSRect { tabRect(index) }
}

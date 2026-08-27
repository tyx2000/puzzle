import AppKit

/// One control, two targets: a label (with an optional count badge) that runs
/// the action, and a chevron that opens a menu. Drawn rather than assembled
/// from two buttons, which always read as two pills however tightly they are
/// packed — and a segmented control cannot carry a badge.
final class SplitActionButton: NSView {
    var onPrimary: (() -> Void)?
    /// Opened by the chevron half. Named apart from `NSView.menu`, which is the
    /// right-click menu and would collide.
    var actionMenu: NSMenu?

    var title = "" {
        didSet {
            guard title != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    /// Shown as a pill after the title. Empty hides it.
    var badge = "" {
        didSet {
            guard badge != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    var isEnabled = true {
        didSet { needsDisplay = true }
    }

    static let chevronWidth: CGFloat = 22
    static let height: CGFloat = 22
    private static let horizontalPadding: CGFloat = 10

    private enum Half { case primary, menu }
    private var hovered: Half?
    private var pressed: Half?
    private var hoverTracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private var labelFont: NSFont { Theme.uiFont(10.5) }

    override var intrinsicContentSize: NSSize {
        let titleWidth = ceil((title as NSString).size(withAttributes: [.font: labelFont]).width)
        let badgeSize = SidebarCellDrawing.Badge.size(badge, labelFont: labelFont)
        let badgeWidth = badgeSize.width > 0
            ? SidebarCellDrawing.Badge.gap + badgeSize.width : 0
        return NSSize(width: Self.horizontalPadding * 2 + titleWidth + badgeWidth
                        + Self.chevronWidth,
                      height: Self.height)
    }

    private var primaryRect: NSRect {
        NSRect(x: 0, y: 0, width: max(0, bounds.width - Self.chevronWidth),
               height: bounds.height)
    }
    private var menuRect: NSRect {
        NSRect(x: primaryRect.maxX, y: 0, width: Self.chevronWidth, height: bounds.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let half: Half? = !isEnabled ? nil : (menuRect.contains(point) ? .menu : .primary)
        guard half != hovered else { return }
        hovered = half
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        pressed = menuRect.contains(point) ? .menu : .primary
        needsDisplay = true
        // The menu opens on press, the way a pull-down does.
        if pressed == .menu, let actionMenu {
            actionMenu.popUp(positioning: nil,
                       at: NSPoint(x: menuRect.minX, y: bounds.maxY + 4), in: self)
            pressed = nil
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        let was = pressed
        pressed = nil
        needsDisplay = true
        let point = convert(event.locationInWindow, from: nil)
        guard was == .primary, primaryRect.contains(point) else { return }
        onPrimary?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: 5, yRadius: 5)
        // A disabled control keeps its shape but stops looking pressable.
        (isEnabled ? Theme.activeTab : Theme.inactiveTab).setFill()
        path.fill()
        if isEnabled, let half = pressed ?? hovered {
            Theme.hover.setFill()
            let rect = half == .menu ? menuRect : primaryRect
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            rect.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        (isEnabled ? Theme.border : Theme.border.withAlphaComponent(0.6)).setStroke()
        path.lineWidth = 1
        path.stroke()

        // The seam between the two halves, so it reads as one control that is
        // divided rather than two that are touching.
        Theme.border.setFill()
        NSRect(x: menuRect.minX, y: 1, width: 1, height: bounds.height - 2).fill()

        let ink = isEnabled ? Theme.foreground : Theme.dimText
        let font = labelFont
        let titleWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        let baseline = SidebarCellDrawing.centeredBaseline(for: font, in: primaryRect)
        SidebarCellDrawing.text(title, font: font, color: ink, baseline: baseline,
                                in: NSRect(x: Self.horizontalPadding, y: 0,
                                           width: titleWidth, height: bounds.height))
        SidebarCellDrawing.Badge.draw(
            badge, at: Self.horizontalPadding + titleWidth + SidebarCellDrawing.Badge.gap,
            baseline: baseline, labelFont: font,
            background: Theme.activeRow, foreground: ink)
        drawChevron(in: NSRect(x: menuRect.midX - 4, y: bounds.midY - 2.5,
                               width: 8, height: 5), colour: ink)
    }

    /// Stroked rather than drawn from a template image: this view paints its
    /// own opaque background first, and the tint-by-`sourceAtop` helper the
    /// cells use would then fill the whole icon box instead of the glyph.
    private func drawChevron(in rect: NSRect, colour: NSColor) {
        let path = NSBezierPath()
        path.lineWidth = 1.3
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: NSPoint(x: rect.minX, y: rect.minY))
        path.line(to: NSPoint(x: rect.midX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        colour.setStroke()
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Regression-test surface

    var halvesForTesting: (primary: NSRect, menu: NSRect) { (primaryRect, menuRect) }
    /// Goes through the same enablement check as a real click.
    @discardableResult
    func clickPrimaryForTesting() -> Bool {
        guard isEnabled else { return false }
        onPrimary?()
        return true
    }
    var menuIsReachableForTesting: Bool { isEnabled && actionMenu != nil }
}

import AppKit

/// A flat button with an optional count badge — Commit and Push on the line
/// over a project's changes.
///
/// Drawn rather than assembled from an `NSButton`, because AppKit's button has
/// nowhere to put a badge that stays on the label's baseline.
final class BadgeButton: NSView {
    var onClick: (() -> Void)?

    /// `.bordered` is filled and outlined. `.plain` draws
    /// no shape of its own until the pointer is over it — for a strip that is
    /// already the controls' ground, like the commit line over a project's
    /// changes, where a frame round each button would split the line up.
    enum Style {
        case bordered
        case plain
    }
    var style: Style = .bordered {
        didSet { needsDisplay = true }
    }

    var title = "" {
        didSet {
            guard title != oldValue else { return }
            setAccessibilityLabel(accessibilityText)
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    /// Shown as a circle after the title. Empty hides it.
    var badge = "" {
        didSet {
            guard badge != oldValue else { return }
            setAccessibilityLabel(accessibilityText)
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    var isEnabled = true {
        didSet { needsDisplay = true }
    }

    static let height: CGFloat = 22
    private static let horizontalPadding: CGFloat = 10

    private var hovered = false
    private var pressed = false
    private var hoverTracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private var labelFont: NSFont { Theme.uiFont(10.5) }
    private var accessibilityText: String { badge.isEmpty ? title : "\(title), \(badge)" }

    override var intrinsicContentSize: NSSize {
        let titleWidth = ceil((title as NSString).size(withAttributes: [.font: labelFont]).width)
        let badgeSize = SidebarCellDrawing.Badge.size(badge, labelFont: labelFont)
        let badgeWidth = badgeSize.width > 0
            ? SidebarCellDrawing.Badge.gap + badgeSize.width : 0
        return NSSize(width: Self.horizontalPadding * 2 + titleWidth + badgeWidth,
                      height: Self.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        // Tracked while disabled too, and only drawn while enabled: a button
        // that comes back to life under the pointer lights up without the
        // pointer having to leave and come back.
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        pressed = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let was = pressed
        pressed = false
        needsDisplay = true
        guard was, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    /// Whether the pointer is showing this button can be clicked.
    private var isLit: Bool { isEnabled && (pressed || hovered) }

    override func draw(_ dirtyRect: NSRect) {
        guard style == .bordered else {
            drawPlain()
            return
        }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: 5, yRadius: 5)
        // Disabled keeps the shape but stops looking pressable.
        (isEnabled ? Theme.activeTab : Theme.inactiveTab).setFill()
        path.fill()
        if isLit {
            Theme.hover.setFill()
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            bounds.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        (isEnabled ? Theme.border : Theme.border.withAlphaComponent(0.6)).setStroke()
        path.lineWidth = 1
        path.stroke()

        let ink = isEnabled ? Theme.foreground : Theme.dimText
        SidebarCellDrawing.attributedText(
            SidebarCellDrawing.labelWithBadge(
                title, badge: badge, font: labelFont, colour: ink,
                badgeBackground: Theme.activeRow, badgeForeground: ink,
                alignment: .center),
            in: bounds)
    }

    /// Nothing but the label until the pointer is over it; then the area a
    /// click lands in. Disabled is the label dimmed, never lit.
    private func drawPlain() {
        if isLit {
            Theme.activeRow.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        let ink = isEnabled ? Theme.foreground : Theme.dimText
        // The badge keeps its own round against the lit background as well as
        // the strip's.
        SidebarCellDrawing.attributedText(
            SidebarCellDrawing.labelWithBadge(
                title, badge: badge, font: labelFont, colour: ink,
                badgeBackground: Theme.panelBackground, badgeForeground: ink,
                alignment: .center),
            in: bounds)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Regression-test surface

    /// Goes through the same enablement check as a real click.
    @discardableResult
    func clickForTesting() -> Bool {
        guard isEnabled else { return false }
        onClick?()
        return true
    }
    var isHoveredForTesting: Bool { hovered }
    var isLitForTesting: Bool { isLit }
    func setHoveredForTesting(_ on: Bool) {
        hovered = on
        needsDisplay = true
    }
}

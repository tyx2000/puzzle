import AppKit

/// Zed's bottom-left action bar: a 40pt row spanning the panel width with one
/// evenly-spaced button per panel. The button for the visible panel gets a
/// full-height active background.
///
/// Settings is not here: it opens a file rather than a panel, so it lives with
/// the editor's own actions at the top right of the window.
final class ActivityBarView: NSView {
    static let height: CGFloat = 40

    enum Action: Int, CaseIterable { case project, search, git }

    /// Called with the tapped action. The host decides whether to show that
    /// panel or, if it's already showing, collapse the sidebar.
    var onAction: ((Action) -> Void)?

    private var buttons: [ActivityButton] = []

    /// The colours the selected button paints with, so a test can hold the
    /// three strips to one another.
    static var selectedColoursForTesting: (surface: NSColor, ink: NSColor) {
        (Theme.selectedControl, Theme.selectedControlText)
    }

    /// Repaint after a theme change (the bar draws straight from the theme).
    func refreshAppearance() {
        needsDisplay = true
        subviews.forEach { $0.needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.activityBar.setFill()
        bounds.fill()
        Theme.border.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        buttons.forEach { $0.needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let specs: [(Action, title: String)] = [
            (.project, "Files"),
            (.search, "Search"),
            (.git, "Git"),
        ]
        buttons = specs.map { action, title in
            let b = ActivityButton(title: title)
            b.onClick = { [weak self] in self?.onAction?(action) }
            addSubview(b)
            return b
        }
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Each button owns an evenly-divided slot: its background and its clickable
    /// area both span the full slot width.
    override func layout() {
        super.layout()
        guard !buttons.isEmpty else { return }
        let height = bounds.height - 1   // preserve the one-point top divider
        let slot = bounds.width / CGFloat(buttons.count)
        for (i, b) in buttons.enumerated() {
            b.frame = NSRect(x: (slot * CGFloat(i)).rounded(), y: 0,
                             width: slot.rounded(), height: height)
        }
    }

    /// Number of changed files, shown after the Git label in the same form the
    /// panel's own tab uses — "Changes (3)" there, "Git (3)" here. Nothing to
    /// commit means nothing to say, so a clean tree drops the count entirely.
    func setChangeCount(_ count: Int) {
        guard let button = buttons.indices.contains(Action.git.rawValue)
            ? buttons[Action.git.rawValue] : nil else { return }
        button.badge = count > 0 ? "\(count)" : nil
    }

    var buttonTitlesForTesting: [String] { buttons.map(\.displayTitleForTesting) }
    var buttonTooltipsForTesting: [String?] { buttons.map(\.toolTip) }

    func setSelected(_ action: Action?) {
        for (i, b) in buttons.enumerated() {
            b.isSelected = (action?.rawValue == i)
        }
    }
}

/// Flat text button with an edge-to-edge background when selected. The label is
/// the whole affordance, so there is no tooltip to explain an icon.
final class ActivityButton: NSView {
    /// Flipped like every other drawn view here, so the shared text and badge
    /// drawing lands where it does everywhere else.
    override var isFlipped: Bool { true }
    var onClick: (() -> Void)?
    var isSelected = false { didSet { needsDisplay = true } }

    private let title: String
    /// Appended after the label, e.g. the number of changed files.
    var badge: String? {
        didSet {
            guard badge != oldValue else { return }
            setAccessibilityLabel(displayTitle)
            needsDisplay = true
        }
    }
    private var displayTitle: String { badge.map { "\(title) \($0)" } ?? title }

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }

    var displayTitleForTesting: String { displayTitle }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            Theme.selectedControl.setFill()
            bounds.fill()
        }
        // Label and badge are centred as one unit, and the badge sits on the
        // label's own line. Truncates rather than overflowing into the
        // neighbouring slot when the panel is dragged narrow.
        let font = Theme.uiFont(10.5)
        let ink = isSelected ? Theme.selectedControlText : Theme.dimText
        let content = bounds.insetBy(dx: 4, dy: 0)
        SidebarCellDrawing.attributedText(
            SidebarCellDrawing.labelWithBadge(
                title, badge: badge ?? "", font: font, colour: ink,
                badgeBackground: Theme.activeRow, badgeForeground: Theme.foreground,
                alignment: .center),
            in: content)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

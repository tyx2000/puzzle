import AppKit

/// Zed's bottom-left action bar: a 40pt row spanning the panel width with four
/// evenly-spaced buttons (project, search, git, settings). The button for the
/// visible panel gets a white rounded background.
final class ActivityBarView: NSView {
    static let height: CGFloat = 40

    enum Action: Int, CaseIterable { case project, search, git, settings }

    /// Called with the tapped action. The host decides whether to show that
    /// panel or, if it's already showing, collapse the sidebar.
    var onAction: ((Action) -> Void)?

    private var buttons: [ActivityButton] = []

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

        let specs: [(Action, String, String)] = [
            (.project, "sidebar.left", "Project panel"),
            (.search, "magnifyingglass", "Search"),
            (.git, "arrow.triangle.branch", "Git"),
            (.settings, "gearshape", "Settings"),
        ]
        buttons = specs.map { action, symbol, tip in
            let b = ActivityButton(symbol: symbol, tip: tip)
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
        let inset: CGFloat = 4
        let height = bounds.height - inset * 2 - 1   // -1 for the top border
        let slot = bounds.width / CGFloat(buttons.count)
        for (i, b) in buttons.enumerated() {
            b.frame = NSRect(x: (slot * CGFloat(i)).rounded(), y: inset,
                             width: slot.rounded(), height: height)
        }
    }

    func setSelected(_ action: Action?) {
        for (i, b) in buttons.enumerated() {
            b.isSelected = (action?.rawValue == i)
        }
    }
}

/// Flat icon button with a white rounded background when selected.
final class ActivityButton: NSView {
    var onClick: (() -> Void)?
    var isSelected = false { didSet { needsDisplay = true; updateTint() } }

    private let imageView = NSImageView()

    init(symbol: String, tip: String) {
        super.init(frame: .zero)
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        imageView.imageScaling = .scaleProportionallyDown
        addSubview(imageView)
        toolTip = tip
        updateTint()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func updateTint() {
        imageView.contentTintColor = isSelected ? Theme.foreground : Theme.dimText
    }

    override func layout() {
        super.layout()
        // Icon stays a fixed size, centered in the (wider) clickable slot.
        let size: CGFloat = 16
        imageView.frame = NSRect(x: (bounds.width - size) / 2,
                                 y: (bounds.height - size) / 2,
                                 width: size, height: size)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        Theme.activeTab.setFill()   // white in light, editor bg in dark
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 0), xRadius: 6, yRadius: 6).fill()
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTint(); needsDisplay = true
    }
}

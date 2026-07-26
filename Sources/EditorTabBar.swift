import AppKit

/// Zed-style floating pill tabs. Tabs wrap onto extra rows when they don't fit;
/// the active tab is a plain white pill with no border. The split button is
/// pinned at the top-right.
final class EditorTabBar: NSView {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onSplit: (() -> Void)?

    var splitActive = false {
        didSet { splitButton.contentTintColor = splitActive ? Theme.cursor : Theme.dimText }
    }
    var paneActive = true { didSet { needsDisplay = true } }

    struct TabInfo {
        let title: String
        let modified: Bool
    }

    private var pills: [TabPillView] = []
    private let splitButton = NSButton()
    private let rowHeight: CGFloat = 28
    private let gap: CGFloat = 6
    private let padding: CGFloat = 8
    private let splitAreaWidth: CGFloat = 34
    private var contentHeight: CGFloat = 44

    /// Rows are laid out top-down.
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        splitButton.image = NSImage(systemSymbolName: "rectangle.split.2x1",
                                    accessibilityDescription: "Split editor")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        splitButton.isBordered = false
        splitButton.bezelStyle = .regularSquare
        splitButton.imageScaling = .scaleProportionallyDown
        splitButton.contentTintColor = Theme.dimText
        splitButton.toolTip = "Split editor"
        splitButton.target = self
        splitButton.action = #selector(splitAction)
        splitButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(splitButton)
        NSLayoutConstraint.activate([
            splitButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            splitButton.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            splitButton.widthAnchor.constraint(equalToConstant: 22),
            splitButton.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        Theme.barBackground.setFill()
        bounds.fill()
        Theme.border.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func reload(tabs: [TabInfo], active: Int) {
        pills.forEach { $0.removeFromSuperview() }
        pills = tabs.enumerated().map { index, tab in
            let pill = TabPillView()
            pill.configure(title: tab.title, modified: tab.modified, active: index == active)
            pill.onSelect = { [weak self] in self?.onSelect?(index) }
            pill.onClose = { [weak self] in self?.onClose?(index) }
            addSubview(pill)
            return pill
        }
        needsLayout = true
        layoutPills()
    }

    override func layout() {
        super.layout()
        layoutPills()
    }

    private func layoutPills() {
        let available = max(80, bounds.width - splitAreaWidth - padding)
        var x = padding
        var y = padding
        var rows = 1
        for pill in pills {
            let width = min(pill.preferredWidth, available - padding)
            if x + width > available, x > padding {
                x = padding
                y += rowHeight + gap
                rows += 1
            }
            pill.frame = NSRect(x: x, y: y, width: width, height: rowHeight)
            x += width + gap
        }
        let height = padding * 2 + CGFloat(rows) * rowHeight + CGFloat(rows - 1) * gap
        if abs(height - contentHeight) > 0.5 {
            contentHeight = height
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: max(44, contentHeight))
    }

    @objc private func splitAction() { onSplit?() }
}

/// One floating pill tab. Active = white pill, no border.
final class TabPillView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var active = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.lineBreakMode = .byTruncatingTail
        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.image = NSImage(systemSymbolName: "xmark",
                                    accessibilityDescription: "Close tab")?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.target = self
        closeButton.action = #selector(closeAction)
        addSubview(label)
        addSubview(closeButton)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, modified: Bool, active: Bool) {
        self.active = active
        label.stringValue = modified ? "\(title) ●" : title
        label.font = Theme.uiFont(11.5)
        label.textColor = active ? Theme.foreground : Theme.dimText
        closeButton.contentTintColor = active ? Theme.foreground : Theme.dimText
        needsDisplay = true
        needsLayout = true
    }

    var preferredWidth: CGFloat {
        let textWidth = label.attributedStringValue.size().width
        return 12 + ceil(textWidth) + 8 + 14 + 10
    }

    override func layout() {
        super.layout()
        let mid = (bounds.height - 14) / 2
        closeButton.frame = NSRect(x: bounds.width - 22, y: mid, width: 14, height: 14)
        label.frame = NSRect(x: 12, y: (bounds.height - 16) / 2,
                             width: max(0, bounds.width - 12 - 26), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Floating pill: white when active, transparent otherwise. No border.
        guard active else { return }
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        Theme.activeTab.setFill()
        path.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // Reliable click handling (gesture recognizers inside a scroll view were
    // swallowing clicks, so tabs could not be switched).
    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    @objc private func closeAction() { onClose?() }
}

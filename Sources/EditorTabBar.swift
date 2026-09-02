import AppKit

/// Flat file tabs. Each row follows the owning window's traffic-light geometry;
/// tabs wrap onto rows of that same height when they do not fit.
final class EditorTabBar: NSView {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onCloseOthers: ((Int) -> Void)?
    var onCloseRight: ((Int) -> Void)?
    var onHeightChanged: ((CGFloat) -> Void)?


    var paneActive = true { didSet { needsDisplay = true } }

    struct TabInfo {
        let title: String
        let modified: Bool
        /// Full file path, shown as the tab's hover tooltip.
        let path: String
    }

    private var pills: [TabPillView] = []
    /// Fallback until the owning window reports its traffic-light geometry.
    static let defaultRowHeight: CGFloat = 32
    private(set) var rowHeight: CGFloat = EditorTabBar.defaultRowHeight
    private let gap: CGFloat = 0
    private let padding: CGFloat = 0
    /// Space kept clear on the right for the window's own actions, which are
    /// drawn over this bar by the editor container so they survive an empty
    /// window with no tabs at all.
    static let actionAreaWidth: CGFloat = 34
    private var contentHeight: CGFloat = EditorTabBar.defaultRowHeight

    /// Rows are laid out top-down.
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)


    }

    required init?(coder: NSCoder) { fatalError() }

    func setRowHeight(_ height: CGFloat) {
        let resolved = max(20, height)
        guard abs(resolved - rowHeight) > 0.5 else { return }
        let rows = max(1, Int(round(contentHeight / rowHeight)))
        rowHeight = resolved
        contentHeight = CGFloat(rows) * rowHeight + CGFloat(rows - 1) * gap
        invalidateIntrinsicContentSize()
        needsLayout = true
        layoutPills()
        onHeightChanged?(currentHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.barBackground.setFill()
        bounds.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    static var selectedColoursForTesting: (surface: NSColor, ink: NSColor) {
        (Theme.selectedControl, Theme.selectedControlText)
    }

    func reload(tabs: [TabInfo], active: Int) {
        while pills.count > tabs.count {
            pills.removeLast().removeFromSuperview()
        }
        while pills.count < tabs.count {
            let pill = TabPillView()
            addSubview(pill)
            pills.append(pill)
        }
        for (index, tab) in tabs.enumerated() {
            let pill = pills[index]
            pill.configure(title: tab.title, modified: tab.modified,
                           active: index == active, path: tab.path)
            pill.onSelect = { [weak self] in self?.onSelect?(index) }
            pill.onClose = { [weak self] in self?.onClose?(index) }
            pill.onCloseOthers = { [weak self] in self?.onCloseOthers?(index) }
            pill.onCloseRight = { [weak self] in self?.onCloseRight?(index) }
            // Nothing to close: only tab open / already the last tab.
            pill.canCloseOthers = tabs.count > 1
            pill.canCloseRight = index < tabs.count - 1
        }
        needsLayout = true
        layoutPills()
    }

    override func layout() {
        super.layout()
        layoutPills()
    }

    private func layoutPills() {
        let available = max(80, bounds.width - Self.actionAreaWidth - padding)
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
            onHeightChanged?(max(rowHeight, height))
        }
    }

    var currentHeight: CGFloat { max(rowHeight, contentHeight) }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: max(rowHeight, contentHeight))
    }

}

/// One flat tab. Active = full-height background, no border or outer gap.
final class TabPillView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onCloseOthers: (() -> Void)?
    var onCloseRight: (() -> Void)?

    /// Drive the context menu's enabled state — set by the tab bar on reload.
    var canCloseOthers = false
    var canCloseRight = false

    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var active = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.lineBreakMode = .byTruncatingTail
        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.image = Theme.symbol("xmark", accessibilityDescription: "Close tab",
                                         pointSize: 8, weight: .semibold)
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.target = self
        closeButton.action = #selector(closeAction)
        addSubview(label)
        addSubview(closeButton)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, modified: Bool, active: Bool, path: String) {
        self.active = active
        label.stringValue = modified ? "\(title) ●" : title
        label.font = Theme.uiFont(11.5)
        // The open file reads like the selected item everywhere else does: its
        // own surface and its own ink. The rest stay legible rather than
        // greyed, so the strip does not look half-disabled.
        label.textColor = active ? Theme.selectedControlText : Theme.foreground
        closeButton.contentTintColor = active ? Theme.selectedControlText : Theme.foreground
        toolTip = path
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
        guard active else { return }
        Theme.selectedControl.setFill()
        bounds.fill()
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

    // Built per right-click rather than assigned to `menu` once, so the
    // enabled state always reflects the tab list as it is right now.
    override func menu(for event: NSEvent) -> NSMenu? {
        let close = NSMenuItem(title: "Close",
                               action: #selector(closeAction), keyEquivalent: "")
        let others = NSMenuItem(title: "Close Others",
                                action: #selector(closeOthersAction), keyEquivalent: "")
        let right = NSMenuItem(title: "Close Tabs to the Right",
                               action: #selector(closeRightAction), keyEquivalent: "")
        others.isEnabled = canCloseOthers
        right.isEnabled = canCloseRight

        let menu = NSMenu()
        // Without this AppKit re-derives enablement and ignores isEnabled above.
        menu.autoenablesItems = false
        for item in [close, others, right] { item.target = self }
        menu.items = [close, .separator(), others, right]
        return menu
    }

    @objc private func closeAction() { onClose?() }
    @objc private func closeOthersAction() { onCloseOthers?() }
    @objc private func closeRightAction() { onCloseRight?() }
}

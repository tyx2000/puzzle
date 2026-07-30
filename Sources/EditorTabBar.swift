import AppKit

/// Flat file tabs. Tabs wrap onto extra 36-point rows when they do not fit; the
/// active tab uses the same edge-to-edge background rule as the action bar.
final class EditorTabBar: NSView {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onCloseOthers: ((Int) -> Void)?
    var onCloseRight: ((Int) -> Void)?
    var onSplit: (() -> Void)?
    var onTogglePreview: (() -> Void)?

    var splitActive = false {
        didSet { splitButton.contentTintColor = splitActive ? Theme.cursor : Theme.dimText }
    }

    /// The preview button only makes sense for markdown, so it appears per-file.
    var showsPreviewToggle = false {
        didSet {
            guard showsPreviewToggle != oldValue else { return }
            previewButton.isHidden = !showsPreviewToggle
            needsLayout = true
            layoutPills()
        }
    }
    var previewActive = false {
        didSet { previewButton.contentTintColor = previewActive ? Theme.cursor : Theme.dimText }
    }
    var paneActive = true { didSet { needsDisplay = true } }

    struct TabInfo {
        let title: String
        let modified: Bool
    }

    private var pills: [TabPillView] = []
    private let splitButton = NSButton()
    private let previewButton = NSButton()
    /// Shared with the sidebar's titlebar clearance so both surfaces start on
    /// the same horizontal rhythm.
    static let rowHeight: CGFloat = 36
    private let gap: CGFloat = 0
    private let padding: CGFloat = 0
    /// Space reserved on the right for the action buttons — grows when the
    /// markdown preview toggle is showing, so pills never slide underneath it.
    private var splitAreaWidth: CGFloat { showsPreviewToggle ? 60 : 34 }
    private var contentHeight: CGFloat = 36

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
            splitButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            splitButton.widthAnchor.constraint(equalToConstant: 22),
            splitButton.heightAnchor.constraint(equalToConstant: 20),
        ])

        previewButton.image = NSImage(systemSymbolName: "eye",
                                      accessibilityDescription: "Toggle markdown preview")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        previewButton.isBordered = false
        previewButton.bezelStyle = .regularSquare
        previewButton.imageScaling = .scaleProportionallyDown
        previewButton.contentTintColor = Theme.dimText
        previewButton.toolTip = "Toggle markdown preview"
        previewButton.target = self
        previewButton.action = #selector(previewAction)
        previewButton.isHidden = true
        previewButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(previewButton)
        NSLayoutConstraint.activate([
            previewButton.trailingAnchor.constraint(equalTo: splitButton.leadingAnchor,
                                                    constant: -6),
            previewButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            previewButton.widthAnchor.constraint(equalToConstant: 22),
            previewButton.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        Theme.barBackground.setFill()
        bounds.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
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
            pill.configure(title: tab.title, modified: tab.modified, active: index == active)
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
        let available = max(80, bounds.width - splitAreaWidth - padding)
        var x = padding
        var y = padding
        var rows = 1
        for pill in pills {
            let width = min(pill.preferredWidth, available - padding)
            if x + width > available, x > padding {
                x = padding
                y += Self.rowHeight + gap
                rows += 1
            }
            pill.frame = NSRect(x: x, y: y, width: width, height: Self.rowHeight)
            x += width + gap
        }
        let height = padding * 2 + CGFloat(rows) * Self.rowHeight + CGFloat(rows - 1) * gap
        if abs(height - contentHeight) > 0.5 {
            contentHeight = height
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: max(36, contentHeight))
    }

    @objc private func splitAction() { onSplit?() }
    @objc private func previewAction() { onTogglePreview?() }
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

    func configure(title: String, modified: Bool, active: Bool) {
        self.active = active
        label.stringValue = modified ? "\(title) ●" : title
        label.font = Theme.uiFont(11.5)
        // Selection is communicated solely by the active tab surface. Keeping
        // the foreground stable avoids making inactive file names look disabled.
        label.textColor = Theme.foreground
        closeButton.contentTintColor = Theme.foreground
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
        Theme.activeTab.setFill()
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

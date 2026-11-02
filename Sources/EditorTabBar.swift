import AppKit

/// Flat file tabs. Each row follows the owning window's traffic-light geometry;
/// tabs wrap onto rows of that same height when they do not fit.
final class EditorTabBar: NSView {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onCloseOthers: ((Int) -> Void)?
    var onCloseRight: ((Int) -> Void)?
    var onCloseAll: (() -> Void)?


    var paneActive = true { didSet { needsDisplay = true } }

    struct TabInfo {
        let title: String
        let modified: Bool
        /// Full file path, shown as the tab's hover tooltip.
        let path: String
    }

    private var pills: [TabPillView] = []
    /// The open tab is framed rather than filled, and the frame moves to the
    /// tab chosen next, as the sidebar's moves to its row.
    private let openFrame = OpenFrameMarker()
    /// Room for the frame's band round its line, inside the tab.
    static let frameInset = NSSize(width: 4, height: 4)
    private var activeIndex = -1
    /// The open tab as the frame knows it: a tab that only moved, because
    /// one before it closed, is not a new tab to move to.
    private var activeTab: String?
    private var framedTab: String?
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
    /// Room kept at the start of the first row for what stands over it once
    /// the sidebar is away: the traffic lights and the sidebar's toggle. Set
    /// inside the sidebar's slide, the tabs move with it.
    var leadingInset: CGFloat = 0 {
        didSet {
            guard leadingInset != oldValue else { return }
            needsLayout = true
            layoutPills()
        }
    }

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
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.barBackground.setFill()
        bounds.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        openFrame.refreshColour()
    }

    var titlesForTesting: [String] { pills.map(\.titleForTesting) }
    var tabFramesForTesting: [NSRect] { pills.map(\.frame) }
    /// Where the open tab's frame is, its line, in this view's coordinates.
    var openFrameRectForTesting: NSRect? { openFrame.isHidden ? nil : openFrame.rect }
    var openFrameShownRectForTesting: NSRect { openFrame.line.frame }

    func reload(tabs: [TabInfo], active: Int) {
        while pills.count > tabs.count {
            pills.removeLast().removeFromSuperview()
        }
        while pills.count < tabs.count {
            let pill = TabPillView()
            addSubview(pill)
            pills.append(pill)
        }
        activeIndex = active
        activeTab = tabs.indices.contains(active) ? tabs[active].title + "\n" + tabs[active].path : nil
        for (index, tab) in tabs.enumerated() {
            let pill = pills[index]
            pill.configure(title: tab.title, modified: tab.modified,
                           active: index == active, path: tab.path)
            pill.onSelect = { [weak self] in self?.onSelect?(index) }
            pill.onClose = { [weak self] in self?.onClose?(index) }
            pill.onCloseOthers = { [weak self] in self?.onCloseOthers?(index) }
            pill.onCloseRight = { [weak self] in self?.onCloseRight?(index) }
            pill.onCloseAll = { [weak self] in self?.onCloseAll?() }
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
        var rowStart = padding + leadingInset
        var x = rowStart
        var y = padding
        var rows = 1
        for pill in pills {
            let width = min(pill.preferredWidth, available - padding)
            if x + width > available, x > rowStart {
                rowStart = padding
                x = rowStart
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
        placeOpenFrame()
    }

    /// Over the open tab: moved there when another tab has been chosen, and
    /// simply kept on it when the tabs only moved round it.
    private func placeOpenFrame() {
        guard pills.indices.contains(activeIndex) else {
            openFrame.isHidden = true
            framedTab = nil
            return
        }
        openFrame.raise(in: self)
        let target = pills[activeIndex].frame.insetBy(dx: Self.frameInset.width,
                                                      dy: Self.frameInset.height)
        let moving = framedTab != nil && framedTab != activeTab
        openFrame.isHidden = false
        if openFrame.rect != target || moving {
            openFrame.place(target, moving: moving)
        }
        framedTab = activeTab
    }

    var currentHeight: CGFloat { max(rowHeight, contentHeight) }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: max(rowHeight, contentHeight))
    }

}

/// One flat tab, the same whether open or not: the open one is framed by the
/// bar.
final class TabPillView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onCloseOthers: (() -> Void)?
    var onCloseRight: (() -> Void)?
    var onCloseAll: (() -> Void)?

    /// Drive the context menu's enabled state — set by the tab bar on reload.
    var canCloseOthers = false
    var canCloseRight = false

    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()

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

    var titleForTesting: String { label.stringValue }

    func configure(title: String, modified: Bool, active: Bool, path: String) {
        label.stringValue = modified ? "\(title) ●" : title
        label.font = Theme.uiFont(11.5)
        // Every tab in the same ink: the frame says which is open, and the
        // rest stay legible rather than greyed.
        label.textColor = Theme.foreground
        closeButton.contentTintColor = Theme.foreground
        setAccessibilitySelected(active)
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
        // Always available: the tab that was right-clicked is itself one to
        // close, so there is never nothing for this to do.
        let all = NSMenuItem(title: "Close All",
                             action: #selector(closeAllAction), keyEquivalent: "")
        others.isEnabled = canCloseOthers
        right.isEnabled = canCloseRight

        let menu = NSMenu()
        // Without this AppKit re-derives enablement and ignores isEnabled above.
        menu.autoenablesItems = false
        for item in [close, others, right, all] { item.target = self }
        // Close All leads the batch group: it is the one that always applies,
        // and the two below it narrow from there.
        menu.items = [close, .separator(), all, others, right]
        return menu
    }

    @objc private func closeAction() { onClose?() }
    @objc private func closeOthersAction() { onCloseOthers?() }
    @objc private func closeRightAction() { onCloseRight?() }
    @objc private func closeAllAction() { onCloseAll?() }

    static func contextMenuTitlesForTesting(canCloseOthers: Bool,
                                            canCloseRight: Bool) -> [String] {
        let pill = TabPillView()
        pill.canCloseOthers = canCloseOthers
        pill.canCloseRight = canCloseRight
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)!
        return pill.menu(for: event)?.items.map(\.title) ?? []
    }
}

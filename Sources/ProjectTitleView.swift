import AppKit

/// The project name and current branch shown beside the traffic lights, the way
/// Zed labels its window. It fills the whole title band, so its text sits on the
/// traffic lights' centre line, and clicking it opens the project folder in
/// Terminal.
final class ProjectTitleView: NSView {
    var onClick: (() -> Void)?

    private var project = ""
    private var branch = ""
    private var isPressed = false

    private static let horizontalPadding: CGFloat = 8
    private static let branchGap: CGFloat = 6
    private static let branchIconWidth: CGFloat = 11

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        // The strip hugs its text and truncates instead of pushing the window
        // layout around when the panel is narrow.
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(project: String, branch: String) {
        guard project != self.project || branch != self.branch else { return }
        let hadProject = !self.project.isEmpty
        self.project = project
        self.branch = branch
        if hadProject != !project.isEmpty { window?.invalidateCursorRects(for: self) }
        toolTip = project.isEmpty ? nil : "Open \(project) in Terminal"
        setAccessibilityLabel(
            branch.isEmpty ? project : "\(project), branch \(branch)")
        setAccessibilityHelp("Opens the project folder in Terminal.")
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    /// Re-measure after a UI font change.
    func refreshAppearance() {
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    private var projectFont: NSFont { Theme.uiFont(11.5) }
    private var branchFont: NSFont { Theme.uiFont(11) }

    override var intrinsicContentSize: NSSize {
        guard !project.isEmpty else { return NSSize(width: 0, height: NSView.noIntrinsicMetric) }
        var width = ceil((project as NSString).size(
            withAttributes: [.font: projectFont]).width)
        if !branch.isEmpty {
            width += Self.branchGap + Self.branchIconWidth + 3
                + ceil((branch as NSString).size(withAttributes: [.font: branchFont]).width)
        }
        return NSSize(width: width + Self.horizontalPadding * 2,
                      height: NSView.noIntrinsicMetric)
    }

    /// A pointer is the only hover feedback — the strip draws no background of
    /// its own, so nothing in the title band moves under the cursor.
    override func resetCursorRects() {
        super.resetCursorRects()
        guard !project.isEmpty else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard !project.isEmpty else { return }
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false
        guard wasPressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !project.isEmpty else { return }
        let content = bounds.insetBy(dx: Self.horizontalPadding, dy: 0)
        guard content.width > 0 else { return }
        // One shared baseline so the smaller branch text sits on the same line
        // as the project name instead of being centered on its own.
        let baseline = SidebarCellDrawing.centeredBaseline(for: projectFont, in: content)
        let projectWidth = min(
            ceil((project as NSString).size(withAttributes: [.font: projectFont]).width),
            content.width)
        SidebarCellDrawing.text(project, font: projectFont, color: Theme.foreground,
                                baseline: baseline,
                                in: NSRect(x: content.minX, y: content.minY,
                                           width: projectWidth, height: content.height))
        guard !branch.isEmpty else { return }
        let iconX = content.minX + projectWidth + Self.branchGap
        let iconRect = NSRect(x: iconX,
                              y: content.midY - Self.branchIconWidth / 2,
                              width: Self.branchIconWidth, height: Self.branchIconWidth)
        guard iconRect.maxX < content.maxX else { return }
        SidebarCellDrawing.image(Theme.symbol("arrow.triangle.branch", pointSize: 10),
                                 tint: Theme.dimText, in: iconRect)
        let branchX = iconRect.maxX + 3
        SidebarCellDrawing.text(branch, font: branchFont, color: Theme.dimText,
                                baseline: baseline,
                                in: NSRect(x: branchX, y: content.minY,
                                           width: max(0, content.maxX - branchX),
                                           height: content.height))
    }

    // MARK: - Regression-test surface

    var titleForTesting: (project: String, branch: String) { (project, branch) }
    var hasClickHandlerForTesting: Bool { onClick != nil }
}

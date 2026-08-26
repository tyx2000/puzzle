import AppKit

/// The project name and current branch shown beside the traffic lights, the way
/// Zed labels its window. It fills the whole title band, so its text sits on the
/// traffic lights' centre line, and clicking it opens the project folder in
/// Terminal.
final class ProjectTitleView: NSView {
    /// Clicking the project name opens the folder in a terminal.
    var onProjectClick: (() -> Void)?
    /// Clicking the branch name asks for the branch menu, anchored under the
    /// branch text (the rect is in this view's coordinates).
    var onBranchClick: ((NSRect) -> Void)?

    private var project = ""
    private var branch = ""
    private enum Zone { case project, branch }
    private var pressedZone: Zone?

    private static let horizontalPadding: CGFloat = 8
    private static let branchGap: CGFloat = 8

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
        toolTip = project.isEmpty ? nil
            : "Click the name to open a terminal here, the branch to switch"
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
            width += Self.branchGap
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
        addCursorRect(projectRect(), cursor: .pointingHand)
        if !branch.isEmpty { addCursorRect(branchRect(), cursor: .pointingHand) }
    }

    /// The two halves are separate targets, so the same text the reader sees is
    /// exactly what they click. Both are derived from one layout pass shared
    /// with `draw`.
    private func layoutZones() -> (project: NSRect, branch: NSRect) {
        let content = bounds.insetBy(dx: Self.horizontalPadding, dy: 0)
        guard content.width > 0, !project.isEmpty else { return (.zero, .zero) }
        let projectWidth = min(
            ceil((project as NSString).size(withAttributes: [.font: projectFont]).width),
            content.width)
        let projectRect = NSRect(x: content.minX, y: content.minY,
                                 width: projectWidth, height: content.height)
        guard !branch.isEmpty else { return (projectRect, .zero) }
        let branchX = projectRect.maxX + Self.branchGap
        guard branchX < content.maxX else { return (projectRect, .zero) }
        let branchWidth = min(
            ceil((branch as NSString).size(withAttributes: [.font: branchFont]).width),
            content.maxX - branchX)
        return (projectRect, NSRect(x: branchX, y: content.minY,
                                    width: branchWidth, height: content.height))
    }

    private func projectRect() -> NSRect { layoutZones().project }
    private func branchRect() -> NSRect { layoutZones().branch }

    private func zone(at point: NSPoint) -> Zone? {
        let zones = layoutZones()
        if !branch.isEmpty, zones.branch.contains(point) { return .branch }
        if zones.project.contains(point) { return .project }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        guard !project.isEmpty else { return }
        pressedZone = zone(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let pressed = pressedZone
        pressedZone = nil
        let point = convert(event.locationInWindow, from: nil)
        guard let pressed, pressed == zone(at: point) else { return }
        switch pressed {
        case .project: onProjectClick?()
        case .branch: onBranchClick?(branchRect())
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !project.isEmpty else { return }
        let zones = layoutZones()
        guard zones.project.width > 0 else { return }
        // One shared baseline so the smaller branch text sits on the same line
        // as the project name instead of being centered on its own.
        let baseline = SidebarCellDrawing.centeredBaseline(for: projectFont, in: zones.project)
        SidebarCellDrawing.text(project, font: projectFont, color: Theme.foreground,
                                baseline: baseline, in: zones.project)
        guard zones.branch.width > 0 else { return }
        SidebarCellDrawing.text(branch, font: branchFont, color: Theme.dimText,
                                baseline: baseline, in: zones.branch,
                                lineBreak: .byTruncatingHead)
    }

    // MARK: - Regression-test surface

    var titleForTesting: (project: String, branch: String) { (project, branch) }
    var hasClickHandlerForTesting: Bool { onProjectClick != nil && onBranchClick != nil }
    var zonesForTesting: (project: NSRect, branch: NSRect) { layoutZones() }
    func zoneNameForTesting(at point: NSPoint) -> String? {
        switch zone(at: point) {
        case .project: return "project"
        case .branch: return "branch"
        case nil: return nil
        }
    }
}

import AppKit

/// The strip above a git diff: which file the diff belongs to on the left, and
/// the controls that step through its changes on the right.
final class DiffHeaderView: FlatView {
    /// How a diff is laid out. The choice sticks for the session, so switching
    /// files does not switch back.
    enum Mode {
        case unified, sideBySide

        var next: Mode { self == .unified ? .sideBySide : .unified }
        /// The icon shows what clicking it gives you.
        var symbol: String {
            self == .unified ? "rectangle.split.2x1" : "rectangle"
        }
        var label: String {
            self == .unified ? "Show side by side" : "Show as one file"
        }
    }

    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onToggleMode: (() -> Void)?

    static let height: CGFloat = 28

    private let previousButton = DiffHeaderButton()
    private let nextButton = DiffHeaderButton()
    private let modeButton = DiffHeaderButton()
    private var mode: Mode = .unified
    private var folder = ""
    private var name = ""
    private var summary = ""

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        fillColor = Theme.barBackground
        bottomBorder = true
        configure(button: previousButton, symbol: "chevron.up",
                  label: "Previous change", action: #selector(previousAction))
        configure(button: nextButton, symbol: "chevron.down",
                  label: "Next change", action: #selector(nextAction))
        configure(button: modeButton, symbol: mode.symbol,
                  label: mode.label, action: #selector(modeAction))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func configure(button: DiffHeaderButton, symbol: String,
                           label: String, action: Selector) {
        button.image = Theme.symbol(symbol, accessibilityDescription: label,
                                    pointSize: 11, weight: .medium)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.bezelStyle = .inline
        button.isBordered = false
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.target = self
        button.action = action
        addSubview(button)
    }

    /// `path` is repository-relative; `changes` is how many separate blocks of
    /// added/removed lines the buffer holds, which decides whether stepping
    /// through them is possible at all.
    func configure(path: String, changes: Int) {
        folder = (path as NSString).deletingLastPathComponent
        name = (path as NSString).lastPathComponent
        summary = changes == 1 ? "1 change" : "\(changes) changes"
        previousButton.isEnabled = changes > 0
        nextButton.isEnabled = changes > 0
        toolTip = path
        setAccessibilityLabel("\(path), \(summary)")
        needsDisplay = true
    }

    /// Reflect the mode the caller settled on, without firing the callback.
    func setMode(_ mode: Mode) {
        guard mode != self.mode else { return }
        self.mode = mode
        modeButton.image = Theme.symbol(mode.symbol, accessibilityDescription: mode.label,
                                        pointSize: 11, weight: .medium)
        modeButton.toolTip = mode.label
        modeButton.setAccessibilityLabel(mode.label)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        // Wider than the glyph: a 20pt target for an 11pt chevron was a poke,
        // and the hover background needs room to read as a button.
        let width: CGFloat = 30
        let height: CGFloat = 22
        let y = floor((bounds.height - height) / 2)
        // Mode last, past the stepping controls it applies to.
        modeButton.frame = NSRect(x: max(0, bounds.width - 6 - width), y: y,
                                  width: width, height: height)
        nextButton.frame = NSRect(x: max(0, modeButton.frame.minX - 6 - width), y: y,
                                  width: width, height: height)
        previousButton.frame = NSRect(x: max(0, nextButton.frame.minX - width), y: y,
                                      width: width, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let font = Theme.uiFont(11)
        let summaryFont = Theme.uiFont(10)
        let baseline = SidebarCellDrawing.centeredBaseline(for: font, in: bounds)
        let summaryWidth = summary.isEmpty ? 0
            : ceil((summary as NSString).size(withAttributes: [.font: summaryFont]).width) + 10
        let right = max(0, previousButton.frame.minX - 6 - summaryWidth)
        if !summary.isEmpty {
            SidebarCellDrawing.text(summary, font: summaryFont, color: Theme.dimText,
                                    baseline: baseline,
                                    in: NSRect(x: right, y: 0,
                                               width: summaryWidth, height: bounds.height),
                                    alignment: .right)
        }
        // The folder is context; the file name is what the reader is looking for,
        // so it keeps full contrast and the path truncates from the head.
        let separator = folder.isEmpty ? "" : folder + "/"
        let nameWidth = ceil((name as NSString).size(withAttributes: [.font: font]).width)
        let folderWidth = max(0, right - 10 - nameWidth)
        SidebarCellDrawing.text(separator, font: font, color: Theme.dimText,
                                baseline: baseline,
                                in: NSRect(x: 10, y: 0, width: folderWidth, height: bounds.height),
                                lineBreak: .byTruncatingHead)
        let measured = min(folderWidth,
                           ceil((separator as NSString).size(withAttributes: [.font: font]).width))
        SidebarCellDrawing.text(name, font: font, color: Theme.foreground,
                                baseline: baseline,
                                in: NSRect(x: 10 + measured, y: 0,
                                           width: max(0, right - 10 - measured),
                                           height: bounds.height),
                                lineBreak: .byTruncatingMiddle)
    }

    /// Re-read the theme colours captured when the strip was built.
    func refreshAppearance() {
        fillColor = Theme.barBackground
        needsDisplay = true
    }

    @objc private func modeAction() { onToggleMode?() }
    @objc private func previousAction() { onPrevious?() }
    @objc private func nextAction() { onNext?() }

    // MARK: - Regression-test surface

    var pathForTesting: String { folder.isEmpty ? name : "\(folder)/\(name)" }
    var modeForTesting: Mode { mode }
    func hoverNextForTesting() { nextButton.setHoveredForTesting(true) }
    var buttonFramesForTesting: [NSRect] {
        [previousButton.frame, nextButton.frame, modeButton.frame]
    }
    var modeLabelForTesting: String? { modeButton.toolTip }
    func toggleModeForTesting() { onToggleMode?() }
    var summaryForTesting: String { summary }
    var stepControlsEnabledForTesting: Bool { nextButton.isEnabled && previousButton.isEnabled }
    func clickNextForTesting() { onNext?() }
    func clickPreviousForTesting() { onPrevious?() }
}

/// A borderless icon button that shows a rounded hover background, so the strip
/// tells you where it can be clicked before you click it.
final class DiffHeaderButton: NSButton {
    private var isHovered = false
    private var hoverTracking: NSTrackingArea?

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
        guard isEnabled else { return }
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered, isEnabled {
            Theme.hover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    var isHoveredForTesting: Bool { isHovered }
    func setHoveredForTesting(_ hovered: Bool) {
        isHovered = hovered
        needsDisplay = true
    }
}

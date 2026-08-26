import AppKit

/// The strip above a git diff: which file the diff belongs to on the left, and
/// the controls that step through its changes on the right.
final class DiffHeaderView: FlatView {
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?

    static let height: CGFloat = 28

    private let previousButton = NSButton()
    private let nextButton = NSButton()
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
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func configure(button: NSButton, symbol: String,
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

    override func layout() {
        super.layout()
        let side: CGFloat = 20
        let y = floor((bounds.height - side) / 2)
        nextButton.frame = NSRect(x: max(0, bounds.width - 8 - side), y: y,
                                  width: side, height: side)
        previousButton.frame = NSRect(x: max(0, nextButton.frame.minX - 2 - side), y: y,
                                      width: side, height: side)
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

    @objc private func previousAction() { onPrevious?() }
    @objc private func nextAction() { onNext?() }

    // MARK: - Regression-test surface

    var pathForTesting: String { folder.isEmpty ? name : "\(folder)/\(name)" }
    var summaryForTesting: String { summary }
    var stepControlsEnabledForTesting: Bool { nextButton.isEnabled && previousButton.isEnabled }
    func clickNextForTesting() { onNext?() }
    func clickPreviousForTesting() { onPrevious?() }
}

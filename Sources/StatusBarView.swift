import AppKit

/// Zed-style full-width bottom bar: activity buttons (project panel, search,
/// git, outline, settings) on the left; branch · cursor · language on the right.
final class StatusBarView: NSView {
    var onProjectPanel: (() -> Void)?
    var onSearch: (() -> Void)?
    var onGit: (() -> Void)?
    var onOutline: (() -> Void)?
    var onSettings: (() -> Void)?

    private let branchLabel = NSTextField(labelWithString: "")
    private let cursorLabel = NSTextField(labelWithString: "")
    private let langLabel = NSTextField(labelWithString: "")

    override func draw(_ dirtyRect: NSRect) {
        Theme.barBackground.setFill()
        bounds.fill()
        Theme.border.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()  // top border
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let activity = NSStackView(views: [
            iconButton("sidebar.left", "Project panel", #selector(projectAction)),
            iconButton("magnifyingglass", "Search", #selector(searchAction)),
            iconButton("arrow.triangle.branch", "Git", #selector(gitAction)),
            iconButton("list.bullet.indent", "Outline", #selector(outlineAction)),
            iconButton("gearshape", "Settings", #selector(settingsAction)),
        ])
        activity.orientation = .horizontal
        activity.spacing = 14
        activity.translatesAutoresizingMaskIntoConstraints = false

        for label in [branchLabel, cursorLabel, langLabel] {
            label.font = Theme.uiFont(10.5)
            label.textColor = Theme.dimText
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        let right = NSStackView(views: [branchLabel, cursorLabel, langLabel])
        right.orientation = .horizontal
        right.spacing = 16
        right.translatesAutoresizingMaskIntoConstraints = false

        addSubview(activity)
        addSubview(right)
        NSLayoutConstraint.activate([
            activity.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            activity.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        let b = NSButton()
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(config)
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.imageScaling = .scaleProportionallyDown
        b.contentTintColor = Theme.dimText
        b.toolTip = tip
        b.target = self
        b.action = action
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 20).isActive = true
        b.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return b
    }

    @objc private func projectAction() { onProjectPanel?() }
    @objc private func searchAction() { onSearch?() }
    @objc private func gitAction() { onGit?() }
    @objc private func outlineAction() { onOutline?() }
    @objc private func settingsAction() { onSettings?() }

    func setBranch(_ branch: String?) {
        branchLabel.stringValue = branch.map { " \($0)" } ?? ""
    }
    func setCursor(line: Int, column: Int) {
        cursorLabel.stringValue = "Ln \(line), Col \(column)"
    }
    func setLanguage(_ name: String) {
        langLabel.stringValue = name
    }
}

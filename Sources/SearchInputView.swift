import AppKit

/// A flat, rounded search field with Aa / wd / .* toggles on the right.
/// No focus ring — focus is shown by a subtle border tint instead.
/// Used by both the project search panel and the in-file find bar.
final class SearchInputView: NSView, NSTextFieldDelegate {
    var onChange: ((String, SearchOptions) -> Void)?
    var onSubmit: ((String, SearchOptions) -> Void)?
    var onCancel: (() -> Void)?

    /// Set the toggles programmatically (⌥⌘F seeding, tests).
    func setOptions(_ newOptions: SearchOptions) { options = newOptions }

    private(set) var options = SearchOptions() {
        didSet {
            guard options != oldValue else { return }
            onChange?(stringValue, options)
        }
    }

    private let field = NSTextField()
    private let clearButton = ClearButton()
    private var toggles: [GlyphToggle] = []
    private var optionStack: NSStackView!
    private var fieldToOptions: NSLayoutConstraint!
    private var fieldToEdge: NSLayoutConstraint!
    private var focused = false

    /// Inline file-tree editors reuse the same chrome without search options.
    var showsOptions = true {
        didSet {
            guard optionStack != nil else { return }
            optionStack.isHidden = !showsOptions
            fieldToOptions.isActive = showsOptions
            fieldToEdge.isActive = !showsOptions
        }
    }

    var stringValue: String {
        get { field.stringValue }
        set {
            field.stringValue = newValue
            updateClearButton()
        }
    }
    var placeholder: String = "" {
        didSet { field.placeholderAttributedString = placeholderString(placeholder) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none          // no ugly focus ring
        field.isBezeled = false
        field.delegate = self
        field.font = Theme.uiFont(12)
        field.textColor = Theme.foreground
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        field.setContentHuggingPriority(.init(1), for: .horizontal)
        addSubview(field)

        toggles = [
            GlyphToggle(glyph: "Aa", underlined: false, tip: "Match case"),
            GlyphToggle(glyph: "wd", underlined: true, tip: "Whole word"),
            GlyphToggle(glyph: ".*", underlined: false, tip: "Regular expression"),
        ]
        toggles[0].onToggle = { [weak self] on in self?.options.caseSensitive = on }
        toggles[1].onToggle = { [weak self] on in self?.options.wholeWord = on }
        toggles[2].onToggle = { [weak self] on in self?.options.regex = on }

        clearButton.onClick = { [weak self] in self?.clear() }

        // First in the row of trailing controls, so it sits right after the
        // text it clears. A stack view collapses it when it is hidden, which an
        // ordinary constraint would not — the field takes the room back.
        optionStack = NSStackView(views: [clearButton] + toggles)
        optionStack.orientation = .horizontal
        optionStack.spacing = 8
        optionStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(optionStack)

        fieldToOptions = field.trailingAnchor.constraint(
            equalTo: optionStack.leadingAnchor, constant: -8)
        fieldToEdge = field.trailingAnchor.constraint(
            equalTo: trailingAnchor, constant: -10)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            fieldToOptions,
            optionStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            optionStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateClearButton()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func placeholderString(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: Theme.uiFont(12), .foregroundColor: Theme.dimText,
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7)
        Theme.inputBackground.setFill()
        path.fill()
        (focused ? Theme.inputBorderFocused : Theme.inputBorder).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func focus(selectAll: Bool = false) {
        guard let window else { return }
        window.makeKey()
        // `selectText` creates the field editor if needed. A bare
        // makeFirstResponder call can leave focus on the window when this view
        // has just been inserted into an outline row from a context menu.
        field.selectText(nil)
        if window.firstResponder !== field.currentEditor() {
            window.makeFirstResponder(field)
        }
        if selectAll { field.currentEditor()?.selectAll(nil) }
    }

    /// Empty the query the way the Escape key does, without closing anything.
    func clear() {
        guard !field.stringValue.isEmpty else { return }
        field.stringValue = ""
        updateClearButton()
        onChange?("", options)
        focus()
    }

    /// Nothing to clear, nothing to show: the button appears with the text.
    private func updateClearButton() {
        let shouldShow = !field.stringValue.isEmpty
        guard clearButton.isHidden == shouldShow else { return }
        clearButton.isHidden = !shouldShow
    }

    func refreshFonts() {
        field.font = Theme.uiFont(12)
        field.placeholderAttributedString = placeholderString(placeholder)
        toggles.forEach { $0.needsDisplay = true }
        needsDisplay = true
    }

    var showsClearButtonForTesting: Bool { !clearButton.isHidden }
    func clickClearForTesting() { clearButton.performClickForTesting() }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        updateClearButton()
        onChange?(field.stringValue, options)
    }
    func controlTextDidBeginEditing(_ obj: Notification) { focused = true; needsDisplay = true }
    func controlTextDidEndEditing(_ obj: Notification) { focused = false; needsDisplay = true }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onSubmit?(field.stringValue, options); return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?(); return true
        default:
            return false
        }
    }
}

/// The round ✕ inside a search field. Drawn rather than an NSButton so it can
/// carry the same hover treatment as the glyph toggles beside it.
private final class ClearButton: NSView {
    /// Like every other drawn view here — the shared drawing helpers assume it.
    override var isFlipped: Bool { true }
    var onClick: (() -> Void)?
    private var hovered = false
    private var tracking: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        isHidden = true
        toolTip = "Clear"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Clear search")
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 16).isActive = true
        heightAnchor.constraint(equalToConstant: 18).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow,
                                            .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    func performClickForTesting() { onClick?() }
    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Drawn rather than an SF Symbol: the disc has to read at 13pt against
        // the field's own background, and the cross is cut out of it in that
        // background colour so it stays crisp at any size.
        let side: CGFloat = 13
        let box = NSRect(x: floor((bounds.width - side) / 2),
                         y: floor((bounds.height - side) / 2),
                         width: side, height: side)
        (hovered ? Theme.foreground : Theme.dimText).setFill()
        NSBezierPath(ovalIn: box).fill()

        let arm = box.insetBy(dx: 4, dy: 4)
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: arm.minX, y: arm.minY))
        cross.line(to: NSPoint(x: arm.maxX, y: arm.maxY))
        cross.move(to: NSPoint(x: arm.maxX, y: arm.minY))
        cross.line(to: NSPoint(x: arm.minX, y: arm.maxY))
        cross.lineWidth = 1.5
        cross.lineCapStyle = .round
        Theme.inputBackground.setStroke()
        cross.stroke()
    }
}

/// A small text glyph that toggles on click (Aa / wd / .*).
private final class GlyphToggle: NSView {
    var onToggle: ((Bool) -> Void)?
    private let glyph: String
    private let underlined: Bool
    private var isOn = false

    init(glyph: String, underlined: Bool, tip: String) {
        self.glyph = glyph
        self.underlined = underlined
        super.init(frame: .zero)
        toolTip = tip
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 20).isActive = true
        heightAnchor.constraint(equalToConstant: 18).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        isOn.toggle()
        needsDisplay = true
        onToggle?(isOn)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isOn {
            Theme.toggleActiveBackground.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        var attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.uiFont(11),
            .foregroundColor: isOn ? Theme.foreground : Theme.dimText,
        ]
        if underlined { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        let text = glyph as NSString
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                              y: (bounds.height - size.height) / 2),
                  withAttributes: attrs)
    }
}

import AppKit

/// Search options toggled by the Aa / wd / .* glyphs.
struct SearchOptions: Equatable {
    var caseSensitive = false
    var wholeWord = false
    var regex = false
}

/// A flat, rounded search field with Aa / wd / .* toggles on the right.
/// No focus ring — focus is shown by a subtle border tint instead.
/// Used by both the project search panel and the in-file find bar.
final class SearchInputView: NSView, NSTextFieldDelegate {
    var onChange: ((String, SearchOptions) -> Void)?
    var onSubmit: ((String, SearchOptions) -> Void)?
    var onCancel: (() -> Void)?

    private(set) var options = SearchOptions() {
        didSet {
            guard options != oldValue else { return }
            onChange?(stringValue, options)
        }
    }

    private let field = NSTextField()
    private var toggles: [GlyphToggle] = []
    private var focused = false

    var stringValue: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
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

        let stack = NSStackView(views: toggles)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.trailingAnchor.constraint(equalTo: stack.leadingAnchor, constant: -8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
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

    func focus() {
        window?.makeFirstResponder(field)
    }

    func refreshFonts() {
        field.font = Theme.uiFont(12)
        field.placeholderAttributedString = placeholderString(placeholder)
        toggles.forEach { $0.needsDisplay = true }
        needsDisplay = true
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
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

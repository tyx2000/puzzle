import AppKit

/// Centred message shown in place of the editor when a file has no contents to
/// display — a binary, something too large to lay out, a file that would not
/// read, an EPS with no preview inside it.
///
/// These buffers hold an explanation rather than any of the file's bytes, and
/// showing an explanation through the text view made it look like a document
/// that happened to say so: numbered from line 1 in the gutter, ranged against
/// the left margin, with a caret in it. Centring it is what makes it read as
/// the editor talking rather than as a file.
final class PlaceholderView: FlatView {
    private let headingLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        fillColor = Theme.editorBackground

        headingLabel.alignment = .center
        headingLabel.lineBreakMode = .byTruncatingMiddle
        headingLabel.translatesAutoresizingMaskIntoConstraints = false

        bodyLabel.alignment = .center
        bodyLabel.maximumNumberOfLines = 0
        bodyLabel.lineBreakMode = .byWordWrapping
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(headingLabel)
        addSubview(bodyLabel)

        // The pair is centred as a unit: the heading sits above the midpoint by
        // half the body's height, so the block as a whole is centred rather
        // than the heading being centred and the body hanging below it.
        let group = NSLayoutGuide()
        addLayoutGuide(group)
        NSLayoutConstraint.activate([
            headingLabel.topAnchor.constraint(equalTo: group.topAnchor),
            headingLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            headingLabel.leadingAnchor.constraint(greaterThanOrEqualTo: group.leadingAnchor),
            headingLabel.trailingAnchor.constraint(lessThanOrEqualTo: group.trailingAnchor),

            bodyLabel.topAnchor.constraint(equalTo: headingLabel.bottomAnchor, constant: 10),
            bodyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            bodyLabel.leadingAnchor.constraint(equalTo: group.leadingAnchor),
            bodyLabel.trailingAnchor.constraint(equalTo: group.trailingAnchor),
            bodyLabel.bottomAnchor.constraint(equalTo: group.bottomAnchor),

            group.centerXAnchor.constraint(equalTo: centerXAnchor),
            group.centerYAnchor.constraint(equalTo: centerYAnchor),
            group.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            group.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),
            // Wrapping at full window width would put a sentence of
            // explanation on one very long line.
            group.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
        ])
        applyFonts()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The messages are written as a title, a blank line, then the detail. The
    /// split is on that blank line, so a message that has no detail simply
    /// shows a title and nothing else.
    func show(message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.components(separatedBy: "\n\n")
        headingLabel.stringValue = parts.first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? trimmed
        // Paragraphs after the title keep their own breaks; the hard wraps the
        // message was written with do not survive, because the label wraps to
        // whatever width the pane gives it.
        bodyLabel.stringValue = parts.dropFirst()
            .map { $0.replacingOccurrences(of: "\n", with: " ")
                     .trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        bodyLabel.isHidden = bodyLabel.stringValue.isEmpty
        toolTip = trimmed
    }

    func clear() {
        headingLabel.stringValue = ""
        bodyLabel.stringValue = ""
        toolTip = nil
    }

    private func applyFonts() {
        let base = Theme.uiFont(13)
        headingLabel.font = NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(.bold),
                                   size: base.pointSize) ?? base
        headingLabel.textColor = Theme.foreground
        bodyLabel.font = Theme.uiFont(11.5)
        bodyLabel.textColor = Theme.dimText
    }

    func refreshFonts() {
        fillColor = Theme.editorBackground
        applyFonts()
        needsDisplay = true
    }

    /// The box the two labels actually occupy, which is what has to sit in the
    /// middle of the view.
    var contentFrameForTesting: NSRect {
        bodyLabel.isHidden ? headingLabel.frame : headingLabel.frame.union(bodyLabel.frame)
    }
    var headingForTesting: String { headingLabel.stringValue }
    var bodyForTesting: String { bodyLabel.stringValue }
}

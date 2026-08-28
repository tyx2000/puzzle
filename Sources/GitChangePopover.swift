import AppKit

/// The little diff that opens when a gutter mark is clicked: what the lines
/// were, what they are now, in the colours the diff tabs use.
final class GitChangePopoverController: NSViewController {
    private let change: GitLineChanges.Change
    private let textView = NSTextView()
    private let scroll = NSScrollView()

    init(change: GitLineChanges.Change) {
        self.change = change
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let container = FlatView()
        container.fillColor = Theme.editorBackground

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

PuzzleScroller.adopt(scroll)
                scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        render()
    }

    private func render() {
        let body = NSMutableAttributedString()
        let font = Theme.editorFont()
        func append(_ text: String, _ colour: NSColor) {
            body.append(NSAttributedString(string: text + "\n",
                                           attributes: [.font: font, .foregroundColor: colour]))
        }
        let heading: String
        switch change.kind {
        case .added: heading = change.lines.count == 1
            ? "Line \(change.lines.lowerBound) added"
            : "Lines \(change.lines.lowerBound)–\(change.lines.upperBound) added"
        case .modified: heading = change.lines.count == 1
            ? "Line \(change.lines.lowerBound) modified"
            : "Lines \(change.lines.lowerBound)–\(change.lines.upperBound) modified"
        case .deleted: heading = change.removed.count == 1
            ? "1 line deleted above line \(change.lines.lowerBound)"
            : "\(change.removed.count) lines deleted above line \(change.lines.lowerBound)"
        }
        body.append(NSAttributedString(
            string: heading + "\n",
            attributes: [.font: Theme.uiFont(10.5), .foregroundColor: Theme.dimText]))
        for line in change.removed { append("- " + line, Theme.diffRemovedText) }
        for line in change.added { append("+ " + line, Theme.diffAddedText) }
        textView.textStorage?.setAttributedString(body)
    }

    /// Size the popover to its content, within limits that keep it a popover.
    var preferredSize: NSSize {
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let used = textView.layoutManager?.usedRect(for: textView.textContainer!).size
            ?? NSSize(width: 320, height: 80)
        return NSSize(width: min(max(320, used.width + 24), 720),
                      height: min(max(60, used.height + 20), 320))
    }

    var contentForTesting: String { textView.string }
}

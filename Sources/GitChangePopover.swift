import AppKit

/// The little diff that opens when a gutter mark is clicked: what the lines
/// were, what they are now, in the colours the diff tabs use.
final class GitChangePopoverController: NSViewController {
    private let change: GitLineChanges.Change
    private let textView = NSTextView()
    private let scroll = NSScrollView()
    private let revert = NSButton()
    /// NSPopover sizes itself from the content view's fitting size whenever
    /// that view uses Auto Layout, and ignores `contentSize` when it does. The
    /// scroll view has no intrinsic size of its own, so without these the
    /// popover collapses to whatever the Revert button alone needs — which is
    /// how the diff came to open as an empty sliver.
    private var widthConstraint: NSLayoutConstraint!
    private var heightConstraint: NSLayoutConstraint!

    /// What the button does: put these lines back the way HEAD has them.
    var onRevert: (() -> Void)?
    /// Hidden for a read-only buffer — a diff tab, an unsupported file — where
    /// there is nothing the button could put back.
    var canRevert = false

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
        textView.textContainerInset = NSSize(width: Self.padding, height: Self.padding)
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

        revert.title = "Revert"
        revert.bezelStyle = .inline
        revert.isBordered = false
        revert.font = Theme.uiFont(11)
        revert.contentTintColor = Theme.blue
        revert.target = self
        revert.action = #selector(revertClicked)
        revert.isHidden = !canRevert
        revert.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(revert)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: canRevert
                ? revert.topAnchor : container.bottomAnchor),
            // Under the first character of the diff, not off in the corner:
            // the button belongs to the lines above it. Its margins are the
            // text's own inset, so the padding is the same on all four sides.
            revert.leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                            constant: Self.padding),
            revert.bottomAnchor.constraint(equalTo: container.bottomAnchor,
                                           constant: -Self.padding),
        ])
        view = container
        widthConstraint = container.widthAnchor.constraint(equalToConstant: 320)
        heightConstraint = container.heightAnchor.constraint(equalToConstant: 80)
        NSLayoutConstraint.activate([widthConstraint, heightConstraint])
        render()
    }

    @objc private func revertClicked() { onRevert?() }

    /// Room for the button under the diff, when there is one: the button plus
    /// the margin below it. The gap *above* it is the text view's own bottom
    /// inset, which is the same `padding` again.
    private var footerHeight: CGFloat {
        canRevert ? ceil(revert.fittingSize.height) + Self.padding : 0
    }

    /// One number for every edge: the text's inset, the button's margins, and
    /// the gap between them.
    static let padding: CGFloat = 8

    /// Narrow enough to fit a short change, wide enough to stay a popover —
    /// and to hold the heading and the Revert button.
    static let minimumWidth: CGFloat = 170

    private func render() {
        let body = NSMutableAttributedString()
        let font = Theme.editorFont()
        // A trailing newline would give the layout manager an empty final line
        // fragment to place, which the popover then has to be tall enough to
        // hold: a blank row above the button that the top edge has no twin for.
        // Lines are separated instead of terminated.
        func newline() {
            guard body.length > 0 else { return }
            body.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        }
        func append(_ marker: String, _ line: String, _ colour: NSColor) {
            newline()
            body.append(NSAttributedString(
                string: marker + " ", attributes: [.font: font, .foregroundColor: colour]))
            // A blank line has nothing to print, and a popover holding a lone
            // "+" reads as one that failed to load. Name the line instead.
            let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
            body.append(NSAttributedString(
                string: blank ? (line.isEmpty ? "(blank line)" : "(whitespace only)") : line,
                attributes: [.font: blank ? Theme.uiFont(10.5) : font,
                             .foregroundColor: blank ? Theme.dimText : colour]))
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
            string: heading,
            attributes: [.font: Theme.uiFont(10.5), .foregroundColor: Theme.dimText]))
        for line in change.removed { append("-", line, Theme.diffRemovedText) }
        for line in change.added { append("+", line, Theme.diffAddedText) }
        textView.textStorage?.setAttributedString(body)
    }

    /// Size the popover to its content, within limits that keep it a popover.
    ///
    /// The answer is also written into the view's own constraints: it is the
    /// fitting size that NSPopover actually obeys.
    var preferredSize: NSSize {
        _ = view
        guard textView.textContainer != nil, textView.layoutManager != nil else {
            return NSSize(width: 320, height: 80)
        }
        // The width comes from the text itself, not from the layout manager:
        // the container tracks the text view, so `usedRect` would report
        // whatever width the view happens to have rather than what the lines
        // need. A one-word change gets a one-word popover; only a genuinely
        // long line pushes out to the cap.
        let inset = textView.textContainerInset.width * 2
        let natural = textView.attributedString().boundingRect(
            with: NSSize(width: 10_000, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let width = min(max(Self.minimumWidth, ceil(natural.width) + inset + 4), 720)
        // Height is asked of the layout manager that will do the drawing, with
        // the container held at the chosen width. `boundingRect` answers a few
        // points taller than the text view lays the same string out, and that
        // difference shows up as a gap above the button that the top edge does
        // not have. Width tracking is off for the measurement only: it would
        // otherwise snap the container back to the unsized text view.
        let container = textView.textContainer!
        let tracking = container.widthTracksTextView
        container.widthTracksTextView = false
        container.size = NSSize(width: width - inset, height: CGFloat.greatestFiniteMagnitude)
        textView.layoutManager?.ensureLayout(for: container)
        let wrapped = textView.layoutManager?.usedRect(for: container)
            ?? NSRect(x: 0, y: 0, width: width, height: 40)
        container.widthTracksTextView = tracking
        // The text view's insets are the top and bottom padding, so the content
        // height is the text plus exactly those: any slack on top of it shows
        // as a gap that the top edge does not have.
        let size = NSSize(width: width,
                          height: min(ceil(wrapped.height) + inset, 320) + footerHeight)
        widthConstraint.constant = size.width
        heightConstraint.constant = size.height
        preferredContentSize = size
        return size
    }

    var contentForTesting: String { textView.string }
    var revertButtonForTesting: NSButton { revert }
}

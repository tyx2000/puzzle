import AppKit

/// The little diff that opens when a gutter mark is clicked: what the lines
/// were, what they are now, in the colours the diff tabs use.
final class GitChangePopoverController: NSViewController {
    private let change: GitLineChanges.Change
    private let textView = NSTextView()
    private let scroll = NSScrollView()
    private let revert = NSButton()
    /// The scroll view has no intrinsic size; explicit constraints keep the
    /// diff content and its containing panel at the same dimensions.
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
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                 height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]

        PuzzleScroller.adopt(scroll)
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
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
        preferredSize(forWidth: 320)
    }

    /// Match the visible code area, independent of the changed line's length.
    /// Long lines retain their horizontal scrollbar inside this fixed width.
    func preferredSize(forWidth width: CGFloat, maximumHeight: CGFloat = 320) -> NSSize {
        _ = view
        guard let container = textView.textContainer,
              let layoutManager = textView.layoutManager else {
            return NSSize(width: width, height: min(80, maximumHeight))
        }
        let inset = textView.textContainerInset.width * 2
        layoutManager.ensureLayout(for: container)
        let natural = layoutManager.usedRect(for: container)
        // The text view's insets are the top and bottom padding, so the content
        // height is the text plus exactly those: any slack on top of it shows
        // as a gap that the top edge does not have.
        let size = NSSize(width: max(1, width),
                          height: max(1, min(ceil(natural.height) + inset + footerHeight,
                                            maximumHeight)))
        widthConstraint.constant = size.width
        heightConstraint.constant = size.height
        preferredContentSize = size
        return size
    }

    var contentForTesting: String { textView.string }
    var textViewForTesting: NSTextView { textView }
    var scrollViewForTesting: NSScrollView { scroll }
    var revertButtonForTesting: NSButton { revert }
}

/// A square child panel avoids NSPopover's compulsory arrow and rounded frame.
/// It can become key for text selection without taking the editor's main window.
final class GitChangePanel: NSPanel {
    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    init(controller: GitChangePopoverController) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = true
        backgroundColor = Theme.editorBackground
        hasShadow = true
        hidesOnDeactivate = true
        becomesKeyOnlyIfNeeded = true
        contentViewController = controller
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show(below anchor: NSRect, codeArea: NSRect, in owner: NSWindow) {
        guard let controller = contentViewController as? GitChangePopoverController,
              codeArea.width > 0, codeArea.height > 0 else { return }
        let size = controller.preferredSize(forWidth: codeArea.width,
                                            maximumHeight: min(320, codeArea.height))
        var y = anchor.minY - size.height
        if y < codeArea.minY { y = anchor.maxY }
        y = min(max(y, codeArea.minY), codeArea.maxY - size.height)
        setFrame(NSRect(x: codeArea.minX, y: y, width: size.width, height: size.height),
                 display: false)
        owner.addChildWindow(self, ordered: .above)
        orderFront(nil)
        contentView?.layoutSubtreeIfNeeded()
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 {
                    self.close()
                    return nil
                }
            } else if event.window !== self {
                self.close()
            }
            return event
        }
        let center = NotificationCenter.default
        for name in [NSWindow.willCloseNotification, NSWindow.didResizeNotification] {
            observers.append(center.addObserver(forName: name, object: owner, queue: .main) {
                [weak self] _ in self?.close()
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification,
                                             object: nil, queue: .main) {
            [weak self] _ in self?.close()
        })
    }

    override func cancelOperation(_ sender: Any?) { close() }

    override func close() {
        stopMonitoring()
        parent?.removeChildWindow(self)
        orderOut(nil)
    }

    private func stopMonitoring() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    deinit { stopMonitoring() }
}

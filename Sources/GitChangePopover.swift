import AppKit

/// The little diff that opens when a gutter mark is clicked: what the lines
/// were, what they are now, in the colours the diff tabs use.
final class GitChangePopoverController: NSViewController {
    let change: GitLineChanges.Change
    private let textView = NSTextView()
    private let scroll = NSScrollView()
    private let revert = PointerButton()
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
        let container = GitChangeSurfaceView()
        container.accent = change.colour

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
            // Right of the stripe, so text scrolled sideways never runs over it.
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                            constant: GitChangeSurfaceView.accentWidth),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            // The button keeps clear of the last line of the diff: under the
            // text's own inset alone it sat against the code it acts on.
            scroll.bottomAnchor.constraint(equalTo: canRevert
                ? revert.topAnchor : container.bottomAnchor,
                constant: canRevert ? -Self.buttonGap : 0),
            // Under the first character of the diff, not off in the corner:
            // the button belongs to the lines above it. Its margins are the
            // text's own inset, so the padding is the same on all four sides.
            revert.leadingAnchor.constraint(equalTo: scroll.leadingAnchor,
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

    /// Room for the button under the diff, when there is one: the button, the
    /// margin below it, and `buttonGap` above it — on top of the text view's
    /// own bottom inset, which is the same `padding` again.
    private var footerHeight: CGFloat {
        canRevert ? ceil(revert.fittingSize.height) + Self.padding + Self.buttonGap : 0
    }

    /// Between the diff and the button, beyond the text's own inset.
    static let buttonGap: CGFloat = 6

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

/// The diff's surface: a step lighter than the code it is laid over, an edge
/// along the top and bottom where it meets the code, and down the left the
/// colour of the change — the mark that was clicked to open it. Laid edge to
/// edge over the code in the code's own colour, it read as more code.
final class GitChangeSurfaceView: NSView {
    var accent: NSColor = Theme.raisedEdge { didSet { needsDisplay = true } }
    static let accentWidth: CGFloat = 3

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.raisedSurface.setFill()
        bounds.fill()
        accent.setFill()
        NSRect(x: 0, y: 0, width: Self.accentWidth, height: bounds.height).fill()
        Theme.raisedEdge.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

/// A square child panel avoids NSPopover's compulsory arrow and rounded frame.
/// It can become key for text selection without taking the editor's main window.
///
/// It moves rather than blinks: it unfolds from the edge beside the change it
/// shows, folds back there when put away, and when another change in the file
/// is clicked it flows to that one, growing or shrinking to its height, as the
/// one panel. The gutter's join follows it frame by frame.
final class GitChangePanel: NSPanel {
    /// Told when the panel goes, whatever put it away.
    var onClose: (() -> Void)?
    /// Told on every frame of a transition, for whatever is drawn against
    /// the panel's position — the gutter's join.
    var onFrameChange: (() -> Void)?
    /// A click the panel should not take as a click outside it: one on
    /// another change's mark, which moves the panel there instead.
    var ignoresClick: ((NSEvent) -> Bool)?

    private(set) var controller: GitChangePopoverController
    private let clip = GitChangeClipView()
    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var ticker: Timer?
    /// Folding away: still on screen, already gone as far as anything asks.
    private(set) var isClosing = false
    /// Below the change, or above it when there was no room below — the
    /// edge it unfolds from and folds back to.
    private var opensDownward = true

    static let appearDuration: TimeInterval = 0.18
    static let moveDuration: TimeInterval = 0.22
    static let disappearDuration: TimeInterval = 0.14

    init(controller: GitChangePopoverController) {
        self.controller = controller
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = true
        backgroundColor = Theme.raisedSurface
        hasShadow = true
        hidesOnDeactivate = true
        becomesKeyOnlyIfNeeded = true
        // The diff sits in a clip the window's frame can animate freely: its
        // own layout keeps it at full size, and the clip shows as much of it
        // as the window has unfolded.
        contentView = clip
        clip.show(controller.view)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var isShown: Bool { isVisible && !isClosing }

    /// Where the diff for `anchor` goes: across the code, under the change
    /// or, without room there, over it.
    private func target(for anchor: NSRect, codeArea: NSRect,
                        size: NSSize) -> (frame: NSRect, downward: Bool) {
        var y = anchor.minY - size.height
        var downward = true
        if y < codeArea.minY {
            y = anchor.maxY
            downward = false
        }
        y = min(max(y, codeArea.minY), codeArea.maxY - size.height)
        return (NSRect(x: codeArea.minX, y: y, width: size.width, height: size.height), downward)
    }

    /// The frame folded flat against the edge nearest the change.
    private func folded(_ frame: NSRect) -> NSRect {
        NSRect(x: frame.minX, y: opensDownward ? frame.maxY : frame.minY,
               width: frame.width, height: 0)
    }

    static var reducesMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func show(below anchor: NSRect, codeArea: NSRect, in owner: NSWindow) {
        guard codeArea.width > 0, codeArea.height > 0 else { return }
        let size = controller.preferredSize(forWidth: codeArea.width,
                                            maximumHeight: min(320, codeArea.height))
        let placed = target(for: anchor, codeArea: codeArea, size: size)
        opensDownward = placed.downward
        clip.anchorsToBottom = !placed.downward
        clip.contentSize = size
        isClosing = false
        let reduce = Self.reducesMotion
        setFrame(reduce ? placed.frame : folded(placed.frame), display: false)
        alphaValue = 0
        owner.addChildWindow(self, ordered: .above)
        orderFront(nil)
        startMonitoring(owner)
        animate(duration: Self.appearDuration) {
            if !reduce { self.animator().setFrame(placed.frame, display: true) }
            self.animator().alphaValue = 1
        }
    }

    /// Another change of the same file: the same panel flows there, its
    /// height going to the new diff's.
    func move(to controller: GitChangePopoverController, below anchor: NSRect, codeArea: NSRect) {
        guard codeArea.width > 0, codeArea.height > 0 else { return }
        self.controller = controller
        let size = controller.preferredSize(forWidth: codeArea.width,
                                            maximumHeight: min(320, codeArea.height))
        let placed = target(for: anchor, codeArea: codeArea, size: size)
        opensDownward = placed.downward
        clip.anchorsToBottom = !placed.downward
        clip.contentSize = size
        clip.show(controller.view)
        isClosing = false
        if Self.reducesMotion {
            setFrame(placed.frame, display: true)
            onFrameChange?()
            animate(duration: Self.appearDuration) { self.animator().alphaValue = 1 }
            return
        }
        animate(duration: Self.moveDuration) {
            self.animator().setFrame(placed.frame, display: true)
            self.animator().alphaValue = 1
        }
    }

    /// Put away by the reader — Esc, a click elsewhere: folded back to the
    /// change and faded, then gone.
    func dismiss() {
        guard isVisible, !isClosing else { return }
        isClosing = true
        stopMonitoring()
        let reduce = Self.reducesMotion
        let flat = folded(frame)
        animate(duration: Self.disappearDuration, completion: { [weak self] in
            guard let self, self.isClosing else { return }
            self.finish()
        }) {
            if !reduce { self.animator().setFrame(flat, display: true) }
            self.animator().alphaValue = 0
        }
    }

    override func cancelOperation(_ sender: Any?) { dismiss() }

    /// Gone at once — the document changed, or scrolled out from under it.
    override func close() {
        isClosing = true
        finish()
    }

    private func finish() {
        stopTicking()
        stopMonitoring()
        parent?.removeChildWindow(self)
        orderOut(nil)
        alphaValue = 1
        isClosing = false
        let closed = onClose
        onClose = nil
        closed?()
    }

    private func animate(duration: TimeInterval, completion: (() -> Void)? = nil,
                         _ changes: @escaping () -> Void) {
        startTicking(for: duration)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            changes()
        }, completionHandler: completion)
    }

    /// What is drawn against the panel follows it on every frame of a
    /// transition, and once more when it ends.
    private func startTicking(for duration: TimeInterval) {
        stopTicking()
        let ends = Date().addingTimeInterval(duration + 0.05)
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            self?.onFrameChange?()
            if Date() >= ends { timer.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
        onFrameChange?()
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    private func startMonitoring(_ owner: NSWindow) {
        stopMonitoring()
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 {
                    self.dismiss()
                    return nil
                }
            } else if event.window !== self, self.ignoresClick?(event) != true {
                self.dismiss()
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

    private func stopMonitoring() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    deinit {
        stopMonitoring()
        ticker?.invalidate()
    }
}

/// The panel's content view: the diff at its own full size, shown as far as
/// the window has unfolded — from the top when the panel opens downward,
/// from the bottom when it opens upward, so what shows first is the side
/// nearest the change.
final class GitChangeClipView: NSView {
    var contentSize: NSSize = .zero { didSet { needsLayout = true } }
    var anchorsToBottom = false { didSet { needsLayout = true } }
    private weak var shown: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func show(_ view: NSView) {
        if shown !== view {
            shown?.removeFromSuperview()
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
            shown = view
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        guard let shown else { return }
        let size = contentSize == .zero ? bounds.size : contentSize
        shown.frame = NSRect(x: 0, y: anchorsToBottom ? bounds.height - size.height : 0,
                             width: size.width, height: size.height)
    }
}

/// A borderless button that shows the hand under the pointer — which a
/// borderless button otherwise does not, leaving nothing to say it can be
/// clicked but its colour.
final class PointerButton: NSButton {
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: PointerCursor.trackingOptions,
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    var trackingOptionsForTesting: NSTrackingArea.Options? { tracking?.options }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }
    override func cursorUpdate(with event: NSEvent) {
        if isEnabled { PointerCursor.enter() } else { super.cursorUpdate(with: event) }
    }
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if isEnabled { PointerCursor.enter() }
    }
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if isEnabled { PointerCursor.enter() }
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        PointerCursor.leave(self, event: event)
    }
}

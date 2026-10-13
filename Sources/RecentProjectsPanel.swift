import AppKit

/// What the R button opens: a dialog over the window, "Opened Recently",
/// listing the recent projects as the start page lists them — a click ticks
/// one, a double click opens it, the cross on a hovered row takes it off the
/// list — with Open Checked at the top right and Clear All along the bottom.
/// Esc closes it, and so does a click anywhere outside it, or leaving the app.
///
/// A panel like the ⌘P palette rather than a popover: a dialog of its own,
/// not a balloon hanging off the button. The window under it is dimmed while
/// it is up — it is the same colour as the dialog, and a heavy border and
/// shadow were what told them apart before — and a click on the dimmed
/// window only closes the dialog; it does not reach what is under it.
final class RecentProjectsPanel: NSPanel {
    /// The projects to open: one double-clicked, or every ticked one.
    var onOpen: (([URL]) -> Void)?

    static let width: CGFloat = 640
    static let padding: CGFloat = 18
    /// Room around the card for its shadow, inside the panel's own window.
    static let shadowMargin: CGFloat = 32
    static let minimumListHeight: CGFloat = 240
    static let maximumListHeight: CGFloat = 440
    static let title = "Opened Recently"

    private let backdrop = DialogBackdropView()
    /// Over the window under the dialog while it is up. A view in that
    /// window rather than a window of its own, so it has the window's own
    /// rounded corners and size.
    private let scrim = DialogScrimView()
    private var parentResizeObserver: NSObjectProtocol?
    /// Fading out: still on screen, already gone as far as anything asks.
    private var closing = false
    static let appearDuration: TimeInterval = 0.15
    static let disappearDuration: TimeInterval = 0.1
    private let card = NSView()
    private let titleLabel = NSTextField(labelWithString: RecentProjectsPanel.title)
    private let openChecked = NSButton()
    private let separator = FlatView()
    private let footerRule = FlatView()
    private let scroll = NSScrollView()
    private let list = RecentProjectsListView()
    private let empty = NSTextField(labelWithString: "No Recent Projects")
    private let clearAll = DialogRowButton(title: "Clear All")
    private var listHeight: NSLayoutConstraint!
    private var recentsObserver: NSObjectProtocol?
    private var eventMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    init() {
        // Borderless: a titled panel keeps its title bar, invisible or not,
        // over the top of the content, where it took the first row's clicks.
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width + Self.shadowMargin * 2,
                                       height: 400),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        // Gone for good when the app is left, not hidden to come back with it.
        hidesOnDeactivate = false
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        // The shadow is drawn: the window's own is a faint line on a dark
        // window, and did not tell the dialog from what is under it.
        hasShadow = false
        isReleasedWhenClosed = false

        titleLabel.font = NSFontManager.shared.convert(Theme.uiFont(13), toHaveTrait: .boldFontMask)
        titleLabel.textColor = Theme.foreground
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        openChecked.title = "Open Checked"
        openChecked.bezelStyle = .rounded
        openChecked.font = Theme.uiFont(12)
        openChecked.target = self
        openChecked.action = #selector(openCheckedClicked)
        openChecked.isEnabled = false
        openChecked.translatesAutoresizingMaskIntoConstraints = false

        separator.fillColor = Theme.border
        separator.translatesAutoresizingMaskIntoConstraints = false
        footerRule.fillColor = Theme.border
        footerRule.translatesAutoresizingMaskIntoConstraints = false

        list.translatesAutoresizingMaskIntoConstraints = false
        list.onOpen = { [weak self] url in self?.open([url]) }
        list.onCheckedChange = { [weak self] in self?.updateButtons() }
        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        PuzzleScroller.adopt(scroll)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        empty.font = Theme.uiFont(12)
        empty.textColor = Theme.dimText
        empty.translatesAutoresizingMaskIntoConstraints = false

        clearAll.onClick = { RecentProjects.shared.clear() }
        clearAll.translatesAutoresizingMaskIntoConstraints = false

        card.translatesAutoresizingMaskIntoConstraints = false
        for view in [titleLabel, openChecked, separator, scroll, empty, footerRule,
                     clearAll] as [NSView] {
            card.addSubview(view)
        }
        backdrop.addSubview(card)
        let padding = Self.padding
        let margin = Self.shadowMargin
        listHeight = scroll.heightAnchor.constraint(equalToConstant: Self.minimumListHeight)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: margin),
            card.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -margin),
            card.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: margin),
            card.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -margin),
            card.widthAnchor.constraint(equalToConstant: Self.width),

            // What it is, top left; the one thing to do with what is ticked,
            // top right.
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: padding),
            titleLabel.centerYAnchor.constraint(equalTo: openChecked.centerYAnchor),
            openChecked.topAnchor.constraint(equalTo: card.topAnchor, constant: padding - 4),
            openChecked.trailingAnchor.constraint(equalTo: card.trailingAnchor,
                                                  constant: -padding),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: openChecked.leadingAnchor,
                                                 constant: -12),

            separator.topAnchor.constraint(equalTo: openChecked.bottomAnchor, constant: 10),
            separator.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: padding),
            separator.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -padding),
            separator.heightAnchor.constraint(equalToConstant: 1),

            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: padding - 6),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -(padding - 6)),
            listHeight,
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor),

            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),

            // The list's last row, the whole width of it, under a rule that
            // ties it to the list however few projects are above it.
            footerRule.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            footerRule.leadingAnchor.constraint(equalTo: separator.leadingAnchor),
            footerRule.trailingAnchor.constraint(equalTo: separator.trailingAnchor),
            footerRule.heightAnchor.constraint(equalToConstant: 1),
            clearAll.topAnchor.constraint(equalTo: footerRule.bottomAnchor, constant: 6),
            clearAll.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            clearAll.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            clearAll.heightAnchor.constraint(equalToConstant: DialogRowButton.height),
            clearAll.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -padding),
        ])
        backdrop.wantsLayer = true
        contentView = backdrop
        scrim.onClick = { [weak self] in self?.dismissByClickOutside() }
        recentsObserver = NotificationCenter.default.addObserver(
            forName: RecentProjects.didChange, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isVisible else { return }
            self.reload()
        }
    }

    deinit {
        if let recentsObserver { NotificationCenter.default.removeObserver(recentsObserver) }
        if let parentResizeObserver {
            NotificationCenter.default.removeObserver(parentResizeObserver)
        }
        stopWatching()
    }

    override var canBecomeKey: Bool { true }

    var isShown: Bool { isVisible && !closing }

    /// In the middle of `parent`, over everything in it, the rest of `parent`
    /// dimmed. It fades in, the card growing the last few percent to its size.
    func present(over parent: NSWindow) {
        if closing { finishClosing() }
        reload()
        center(over: parent)
        if let content = parent.contentView {
            scrim.frame = content.bounds
            scrim.autoresizingMask = [.width, .height]
            scrim.alphaValue = 0
            content.addSubview(scrim)
        }
        parentResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: parent,
            queue: .main) { [weak self, weak parent] _ in
            guard let self, let parent else { return }
            self.center(over: parent)
        }
        alphaValue = 0
        parent.addChildWindow(self, ordered: .above)
        makeKeyAndOrderFront(nil)
        startWatching()
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let bounds = backdrop.bounds
            var grown = CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0)
            grown = CATransform3DScale(grown, 0.97, 0.97, 1)
            grown = CATransform3DTranslate(grown, -bounds.midX, -bounds.midY, 0)
            let grow = CABasicAnimation(keyPath: "transform")
            grow.fromValue = grown
            grow.toValue = CATransform3DIdentity
            grow.duration = Self.appearDuration
            grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
            backdrop.layer?.add(grow, forKey: "appear")
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.appearDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
            self.scrim.animator().alphaValue = 1
        }
    }

    private func center(over parent: NSWindow) {
        let parentFrame = parent.frame
        var frame = self.frame
        frame.origin.x = (parentFrame.midX - frame.width / 2).rounded()
        frame.origin.y = (parentFrame.midY - frame.height / 2).rounded()
        setFrame(frame, display: isVisible)
    }

    /// Put away, whatever the reason: faded out with the dimming, then gone.
    func dismiss() {
        guard isVisible, !closing else { return }
        closing = true
        stopWatching()
        if let parentResizeObserver {
            NotificationCenter.default.removeObserver(parentResizeObserver)
        }
        parentResizeObserver = nil
        // The keyboard goes back to the window the dialog was over.
        parent?.makeKey()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.disappearDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
            self.scrim.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.closing else { return }
            self.finishClosing()
        })
    }

    private func finishClosing() {
        parent?.removeChildWindow(self)
        orderOut(nil)
        scrim.removeFromSuperview()
        alphaValue = 1
        closing = false
    }

    private func dismissByClickOutside() {
        guard isShown else { return }
        dismiss()
    }

    /// Losing the keyboard — to another of the app's windows, say — is
    /// leaving the dialog.
    override func resignKey() {
        super.resignKey()
        guard !closing else { return }
        dismissByClickOutside()
    }

    /// And in case the dialog never had the keyboard to lose: the app's own
    /// clicks and keys while it is up, and the app being left.
    private func startWatching() {
        stopWatching()
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil,
            queue: .main) { [weak self] _ in self?.dismissByClickOutside() }
    }

    private func stopWatching() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    /// A click outside closes it. On the dimmed window — or the shadow
    /// round the card — that is all it does; in another of the app's windows,
    /// which is not dimmed, it still lands where it was aimed. Esc closes it
    /// and goes no further; anything else passes.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard isShown else { return event }
        if event.type == .keyDown {
            guard event.keyCode == 53 else { return event }
            dismiss()
            return nil
        }
        if event.window === self {
            guard !card.frame.contains(backdrop.convert(event.locationInWindow, from: nil))
            else { return event }
            dismissByClickOutside()
            return nil
        }
        let dimmed = event.window != nil && event.window === parent
        dismissByClickOutside()
        return dimmed ? nil : event
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            dismiss()
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { dismiss() }

    private func reload() {
        list.reload()
        empty.isHidden = !list.arrangedSubviews.isEmpty
        list.layoutSubtreeIfNeeded()
        listHeight.constant = min(Self.maximumListHeight,
                                  max(Self.minimumListHeight, list.fittingSize.height))
        updateButtons()
        backdrop.layoutSubtreeIfNeeded()
        let size = backdrop.fittingSize
        var frame = self.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        setFrame(frame, display: isVisible)
    }

    private func updateButtons() {
        openChecked.isEnabled = !list.checkedURLs.isEmpty
        clearAll.isEnabled = !list.arrangedSubviews.isEmpty
    }

    @objc private func openCheckedClicked() {
        let urls = list.checkedURLs
        guard !urls.isEmpty else { return }
        open(urls)
    }

    private func open(_ urls: [URL]) {
        dismiss()
        onOpen?(urls)
    }

    var listForTesting: RecentProjectsListView { list }
    var openCheckedEnabledForTesting: Bool { openChecked.isEnabled }
    func openCheckedForTesting() { openCheckedClicked() }
    var isEmptyNoteShownForTesting: Bool { !empty.isHidden }
    var clearAllEnabledForTesting: Bool { clearAll.isEnabled }
    func clearAllForTesting() { clearAll.clickForTesting() }
    var titleForTesting: String { titleLabel.stringValue }
    /// Where things are in the card, its bottom left corner the origin.
    var cardForTesting: NSView { card }
    var titleFrameForTesting: NSRect { titleLabel.frame }
    var openCheckedFrameForTesting: NSRect { openChecked.frame }
    var clearAllFrameForTesting: NSRect { clearAll.frame }
    var listAreaFrameForTesting: NSRect { scroll.frame }
    var backdropForTesting: NSView { backdrop }
    var isWatchingForTesting: Bool { eventMonitor != nil }
    /// The dimming over the window under the dialog, while it is there.
    var scrimForTesting: NSView? { scrim.superview == nil ? nil : scrim }
    var isFadingOutForTesting: Bool { closing }
    /// A key, as the app's event stream sees it: whether it went on.
    func pressKeyForTesting(code: UInt16, characters: String) -> Bool {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
        else { return true }
        return handle(event) != nil
    }
    /// A click in `window` — or in the dialog itself when nil, at `point` in
    /// its window's coordinates, the card's middle by default.
    func clickForTesting(in window: NSWindow?, at point: NSPoint? = nil) -> Bool {
        let target = window ?? self
        let location = point ?? (window == nil
            ? NSPoint(x: card.frame.midX, y: card.frame.midY) : NSPoint(x: 10, y: 10))
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown, location: location, modifierFlags: [],
            timestamp: 0, windowNumber: target.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1) else { return true }
        return handle(event) != nil
    }
}

/// The panel's whole window: clear, but for the card's shadow, fill and
/// border, which it draws behind the card's content.
private final class DialogBackdropView: NSView {
    static let cornerRadius: CGFloat = 12

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let cardFrame = subviews.first?.frame, !cardFrame.isEmpty else { return }
        let shape = NSBezierPath(roundedRect: cardFrame, xRadius: Self.cornerRadius,
                                 yRadius: Self.cornerRadius)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 20
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.set()
        Theme.panelBackground.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        // A hairline of light, not a drawn border: the dimming does the
        // setting apart, the edge only finishes the card.
        NSColor.white.withAlphaComponent(0.08).setStroke()
        let edge = NSBezierPath(roundedRect: cardFrame.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        edge.lineWidth = 1
        edge.stroke()
    }
}

/// Lays the list out from the top.
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// A button the width of a list, as a row of it: the text in the middle,
/// the row lit under the pointer.
final class DialogRowButton: NSView {
    static let height: CGFloat = 30
    var onClick: (() -> Void)?
    var isEnabled = true {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    private let title: String
    private var hovered = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: PointerCursor.trackingOptions,
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        if isEnabled { PointerCursor.enter() }
    }
    override func mouseMoved(with event: NSEvent) { if isEnabled { PointerCursor.enter() } }
    override func cursorUpdate(with event: NSEvent) {
        if isEnabled { PointerCursor.enter() } else { NSCursor.arrow.set() }
    }
    override func mouseExited(with event: NSEvent) {
        hovered = false
        PointerCursor.leave(self, event: event)
    }
    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else {
            return
        }
        onClick?()
    }
    override func mouseDown(with event: NSEvent) {}

    override func draw(_ dirtyRect: NSRect) {
        if hovered, isEnabled {
            Theme.activeRow.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Theme.uiFont(12),
            .foregroundColor: isEnabled ? Theme.red : Theme.gutter,
        ]
        let text = title as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: ((bounds.width - size.width) / 2).rounded(),
                              y: ((bounds.height - size.height) / 2).rounded()),
                  withAttributes: attributes)
    }

    func clickForTesting() { if isEnabled { onClick?() } }
}

/// The dimming over the window under the dialog. It takes every click on
/// the window, which closes the dialog and goes nowhere else.
private final class DialogScrimView: NSView {
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.4).cgColor
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onClick?() }
    override func scrollWheel(with event: NSEvent) {}
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

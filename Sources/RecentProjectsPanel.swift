import AppKit

/// What the R button opens: a dialog over the window listing the recent
/// projects as the start page lists them — a click ticks one, a double click
/// opens it, the cross on a hovered row takes it off the list — with Open
/// Checked alone in the bottom right corner. Esc closes it, and so does a
/// click anywhere outside it — in the window under it, another of the app's
/// windows, or another app.
///
/// A panel like the ⌘P palette rather than a popover: a dialog of its own,
/// not a balloon hanging off the button.
final class RecentProjectsPanel: NSPanel {
    /// The projects to open: one double-clicked, or every ticked one.
    var onOpen: (([URL]) -> Void)?

    static let width: CGFloat = 520
    static let padding: CGFloat = 12

    private let list = RecentProjectsListView()
    private let openChecked = NSButton()
    private let empty = NSTextField(labelWithString: "No Recent Projects")
    private var recentsObserver: NSObjectProtocol?
    private var eventMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    init() {
        // Borderless: a titled panel keeps its title bar, invisible or not,
        // over the top of the content, where it took the first row's clicks.
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 120),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        // Gone for good when the app is left, not hidden to come back with it.
        hidesOnDeactivate = false
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false

        let content = FlatView()
        content.fillColor = Theme.panelBackground
        content.wantsLayer = true
        content.layer?.cornerRadius = 10
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 1
        content.layer?.borderColor = Theme.border.cgColor

        list.translatesAutoresizingMaskIntoConstraints = false
        list.onOpen = { [weak self] url in self?.open([url]) }
        list.onCheckedChange = { [weak self] in self?.updateOpenChecked() }

        empty.font = Theme.uiFont(12)
        empty.textColor = Theme.dimText
        empty.translatesAutoresizingMaskIntoConstraints = false

        openChecked.title = "Open Checked"
        openChecked.bezelStyle = .rounded
        openChecked.font = Theme.uiFont(12)
        openChecked.target = self
        openChecked.action = #selector(openCheckedClicked)
        openChecked.isEnabled = false
        openChecked.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(list)
        content.addSubview(empty)
        content.addSubview(openChecked)
        let padding = Self.padding
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: Self.width),
            list.topAnchor.constraint(equalTo: content.topAnchor, constant: padding),
            list.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: padding),
            list.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -padding),
            empty.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            empty.topAnchor.constraint(equalTo: content.topAnchor, constant: padding * 2),
            // Only the one button, and only in the corner: the list above is
            // where everything else happens.
            openChecked.topAnchor.constraint(
                greaterThanOrEqualTo: list.bottomAnchor, constant: padding),
            openChecked.topAnchor.constraint(
                greaterThanOrEqualTo: empty.bottomAnchor, constant: padding * 2),
            openChecked.trailingAnchor.constraint(equalTo: content.trailingAnchor,
                                                  constant: -padding),
            openChecked.bottomAnchor.constraint(equalTo: content.bottomAnchor,
                                                constant: -padding),
        ])
        contentView = content
        recentsObserver = NotificationCenter.default.addObserver(
            forName: RecentProjects.didChange, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isVisible else { return }
            self.reload()
        }
    }

    deinit {
        if let recentsObserver { NotificationCenter.default.removeObserver(recentsObserver) }
        stopWatching()
    }

    override var canBecomeKey: Bool { true }

    var isShown: Bool { isVisible }

    /// In the middle of `parent`, over everything in it.
    func present(over parent: NSWindow) {
        reload()
        let parentFrame = parent.frame
        var frame = self.frame
        frame.origin.x = (parentFrame.midX - frame.width / 2).rounded()
        frame.origin.y = (parentFrame.midY - frame.height / 2).rounded()
        setFrame(frame, display: true)
        parent.addChildWindow(self, ordered: .above)
        makeKeyAndOrderFront(nil)
        startWatching()
    }

    /// Put away, whatever the reason.
    func dismiss() {
        closingItself = true
        stopWatching()
        parent?.removeChildWindow(self)
        orderOut(nil)
        closingItself = false
    }
    private var closingItself = false

    private func dismissByClickOutside() {
        guard isVisible else { return }
        dismiss()
        closedByClickAt = Date()
    }

    /// A click outside takes the keyboard to whatever was clicked.
    override func resignKey() {
        super.resignKey()
        guard !closingItself else { return }
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

    /// A click outside closes it and still lands where it was aimed; Esc
    /// closes it and goes no further; anything else passes.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard isVisible else { return event }
        if event.type == .keyDown {
            guard event.keyCode == 53 else { return event }
            dismiss()
            return nil
        }
        if event.window !== self { dismissByClickOutside() }
        return event
    }

    /// A click on the R button while the dialog is up closes it on the way
    /// down — it is a click outside — and would open it again on the way up.
    /// That click was meant to close it. Only a close of that kind counts:
    /// one the dialog did itself, opening a project, leaves R free to open it.
    private var closedByClickAt: Date?
    var justClosed: Bool {
        closedByClickAt.map { Date().timeIntervalSince($0) < 0.5 } ?? false
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
        updateOpenChecked()
        contentView?.layoutSubtreeIfNeeded()
        let size = contentView?.fittingSize ?? frame.size
        var frame = self.frame
        frame.origin.y += frame.height - size.height
        frame.size = NSSize(width: Self.width, height: size.height)
        setFrame(frame, display: isVisible)
    }

    private func updateOpenChecked() {
        openChecked.isEnabled = !list.checkedURLs.isEmpty
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
    var openCheckedFrameForTesting: NSRect { openChecked.frame }
    var isEmptyNoteShownForTesting: Bool { !empty.isHidden }
    /// A key, as the app's event stream sees it: whether it went on.
    func pressKeyForTesting(code: UInt16, characters: String) -> Bool {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
        else { return true }
        return handle(event) != nil
    }
    /// A click in `window` — or in the dialog itself when nil.
    func clickForTesting(in window: NSWindow?) -> Bool {
        let target = window ?? self
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [],
            timestamp: 0, windowNumber: target.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1) else { return true }
        return handle(event) != nil
    }
    var isWatchingForTesting: Bool { eventMonitor != nil }
}

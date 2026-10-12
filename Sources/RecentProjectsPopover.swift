import AppKit

/// What the R button opens: the recent projects as the start page lists them —
/// a click ticks one, a double click opens it, the cross on a hovered row
/// takes it off the list — and Open Checked in the bottom right corner for
/// the ticked ones. A click anywhere else, or Esc, closes it.
final class RecentProjectsPopover: NSObject, NSPopoverDelegate {
    /// The projects to open: one double-clicked, or every ticked one.
    var onOpen: (([URL]) -> Void)?

    static let width: CGFloat = 400
    static let padding: CGFloat = 8

    private let popover = NSPopover()
    private let list = RecentProjectsListView()
    private let openChecked = NSButton()
    private let empty = NSTextField(labelWithString: "No Recent Projects")
    private var escapeMonitor: Any?
    private var recentsObserver: NSObjectProtocol?

    override init() {
        super.init()
        let content = FlatView()
        content.fillColor = Theme.panelBackground

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

        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.delegate = self
        recentsObserver = NotificationCenter.default.addObserver(
            forName: RecentProjects.didChange, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            self.reload()
        }
    }

    deinit {
        if let recentsObserver { NotificationCenter.default.removeObserver(recentsObserver) }
        removeEscapeMonitor()
    }

    var isShown: Bool { popover.isShown }

    /// Under `rect`, which is in `view`'s coordinates.
    func show(relativeTo rect: NSRect, of view: NSView) {
        reload()
        popover.show(relativeTo: rect, of: view, preferredEdge: view.isFlipped ? .maxY : .minY)
        // The popover does not become key, so Esc goes to whatever had the
        // keyboard before it opened; it is taken here instead.
        removeEscapeMonitor()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) ?? event
        }
    }

    /// Esc closes it, and goes no further; any other key is left alone.
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard popover.isShown, event.keyCode == 53 else { return event }
        close()
        return nil
    }

    /// At once: the popover's closing animation runs only while events are
    /// being handled, and a project opening in the meantime found it still up.
    func close() {
        closingItself = true
        popover.animates = false
        popover.close()
        popover.animates = true
        closingItself = false
    }
    private var closingItself = false

    func popoverDidClose(_ notification: Notification) {
        removeEscapeMonitor()
        closedAt = closingItself ? nil : Date()
    }

    /// A click on the R button while the popover is up closes it on the way
    /// down — it is a click outside — and would open it again on the way up.
    /// That click was meant to close it. Only a close of that kind counts: one
    /// the popover did itself, opening a project, leaves R free to open it.
    private var closedAt: Date?
    var justClosed: Bool {
        closedAt.map { Date().timeIntervalSince($0) < 0.5 } ?? false
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    private func reload() {
        list.reload()
        empty.isHidden = !list.arrangedSubviews.isEmpty
        updateOpenChecked()
        popover.contentViewController?.view.layoutSubtreeIfNeeded()
        popover.contentSize = popover.contentViewController?.view.fittingSize ?? .zero
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
        close()
        onOpen?(urls)
    }

    var listForTesting: RecentProjectsListView { list }
    var behaviorForTesting: NSPopover.Behavior { popover.behavior }
    var openCheckedEnabledForTesting: Bool { openChecked.isEnabled }
    func openCheckedForTesting() { openCheckedClicked() }
    var openCheckedFrameForTesting: NSRect { openChecked.frame }
    var contentForTesting: NSView? { popover.contentViewController?.view }
    var isEmptyNoteShownForTesting: Bool { !empty.isHidden }
    /// A key, as the monitor sees it: whether it went on to the window.
    func pressKeyForTesting(code: UInt16, characters: String) -> Bool {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
        else { return true }
        return handleKey(event) != nil
    }
}

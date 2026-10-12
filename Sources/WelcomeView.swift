import AppKit

/// Shown centred in the editor area when no file is open: the app name, an
/// "Open Folder…" button, and the recently opened projects.
final class WelcomeView: FlatView {
    var onOpenFolder: (() -> Void)?
    var onOpenRecent: ((URL) -> Void)?
    /// Open several at once — every recent project whose box is ticked.
    var onOpenChecked: (([URL]) -> Void)?

    private let stack = NSStackView()
    /// Ties the list to the column's width. Remade on every reload because the
    /// list leaves the view hierarchy whenever there are no recents, which
    /// takes any constraint on it with it.
    private var recentWidthConstraint: NSLayoutConstraint?
    private let recentList = RecentProjectsListView()
    private let openCheckedButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        fillColor = .clear

        let title = NSTextField(labelWithString: "Puzzle")
        title.font = Theme.uiFont(22)
        title.textColor = Theme.foreground
        title.alignment = .left

        let openButton = NSButton(title: "Open", target: self,
                                  action: #selector(openFolderTapped))
        openButton.bezelStyle = .rounded
        openButton.font = Theme.uiFont(12)
        openButton.keyEquivalent = "\r"

        // Beside it: open everything that has been ticked below. Disabled
        // until something is, so the button says whether it has anything to do.
        openCheckedButton.title = "Open Checked"
        openCheckedButton.bezelStyle = .rounded
        openCheckedButton.font = Theme.uiFont(12)
        openCheckedButton.target = self
        openCheckedButton.action = #selector(openCheckedTapped)
        openCheckedButton.isEnabled = false

        let buttons = NSStackView(views: [openButton, openCheckedButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        recentList.onOpen = { [weak self] url in self?.onOpenRecent?(url) }
        recentList.onCheckedChange = { [weak self] in
            guard let self else { return }
            self.openCheckedButton.isEnabled = !self.recentList.checkedURLs.isEmpty
        }

        stack.orientation = .vertical
        // Everything on one left edge: the name, the buttons and the list.
        //
        // The list is a column of names of unequal length, so its right edge is
        // ragged however it is arranged. Centring the title over it made that
        // raggedness read as the list being pushed off to one side, and pulling
        // the paths over to a flush right edge only moved the gap into the
        // middle of each row, where it separates a project from its own path.
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setViews([title, buttons], in: .top)
        stack.setCustomSpacing(18, after: title)

        addSubview(stack)
        // The block is as wide as its widest row and sits in the middle of the
        // window. No fixed width: a project name is never truncated, so the
        // block has to be able to grow for one.
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
        ])

        NotificationCenter.default.addObserver(
            self, selector: #selector(reloadRecents),
            name: RecentProjects.didChange, object: nil)
        reloadRecents()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func openFolderTapped() { onOpenFolder?() }

    @objc private func openCheckedTapped() {
        let wanted = recentList.checkedURLs
        guard !wanted.isEmpty else { return }
        onOpenChecked?(wanted)
    }

    @objc func reloadRecents() {
        recentList.reload()
        openCheckedButton.isEnabled = !recentList.checkedURLs.isEmpty
        // Drop the recents block entirely when there's nothing to show.
        if stack.arrangedSubviews.contains(recentList) {
            stack.removeArrangedSubview(recentList)
            recentList.removeFromSuperview()
        }
        guard !recentList.arrangedSubviews.isEmpty else { return }
        stack.addArrangedSubview(recentList)
        // The list spans the whole block, so a hovered row's highlight reaches
        // the same right edge whether the widest thing above it is a button or
        // a project name.
        recentWidthConstraint?.isActive = false
        let width = recentList.widthAnchor.constraint(equalTo: stack.widthAnchor)
        width.isActive = true
        recentWidthConstraint = width
    }

    var checkedForTesting: [URL] { recentList.checkedURLs }
    var openCheckedEnabledForTesting: Bool { openCheckedButton.isEnabled }
    var openCheckedTitleForTesting: String { openCheckedButton.title }
    func openCheckedForTesting() { openCheckedTapped() }
    func rowsForTesting() -> [NSView] { recentList.arrangedSubviews }
    /// Width each row gives its parent path. Zero means a long project name
    /// squeezed the path out of the row entirely.
    func pathWidthsForTesting() -> [CGFloat] { recentList.pathWidthsForTesting() }
    /// The block everything on the page is laid out in.
    var columnFrameForTesting: NSRect { stack.frame }
    /// The title's alignment rect, in this view's coordinates. The frame is
    /// not the same thing — a text field's frame carries a couple of points of
    /// bearing outside the glyphs, and the stack lines its children up on the
    /// alignment rect, so comparing frames would always be off by that much.
    var titleFrameForTesting: NSRect {
        guard let title = stack.arrangedSubviews.first else { return .zero }
        return stack.convert(title.alignmentRect(forFrame: title.frame), to: self)
    }
    func toggleCheckForTesting(at index: Int) { recentList.toggleCheckForTesting(at: index) }
    /// A double click on the row, which is what opens it.
    func openRowForTesting(_ index: Int) { recentList.openRowForTesting(index) }
    func isRowCheckedForTesting(_ index: Int) -> Bool { recentList.isRowCheckedForTesting(index) }

    func refreshFonts() {
        reloadRecents()
        needsDisplay = true
    }
}

/// The recent projects, a row each: a click ticks one, a double click opens
/// it, the cross on a hovered row takes it off the list. The start page shows
/// it, and so does the R button's popover, which behaves the same.
final class RecentProjectsListView: NSStackView {
    var onOpen: ((URL) -> Void)?
    /// Something was ticked or unticked — or left the list ticked.
    var onCheckedChange: (() -> Void)?
    private var checked: Set<URL> = []

    /// Ticked, in the order they are listed, so the projects arrive in the
    /// order they are read.
    var checkedURLs: [URL] { RecentProjects.shared.urls.filter { checked.contains($0) } }

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        // Every row the width of the widest, so the hover highlight is the
        // same rectangle down the list rather than tracking each name.
        alignment = .width
        spacing = 2
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Everything the store keeps, up to what it shows — the same list the
    /// Dock menu has: a list that hides half of them sends the reader to the
    /// menu to find the rest.
    func reload() {
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        let recents = RecentProjects.shared.urls
        // A project that has left the list cannot stay ticked.
        let before = checked
        checked.formIntersection(recents)
        for url in recents.prefix(RecentProjects.displayLimit) {
            addArrangedSubview(RecentRowView(
                url: url,
                isChecked: checked.contains(url),
                action: { [weak self] in self?.onOpen?(url) },
                checkAction: { [weak self] on in self?.setChecked(url, on) },
                removeAction: { RecentProjects.shared.remove(url) }))
        }
        if checked != before { onCheckedChange?() }
    }

    private func setChecked(_ url: URL, _ isChecked: Bool) {
        if isChecked { checked.insert(url) } else { checked.remove(url) }
        onCheckedChange?()
    }

    private func row(_ index: Int) -> RecentRowView? {
        arrangedSubviews.indices.contains(index) ? arrangedSubviews[index] as? RecentRowView : nil
    }
    func pathWidthsForTesting() -> [CGFloat] {
        arrangedSubviews.compactMap { ($0 as? RecentRowView)?.pathWidthForTesting }
    }
    func toggleCheckForTesting(at index: Int) { row(index)?.toggleCheckForTesting() }
    func openRowForTesting(_ index: Int) { row(index)?.openForTesting() }
    func isRowCheckedForTesting(_ index: Int) -> Bool { row(index)?.isCheckedForTesting ?? false }
    func removeRowForTesting(_ index: Int) { row(index)?.removeForTesting() }
    /// Each row's box: the width it was given, and the width it needs.
    func checkWidthsForTesting() -> [(given: CGFloat, needed: CGFloat)] {
        arrangedSubviews.compactMap { ($0 as? RecentRowView)?.checkWidthForTesting }
    }
}

/// One clickable recent-project row: name + dimmed parent folder.
private final class RecentRowView: FlatView {
    /// How much of the parent path is always shown before it truncates.
    static let minimumPathWidth: CGFloat = 104

    private var pathLabel: NSTextField?
    var pathWidthForTesting: CGFloat { pathLabel?.frame.width ?? 0 }

    private let action: () -> Void
    private let checkAction: (Bool) -> Void
    private let removeAction: () -> Void
    private let url: URL
    private var hovering = false { didSet { removeButton.isHidden = !hovering; needsDisplay = true } }
    private var tracking: NSTrackingArea?
    private let removeButton = NSButton()
    private let check = NSButton()

    init(url: URL, isChecked: Bool, action: @escaping () -> Void,
         checkAction: @escaping (Bool) -> Void, removeAction: @escaping () -> Void) {
        self.action = action
        self.checkAction = checkAction
        self.removeAction = removeAction
        self.url = url
        super.init(frame: .zero)
        fillColor = .clear

        // Ticking is for gathering several; clicking the row still opens this
        // one on its own, so the box takes its own clicks.
        check.setButtonType(.switch)
        check.title = ""
        check.state = isChecked ? .on : .off
        check.target = self
        check.action = #selector(checkToggled)
        check.setAccessibilityLabel("Open \(url.lastPathComponent) with the others")
        check.translatesAutoresizingMaskIntoConstraints = false
        // The box keeps its size whatever the name beside it: in a list of
        // fixed width, a long name squeezed it half out of sight.
        check.setContentCompressionResistancePriority(.required, for: .horizontal)
        check.setContentHuggingPriority(.required, for: .horizontal)

        let name = NSTextField(labelWithString: url.lastPathComponent)
        name.font = Theme.uiFont(12)
        name.textColor = Theme.foreground
        name.lineBreakMode = .byTruncatingTail
        let parent = NSTextField(labelWithString: RecentProjects.displayParent(for: url))
        parent.font = Theme.uiFont(10)
        parent.textColor = Theme.dimText
        parent.lineBreakMode = .byTruncatingHead

        // Long paths truncate rather than stretch the page, and the name only
        // once the path is down to its floor — never the box before it. But
        // resistance that low lets the path collapse to nothing as well, which
        // it did the moment the row stopped being pinned to a fixed width: the
        // longest name took the whole row and its path vanished. The floor is
        // what a path has to show before it starts truncating.
        name.setContentCompressionResistancePriority(.init(760), for: .horizontal)
        parent.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        parent.setContentHuggingPriority(.init(1), for: .horizontal)
        parent.widthAnchor.constraint(
            greaterThanOrEqualToConstant: Self.minimumPathWidth).isActive = true

        // Remove-from-history button, revealed on hover.
        removeButton.image = NSImage(systemSymbolName: "xmark",
                                     accessibilityDescription: "Remove from Recent")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .medium))
        removeButton.isBordered = false
        removeButton.bezelStyle = .regularSquare
        removeButton.contentTintColor = Theme.dimText
        removeButton.target = self
        removeButton.action = #selector(removeTapped)
        removeButton.toolTip = "Remove from Recent"
        removeButton.isHidden = true
        removeButton.translatesAutoresizingMaskIntoConstraints = false

        pathLabel = parent

        let row = NSStackView(views: [name, parent])
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(check)
        addSubview(row)
        addSubview(removeButton)
        NSLayoutConstraint.activate([
            check.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: removeButton.leadingAnchor, constant: -6),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            removeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: 16),
            removeButton.heightAnchor.constraint(equalToConstant: 16),
            heightAnchor.constraint(equalToConstant: 22),
        ])
        toolTip = url.path

        // Right-click also offers removal.
        let contextMenu = NSMenu()
        let removeItem = NSMenuItem(title: "Remove from Recent",
                                    action: #selector(removeTapped), keyEquivalent: "")
        removeItem.target = self
        contextMenu.addItem(removeItem)
        let revealItem = NSMenuItem(title: "Reveal in Finder",
                                    action: #selector(revealTapped), keyEquivalent: "")
        revealItem.target = self
        contextMenu.addItem(revealItem)
        self.menu = contextMenu
    }

    @objc private func checkToggled() { checkAction(check.state == .on) }

    @objc private func removeTapped() { removeAction() }

    var isCheckedForTesting: Bool { check.state == .on }
    var checkWidthForTesting: (given: CGFloat, needed: CGFloat) {
        (check.frame.width, check.intrinsicContentSize.width)
    }
    func removeForTesting() { removeAction() }
    /// What a double click does.
    func openForTesting() { action() }
    /// What a single click — or the box itself — does.
    func toggleCheckForTesting() {
        check.state = check.state == .on ? .off : .on
        checkToggled()
    }

    @objc private func revealTapped() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
        // An area laid under a pointer already resting on it reports nothing
        // until the pointer leaves, so a page made under the pointer — it is
        // made a turn after the window — read as not hovered. Ask instead.
        if let window, window.isKeyWindow {
            let inside = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
            if inside != hovering { hovering = inside }
        }
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    /// A click ticks the row; a double click opens it. Gathering several is
    /// the common errand on this page, and the box is a small target — the
    /// whole row is the easier one.
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount < 2 else {
            action()
            return
        }
        toggleCheckForTesting()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        Theme.activeRow.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    }
}

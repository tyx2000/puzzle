import AppKit

/// Shown centred in the editor area when no file is open: the app name, an
/// "Open Folder…" button, and the recently opened projects.
final class WelcomeView: FlatView {
    var onOpenFolder: (() -> Void)?
    var onOpenRecent: ((URL) -> Void)?

    private let stack = NSStackView()
    private let recentStack = NSStackView()
    private let recentHeading = NSTextField(labelWithString: "Recent")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        fillColor = .clear

        let title = NSTextField(labelWithString: "Puzzle")
        title.font = Theme.uiFont(22)
        title.textColor = Theme.foreground
        title.alignment = .center

        let subtitle = NSTextField(labelWithString: "Open a folder to get started")
        subtitle.font = Theme.uiFont(11.5)
        subtitle.textColor = Theme.dimText
        subtitle.alignment = .center

        let openButton = NSButton(title: "Open Folder…", target: self,
                                  action: #selector(openFolderTapped))
        openButton.bezelStyle = .rounded
        openButton.font = Theme.uiFont(12)
        openButton.keyEquivalent = "\r"

        recentHeading.font = Theme.uiFont(10.5)
        recentHeading.textColor = Theme.dimText
        recentHeading.alignment = .left

        recentStack.orientation = .vertical
        recentStack.alignment = .leading
        recentStack.spacing = 2

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setViews([title, subtitle, openButton], in: .top)
        stack.setCustomSpacing(18, after: subtitle)

        addSubview(stack)
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

    @objc func reloadRecents() {
        recentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let recents = RecentProjects.shared.urls
        // Drop the recents block entirely when there's nothing to show.
        for view in [recentHeading, recentStack] where stack.arrangedSubviews.contains(view) {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard !recents.isEmpty else { return }

        for url in recents.prefix(8) {
            recentStack.addArrangedSubview(RecentRowView(
                url: url,
                action: { [weak self] in self?.onOpenRecent?(url) },
                removeAction: { RecentProjects.shared.remove(url) }))
        }
        stack.addArrangedSubview(recentHeading)
        stack.addArrangedSubview(recentStack)
        stack.setCustomSpacing(20, after: recentStack.arrangedSubviews.isEmpty ? recentHeading : recentHeading)
    }

    func refreshFonts() {
        reloadRecents()
        needsDisplay = true
    }
}

/// One clickable recent-project row: name + dimmed parent folder.
private final class RecentRowView: FlatView {
    private let action: () -> Void
    private let removeAction: () -> Void
    private let url: URL
    private var hovering = false { didSet { removeButton.isHidden = !hovering; needsDisplay = true } }
    private var tracking: NSTrackingArea?
    private let removeButton = NSButton()

    init(url: URL, action: @escaping () -> Void, removeAction: @escaping () -> Void) {
        self.action = action
        self.removeAction = removeAction
        self.url = url
        super.init(frame: .zero)
        fillColor = .clear

        let name = NSTextField(labelWithString: url.lastPathComponent)
        name.font = Theme.uiFont(12)
        name.textColor = Theme.foreground
        let parent = NSTextField(labelWithString: RecentProjects.displayParent(for: url))
        parent.font = Theme.uiFont(10)
        parent.textColor = Theme.dimText
        parent.lineBreakMode = .byTruncatingHead

        // Long paths must truncate rather than stretch the welcome layout.
        name.setContentCompressionResistancePriority(.required, for: .horizontal)
        parent.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        parent.setContentHuggingPriority(.init(1), for: .horizontal)

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

        let row = NSStackView(views: [name, parent])
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        addSubview(removeButton)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: removeButton.leadingAnchor, constant: -6),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            removeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: 16),
            removeButton.heightAnchor.constraint(equalToConstant: 16),
            heightAnchor.constraint(equalToConstant: 22),
            widthAnchor.constraint(equalToConstant: 420),
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

    @objc private func removeTapped() { removeAction() }

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
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { action() }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        Theme.activeRow.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    }
}

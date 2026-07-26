import AppKit

/// Zed-style git panel: Changes / History tabs, a staged-checkbox list of changed
/// files, the branch, a commit message box and a commit button.
final class GitPanelViewController: NSViewController {
    var onOpenFile: ((URL) -> Void)?
    /// Clicking a changed file asks the window to show its coloured diff.
    var onOpenDiff: ((GitService.Status.Entry, URL) -> Void)?
    var onChanged: (() -> Void)?

    /// Rows are either a section header or a changed file.
    private enum Row {
        case header(String)
        case file(GitService.Status.Entry, index: Int)
    }
    private var rows: [Row] = []

    private var directory: URL?
    private var entries: [GitService.Status.Entry] = []
    private var history: [GitService.Commit] = []
    private var staged: Set<String> = []
    private var showingHistory = false

    private let segmented = NSSegmentedControl(labels: ["Changes", "History"],
                                               trackingMode: .selectOne, target: nil, action: nil)
    private let stageAllButton = NSButton()
    private let table = NSTableView()
    private let branchLabel = NSTextField(labelWithString: "")
    private let commitField = NSTextView()
    private let commitButton = NSButton()

    func setDirectory(_ url: URL) { directory = url; refresh() }

    override func loadView() {
        let container = FlatView()
        container.fillColor = Theme.panelBackground

        segmented.selectedSegment = 0
        segmented.target = self
        segmented.action = #selector(tabChanged)
        segmented.translatesAutoresizingMaskIntoConstraints = false
        segmented.font = Theme.uiFont(11)

        stageAllButton.title = "Stage All"
        stageAllButton.bezelStyle = .rounded
        stageAllButton.controlSize = .small
        stageAllButton.font = Theme.uiFont(10.5)
        stageAllButton.target = self
        stageAllButton.action = #selector(stageAll)
        stageAllButton.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowSizeStyle = .custom
        table.backgroundColor = Theme.panelBackground
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.usesAlternatingRowBackgroundColors = false

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.panelBackground
        scroll.translatesAutoresizingMaskIntoConstraints = false

        branchLabel.font = Theme.uiFont(10.5)
        branchLabel.textColor = Theme.dimText
        branchLabel.translatesAutoresizingMaskIntoConstraints = false

        // Commit message box.
        commitField.font = Theme.uiFont(11)
        commitField.isRichText = false
        commitField.backgroundColor = Theme.activeTab
        commitField.textColor = Theme.foreground
        commitField.textContainerInset = NSSize(width: 4, height: 4)
        let commitScroll = NSScrollView()
        commitScroll.documentView = commitField
        commitScroll.borderType = .lineBorder
        commitScroll.hasVerticalScroller = true
        commitScroll.translatesAutoresizingMaskIntoConstraints = false

        commitButton.title = "Commit Tracked"
        commitButton.bezelStyle = .rounded
        commitButton.controlSize = .small
        commitButton.font = Theme.uiFont(10.5)
        commitButton.target = self
        commitButton.action = #selector(commit)
        commitButton.translatesAutoresizingMaskIntoConstraints = false

        [segmented, stageAllButton, scroll, branchLabel, commitScroll, commitButton]
            .forEach { container.addSubview($0) }

        NSLayoutConstraint.activate([
            segmented.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            segmented.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            segmented.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            stageAllButton.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 6),
            stageAllButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            scroll.topAnchor.constraint(equalTo: stageAllButton.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: branchLabel.topAnchor, constant: -6),

            branchLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            branchLabel.bottomAnchor.constraint(equalTo: commitScroll.topAnchor, constant: -6),

            commitScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            commitScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            commitScroll.heightAnchor.constraint(equalToConstant: 60),
            commitScroll.bottomAnchor.constraint(equalTo: commitButton.topAnchor, constant: -6),

            commitButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            commitButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        self.view = container
    }

    // MARK: - Data

    /// Re-apply the UI font after a settings change.
    func refreshFonts() {
        segmented.font = Theme.uiFont(11)
        stageAllButton.font = Theme.uiFont(10.5)
        branchLabel.font = Theme.uiFont(10.5)
        commitField.font = Theme.uiFont(11)
        commitButton.font = Theme.uiFont(10.5)
        refresh()          // rebuilds the rows, which set their own fonts
    }

    func refresh() {
        guard let directory else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let status = GitService.status(in: directory)
            let log = GitService.log(in: directory, limit: 40)
            DispatchQueue.main.async {
                guard let self else { return }
                self.entries = status.entries
                self.history = log
                self.staged = Set(status.entries.filter { $0.isStaged }.map { $0.path })
                self.rebuildRows()
                self.branchLabel.stringValue = status.isRepo
                    ? "\(directory.lastPathComponent) / \(status.branch)"
                    : "not a git repository"
                self.segmented.setLabel("Changes (\(status.entries.count))", forSegment: 0)
                self.table.reloadData()
            }
        }
    }

    /// Tracked changes first, then an "Untracked" section (Zed's grouping).
    private func rebuildRows() {
        var built: [Row] = []
        let tracked = entries.enumerated().filter { !$0.element.isUntracked }
        let untracked = entries.enumerated().filter { $0.element.isUntracked }
        if !tracked.isEmpty {
            built.append(.header("Tracked"))
            built += tracked.map { .file($0.element, index: $0.offset) }
        }
        if !untracked.isEmpty {
            built.append(.header("Untracked"))
            built += untracked.map { .file($0.element, index: $0.offset) }
        }
        rows = built
    }

    @objc private func tabChanged() {
        showingHistory = segmented.selectedSegment == 1
        stageAllButton.isHidden = showingHistory
        table.reloadData()
    }

    @objc private func stageAll() {
        guard let directory else { return }
        GitService.run(["add", "-A"], in: directory)
        refresh()
        onChanged?()
    }

    @objc private func commit() {
        guard let directory else { return }
        let message = commitField.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Commit message required"
            alert.runModal(); return
        }
        let result = GitService.run(["commit", "-m", message], in: directory)
        if result.code != 0 {
            let alert = NSAlert()
            alert.messageText = "Commit failed"
            alert.informativeText = result.err.isEmpty ? result.out : result.err
            alert.runModal()
        } else {
            commitField.string = ""
        }
        refresh()
        onChanged?()
    }

    @objc private func rowClicked() {
        let row = table.clickedRow
        guard !showingHistory, row >= 0, row < rows.count, let directory else { return }
        if case .file(let entry, _) = rows[row] {
            // Clicking a changed file shows its diff, not the plain file.
            onOpenDiff?(entry, directory)
        }
    }

    @objc private func toggleStage(_ sender: NSButton) {
        guard let directory, sender.tag >= 0, sender.tag < entries.count else { return }
        let path = entries[sender.tag].path
        if sender.state == .on {
            GitService.run(["add", "--", path], in: directory)
        } else {
            GitService.run(["restore", "--staged", "--", path], in: directory)
        }
        refresh()
        onChanged?()
    }
}

extension GitPanelViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        showingHistory ? history.count : rows.count
    }
}

extension GitPanelViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if !showingHistory, row < rows.count, case .header = rows[row] { return 20 }
        return 22
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        if showingHistory {
            guard row < history.count else { return nil }
            let commit = history[row]
            let subject = NSTextField(labelWithString: commit.subject)
            subject.font = Theme.uiFont(11)
            subject.textColor = Theme.foreground
            subject.lineBreakMode = .byTruncatingTail
            let meta = NSTextField(labelWithString: commit.shortHash)
            meta.font = Theme.uiFont(9.5)
            meta.textColor = Theme.dimText
            for v in [meta, subject] as [NSView] {
                v.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(v)
            }
            NSLayoutConstraint.activate([
                meta.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                meta.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                meta.widthAnchor.constraint(equalToConstant: 52),
                subject.leadingAnchor.constraint(equalTo: meta.trailingAnchor, constant: 4),
                subject.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                subject.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        guard row < rows.count else { return nil }
        // Section header ("Tracked" / "Untracked").
        if case .header(let title) = rows[row] {
            let label = NSTextField(labelWithString: title)
            label.font = Theme.uiFont(10)
            label.textColor = Theme.dimText
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
        guard case .file(let entry, let entryIndex) = rows[row] else { return nil }
        let status = NSTextField(labelWithString: entry.displayCode)
        status.font = Theme.uiFont(10)
        status.textColor = entry.isUntracked ? Theme.green : Theme.yellow
        status.alignment = .center

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName:
            FileTreeViewController.iconName(for: (entry.path as NSString).pathExtension),
            accessibilityDescription: nil)
        icon.contentTintColor = Theme.dimText

        let name = NSTextField(labelWithString: (entry.path as NSString).lastPathComponent)
        name.font = Theme.uiFont(11)
        name.textColor = Theme.foreground
        name.lineBreakMode = .byTruncatingMiddle

        let folder = NSTextField(labelWithString: (entry.path as NSString).deletingLastPathComponent)
        folder.font = Theme.uiFont(9.5)
        folder.textColor = Theme.dimText
        folder.lineBreakMode = .byTruncatingHead

        let check = NSButton()
        check.setButtonType(.switch)
        check.title = ""
        check.state = staged.contains(entry.path) ? .on : .off
        check.tag = entryIndex
        check.target = self
        check.action = #selector(toggleStage(_:))

        for v in [status, icon, name, folder, check] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(v)
        }
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            status.widthAnchor.constraint(equalToConstant: 18),
            status.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.leadingAnchor.constraint(equalTo: status.trailingAnchor, constant: 2),
            icon.widthAnchor.constraint(equalToConstant: 13),
            icon.heightAnchor.constraint(equalToConstant: 13),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            name.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            folder.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 5),
            folder.trailingAnchor.constraint(lessThanOrEqualTo: check.leadingAnchor, constant: -4),
            folder.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            check.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            check.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

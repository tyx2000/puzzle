import AppKit

/// App-level concerns only: the menu bar, and the set of open windows.
/// Everything per-window lives in `WorkspaceWindowController`.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var windows: [WorkspaceWindowController] = []
    /// Rebuilt each time the menu opens, so it always reflects current history.
    private let recentMenu = NSMenu(title: "Open Recent")

    /// The window the menus should act on.
    private var activeController: WorkspaceWindowController? {
        if let key = NSApp.keyWindow?.windowController as? WorkspaceWindowController { return key }
        if let main = NSApp.mainWindow?.windowController as? WorkspaceWindowController { return main }
        return windows.last
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.shared.load()
        // A settings.json written by an older build lacks options added since;
        // rewrite it with the full documented set, keeping the user's values.
        Settings.shared.upgradeFileIfNeeded()
        setupMenu()

        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: Settings.didChange, object: nil)

        let controller = makeWindow()
        NSApp.activate(ignoringOtherApps: true)
        applyLaunchArguments(to: controller)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Clicking the dock icon with no windows open makes a fresh one.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { makeWindow() }
        return true
    }

    // MARK: - Windows

    @discardableResult
    private func makeWindow() -> WorkspaceWindowController {
        let controller = WorkspaceWindowController()
        controller.onClose = { [weak self] closed in
            self?.windows.removeAll { $0 === closed }
        }
        windows.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    /// ⌘N — a new window, starting at the same project as the current one so it
    /// is immediately useful (Zed opens a new window on the same workspace).
    @objc private func newWindow(_ sender: Any?) {
        let source = activeController
        let controller = makeWindow()
        if let url = source?.projectURL {
            controller.openProject(url)
        } else {
            controller.openFolder(nil)
        }
    }

    // MARK: - Launch arguments

    private func applyLaunchArguments(to controller: WorkspaceWindowController) {
        let args = CommandLine.arguments
        let preset = args.dropFirst().first(where: {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue
        }) ?? ProcessInfo.processInfo.environment["PUZZLE_OPEN"]

        let fileArgs = args.dropFirst().filter {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && !isDir.boolValue
        }

        DispatchQueue.main.async {
            // No auto file-picker: with no arguments the window shows the
            // welcome screen (recent projects + an Open Folder button).
            if let preset, !preset.isEmpty {
                controller.openProject(URL(fileURLWithPath: preset))
            }
            for f in fileArgs { controller.editor.open(url: URL(fileURLWithPath: f)) }

            if args.contains("--split") { controller.editor.splitEditor() }
            if let i = args.firstIndex(of: "--panel"), i + 1 < args.count {
                switch args[i + 1] {
                case "search":   controller.sidebar.showSearch()
                case "git":      controller.sidebar.showGit()
                case "settings": controller.openSettings()
                default:         controller.sidebar.showFiles()
                }
            }
            if let i = args.firstIndex(of: "--search"), i + 1 < args.count {
                controller.sidebar.showSearch()
                controller.sidebar.search.performSearch(args[i + 1])
            }
            if let i = args.firstIndex(of: "--find"), i + 1 < args.count {
                controller.editor.showFindBar(seed: args[i + 1])
            }
            // `--windows N` opens N extra windows (scripting / screenshots).
            if let i = args.firstIndex(of: "--windows"), i + 1 < args.count,
               let extra = Int(args[i + 1]), extra > 1 {
                for _ in 1..<extra { self.newWindow(nil) }
            }
        }
    }

    // MARK: - Menu

    private func setupMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Puzzle", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Puzzle",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Open Folder…",
                         action: #selector(WorkspaceWindowController.openFolder(_:)), keyEquivalent: "o")
        // Open Recent ▸ — each entry opens that project in a NEW window.
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recentMenu.delegate = self
        recentItem.submenu = recentMenu
        fileMenu.addItem(recentItem)
        fileMenu.addItem(withTitle: "Save",
                         action: #selector(WorkspaceWindowController.saveDocument(_:)), keyEquivalent: "s")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window",
                         action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Find in File…",
                         action: #selector(WorkspaceWindowController.findInFile(_:)), keyEquivalent: "f")
        editMenu.addItem(withTitle: "Find in Folder…",
                         action: #selector(WorkspaceWindowController.findInFolder(_:)), keyEquivalent: "F")
        editMenuItem.submenu = editMenu

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Show Files",
                         action: #selector(WorkspaceWindowController.showFiles(_:)), keyEquivalent: "1")
        viewMenu.addItem(withTitle: "Show Search",
                         action: #selector(WorkspaceWindowController.findInFolder(_:)), keyEquivalent: "2")
        viewMenu.addItem(withTitle: "Show Git",
                         action: #selector(WorkspaceWindowController.showGit(_:)), keyEquivalent: "3")
        viewMenu.addItem(withTitle: "Toggle Sidebar",
                         action: #selector(WorkspaceWindowController.toggleSidebar(_:)), keyEquivalent: "b")
        viewMenu.addItem(withTitle: "Split Editor",
                         action: #selector(WorkspaceWindowController.splitEditor(_:)), keyEquivalent: "\\")
        viewMenuItem.submenu = viewMenu

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - App actions

    // MARK: - Open Recent

    /// Rebuild just before the submenu is shown.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let recents = RecentProjects.shared.urls
        if recents.isEmpty {
            let empty = NSMenuItem(title: "No Recent Projects", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for url in recents {
            let item = NSMenuItem(title: url.lastPathComponent,
                                  action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
            menu.addItem(item)

            // Hold ⌥ to remove this entry instead of opening it.
            let remove = NSMenuItem(title: "Remove “\(url.lastPathComponent)” from Recent",
                                    action: #selector(removeRecent(_:)), keyEquivalent: "")
            remove.target = self
            remove.representedObject = url
            remove.isAlternate = true
            remove.keyEquivalentModifierMask = .option
            menu.addItem(remove)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear Menu", action: #selector(clearRecents), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }

    /// Recent projects open in a new window, leaving the current one alone.
    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        makeWindow().openProject(url)
    }

    @objc private func removeRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        RecentProjects.shared.remove(url)
    }

    @objc private func clearRecents() { RecentProjects.shared.clear() }

    @objc private func settingsChanged() {
        // Re-apply fonts/metrics to every open window.
        DocumentStore.shared.reapplyDisplaySettings()
        windows.forEach { $0.refreshDisplay() }
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Puzzle"
        alert.informativeText = "A minimal native code editor.\nSwift + AppKit."
        alert.runModal()
    }
}

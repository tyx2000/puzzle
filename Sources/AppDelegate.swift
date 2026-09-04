import AppKit

/// App-level concerns only: the menu bar, and the set of open windows.
/// Everything per-window lives in `WorkspaceWindowController`.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var windows: [WorkspaceWindowController] = []
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var hasCompletedInitialActivation = false
    private let recentProjects: RecentProjects
    /// Rebuilt each time the menu opens, so it always reflects current history.
    private let recentMenu = NSMenu(title: "Open Recent")

    override convenience init() {
        self.init(recentProjects: .shared)
    }

    init(recentProjects: RecentProjects) {
        self.recentProjects = recentProjects
        super.init()
    }

    /// The window the menus should act on.
    private var activeController: WorkspaceWindowController? {
        if let key = NSApp.keyWindow?.windowController as? WorkspaceWindowController { return key }
        if let main = NSApp.mainWindow?.windowController as? WorkspaceWindowController { return main }
        return windows.last
    }

    /// Settings have to be in place before any view exists.
    ///
    /// Views cache the fonts and metrics they are built with, and `openFiles:`
    /// — how Finder and `pz` start the app with a project — runs *before*
    /// `applicationDidFinishLaunching`. Loading settings there meant a window
    /// opened that way was built against the defaults rather than the user's.
    func applicationWillFinishLaunching(_ notification: Notification) {
        prepareSettings()
    }

    /// Idempotent: `applicationDidFinishLaunching` still calls it in case a
    /// future entry point reaches that first.
    private func prepareSettings() {
        guard !settingsPrepared else { return }
        settingsPrepared = true
        Settings.shared.load()
        Theme.applyAppearance()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        prepareSettings()
        LauncherInstaller.installIfNeeded()
        // A settings.json written by an older build lacks options added since;
        // rewrite it with the full documented set, keeping the user's values.
        Settings.shared.upgradeFileIfNeeded()
        setupMenu()
        setupMemoryPressureHandling()

        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: Settings.didChange, object: nil)

        // When the app is launched WITH a document (Finder open-with, or `pz`),
        // `application(_:openFiles:)` fires BEFORE this method and has already
        // made a window for it. Creating one unconditionally here left an extra
        // empty welcome window alongside the project.
        let controller = windows.first ?? makeWindow()
        NSApp.activate(ignoringOtherApps: true)
        applyLaunchArguments(to: controller)
    }

    private var settingsPrepared = false
    var settingsPreparedForTesting: Bool { settingsPrepared }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// FSEvents normally delivers external Git changes while Puzzle is in the
    /// background. Refresh on activation as a fallback for coalesced/missed
    /// events and for repositories whose metadata directory was replaced.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard hasCompletedInitialActivation else {
            hasCompletedInitialActivation = true
            return
        }
        windows.forEach { $0.refreshExternalGitState() }
    }

    private func setupMemoryPressureHandling() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            self?.windows.forEach { $0.releaseTransientMemory() }
            DocumentStore.shared.releaseTransientMemory()
            FileIcons.releaseTransientMemory()
        }
        source.resume()
        memoryPressureSource = source
    }

    /// Finder and `pz` use the same routing as the in-app file picker.
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        // This can be the first delegate call of the process, before any
        // window — and therefore any cached colour — exists.
        prepareSettings()
        let handled = openURLs(filenames.map { URL(fileURLWithPath: $0) })
        NSApp.activate(ignoringOtherApps: true)
        sender.reply(toOpenOrPrint: handled ? .success : .failure)
    }

    /// Reuse an owning project before considering the requesting welcome
    /// window or creating a workspace. Every external/open-panel entry point
    /// goes through this method so it cannot create duplicate project windows.
    @discardableResult
    func openURLs(_ urls: [URL], from source: WorkspaceWindowController? = nil) -> Bool {
        var handled = false
        // Open explicitly selected folders before their files, regardless of
        // the order returned by a multiple-selection panel or Finder.
        let items = urls.compactMap { url -> (url: URL, isDirectory: Bool)? in
            var isDir: ObjCBool = false
            guard url.isFileURL,
                  FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
            return (url.standardizedFileURL.resolvingSymlinksInPath(), isDir.boolValue)
        }
        for item in items.filter(\.isDirectory) + items.filter({ !$0.isDirectory }) {
            let url = item.url
            let welcome = source.flatMap { $0.hasProject ? nil : $0 }
                ?? windows.first { !$0.hasProject }
            if item.isDirectory {
                // The project may already be open: raise that window instead of
                // stacking a second copy of the same workspace.
                let target = window(showingProject: url)
                    ?? welcome
                    ?? makeWindow()
                if target.projectURL == nil { target.openProject(url) }
                target.window?.makeKeyAndOrderFront(nil)
            } else {
                // A file inside an open project becomes a tab there. Each window
                // carries its own editor, tree and Git state, so spawning one per
                // file cost ~60 MB a time and split the project across windows.
                let target = window(containing: url)
                    ?? welcome
                    ?? makeWindow()
                if target.projectURL == nil {
                    target.openProject(url.deletingLastPathComponent())
                }
                target.editor.open(url: url)
                target.window?.makeKeyAndOrderFront(nil)
            }
            handled = true
        }
        return handled
    }

    var windowsForTesting: [WorkspaceWindowController] { windows }

    /// The window whose project is exactly this folder.
    func window(showingProject url: URL) -> WorkspaceWindowController? {
        Self.projectIndex(matching: url, in: windows.map(\.projectURL)).map { windows[$0] }
    }

    /// The window whose project contains this file.
    func window(containing file: URL) -> WorkspaceWindowController? {
        Self.projectIndex(owning: file, in: windows.map(\.projectURL)).map { windows[$0] }
    }

    /// Paths are compared symlink-resolved: `/tmp/x` and `/private/tmp/x` are
    /// the same project, and a plain string prefix would miss that.
    private static func normalized(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Which open project is exactly this folder.
    static func projectIndex(matching folder: URL, in roots: [URL?]) -> Int? {
        let target = normalized(folder)
        return roots.firstIndex { $0.map(normalized) == target }
    }

    /// Which open project contains this file — the deepest one wins, so a file
    /// inside a nested workspace lands in that workspace rather than its parent.
    static func projectIndex(owning file: URL, in roots: [URL?]) -> Int? {
        let path = normalized(file)
        return roots.enumerated()
            .compactMap { index, root -> (Int, Int)? in
                guard let root else { return nil }
                let rootPath = normalized(root)
                let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
                guard path.hasPrefix(prefix) else { return nil }
                return (index, rootPath.count)
            }
            .max { $0.1 < $1.1 }?.0
    }

    /// Clicking the dock icon with no windows open makes a fresh one.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { makeWindow() }
        return true
    }

    /// Rebuilt on every Dock right-click so changes made by any window appear
    /// immediately. Dock menus should stay action-focused, so they contain only
    /// the ten newest valid projects and no remove/clear management commands.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu(title: "Recent Projects")
        let recents = recentProjects.urls.prefix(10)
        if recents.isEmpty {
            let empty = NSMenuItem(title: "No Recent Projects", action: nil,
                                   keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return menu
        }
        for url in recents {
            let item = recentProjectMenuItem(for: url)
            menu.addItem(item)
        }
        return menu
    }

    // MARK: - Windows

    @discardableResult
    private func makeWindow() -> WorkspaceWindowController {
        let controller = WorkspaceWindowController()
        controller.onClose = { [weak self] closed in
            self?.windows.removeAll { $0 === closed }
        }
        controller.onOpenRequested = { [weak self, weak controller] urls in
            self?.openURLs(urls, from: controller)
        }
        windows.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    /// ⌘N — an empty window: the welcome screen with recent projects and an
    /// Open Folder button. Nothing is assumed about which project it is for.
    @objc private func newWindow(_ sender: Any?) {
        _ = makeWindow()
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
            // Skip if openFiles already gave this window a project.
            if let preset, !preset.isEmpty, !controller.hasProject {
                controller.openProject(URL(fileURLWithPath: preset))
            }
            for f in fileArgs { controller.editor.open(url: URL(fileURLWithPath: f)) }

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
                controller.sidebar.performSearch(args[i + 1])
            }
            if let i = args.firstIndex(of: "--find"), i + 1 < args.count {
                controller.editor.showFindBar(seed: args[i + 1])
            }
            // `--history N`: open the History tab and expand the Nth commit.
            if let i = args.firstIndex(of: "--history"), i + 1 < args.count,
                let n = Int(args[i + 1]) {
                controller.sidebar.showGit()
                controller.sidebar.showHistory()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    controller.sidebar.expandCommit(at: n)
                    // `--history-file M` also opens that file's diff.
                    if let j = args.firstIndex(of: "--history-file"), j + 1 < args.count,
                        let m = Int(args[j + 1]) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            controller.sidebar.openCommitFile(commitIndex: n, fileIndex: m)
                        }
                    }
                }
            }
            // `--diff <relative-path>`: show that file's git diff (scripting).
            if let i = args.firstIndex(of: "--diff"), i + 1 < args.count,
               let dir = controller.projectURL {
                let path = args[i + 1]
                if let entry = GitService.status(in: dir).entries.first(where: { $0.path == path }) {
                    controller.sidebar.showGit()
                    controller.showDiff(for: entry, in: dir)
                }
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
        appMenu.addItem(withTitle: "Settings…",
                        action: #selector(WorkspaceWindowController.showSettings(_:)),
                        keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Puzzle",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Open…",
                         action: #selector(WorkspaceWindowController.openFolder(_:)), keyEquivalent: "o")
        // Open Recent uses the same project-window matching as Open.
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recentMenu.delegate = self
        recentItem.submenu = recentMenu
        fileMenu.addItem(recentItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Quick Open…",
                         action: #selector(WorkspaceWindowController.quickOpen(_:)),
                         keyEquivalent: "p")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Save",
                         action: #selector(WorkspaceWindowController.saveDocument(_:)), keyEquivalent: "s")
        fileMenu.addItem(.separator())
        // ⌘W closes the tab, as it does in every editor; the window needs the
        // shift. Closing the last tab still closes the window.
        fileMenu.addItem(withTitle: "Close Tab",
                         action: #selector(WorkspaceWindowController.closeTab(_:)),
                         keyEquivalent: "w")
        let closeWindow = NSMenuItem(title: "Close Window",
                                     action: #selector(NSWindow.performClose(_:)),
                                     keyEquivalent: "w")
        closeWindow.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(closeWindow)
        // ⇧⌘T is the browser's gesture for the same slip of the hand.
        fileMenu.addItem(withTitle: "Reopen Closed Tab",
                         action: #selector(WorkspaceWindowController.reopenClosedTab(_:)),
                         keyEquivalent: "T")
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
        let replaceItem = NSMenuItem(
            title: "Find and Replace…",
            action: #selector(WorkspaceWindowController.findAndReplace(_:)),
            keyEquivalent: "f")
        replaceItem.keyEquivalentModifierMask = [.command, .option]
        editMenu.addItem(replaceItem)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Go to Line…",
                         action: #selector(WorkspaceWindowController.goToLine(_:)),
                         keyEquivalent: "l")
        editMenu.addItem(.separator())
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
        viewMenu.addItem(withTitle: "Show Sidebar",
                         action: #selector(WorkspaceWindowController.showSidebar(_:)), keyEquivalent: "b")
        viewMenu.addItem(.separator())
        // The shortcut every tabbed editor and browser uses; without it the
        // tabs could only be reached with the mouse.
        let nextTab = NSMenuItem(title: "Next Tab",
                                 action: #selector(WorkspaceWindowController.selectNextTab(_:)),
                                 keyEquivalent: "]")
        nextTab.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(nextTab)
        let previousTab = NSMenuItem(
            title: "Previous Tab",
            action: #selector(WorkspaceWindowController.selectPreviousTab(_:)),
            keyEquivalent: "[")
        previousTab.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(previousTab)
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
        let recents = recentProjects.urls
        if recents.isEmpty {
            let empty = NSMenuItem(title: "No Recent Projects", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for url in recents {
            menu.addItem(recentProjectMenuItem(for: url))

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

    private func recentProjectMenuItem(for url: URL) -> NSMenuItem {
        let item = NSMenuItem(title: url.lastPathComponent,
                              action: #selector(openRecent(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = url
        item.toolTip = url.path
        return item
    }

    /// Raise an existing project window when opening it again from Recents.
    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        openURLs([url], from: activeController)
    }

    @objc private func removeRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        recentProjects.remove(url)
    }

    @objc private func clearRecents() { recentProjects.clear() }

    @objc private func settingsChanged() {
        // Fonts and metrics are baked into each cached highlighter's attribute
        // table, so the cache cannot survive a settings change.
        HighlightService.shared.evictUnused(keeping: [])
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

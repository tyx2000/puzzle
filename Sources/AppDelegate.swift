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

    /// The appearance has to be in place before any view exists: `openFiles:`
    /// — how Finder and `gift` start the app with a project — runs *before*
    /// `applicationDidFinishLaunching`.
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before anything else can throw: a crash report names the frames but
        // not the exception, and the reason is what says which invariant went.
        ExceptionLog.install()
        Theme.applyAppearance()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Theme.applyAppearance()
        LauncherInstaller.installIfNeeded()
        setupMenu()
        setupMemoryPressureHandling()

        // When the app is launched WITH a folder (Finder open-with, or `gift`),
        // `application(_:openFiles:)` fires BEFORE this method and has already
        // made a window for it. Creating one unconditionally here left an extra
        // empty welcome window alongside the project.
        let controller = windows.first ?? makeWindow()
        NSApp.activate(ignoringOtherApps: true)
        applyLaunchArguments(to: controller)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// FSEvents normally delivers external Git changes while Gift is in the
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
            FileIcons.releaseTransientMemory()
        }
        source.resume()
        memoryPressureSource = source
    }

    /// Finder and `gift` use the same routing as the in-app folder picker.
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        // This can be the first delegate call of the process, before any
        // window exists.
        Theme.applyAppearance()
        let handled = openURLs(filenames.map { URL(fileURLWithPath: $0) })
        NSApp.activate(ignoringOtherApps: true)
        sender.reply(toOpenOrPrint: handled ? .success : .failure)
    }

    /// Reuse an owning project before considering the requesting start-page
    /// window or creating a workspace. Every external/open-panel entry point
    /// goes through this method so it cannot create duplicate project windows.
    ///
    /// Gift opens folders. A file stands for the folder it is in, so dropping
    /// one on the Dock icon still opens something sensible.
    @discardableResult
    func openURLs(_ urls: [URL], from source: WorkspaceWindowController? = nil) -> Bool {
        var handled = false
        var folders: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard url.isFileURL,
                  FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            let folder = (isDir.boolValue ? url : url.deletingLastPathComponent())
                .standardizedFileURL.resolvingSymlinksInPath()
            if !folders.contains(folder) { folders.append(folder) }
        }
        for url in folders {
            let welcome = source.flatMap { $0.hasProject ? nil : $0 }
                ?? windows.first { !$0.hasProject }
            // Already open somewhere: switch that window to it rather than
            // stacking a second copy of the same workspace.
            if let found = Self.projectIndex(matching: url,
                                             in: windows.map(\.projects)) {
                let target = windows[found.window]
                target.activateProject(found.project)
                target.window?.makeKeyAndOrderFront(nil)
            } else if let source, source.hasProject {
                // Asked for from a window — its own `+`, or its folder picker
                // — so it joins that window's projects.
                source.openProject(url)
                source.window?.makeKeyAndOrderFront(nil)
            } else {
                let target = welcome ?? makeWindow()
                target.openProject(url)
                target.window?.makeKeyAndOrderFront(nil)
            }
            handled = true
        }
        return handled
    }

    var windowsForTesting: [WorkspaceWindowController] { windows }

    /// The window holding this project, whether or not it is the one showing.
    func window(showingProject url: URL) -> WorkspaceWindowController? {
        Self.projectIndex(matching: url, in: windows.map(\.projects))
            .map { windows[$0.window] }
    }

    /// Paths are compared symlink-resolved: `/tmp/x` and `/private/tmp/x` are
    /// the same project, and a plain string comparison would miss that.
    private static func normalized(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// The window holding exactly this project.
    static func projectIndex(matching url: URL,
                             in projects: [[URL]]) -> (window: Int, project: URL)? {
        let path = normalized(url)
        for (index, roots) in projects.enumerated() {
            if let match = roots.first(where: { normalized($0) == path }) {
                return (window: index, project: match)
            }
        }
        return nil
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

    /// ⌘N — an empty window: the start page with recent projects and an
    /// Open button. Nothing is assumed about which project it is for.
    @objc private func newWindow(_ sender: Any?) {
        _ = makeWindow()
    }

    // MARK: - Launch arguments

    private func applyLaunchArguments(to controller: WorkspaceWindowController) {
        let args = CommandLine.arguments
        let preset = args.dropFirst().first(where: {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue
        }) ?? ProcessInfo.processInfo.environment["GIFT_OPEN"]

        DispatchQueue.main.async {
            // No auto folder-picker: with no arguments the window shows the
            // start page (recent projects + an Open button). Skip if openFiles
            // already gave this window a project.
            if let preset, !preset.isEmpty, !controller.hasProject {
                controller.openProject(URL(fileURLWithPath: preset))
            }
            // `--diff <relative-path>`: show that file's diff (scripting).
            if let i = args.firstIndex(of: "--diff"), i + 1 < args.count,
               let dir = controller.projectURL {
                let path = args[i + 1]
                if let entry = GitService.status(in: dir).entries.first(where: { $0.path == path }) {
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
        appMenu.addItem(withTitle: "About Gift", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Gift",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Gift",
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
        // ⌘W closes the diff tab; the window needs the shift. With no tab
        // open ⌘W still closes the window.
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

        // Copy for the diff, and the text editing the commit line needs.
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
        editMenuItem.submenu = editMenu

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Refresh",
                         action: #selector(WorkspaceWindowController.refreshRepository(_:)),
                         keyEquivalent: "r")
        viewMenu.addItem(.separator())
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

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Gift"
        alert.informativeText = "A minimal native Git client.\nSwift + AppKit."
        alert.runModal()
    }
}

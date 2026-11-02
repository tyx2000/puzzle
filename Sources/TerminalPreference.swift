import AppKit

/// Which terminal a project opens in, from the title band's T and the file
/// tree's Open in Terminal alike. Picked from T's right-click menu and kept
/// across launches; with none picked, or the one picked since removed, iTerm
/// where it is installed and Terminal otherwise.
enum TerminalPreference {
    struct App: Equatable {
        let bundleID: String
        let name: String
        let url: URL
    }

    static let iTermID = "com.googlecode.iterm2"
    static let terminalID = "com.apple.Terminal"
    /// Every terminal the menu offers, in its order. Each opens a shell in a
    /// folder handed to it; iTerm is asked by script instead, for a window of
    /// its own.
    static let known: [(bundleID: String, name: String)] = [
        (iTermID, "iTerm2"),
        (terminalID, "Terminal"),
        ("com.mitchellh.ghostty", "Ghostty"),
    ]
    /// Tried in this order with none picked: any other only ever by choice.
    static let fallbackOrder = [iTermID, terminalID]

    static let defaultsKey = "terminal_app"
    /// Where the pick is kept. Injectable, so a test picking one does not
    /// reach into the user's own defaults.
    static var defaults: UserDefaults = .standard
    /// Posted when a terminal is picked, so every window's T names it.
    static let changed = Notification.Name("PuzzleTerminalPreferenceChanged")

    typealias Lookup = (String) -> URL?
    static let workspaceLookup: Lookup = {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
    }

    /// The terminals installed here, in the menu's order.
    static func installed(lookup: Lookup = workspaceLookup) -> [App] {
        known.compactMap { entry in
            lookup(entry.bundleID).map { App(bundleID: entry.bundleID, name: entry.name, url: $0) }
        }
    }

    /// The one a click opens.
    static func current(lookup: Lookup = workspaceLookup) -> App? {
        let apps = installed(lookup: lookup)
        if let picked = defaults.string(forKey: defaultsKey),
           let app = apps.first(where: { $0.bundleID == picked }) {
            return app
        }
        return fallbackOrder.lazy.compactMap { id in apps.first { $0.bundleID == id } }.first
    }

    static func choose(_ bundleID: String) {
        defaults.set(bundleID, forKey: defaultsKey)
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

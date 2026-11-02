import Foundation

/// The windows open when Puzzle last quit, front to back, put back at the
/// next launch. Saved on ⌘Q, and when the last window closes — which quits
/// too, and is how many quit — so that window comes back as well.
enum WindowSession {
    static let defaultsKey = "session_windows"
    /// Where the session is kept. Injectable, so a test quitting does not
    /// write over the user's own.
    static var defaults: UserDefaults = .standard

    /// Windows holding no project are the start page, which a launch gives
    /// anyway; they are not kept.
    static func save(_ windows: [WorkspaceWindowController.Session]) {
        let kept = windows.filter { !$0.projects.isEmpty }
        guard let data = try? JSONEncoder().encode(kept) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    static func load() -> [WorkspaceWindowController.Session] {
        guard let data = defaults.data(forKey: defaultsKey),
              let windows = try? JSONDecoder().decode([WorkspaceWindowController.Session].self,
                                                      from: data)
        else { return [] }
        return windows
    }
}

import Foundation

/// Recently opened project folders, persisted in UserDefaults.
/// Backs both the welcome screen and File ▸ Open Recent.
final class RecentProjects {
    static let shared = RecentProjects()
    static let didChange = Notification.Name("PuzzleRecentProjectsDidChange")

    private let key = "PuzzleRecentProjects"
    private let limit = 12

    /// Most-recent first, with entries that no longer exist filtered out.
    var urls: [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        var seen = Set<String>()
        return paths.compactMap { path -> URL? in
            guard !seen.contains(path) else { return nil }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
                  isDir.boolValue else { return nil }
            seen.insert(path)
            return URL(fileURLWithPath: path)
        }
    }

    func add(_ url: URL) {
        let path = url.standardizedFileURL.path
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        if paths.count > limit { paths = Array(paths.prefix(limit)) }
        UserDefaults.standard.set(paths, forKey: key)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Drop a single entry from the history.
    func remove(_ url: URL) {
        let path = url.standardizedFileURL.path
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        let before = paths.count
        paths.removeAll { $0 == path }
        guard paths.count != before else { return }
        UserDefaults.standard.set(paths, forKey: key)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// "~/Desktop/Puzzle" — the parent folder, shown under each entry.
    static func displayParent(for url: URL) -> String {
        let parent = url.deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return parent.hasPrefix(home) ? "~" + parent.dropFirst(home.count) : parent
    }
}

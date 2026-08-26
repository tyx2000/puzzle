import Foundation

/// Fuzzy file lookup behind ⌘P: the project's files, ranked against what the
/// user has typed so far.
enum QuickOpen {
    /// Directories never worth listing — the same set project search skips.
    static let skipDirectories: Set<String> = [
        ".git", "node_modules", ".build", "build", "DerivedData", ".svn", "Pods", ".obj",
    ]
    static let maxFiles = 20_000
    static let maxResults = 50

    /// Project-relative paths, in directory order. Bounded so a huge checkout
    /// cannot make ⌘P allocate without limit.
    static func index(in directory: URL) -> [String] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: directory,
                                         includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles]) else { return [] }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        var paths: [String] = []
        for case let url as URL in walker {
            if skipDirectories.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(prefix) else { continue }
            paths.append(String(path.dropFirst(prefix.count)))
            if paths.count >= maxFiles { break }
        }
        return paths
    }

    /// Subsequence match with a score: consecutive hits, matches right after a
    /// separator, and matches in the file name rather than the directory all
    /// count for more, which is what makes "epvc" find EditorPaneViewController.
    static func score(_ path: String, query: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        let haystack = Array(path.lowercased())
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        let nameStart = (path as NSString).deletingLastPathComponent.isEmpty
            ? 0 : (path as NSString).deletingLastPathComponent.count + 1

        var score = 0
        var index = 0
        var previousMatch = -2
        for character in needle {
            var found = -1
            var cursor = index
            while cursor < haystack.count {
                if haystack[cursor] == character { found = cursor; break }
                cursor += 1
            }
            guard found >= 0 else { return nil }
            score += 10
            if found == previousMatch + 1 { score += 12 }        // consecutive
            if found == 0 || haystack[found - 1] == "/" { score += 8 }
            if found == nameStart { score += 10 }
            if found >= nameStart { score += 6 }                  // in the file name
            previousMatch = found
            index = found + 1
        }
        // Shorter paths win ties, so `App.swift` beats `deep/nested/App.swift`.
        return score - path.count / 8
    }

    static func matches(_ paths: [String], query: String, limit: Int = maxResults) -> [String] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return Array(paths.prefix(limit))
        }
        var scored: [(path: String, score: Int)] = []
        for path in paths {
            guard let value = score(path, query: query) else { continue }
            scored.append((path, value))
        }
        scored.sort { left, right in
            if left.score != right.score { return left.score > right.score }
            return left.path.localizedStandardCompare(right.path) == .orderedAscending
        }
        return scored.prefix(limit).map(\.path)
    }

    /// "12" jumps to a line, "12:8" to a column too. Nil when it is not one.
    static func lineTarget(_ query: String) -> (line: Int, column: Int?)? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", maxSplits: 1).map(String.init)
        guard let line = Int(parts[0]), line > 0 else { return nil }
        guard parts.count == 2 else { return (line, nil) }
        guard let column = Int(parts[1]), column > 0 else { return (line, nil) }
        return (line, column)
    }
}

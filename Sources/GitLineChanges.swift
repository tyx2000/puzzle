import AppKit

/// Uncommitted changes for one file, positioned by line so the editor's gutter
/// can mark them: added lines, modified lines, and the gaps where lines were
/// deleted. Built from `git diff HEAD -U0`, which reports hunks with no context.
enum GitLineChanges {
    struct Change: Equatable {
        enum Kind: Equatable { case added, modified, deleted }
        let kind: Kind
        /// Lines in the file as it is now. A deletion has no lines of its own,
        /// so it is pinned to the line it sits above (or below, at the top).
        let lines: ClosedRange<Int>
        /// What was there before, for the popover.
        let removed: [String]
        /// What is there now.
        let added: [String]

        var colour: NSColor {
            switch kind {
            case .added: return Theme.diffAddedText
            case .modified: return Theme.blue
            case .deleted: return Theme.diffRemovedText
            }
        }
    }

    /// `git diff -U0` for one path, parsed into per-line marks. Returns an empty
    /// list for anything Git does not track or cannot diff.
    static func changes(for file: URL, in repository: URL) -> [Change] {
        let path = file.standardizedFileURL.resolvingSymlinksInPath().path
        let root = repository.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return [] }
        let relative = String(path.dropFirst(prefix.count))
        // Against HEAD, not the index: Puzzle stages every change as you make
        // it, so a plain `git diff` reports nothing for the very files the
        // gutter exists to mark. Diffing HEAD also covers new files, which are
        // staged whole.
        let result = GitService.run(
            ["--no-pager", "diff", "--no-color", "--no-ext-diff", "-U0", "HEAD", "--", relative],
            in: repository)
        guard result.code == 0 else { return [] }
        return parse(result.out)
    }

    static func parse(_ diff: String) -> [Change] {
        var changes: [Change] = []
        var removed: [String] = []
        var added: [String] = []
        var oldStart = 0
        var newStart = 0
        var inHunk = false

        func flush() {
            defer {
                removed.removeAll()
                added.removeAll()
            }
            guard !removed.isEmpty || !added.isEmpty else { return }
            if added.isEmpty {
                // Nothing left on this side: mark the line the deletion sits
                // above, or the first line when it was cut from the very top.
                let anchor = max(1, newStart)
                changes.append(Change(kind: .deleted, lines: anchor...anchor,
                                      removed: removed, added: []))
                return
            }
            let start = max(1, newStart)
            let end = start + added.count - 1
            changes.append(Change(kind: removed.isEmpty ? .added : .modified,
                                  lines: start...end, removed: removed, added: added))
        }

        for rawLine in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("@@") {
                flush()
                guard let hunk = hunkRanges(line) else {
                    inHunk = false
                    continue
                }
                oldStart = hunk.oldStart
                // A hunk that only deletes reports the line *before* the cut as
                // its new start, so the mark belongs on the next line.
                newStart = hunk.newCount == 0 ? hunk.newStart + 1 : hunk.newStart
                inHunk = true
                continue
            }
            guard inHunk, let first = line.first else {
                flush()
                inHunk = false
                continue
            }
            switch first {
            case "-": removed.append(String(line.dropFirst()))
            case "+": added.append(String(line.dropFirst()))
            case "\\": break
            default:
                flush()
                inHunk = false
            }
            _ = oldStart
        }
        flush()
        return changes
    }

    /// `@@ -12,3 +12,0 @@` → old (12, 3), new (12, 0).
    private static func hunkRanges(_ line: String)
        -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
        let parts = line.split(separator: " ")
        guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { return nil }
        func split(_ field: Substring) -> (Int, Int)? {
            let numbers = field.dropFirst().split(separator: ",")
            guard let start = Int(numbers[0]) else { return nil }
            guard numbers.count > 1 else { return (start, 1) }
            guard let count = Int(numbers[1]) else { return nil }
            return (start, count)
        }
        guard let old = split(parts[1]), let new = split(parts[2]) else { return nil }
        return (old.0, old.1, new.0, new.1)
    }

    /// The change covering a line, if any.
    static func change(at line: Int, in changes: [Change]) -> Change? {
        changes.first { $0.lines.contains(line) }
    }
}

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
    ///
    /// The editor marks the buffer with `changes(from:to:)` instead, since the
    /// file on disk is stale the moment the user types. This stays as the
    /// reference the tests hold that diff against: if the two ever disagree,
    /// the marks would jump the moment a file was saved.
    static func changes(for file: URL, in repository: URL) -> [Change] {
        guard let relative = relativePath(for: file, in: repository) else { return [] }
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


    // MARK: - Live marks

    /// HEAD's copy of a file, split into lines. `nil` when Git has nothing to
    /// compare against — the path is untracked or ignored — which is also the
    /// case where `git diff` reports nothing and the gutter stays clean.
    static func baseline(for file: URL, in repository: URL) -> [String]? {
        guard let relative = relativePath(for: file, in: repository) else { return nil }
        let head = GitService.run(
            ["--no-pager", "show", "HEAD:" + relative], in: repository)
        if head.code == 0 {
            // A binary blob has no lines to mark, and splitting one would only
            // produce noise.
            guard !head.out.utf16.contains(0) else { return nil }
            return lines(of: head.out)
        }
        // Not in HEAD yet. A path Git already knows about — Puzzle stages new
        // files as they are created — is new in its entirety; anything else is
        // none of the gutter's business.
        let tracked = GitService.run(["ls-files", "--", relative], in: repository)
        guard tracked.code == 0, !tracked.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return []
    }

    /// Git's own line splitting: the trailing newline terminates the last line
    /// rather than starting an empty one.
    static func lines(of text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// The same marks `git diff HEAD -U0` produces, computed here instead of by
    /// a subprocess, so the gutter can follow the buffer while it is still
    /// unsaved. Grouping matches the parser above: a run of removals with
    /// replacements is one modification, a run without them is a deletion
    /// pinned to the line it sat above.
    static func changes(from base: [String], to current: [String]) -> [Change] {
        guard base != current else { return [] }
        let difference = current.difference(from: base)
        guard !difference.isEmpty else { return [] }
        var removedAt = Set<Int>()
        var insertedAt = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removedAt.insert(offset)
            case .insert(let offset, _, _): insertedAt.insert(offset)
            }
        }

        var changes: [Change] = []
        var removed: [String] = []
        var added: [String] = []
        var oldIndex = 0
        var newIndex = 0

        /// `newIndex` counts the current-file lines already matched, so the
        /// next one is `newIndex + 1` — where an addition starts, and where a
        /// deletion is anchored.
        func flush() {
            defer {
                removed.removeAll()
                added.removeAll()
            }
            guard !removed.isEmpty || !added.isEmpty else { return }
            let start = max(1, newIndex - added.count + 1)
            if added.isEmpty {
                let anchor = max(1, newIndex + 1)
                changes.append(Change(kind: .deleted, lines: anchor...anchor,
                                      removed: removed, added: []))
                return
            }
            changes.append(Change(kind: removed.isEmpty ? .added : .modified,
                                  lines: start...(start + added.count - 1),
                                  removed: removed, added: added))
        }

        while oldIndex < base.count || newIndex < current.count {
            if oldIndex < base.count, removedAt.contains(oldIndex) {
                removed.append(base[oldIndex])
                oldIndex += 1
                continue
            }
            if newIndex < current.count, insertedAt.contains(newIndex) {
                added.append(current[newIndex])
                newIndex += 1
                continue
            }
            flush()
            oldIndex += 1
            newIndex += 1
        }
        flush()
        return changes
    }

    private static func relativePath(for file: URL, in repository: URL) -> String? {
        let path = file.standardizedFileURL.resolvingSymlinksInPath().path
        let root = repository.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    /// The change covering a line, if any.
    static func change(at line: Int, in changes: [Change]) -> Change? {
        changes.first { $0.lines.contains(line) }
    }
}

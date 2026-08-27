import AppKit

/// Turns a unified diff into aligned left/right rows for the side-by-side view.
///
/// Alignment is what makes the mode worth having: inside one hunk the removed
/// lines are paired with the added ones in order, so a rewritten line sits
/// opposite its replacement, and whichever side runs out is padded with blanks.
enum SideBySideDiff {
    struct Row: Equatable {
        enum Kind: Equatable { case context, change, hunk }
        let kind: Kind
        let leftNumber: Int?
        let leftText: String?
        let rightNumber: Int?
        let rightText: String?
        /// Set for `.hunk`, which spans both columns.
        let header: String?

        static func context(_ left: Int, _ right: Int, _ text: String) -> Row {
            Row(kind: .context, leftNumber: left, leftText: text,
                rightNumber: right, rightText: text, header: nil)
        }
        static func change(left: (Int, String)?, right: (Int, String)?) -> Row {
            Row(kind: .change, leftNumber: left?.0, leftText: left?.1,
                rightNumber: right?.0, rightText: right?.1, header: nil)
        }
        static func hunk(_ header: String) -> Row {
            Row(kind: .hunk, leftNumber: nil, leftText: nil,
                rightNumber: nil, rightText: nil, header: header)
        }

        var isChange: Bool { kind == .change }
    }

    static func rows(from diff: String) -> [Row] {
        var rows: [Row] = []
        var removed: [(Int, String)] = []
        var added: [(Int, String)] = []
        var oldNext = 0
        var newNext = 0
        var inHunk = false

        /// A run of -/+ lines becomes one block of paired rows.
        func flushChanges() {
            guard !removed.isEmpty || !added.isEmpty else { return }
            for index in 0..<max(removed.count, added.count) {
                rows.append(.change(left: index < removed.count ? removed[index] : nil,
                                    right: index < added.count ? added[index] : nil))
            }
            removed.removeAll()
            added.removeAll()
        }

        for rawLine in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("@@") {
                flushChanges()
                if let start = hunkStart(line) {
                    oldNext = start.old
                    newNext = start.new
                    inHunk = true
                    rows.append(.hunk(line))
                } else {
                    inHunk = false
                }
                continue
            }
            guard inHunk, let first = line.first else {
                flushChanges()
                inHunk = false
                continue
            }
            let body = String(line.dropFirst())
            switch first {
            case "-":
                removed.append((oldNext, body))
                oldNext += 1
            case "+":
                added.append((newNext, body))
                newNext += 1
            case " ":
                flushChanges()
                rows.append(.context(oldNext, newNext, body))
                oldNext += 1
                newNext += 1
            case "\\":
                break                       // "\ No newline at end of file"
            default:
                flushChanges()
                inHunk = false
            }
        }
        flushChanges()
        return rows
    }

    /// `@@ -12,7 +14,9 @@ func f()` → (12, 14).
    private static func hunkStart(_ line: String) -> (old: Int, new: Int)? {
        let parts = line.split(separator: " ")
        guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+"),
              let old = Int(parts[1].dropFirst().prefix { $0 != "," }),
              let new = Int(parts[2].dropFirst().prefix { $0 != "," }) else { return nil }
        return (old, new)
    }

    /// Indices where a run of changed rows begins — what the ↑↓ buttons step
    /// between, so both diff modes move by the same notion of "a change".
    static func changeBlockStarts(_ rows: [Row]) -> [Int] {
        var starts: [Int] = []
        var previousWasChange = false
        for (index, row) in rows.enumerated() {
            if row.isChange, !previousWasChange { starts.append(index) }
            previousWasChange = row.isChange
        }
        return starts
    }
}

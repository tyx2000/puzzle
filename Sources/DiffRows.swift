import AppKit

/// Turns a unified diff into the rows the diff view draws.
///
/// `rows(from:)` is the side-by-side form: aligned left/right rows.
/// Alignment is what makes the mode worth having: inside one hunk the removed
/// lines are paired with the added ones in order, so a rewritten line sits
/// opposite its replacement, and whichever side runs out is padded with blanks.
enum DiffRows {
    /// How many lines of a diff are turned into rows. A row costs far more
    /// than the line it stands for — the struct, plus a string per side — so
    /// a generated file's million-line diff modelled in full cost hundreds of
    /// megabytes for something nobody reads to the end. What is left out is
    /// counted and said, above the diff.
    static var lineBudget = 50_000

    /// A parsed diff, and what the budget left out of it.
    struct Parsed: Equatable {
        var rows: [Row] = []
        /// Lines past the budget, not modelled. Zero when the diff is whole.
        var omittedLines = 0
    }

    /// The diff's lines, up to `budget` of them, and how many were left.
    private static func lines(of diff: String, budget: Int)
        -> (lines: [Substring], omitted: Int) {
        var pieces = diff.split(separator: "\n", maxSplits: max(0, budget),
                                omittingEmptySubsequences: false)
        // `maxSplits` leaves everything past the budget in one last piece,
        // which is the part being dropped — counted here rather than parsed.
        guard pieces.count > budget else { return (pieces, 0) }
        let rest = pieces.removeLast()
        guard !rest.isEmpty else { return (pieces, 0) }
        // Counted without splitting it: making substrings for the part being
        // dropped is the work the budget exists to avoid. A trailing newline
        // ends the last line rather than starting another.
        var newlines = 0
        for character in rest where character == "\n" { newlines += 1 }
        return (pieces, rest.hasSuffix("\n") ? newlines : newlines + 1)
    }

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

    /// The unified form: every line in the order Git wrote it, removed lines
    /// carrying only their old number and added lines only their new one.
    /// File headers are left out — the strip above the diff names the file.
    static func unified(from diff: String, budget: Int = lineBudget) -> Parsed {
        var rows: [Row] = []
        var oldNext = 0
        var newNext = 0
        var inHunk = false
        let read = lines(of: diff, budget: budget)
        for rawLine in read.lines {
            let line = String(rawLine)
            if line.hasPrefix("@@") {
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
                inHunk = false
                continue
            }
            let body = String(line.dropFirst())
            switch first {
            case "-":
                rows.append(.change(left: (oldNext, body), right: nil))
                oldNext += 1
            case "+":
                rows.append(.change(left: nil, right: (newNext, body)))
                newNext += 1
            case " ":
                rows.append(.context(oldNext, newNext, body))
                oldNext += 1
                newNext += 1
            case "\\":
                break                       // "\ No newline at end of file"
            default:
                inHunk = false
            }
        }
        return Parsed(rows: rows, omittedLines: read.omitted)
    }

    static func sideBySide(from diff: String, budget: Int = lineBudget) -> Parsed {
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

        let read = lines(of: diff, budget: budget)
        for rawLine in read.lines {
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
        return Parsed(rows: rows, omittedLines: read.omitted)
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

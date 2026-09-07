import Foundation

/// Reads a unified diff back into the file it describes.
///
/// The diff tab is editable, so what the user types on the new side has to end
/// up in the source file. That means replaying the diff rather than diffing:
/// the hunks say which lines of the old side they replace, and everything the
/// diff does not mention is carried through untouched.
enum UnifiedDiff {
    /// One `@@` block: where it starts on the old side, and its body lines with
    /// their leading marker still attached.
    struct Hunk: Equatable {
        /// 1-based line on the old side. A hunk against an empty file reports
        /// 0, which means "before line 1".
        let oldStart: Int
        /// The old-side count from the header. Zero means the hunk inserts
        /// *between* two lines rather than replacing any of them, which puts
        /// the insertion one line further down.
        let oldCount: Int
        let body: [Line]

        struct Line: Equatable {
            enum Kind { case context, removed, added }
            let kind: Kind
            let text: String
        }
    }

    /// What one pass over a diff found: its hunks, and what its
    /// `\ No newline at end of file` markers said about each side's last line.
    private struct Parsed {
        var hunks: [Hunk]?
        var newSideLacksNewline = false
        var oldSideLacksNewline = false
    }

    /// The hunks of a single-file diff, or nil when the text is not one.
    ///
    /// Headers are skipped rather than validated: the user is editing this text
    /// by hand, and a diff is still perfectly applicable with its `index` line
    /// mangled or missing.
    static func hunks(in diff: String) -> [Hunk]? { parse(diff).hunks }

    private static func parse(_ diff: String) -> Parsed {
        var parsed = Parsed()
        var hunks: [Hunk] = []
        var start: Int?
        var oldCount = 0
        var body: [Hunk.Line] = []
        var inHunk = false
        func flush() {
            if let start {
                hunks.append(Hunk(oldStart: start, oldCount: oldCount, body: body))
            }
            start = nil
            oldCount = 0
            body = []
        }
        // `lines(of:)` rather than a plain split: the diff's own trailing
        // newline would otherwise arrive as an empty final line and be read as
        // a context line the file does not have.
        for raw in lines(of: diff) {
            if raw.hasPrefix("@@") {
                flush()
                guard let header = header(raw) else { return Parsed() }
                start = header.oldStart
                oldCount = header.oldCount
                inHunk = true
                continue
            }
            // Outside a hunk every line is header material — `diff --git`, the
            // `index` line, the `---`/`+++` file names — and none of it is
            // needed to replay a body over the pre-image.
            //
            // Inside one, those same shapes are *content*: deleting the line
            // `-- comment` from a Lua or SQL file writes `--- comment` into the
            // hunk. Reading that as a file header truncated the hunk there and
            // silently applied the half of it that had been parsed — over the
            // top of the user's file.
            guard inHunk else { continue }
            if raw.hasPrefix("diff --git") {
                flush()
                inHunk = false
                continue
            }
            if raw.hasPrefix("\\") {
                // "\ No newline at end of file" describes the body line above
                // it, and so says which side is missing its final newline.
                switch body.last?.kind {
                case .added, .context: parsed.newSideLacksNewline = true
                case .removed: parsed.oldSideLacksNewline = true
                case nil: break
                }
                continue
            }
            if raw.isEmpty {
                // Git writes a context line for a blank line as a single space,
                // but editors strip trailing whitespace. Treat a bare empty
                // line inside a hunk as that context line.
                body.append(Hunk.Line(kind: .context, text: ""))
                continue
            }
            let text = String(raw.dropFirst())
            switch raw.first {
            case " ": body.append(Hunk.Line(kind: .context, text: text))
            case "-": body.append(Hunk.Line(kind: .removed, text: text))
            case "+": body.append(Hunk.Line(kind: .added, text: text))
            default:
                flush()
                inHunk = false
            }
        }
        flush()
        parsed.hunks = hunks.isEmpty ? nil : hunks
        return parsed
    }

    /// `@@ -12,7 +12,9 @@` → (12, 7). A field with no comma covers one line.
    ///
    /// The counts do not decide where the body ends — once the user has edited
    /// it the body is the truth, which is what `git apply --recount` does. The
    /// old count is read for one thing only: telling an insertion between two
    /// lines apart from a replacement of one.
    private static func header(_ line: String) -> (oldStart: Int, oldCount: Int)? {
        guard let range = line.range(of: "-") else { return nil }
        let rest = line[range.upperBound...]
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, let start = Int(digits) else { return nil }
        let after = rest[digits.endIndex...]
        guard after.hasPrefix(",") else { return (start, 1) }
        return (start, Int(after.dropFirst().prefix { $0.isNumber }) ?? 1)
    }

    /// The new side of `diff`, built by replaying it over `baseline`.
    ///
    /// Returns nil when the hunks cannot be laid over the baseline — out of
    /// order, past its end, overlapping. Nothing partial is ever returned: a
    /// half-applied diff written to a source file would be worse than an error.
    static func apply(_ diff: String, to baseline: String) -> String? {
        let parsed = parse(diff)
        guard let hunks = parsed.hunks else { return nil }
        let old = lines(of: baseline)
        var result: [String] = []
        var cursor = 0                      // 0-based index into `old`
        for hunk in hunks {
            // `@@ -2,0 +3 @@` inserts *after* old line 2 — a hunk with no old
            // lines sits between two of them rather than replacing one, so it
            // does not step back the way every other hunk does. The header is
            // believed about that only while the body agrees with it, since the
            // body is the half the user edits. `@@ -0,0` — the whole file was
            // empty — lands at line 1 either way.
            let insertsBetweenLines = hunk.oldCount == 0
                && !hunk.body.contains { $0.kind != .added }
            let start = insertsBetweenLines ? hunk.oldStart : max(0, hunk.oldStart - 1)
            guard start >= cursor, start <= old.count else { return nil }
            result.append(contentsOf: old[cursor..<start])
            cursor = start
            for line in hunk.body {
                switch line.kind {
                case .context:
                    // The text comes from the hunk, not from the baseline: an
                    // edited context line is an edit to the file like any other.
                    guard cursor < old.count else { return nil }
                    result.append(line.text)
                    cursor += 1
                case .removed:
                    guard cursor < old.count else { return nil }
                    cursor += 1
                case .added:
                    result.append(line.text)
                }
            }
        }
        result.append(contentsOf: old[cursor...])
        return joined(result, baseline: baseline, parsed: parsed)
    }

    /// Git's line splitting: a trailing newline terminates the last line rather
    /// than starting an empty one.
    static func lines(of text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private static func joined(_ lines: [String], baseline: String,
                               parsed: Parsed) -> String {
        guard !lines.isEmpty else { return "" }
        let text = lines.joined(separator: "\n")
        // The diff knows something the baseline does not: whether the file it
        // describes ends with a newline. A diff that *adds* the final newline
        // marks only its old side, and reading the answer off the baseline used
        // to take that newline straight back off again.
        if parsed.newSideLacksNewline { return text }
        if parsed.oldSideLacksNewline { return text + "\n" }
        // A file that ended with a newline keeps ending with one. A baseline
        // that was empty — a new file — follows the usual convention instead of
        // the empty string's lack of one.
        return baseline.isEmpty || baseline.hasSuffix("\n") ? text + "\n" : text
    }

    /// The pre-image blob named by the diff's own `index a..b` header, when it
    /// names one that is not the all-zero hash of a new file.
    static func oldBlob(in diff: String) -> String? {
        for raw in diff.components(separatedBy: "\n") {
            guard raw.hasPrefix("index ") else {
                if raw.hasPrefix("@@") { return nil }
                continue
            }
            let field = raw.dropFirst(6).prefix { $0 != " " }
            guard let separator = field.range(of: "..") else { return nil }
            let hash = String(field[field.startIndex..<separator.lowerBound])
            guard !hash.isEmpty, hash.contains(where: { $0 != "0" }) else { return nil }
            return hash
        }
        return nil
    }
}

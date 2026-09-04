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
        let body: [Line]

        struct Line: Equatable {
            enum Kind { case context, removed, added }
            let kind: Kind
            let text: String
        }
    }

    /// The hunks of a single-file diff, or nil when the text is not one.
    ///
    /// Headers are skipped rather than validated: the user is editing this text
    /// by hand, and a diff is still perfectly applicable with its `index` line
    /// mangled or missing.
    static func hunks(in diff: String) -> [Hunk]? {
        var hunks: [Hunk] = []
        var start: Int?
        var body: [Hunk.Line] = []
        func flush() {
            if let start { hunks.append(Hunk(oldStart: start, body: body)) }
            start = nil
            body = []
        }
        // `lines(of:)` rather than a plain split: the diff's own trailing
        // newline would otherwise arrive as an empty final line and be read as
        // a context line the file does not have.
        for raw in lines(of: diff) {
            if raw.hasPrefix("@@") {
                flush()
                guard let parsed = oldStart(ofHeader: raw) else { return nil }
                start = parsed
                continue
            }
            guard start != nil else { continue }
            // A hunk ends at the next header, at a "\ No newline" marker's
            // owner line, or at anything that is not a body line at all.
            if raw.hasPrefix("diff --git") || raw.hasPrefix("--- ") || raw.hasPrefix("+++ ") {
                flush()
                continue
            }
            if raw.hasPrefix("\\") { continue }
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
            default: flush()
            }
        }
        flush()
        return hunks.isEmpty ? nil : hunks
    }

    /// `@@ -12,7 +12,9 @@` → 12. The counts are ignored: the body is the truth
    /// once the user has edited it, which is what `git apply --recount` does.
    private static func oldStart(ofHeader header: String) -> Int? {
        guard let range = header.range(of: "-") else { return nil }
        let rest = header[range.upperBound...]
        let digits = rest.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// The new side of `diff`, built by replaying it over `baseline`.
    ///
    /// Returns nil when the hunks cannot be laid over the baseline — out of
    /// order, past its end, overlapping. Nothing partial is ever returned: a
    /// half-applied diff written to a source file would be worse than an error.
    static func apply(_ diff: String, to baseline: String) -> String? {
        guard let hunks = hunks(in: diff) else { return nil }
        let old = lines(of: baseline)
        var result: [String] = []
        var cursor = 0                      // 0-based index into `old`
        for hunk in hunks {
            // `@@ -0,0` means "the file was empty", which is line 1 for us.
            let start = max(0, hunk.oldStart - 1)
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
        return joined(result, keepingTrailingNewlineOf: baseline)
    }

    /// Git's line splitting: a trailing newline terminates the last line rather
    /// than starting an empty one.
    static func lines(of text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private static func joined(_ lines: [String],
                               keepingTrailingNewlineOf baseline: String) -> String {
        guard !lines.isEmpty else { return "" }
        let text = lines.joined(separator: "\n")
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

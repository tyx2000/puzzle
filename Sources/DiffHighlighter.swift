import AppKit

/// Colours a unified `git diff` buffer: added lines green, removed lines red,
/// hunk headers blue, file headers bold, with a tinted background per line so
/// changes read as blocks rather than stray characters.
enum DiffHighlighter {

    /// What a single diff line represents.
    enum LineKind {
        case fileHeader     // diff --git / index / --- / +++
        case hunkHeader     // @@ -1,4 +1,6 @@
        case added          // +…
        case removed        // -…
        case context        // unchanged

        var foreground: NSColor {
            switch self {
            case .fileHeader: return Theme.dimText
            case .hunkHeader: return Theme.blue
            case .added:      return Theme.diffAddedText
            case .removed:    return Theme.diffRemovedText
            case .context:    return Theme.foreground
            }
        }

        var background: NSColor? {
            switch self {
            case .added:   return Theme.diffAddedBackground
            case .removed: return Theme.diffRemovedBackground
            default:       return nil
            }
        }
    }

    /// Classify one raw diff line.
    static func kind(of line: String) -> LineKind {
        if line.hasPrefix("@@") { return .hunkHeader }
        // Order matters: "+++"/"---" are file headers, not add/remove lines.
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .fileHeader }
        if line.hasPrefix("diff --git") || line.hasPrefix("index ")
            || line.hasPrefix("new file") || line.hasPrefix("deleted file")
            || line.hasPrefix("similarity index") || line.hasPrefix("rename ") {
            return .fileHeader
        }
        if line.hasPrefix("+") { return .added }
        if line.hasPrefix("-") { return .removed }
        return .context
    }

    /// Paint a whole diff buffer, returning the full-width line bands the text
    /// view should draw (see `PuzzleTextView.diffBands`).
    @discardableResult
    static func apply(to storage: NSTextStorage) -> [(range: NSRange, color: NSColor)] {
        var bands: [(range: NSRange, color: NSColor)] = []
        let text = storage.string as NSString
        let full = NSRange(location: 0, length: text.length)
        storage.beginEditing()
        storage.setAttributes(Theme.textAttributes(color: Theme.foreground), range: full)

        text.enumerateSubstrings(in: full, options: [.byLines, .substringNotRequired]) {
            _, _, enclosingRange, _ in
            let lineRange = NSIntersectionRange(enclosingRange, full)
            guard lineRange.length > 0 else { return }
            let line = text.substring(with: lineRange)
            let kind = kind(of: line)

            storage.addAttribute(.foregroundColor, value: kind.foreground, range: lineRange)
            if let bg = kind.background {
                // Recorded, not applied as an attribute — the text view paints
                // these full-width so every changed line reads as a solid block.
                bands.append((lineRange, bg))
            }
            if kind == .hunkHeader || kind == .fileHeader {
                let bold = NSFontManager.shared.convert(Theme.editorFont(),
                                                        toHaveTrait: .boldFontMask)
                storage.addAttribute(.font, value: bold, range: lineRange)
            }
        }
        storage.endEditing()
        return bands
    }

    /// Map every line of a unified diff to the file line number it stands for:
    /// context and added lines carry their number in the new file, removed lines
    /// the number they had in the old one. Headers, and the "\ No newline"
    /// marker, belong to no file line and stay blank in the gutter.
    ///
    /// The result is indexed by zero-based buffer line, so the gutter can look a
    /// line up directly instead of counting hunks itself.
    static func lineNumbers(in text: String) -> [Int?] {
        var numbers: [Int?] = []
        var oldNext = 0
        var newNext = 0
        var inHunk = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("@@") {
                if let start = hunkStart(line) {
                    oldNext = start.old
                    newNext = start.new
                    inHunk = true
                } else {
                    inHunk = false
                }
                numbers.append(nil)
                continue
            }
            // Inside a hunk the first character decides the line's fate, and
            // only there: a body line reading "+++ x" is an addition, not the
            // file header `kind(of:)` would call it.
            guard inHunk, let first = line.first else {
                inHunk = false
                numbers.append(nil)
                continue
            }
            switch first {
            case "+":
                numbers.append(newNext)
                newNext += 1
            case "-":
                numbers.append(oldNext)
                oldNext += 1
            case " ":
                numbers.append(newNext)
                newNext += 1
                oldNext += 1
            case "\\":  // "\ No newline at end of file"
                numbers.append(nil)
            default:      // next file's header — the hunk is over
                inHunk = false
                numbers.append(nil)
            }
        }
        return numbers
    }

    /// First old/new line of a hunk header, e.g. `@@ -12,7 +14,9 @@ func f()`.
    private static func hunkStart(_ line: String) -> (old: Int, new: Int)? {
        let parts = line.split(separator: " ")
        guard parts.count >= 3,
              parts[1].hasPrefix("-"), parts[2].hasPrefix("+"),
              let old = Int(parts[1].dropFirst().prefix { $0 != "," }),
              let new = Int(parts[2].dropFirst().prefix { $0 != "," }) else { return nil }
        return (old, new)
    }

}

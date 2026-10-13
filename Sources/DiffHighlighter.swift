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

    /// The room after a line's marker: one column of the code's own face.
    static var markerGap: CGFloat {
        (" " as NSString).size(withAttributes: [.font: Theme.editorFont()]).width
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

        var lines: [(range: NSRange, kind: LineKind)] = []
        text.enumerateSubstrings(in: full, options: [.byLines, .substringNotRequired]) {
            _, _, enclosingRange, _ in
            let lineRange = NSIntersectionRange(enclosingRange, full)
            guard lineRange.length > 0 else { return }
            let line = text.substring(with: lineRange)
            let kind = kind(of: line)
            lines.append((lineRange, kind))

            storage.addAttribute(.foregroundColor, value: kind.foreground, range: lineRange)
            // A line's `+`, `-` or leading space stands a column apart from
            // the code after it, which it ran straight into. The gap is
            // kerning, so the text is the diff as Git wrote it.
            if [.added, .removed, .context].contains(kind),
               let first = line.unicodeScalars.first, "+- ".unicodeScalars.contains(first) {
                storage.addAttribute(.kern, value: Self.markerGap,
                                     range: NSRange(location: lineRange.location, length: 1))
            }
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
        markChangedWords(in: lines, of: text, storage: storage)
        storage.endEditing()
        return bands
    }

    /// Inside a block of removed lines followed by the added lines that
    /// replace it, the words that actually changed, in a deeper shade of the
    /// line's colour — a line with one changed character no longer has to be
    /// read against its twin letter by letter. Lines are paired in order, as
    /// Git lists them; a pair too unlike to be one line edited is left whole.
    private static func markChangedWords(in lines: [(range: NSRange, kind: LineKind)],
                                         of text: NSString, storage: NSTextStorage) {
        // Git places this metadata between the old and new last lines. It is
        // not a context line and must not split the replacement block.
        let lines = lines.filter { !text.substring(with: $0.range).hasPrefix("\\") }
        var index = 0
        while index < lines.count {
            guard lines[index].kind == .removed else {
                index += 1
                continue
            }
            var removedEnd = index
            while removedEnd < lines.count, lines[removedEnd].kind == .removed { removedEnd += 1 }
            var addedEnd = removedEnd
            while addedEnd < lines.count, lines[addedEnd].kind == .added { addedEnd += 1 }
            for offset in 0..<min(removedEnd - index, addedEnd - removedEnd) {
                let removed = body(of: lines[index + offset].range, in: text)
                let added = body(of: lines[removedEnd + offset].range, in: text)
                guard let words = changedWords(removed: text.substring(with: removed),
                                               added: text.substring(with: added)) else { continue }
                for range in words.removed {
                    storage.addAttribute(.backgroundColor, value: Theme.diffRemovedWordBackground,
                                         range: NSRange(location: removed.location + range.location,
                                                        length: range.length))
                }
                for range in words.added {
                    storage.addAttribute(.backgroundColor, value: Theme.diffAddedWordBackground,
                                         range: NSRange(location: added.location + range.location,
                                                        length: range.length))
                }
            }
            index = max(addedEnd, removedEnd)
        }
    }

    /// A diff line without its marker and its line break.
    private static func body(of line: NSRange, in text: NSString) -> NSRange {
        var end = NSMaxRange(line)
        while end > line.location + 1,
              text.character(at: end - 1) == 0x0A || text.character(at: end - 1) == 0x0D {
            end -= 1
        }
        return NSRange(location: line.location + 1, length: max(0, end - line.location - 1))
    }

    /// Where two versions of a line differ, word by word: runs of letters and
    /// digits are words, each other character is one on its own. Nil when the
    /// two have too little in common to be one line edited — marking nearly
    /// all of both says nothing the line colours do not — or are too long to
    /// compare cheaply.
    static func changedWords(removed: String, added: String) -> (removed: [NSRange], added: [NSRange])? {
        let old = tokens(of: removed as NSString), new = tokens(of: added as NSString)
        guard !old.isEmpty || !new.isEmpty,
              old.count <= 250_000 / max(1, new.count) else { return nil }
        // Longest common subsequence of the tokens.
        let width = new.count + 1
        var table = [Int32](repeating: 0, count: (old.count + 1) * width)
        if !old.isEmpty, !new.isEmpty {
            for i in stride(from: old.count - 1, through: 0, by: -1) {
                for j in stride(from: new.count - 1, through: 0, by: -1) {
                    table[i * width + j] = old[i].text == new[j].text
                        ? table[(i + 1) * width + j + 1] + 1
                        : max(table[(i + 1) * width + j], table[i * width + j + 1])
                }
            }
        }
        var keptOld = [Bool](repeating: false, count: old.count)
        var keptNew = [Bool](repeating: false, count: new.count)
        var i = 0, j = 0
        while i < old.count, j < new.count {
            if old[i].text == new[j].text {
                keptOld[i] = true
                keptNew[j] = true
                i += 1
                j += 1
            } else if table[(i + 1) * width + j] >= table[i * width + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        // Too unlike: less than a third of the words that matter survive.
        let solid = { (list: [Token], kept: [Bool]) -> (kept: Int, all: Int) in
            var keptCount = 0, all = 0
            for (token, isKept) in zip(list, kept) where !token.isSpace {
                all += 1
                if isKept { keptCount += 1 }
            }
            return (keptCount, all)
        }
        let oldSolid = solid(old, keptOld), newSolid = solid(new, keptNew)
        let common = min(oldSolid.kept, newSolid.kept)
        guard common * 3 >= max(oldSolid.all, newSolid.all) else { return nil }
        return (spans(of: old, kept: keptOld), spans(of: new, kept: keptNew))
    }

    private struct Token {
        let range: NSRange
        let text: String
        let isSpace: Bool
    }

    private static func tokens(of line: NSString) -> [Token] {
        var runs: [(range: NSRange, kind: Int)] = []
        var location = 0
        var previousKind = -1
        func kind(_ character: Character) -> Int {
            if character == " " || character == "\t" { return 0 }
            guard let scalar = character.unicodeScalars.first else { return 2 }
            // Han text has no spaces between words. Keep each character
            // separate so changing one character does not mark a whole sentence.
            if (0x3400...0x9FFF).contains(scalar.value)
                || (0x20000...0x323AF).contains(scalar.value) { return 2 }
            if CharacterSet.alphanumerics.contains(scalar) || character == "_" { return 1 }
            return 2
        }
        // Walk complete graphemes, retaining NSTextStorage's UTF-16 offsets.
        // Splitting a surrogate pair turned different emoji into identical U+FFFD.
        for character in line as String {
            let text = String(character)
            let currentKind = kind(character)
            let length = text.utf16.count
            if currentKind != 2, currentKind == previousKind, !runs.isEmpty {
                runs[runs.count - 1].range.length += length
            } else {
                runs.append((NSRange(location: location, length: length), currentKind))
            }
            location += length
            previousKind = currentKind
        }
        return runs.map { Token(range: $0.range, text: line.substring(with: $0.range),
                                isSpace: $0.kind == 0) }
    }

    /// The changed tokens as ranges, neighbours joined — across a space
    /// between two changed words too, so a changed phrase is one mark.
    private static func spans(of tokens: [Token], kept: [Bool]) -> [NSRange] {
        var spans: [NSRange] = []
        var pendingSpace: NSRange?
        for (token, isKept) in zip(tokens, kept) {
            if isKept {
                if token.isSpace, spans.last.map({ NSMaxRange($0) == token.range.location }) == true {
                    pendingSpace = token.range
                } else {
                    pendingSpace = nil
                }
                continue
            }
            var range = token.range
            if let space = pendingSpace, let last = spans.last, NSMaxRange(last) == space.location {
                spans.removeLast()
                range = NSUnionRange(last, range)
            } else if let last = spans.last, NSMaxRange(last) == range.location {
                spans.removeLast()
                range = NSUnionRange(last, range)
            }
            pendingSpace = nil
            spans.append(range)
        }
        return spans
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

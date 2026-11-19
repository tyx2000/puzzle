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
        Theme.spaceWidth()
    }

    private static let fileHeaderPrefixes = [
        "diff --git", "index ", "new file", "deleted file", "similarity index", "rename ",
    ]

    /// Paint a whole diff buffer, returning the full-width line bands the text
    /// view should draw (see `PuzzleTextView.diffBands`).
    @discardableResult
    static func apply(to storage: NSTextStorage) -> [(range: NSRange, color: NSColor)] {
        applyWithLineNumbers(to: storage).bands
    }

    /// Paint a whole diff buffer and build its file line-number mapping in a
    /// single pass over the text storage.
    static func applyWithLineNumbers(to storage: NSTextStorage)
        -> (bands: [(range: NSRange, color: NSColor)], lineNumbers: [Int?]) {
        var bands: [(range: NSRange, color: NSColor)] = []
        var numbers: [Int?] = []
        let text = storage.string as NSString
        let length = text.length
        let full = NSRange(location: 0, length: length)
        let firstChar = length > 0 ? text.character(at: 0) : 0
        let wholeFile = firstChar == 0x2B || firstChar == 0x2D
            || firstChar == 0x20 || firstChar == 0x5C
        let gap = markerGap
        let addedColor = Theme.diffAddedText
        let removedColor = Theme.diffRemovedText
        let hunkColor = Theme.blue
        let fileHeaderColor = Theme.dimText
        let addedBg = Theme.diffAddedBackground
        let removedBg = Theme.diffRemovedBackground
        var boldFont: NSFont?

        storage.beginEditing()
        storage.setAttributes(Theme.textAttributes(color: Theme.foreground), range: full)

        var removedRun: [NSRange] = []
        var addedRun: [NSRange] = []
        func flushWordRun() {
            guard !removedRun.isEmpty, !addedRun.isEmpty else {
                removedRun.removeAll(keepingCapacity: true)
                addedRun.removeAll(keepingCapacity: true)
                return
            }
            for offset in 0..<min(removedRun.count, addedRun.count) {
                let removed = body(of: removedRun[offset], in: text)
                let added = body(of: addedRun[offset], in: text)
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
            removedRun.removeAll(keepingCapacity: true)
            addedRun.removeAll(keepingCapacity: true)
        }

        var inHunk = wholeFile
        var oldNext = wholeFile ? 1 : 0
        var newNext = wholeFile ? 1 : 0
        var loc = 0

        while loc < length {
            var lineEnd = 0
            var contentsEnd = 0
            text.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd,
                              for: NSRange(location: loc, length: 0))
            let lineRange = NSRange(location: loc, length: lineEnd - loc)
            let contentLength = contentsEnd - loc
            let c0 = contentLength > 0 ? text.character(at: loc) : 0

            if wholeFile {
                if c0 == 0x2B { // "+"
                    storage.addAttribute(.foregroundColor, value: addedColor, range: lineRange)
                    storage.addAttribute(.kern, value: gap,
                                         range: NSRange(location: loc, length: 1))
                    bands.append((lineRange, addedBg))
                    addedRun.append(lineRange)
                    if inHunk {
                        numbers.append(newNext)
                        newNext += 1
                    } else {
                        numbers.append(nil)
                    }
                } else if c0 == 0x2D { // "-"
                    if !addedRun.isEmpty { flushWordRun() }
                    storage.addAttribute(.foregroundColor, value: removedColor, range: lineRange)
                    storage.addAttribute(.kern, value: gap,
                                         range: NSRange(location: loc, length: 1))
                    bands.append((lineRange, removedBg))
                    removedRun.append(lineRange)
                    if inHunk {
                        numbers.append(oldNext)
                        oldNext += 1
                    } else {
                        numbers.append(nil)
                    }
                } else if c0 == 0x20 { // " "
                    if !removedRun.isEmpty || !addedRun.isEmpty { flushWordRun() }
                    storage.addAttribute(.kern, value: gap,
                                         range: NSRange(location: loc, length: 1))
                    if inHunk {
                        numbers.append(newNext)
                        newNext += 1
                        oldNext += 1
                    } else {
                        numbers.append(nil)
                    }
                } else if c0 == 0x5C { // "\"
                    numbers.append(nil)
                } else {
                    if !removedRun.isEmpty || !addedRun.isEmpty { flushWordRun() }
                    inHunk = false
                    numbers.append(nil)
                }
            } else {
                let kind: LineKind
                if c0 == 0x40, contentLength >= 2, text.character(at: loc + 1) == 0x40 {
                    kind = .hunkHeader
                } else if c0 == 0x2B {
                    kind = (contentLength >= 3 && text.character(at: loc + 1) == 0x2B
                            && text.character(at: loc + 2) == 0x2B) ? .fileHeader : .added
                } else if c0 == 0x2D {
                    kind = (contentLength >= 3 && text.character(at: loc + 1) == 0x2D
                            && text.character(at: loc + 2) == 0x2D) ? .fileHeader : .removed
                } else if c0 == 0x64 || c0 == 0x69 || c0 == 0x6E || c0 == 0x73 || c0 == 0x72 {
                    let prefix = text.substring(with: NSRange(location: loc,
                                                              length: min(contentLength, 16)))
                    kind = Self.fileHeaderPrefixes.contains { prefix.hasPrefix($0) }
                        ? .fileHeader : .context
                } else {
                    kind = .context
                }

                switch kind {
                case .added:
                    storage.addAttribute(.foregroundColor, value: addedColor, range: lineRange)
                    storage.addAttribute(.kern, value: gap,
                                         range: NSRange(location: loc, length: 1))
                    bands.append((lineRange, addedBg))
                    addedRun.append(lineRange)
                case .removed:
                    if !addedRun.isEmpty { flushWordRun() }
                    storage.addAttribute(.foregroundColor, value: removedColor, range: lineRange)
                    storage.addAttribute(.kern, value: gap,
                                         range: NSRange(location: loc, length: 1))
                    bands.append((lineRange, removedBg))
                    removedRun.append(lineRange)
                case .context:
                    if c0 == 0x20 || c0 == 0x2B || c0 == 0x2D {
                        storage.addAttribute(.kern, value: gap,
                                             range: NSRange(location: loc, length: 1))
                    }
                    if c0 != 0x5C && (!removedRun.isEmpty || !addedRun.isEmpty) {
                        flushWordRun()
                    }
                case .hunkHeader, .fileHeader:
                    if !removedRun.isEmpty || !addedRun.isEmpty { flushWordRun() }
                    storage.addAttribute(.foregroundColor,
                                         value: kind == .hunkHeader ? hunkColor : fileHeaderColor,
                                         range: lineRange)
                    let bold = boldFont ?? NSFontManager.shared.convert(
                        Theme.editorFont(), toHaveTrait: .boldFontMask)
                    boldFont = bold
                    storage.addAttribute(.font, value: bold, range: lineRange)
                }

                if kind == .hunkHeader {
                    let hunkLine = text.substring(with: NSRange(location: loc,
                                                                length: contentLength))
                    if let start = hunkStart(hunkLine) {
                        oldNext = start.old
                        newNext = start.new
                        inHunk = true
                    } else {
                        inHunk = false
                    }
                    numbers.append(nil)
                } else if !inHunk || contentLength == 0 {
                    inHunk = false
                    numbers.append(nil)
                } else {
                    switch c0 {
                    case 0x2B:
                        numbers.append(newNext)
                        newNext += 1
                    case 0x2D:
                        numbers.append(oldNext)
                        oldNext += 1
                    case 0x20:
                        numbers.append(newNext)
                        newNext += 1
                        oldNext += 1
                    case 0x5C:
                        numbers.append(nil)
                    default:
                        inHunk = false
                        numbers.append(nil)
                    }
                }
            }

            loc = lineEnd
        }

        flushWordRun()
        if length == 0 || text.character(at: length - 1) == 0x0A {
            numbers.append(nil)
        }
        storage.endEditing()
        return (bands, numbers)
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
        var contiguous = text
        contiguous.makeContiguousUTF8()
        return contiguous.utf8.withContiguousStorageIfAvailable { buffer in
            var numbers: [Int?] = []
            // A whole file's body is one hunk from the first line of both sides.
            var inHunk = isWholeFileBody(contiguous)
            var oldNext = inHunk ? 1 : 0
            var newNext = inHunk ? 1 : 0
            let count = buffer.count
            var i = 0
            while true {
                var lineEnd = i
                while lineEnd < count && buffer[lineEnd] != 0x0A { lineEnd += 1 }
                if lineEnd - i >= 2 && buffer[i] == 0x40 && buffer[i + 1] == 0x40 {
                    let line = String(decoding: buffer[i..<lineEnd], as: UTF8.self)
                    if let start = hunkStart(line) {
                        oldNext = start.old
                        newNext = start.new
                        inHunk = true
                    } else {
                        inHunk = false
                    }
                    numbers.append(nil)
                } else if !inHunk || i == lineEnd {
                    inHunk = false
                    numbers.append(nil)
                } else {
                    switch buffer[i] {
                    case 0x2B: // "+"
                        numbers.append(newNext)
                        newNext += 1
                    case 0x2D: // "-"
                        numbers.append(oldNext)
                        oldNext += 1
                    case 0x20: // " "
                        numbers.append(newNext)
                        newNext += 1
                        oldNext += 1
                    case 0x5C: // "\"
                        numbers.append(nil)
                    default:   // next file's header — the hunk is over
                        inHunk = false
                        numbers.append(nil)
                    }
                }
                if lineEnd == count { break }
                i = lineEnd + 1
            }
            return numbers
        } ?? []
    }

    // MARK: - A whole file

    /// A diff tab shows the whole file. Git is asked for every line as context,
    /// which makes one hunk of it, and the lines above that hunk — `diff --git`,
    /// `index`, `---`, `+++` and the `@@` line itself — are left off: the
    /// header over the tab already names the file and counts the changes. What
    /// is left is the body, every line starting with its marker, numbered from
    /// line 1 on both sides.
    ///
    /// A diff that is not one hunk from the top of the file — binary, a mode
    /// change, a note that there is nothing to show — comes back as it went in.
    static func wholeFileBody(of diff: String) -> String {
        var contiguous = diff
        contiguous.makeContiguousUTF8()
        let bodyByteOffset: Int? = contiguous.utf8.withContiguousStorageIfAvailable { buffer in
            let count = buffer.count
            var hunkLineStart = -1
            var hunkLineEnd = -1
            var hunkCount = 0
            var i = 0
            while i <= count {
                var lineEnd = i
                while lineEnd < count && buffer[lineEnd] != 0x0A { lineEnd += 1 }
                if lineEnd - i >= 2 && buffer[i] == 0x40 && buffer[i + 1] == 0x40 {
                    hunkCount += 1
                    if hunkCount > 1 { return nil }
                    hunkLineStart = i
                    hunkLineEnd = lineEnd
                }
                if lineEnd == count { break }
                i = lineEnd + 1
            }
            guard hunkCount == 1, hunkLineEnd < count else { return nil }
            let hunkLine = String(decoding: buffer[hunkLineStart..<hunkLineEnd], as: UTF8.self)
            guard let start = hunkStart(hunkLine), start.old <= 1, start.new <= 1 else {
                return nil
            }
            let bodyStart = hunkLineEnd + 1
            var j = bodyStart
            var hasNonEmptyBodyLine = false
            while j < count {
                if buffer[j] != 0x0A {
                    hasNonEmptyBodyLine = true
                    break
                }
                j += 1
            }
            return hasNonEmptyBodyLine ? bodyStart : nil
        } ?? nil
        guard let bodyByteOffset else { return diff }
        let idx = contiguous.utf8.index(contiguous.utf8.startIndex, offsetBy: bodyByteOffset)
        return String(contiguous[idx...])
    }

    /// Whether `text` is such a body. A diff starts with a header; a body
    /// starts with a line's marker. Only diffs Git wrote come this way, and
    /// those always open with `diff --git`.
    static func isWholeFileBody(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        return first == "+" || first == "-" || first == " " || first == "\\"
    }

    /// Whether `text` has an added or removed line: a change to step to. A
    /// binary, a mode change or a pure rename has none.
    static func hasChanges(in text: String) -> Bool {
        let wholeFile = isWholeFileBody(text)
        var found = false
        text.enumerateLines { line, stop in
            let lineKind = wholeFile ? bodyKind(of: line) : kind(of: line)
            found = lineKind == .added || lineKind == .removed
            stop = found
        }
        return found
    }

    /// A body line is what its first character says, and nothing else: with
    /// no headers left, an added line reading "++x" is an addition.
    private static func bodyKind(of line: String) -> LineKind {
        switch line.first {
        case "+": return .added
        case "-": return .removed
        default: return .context
        }
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

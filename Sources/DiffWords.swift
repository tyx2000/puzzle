import Foundation

/// The words that changed inside a changed line, so a line with one changed
/// character no longer has to be read against its twin letter by letter.
///
/// A removed line is compared with the added line that replaces it — paired
/// in order, as Git lists them — and the words that are not common to both
/// are marked in a deeper shade of the line's colour. A pair too unlike to be
/// one line edited is left whole.
enum DiffWords {
    /// What to mark on one row: ranges in the removed text, in the added text.
    /// A unified row carries only one side; a side-by-side row can carry both.
    struct Marks: Equatable {
        var removed: [NSRange] = []
        var added: [NSRange] = []
    }

    /// Where two versions of a line differ, word by word: runs of letters and
    /// digits are words, each other character is one on its own. Ranges are in
    /// UTF-16, as NSString counts. Nil when the two have too little in common
    /// to be one line edited — marking nearly all of both says nothing the
    /// line colours do not — or are too long to compare cheaply.
    static func changedWords(removed: String, added: String)
        -> (removed: [NSRange], added: [NSRange])? {
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
        // Walk complete graphemes, keeping NSString's UTF-16 offsets. Splitting
        // a surrogate pair turned different emoji into identical U+FFFD.
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
}

import Foundation

/// Finds the pair adjacent to the insertion point while ignoring common string
/// and comment forms. Angle brackets are deliberately excluded because in most
/// supported languages they are operators or generic syntax, not delimiters.
enum BracketMatcher {
    private enum Mode {
        case code, singleQuote, doubleQuote, backtick, lineComment, blockComment
    }

    private struct Opening {
        let character: unichar
        let location: Int
    }

    private static func isOpening(_ character: unichar) -> Bool {
        character == 0x28 || character == 0x5B || character == 0x7B // ( [ {
    }

    private static func opening(closedBy character: unichar) -> unichar? {
        switch character {
        case 0x29: return 0x28 // )
        case 0x5D: return 0x5B // ]
        case 0x7D: return 0x7B // }
        default: return nil
        }
    }

    private static func isBracket(_ character: unichar) -> Bool {
        isOpening(character) || opening(closedBy: character) != nil
    }

    static let maximumCharacters = 2_000_000

    /// The text a chunk at a time. Asking the storage's string for one
    /// character at a time cost ~27ms a walk through an 800 KB file, and the
    /// editor walks after every keystroke beside a bracket.
    private struct Characters {
        let text: NSString
        let length: Int
        private var buffer = [unichar](repeating: 0, count: 8192)
        private var start = 0
        private var end = 0

        init(_ text: NSString) {
            self.text = text
            length = text.length
        }

        subscript(offset: Int) -> unichar {
            mutating get {
                if offset < start || offset >= end {
                    // Keep the character before, which `#` looks back at.
                    start = max(0, offset - 1)
                    end = min(length, start + buffer.count)
                    let range = NSRange(location: start, length: end - start)
                    buffer.withUnsafeMutableBufferPointer { pointer in
                        text.getCharacters(pointer.baseAddress!, range: range)
                    }
                }
                return buffer[offset - start]
            }
        }
    }

    static func ranges(in text: NSString, caret: Int) -> [NSRange] {
        let length = text.length
        guard length > 0, length <= maximumCharacters else { return [] }
        let clampedCaret = min(max(0, caret), length)
        // A pair is only ever reported when one of its brackets is beside the
        // caret, so beside anything else the walk can only come back empty.
        var candidates: [Int] = []
        if clampedCaret > 0, isBracket(text.character(at: clampedCaret - 1)) {
            candidates.append(clampedCaret - 1)
        }
        if clampedCaret < length, isBracket(text.character(at: clampedCaret)) {
            candidates.append(clampedCaret)
        }
        guard let lastCandidate = candidates.last else { return [] }

        var characters = Characters(text)
        var stack: [Opening] = []
        // Once pushed, a candidate stays on the stack until it is matched.
        var candidateOpened = false
        var mode = Mode.code
        var escaped = false
        var index = 0
        while index < length {
            // Past both candidates with neither of them open, nothing later
            // can pair with one.
            if index > lastCandidate, !candidateOpened { return [] }
            let character = characters[index]

            if character == 0x0A {
                if mode == .lineComment { mode = .code }
                escaped = false
                index += 1
                continue
            }

            switch mode {
            case .lineComment:
                index += 1
                continue
            case .blockComment:
                if character == 0x2A, index + 1 < length, characters[index + 1] == 0x2F {
                    mode = .code
                    index += 2
                } else {
                    index += 1
                }
                continue
            case .singleQuote, .doubleQuote, .backtick:
                let terminator: unichar = mode == .singleQuote ? 0x27
                    : (mode == .doubleQuote ? 0x22 : 0x60)
                if character == terminator, !escaped { mode = .code }
                escaped = character == 0x5C && !escaped
                if character != 0x5C { escaped = false }
                index += 1
                continue
            case .code:
                break
            }

            if character == 0x2F, index + 1 < length {
                let next = characters[index + 1]
                if next == 0x2F {
                    mode = .lineComment
                    index += 2
                    continue
                }
                if next == 0x2A {
                    mode = .blockComment
                    index += 2
                    continue
                }
            }
            if character == 0x23 {
                let previous: unichar = index == 0 ? 0x0A : characters[index - 1]
                if previous == 0x20 || previous == 0x09 || previous == 0x0A {
                    mode = .lineComment
                    index += 1
                    continue
                }
            }
            if character == 0x27 || character == 0x22 || character == 0x60 {
                mode = character == 0x27 ? .singleQuote
                    : (character == 0x22 ? .doubleQuote : .backtick)
                escaped = false
                index += 1
                continue
            }

            if isOpening(character) {
                stack.append(Opening(character: character, location: index))
                if candidates.contains(index) { candidateOpened = true }
            } else if let expected = opening(closedBy: character),
                      let opening = stack.last, opening.character == expected {
                stack.removeLast()
                if candidates.contains(opening.location) || candidates.contains(index) {
                    return [NSRange(location: opening.location, length: 1),
                            NSRange(location: index, length: 1)]
                }
            }
            index += 1
        }
        return []
    }
}

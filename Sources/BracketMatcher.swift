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

    private static let openingToClosing: [unichar: unichar] = [
        0x28: 0x29, // ( )
        0x5B: 0x5D, // [ ]
        0x7B: 0x7D, // { }
    ]
    private static let closingToOpening: [unichar: unichar] = [
        0x29: 0x28,
        0x5D: 0x5B,
        0x7D: 0x7B,
    ]
    static let maximumCharacters = 2_000_000

    static func ranges(in text: NSString, caret: Int) -> [NSRange] {
        guard text.length > 0, text.length <= maximumCharacters else { return [] }
        let clampedCaret = min(max(0, caret), text.length)
        var candidates: Set<Int> = []
        if clampedCaret > 0 { candidates.insert(clampedCaret - 1) }
        if clampedCaret < text.length { candidates.insert(clampedCaret) }
        guard !candidates.isEmpty else { return [] }

        var stack: [Opening] = []
        var mode = Mode.code
        var escaped = false
        var index = 0
        while index < text.length {
            let character = text.character(at: index)
            let next = index + 1 < text.length ? text.character(at: index + 1) : 0

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
                if character == 0x2A, next == 0x2F {
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

            if character == 0x2F, next == 0x2F {
                mode = .lineComment
                index += 2
                continue
            }
            if character == 0x2F, next == 0x2A {
                mode = .blockComment
                index += 2
                continue
            }
            if character == 0x23,
               index == 0 || text.character(at: index - 1) == 0x20
                || text.character(at: index - 1) == 0x09
                || text.character(at: index - 1) == 0x0A {
                mode = .lineComment
                index += 1
                continue
            }
            if character == 0x27 || character == 0x22 || character == 0x60 {
                mode = character == 0x27 ? .singleQuote
                    : (character == 0x22 ? .doubleQuote : .backtick)
                escaped = false
                index += 1
                continue
            }

            if openingToClosing[character] != nil {
                stack.append(Opening(character: character, location: index))
            } else if let expected = closingToOpening[character],
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

import Foundation

/// Re-indents JSON for reading.
///
/// A minified payload is one line thousands of characters long: unreadable, and
/// past `Document.maxDisplayLineLength` the editor refuses to lay it out at all
/// and shows a read-only prefix instead. Browsers pretty-print such a file
/// before showing it; so does Puzzle, on the way into the buffer.
///
/// The source is *re-spaced*, never re-encoded: every string, number and escape
/// is copied through byte for byte and object keys keep their order.
/// `JSONSerialization` would sort keys, rewrite `1.0` as `1`, `1e3` as `1000`,
/// and silently lose the distinction between `1` and `1.0` — a formatter that
/// edits values is not a formatter.
enum JSONFormatter {
    /// Two spaces per level, which is what every JSON viewer uses.
    static let indent = "  "

    /// The pretty form of `text`, or nil when it is not a single valid JSON
    /// document.
    static func pretty(_ text: String) -> String? {
        var printer = Printer(source: Array(text.utf8))
        return printer.run()
    }

    /// Past this a JSON line has stopped being something a person reads.
    static let readableLineLength = 200

    /// Formatting doubles the character count in the worst case and every line
    /// costs TextKit a layout fragment, so only files that stay interactive
    /// afterwards are reformatted.
    static let maxFormattedBytes = 4 * 1024 * 1024

    /// Indenting cannot break a string, so a formatted document can still hold
    /// one very long line. Measured on this machine, TextKit lays one out in
    /// about 25 ms per 100,000 characters (92 ms at 400,000) — worth paying to
    /// show the document rather than a read-only prefix of it. Past this the
    /// file goes back on the bounded-preview path.
    static let maxFormattedLineLength = 400_000

    /// True when `formatted` is worth putting on screen in place of `source`.
    ///
    /// A long line is not on its own a minified file: one base64 blob inside an
    /// otherwise laid-out document is the author's formatting, and re-indenting
    /// the other two hundred lines around it would be rude. A machine-written
    /// file gains lines by the dozen here; a human-written one gains one or two.
    static func worthFormatting(source: String, formatted: String) -> Bool {
        lineCount(formatted) > lineCount(source) * 2
    }

    private static func lineCount(_ text: String) -> Int {
        1 + text.utf8.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
    }

    /// Nesting deeper than this is a machine talking to a machine, and the
    /// printer recurses.
    private static let maxDepth = 200

    private struct Printer {
        let source: [UInt8]
        var index = 0
        var out: [UInt8] = []

        mutating func run() -> String? {
            out.reserveCapacity(source.count + source.count / 4)
            skipWhitespace()
            guard value(depth: 0) else { return nil }
            skipWhitespace()
            guard index == source.count else { return nil }
            out.append(0x0A)
            return String(decoding: out, as: UTF8.self)
        }

        private mutating func skipWhitespace() {
            while index < source.count {
                switch source[index] {
                case 0x20, 0x09, 0x0A, 0x0D: index += 1
                default: return
                }
            }
        }

        private mutating func newline(_ depth: Int) {
            out.append(0x0A)
            for _ in 0..<depth { out.append(contentsOf: Array(JSONFormatter.indent.utf8)) }
        }

        private mutating func value(depth: Int) -> Bool {
            guard depth <= JSONFormatter.maxDepth, index < source.count else { return false }
            switch source[index] {
            case UInt8(ascii: "{"): return container(depth: depth, isObject: true)
            case UInt8(ascii: "["): return container(depth: depth, isObject: false)
            case UInt8(ascii: "\""): return string()
            case UInt8(ascii: "t"): return literal("true")
            case UInt8(ascii: "f"): return literal("false")
            case UInt8(ascii: "n"): return literal("null")
            default: return number()
            }
        }

        /// Objects and arrays differ only in their brackets and in the `key:`
        /// each member carries.
        private mutating func container(depth: Int, isObject: Bool) -> Bool {
            let close = isObject ? UInt8(ascii: "}") : UInt8(ascii: "]")
            out.append(source[index])
            index += 1
            skipWhitespace()
            guard index < source.count else { return false }
            // An empty container stays on one line, as every JSON viewer shows it.
            if source[index] == close {
                out.append(close)
                index += 1
                return true
            }
            var first = true
            while true {
                if !first {
                    guard index < source.count, source[index] == UInt8(ascii: ",") else {
                        return false
                    }
                    index += 1
                    out.append(UInt8(ascii: ","))
                    skipWhitespace()
                }
                first = false
                newline(depth + 1)
                if isObject {
                    guard index < source.count, source[index] == UInt8(ascii: "\""),
                          string() else { return false }
                    skipWhitespace()
                    guard index < source.count, source[index] == UInt8(ascii: ":") else {
                        return false
                    }
                    index += 1
                    out.append(contentsOf: [UInt8(ascii: ":"), 0x20])
                    skipWhitespace()
                }
                guard value(depth: depth + 1) else { return false }
                skipWhitespace()
                guard index < source.count else { return false }
                if source[index] == close {
                    index += 1
                    newline(depth)
                    out.append(close)
                    return true
                }
            }
        }

        /// Copied verbatim, escapes and all: re-encoding a string is how a
        /// formatter corrupts one.
        private mutating func string() -> Bool {
            let start = index
            index += 1
            while index < source.count {
                let byte = source[index]
                if byte == UInt8(ascii: "\\") {
                    index += 2
                    continue
                }
                if byte == UInt8(ascii: "\"") {
                    index += 1
                    out.append(contentsOf: source[start..<index])
                    return true
                }
                // A raw control character is not a legal JSON string body.
                if byte < 0x20 { return false }
                index += 1
            }
            return false
        }

        private mutating func literal(_ word: String) -> Bool {
            let bytes = Array(word.utf8)
            guard index + bytes.count <= source.count,
                  Array(source[index..<(index + bytes.count)]) == bytes else { return false }
            index += bytes.count
            out.append(contentsOf: bytes)
            return true
        }

        private mutating func number() -> Bool {
            let start = index
            if index < source.count, source[index] == UInt8(ascii: "-") { index += 1 }
            var digits = 0
            while index < source.count, source[index] >= 0x30, source[index] <= 0x39 {
                index += 1
                digits += 1
            }
            guard digits > 0 else { return false }
            if index < source.count, source[index] == UInt8(ascii: ".") {
                index += 1
                var fraction = 0
                while index < source.count, source[index] >= 0x30, source[index] <= 0x39 {
                    index += 1
                    fraction += 1
                }
                guard fraction > 0 else { return false }
            }
            if index < source.count,
               source[index] == UInt8(ascii: "e") || source[index] == UInt8(ascii: "E") {
                index += 1
                if index < source.count,
                   source[index] == UInt8(ascii: "+") || source[index] == UInt8(ascii: "-") {
                    index += 1
                }
                var exponent = 0
                while index < source.count, source[index] >= 0x30, source[index] <= 0x39 {
                    index += 1
                    exponent += 1
                }
                guard exponent > 0 else { return false }
            }
            out.append(contentsOf: source[start..<index])
            return true
        }
    }
}

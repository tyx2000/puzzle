import Foundation

/// ⌘/ — comment the lines a selection touches, or take their comments off.
///
/// The rule every editor with the command follows: if every non-blank line is
/// already commented, uncomment each; otherwise comment each, including any
/// that already were, so the toggle is always undone by pressing it again. A
/// line comment goes in at the shallowest indentation among the lines, which
/// keeps a block aligned instead of pushing each line's comment to its own
/// depth. Blank lines are left alone unless there is nothing else to comment.
///
/// A language whose only comment wraps — CSS, HTML, XML, Markdown — has each
/// line wrapped on its own. That keeps the command a line operation both ways:
/// one wrapper around a whole selection could not be taken off a single line.
enum CommentToggle {
    struct Syntax: Equatable {
        let prefix: String
        /// Empty for a line comment.
        let suffix: String
    }

    /// The comment for a language, by the name the highlighter knows it by.
    /// Nil where the file has none — plain text — and then there is no
    /// command to run.
    static func syntax(forLanguage name: String?, fileExtension: String) -> Syntax? {
        let line = { (token: String) in Syntax(prefix: token, suffix: "") }
        switch name {
        // JSON has no comments, but JSONC does, and so does Puzzle's own
        // settings.json: `//`, as every editor that offers the command in JSON.
        case "swift", "typescript", "tsx", "rust", "go", "c", "json":
            return line("//")
        // One grammar reads both; only SCSS has a line comment.
        case "css":
            return fileExtension.lowercased() == "scss"
                ? line("//") : Syntax(prefix: "/*", suffix: "*/")
        case "bash", "yaml", "python", "toml", "dockerfile", "gitignore":
            return line("#")
        case "sql":
            return line("--")
        case "html", "xml", "markdown":
            return Syntax(prefix: "<!--", suffix: "-->")
        default:
            return nil
        }
    }

    /// One change to a block of lines, in its UTF-16 offsets.
    struct Edit: Equatable {
        let location: Int
        let length: Int
        let replacement: String
        /// Whether a caret sitting exactly at `location` moves past what is
        /// inserted. It does after a comment's opening — the caret stays with
        /// the text it was in front of — and not before a closing.
        let carriesCaret: Bool
    }

    /// The edits that toggle `block`, which holds whole lines, in ascending
    /// order. Empty when there is nothing to do.
    static func edits(for block: String, syntax: Syntax) -> [Edit] {
        let text = block as NSString
        struct Line {
            let start: Int
            let contentsEnd: Int
            let indent: Int
            var isBlank: Bool { start + indent == contentsEnd }
        }
        var lines: [Line] = []
        var index = 0
        repeat {
            var start = 0, end = 0, contentsEnd = 0
            text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                              for: NSRange(location: index, length: 0))
            var indent = 0
            while start + indent < contentsEnd {
                let character = text.character(at: start + indent)
                guard character == 0x20 || character == 0x09 else { break }
                indent += 1
            }
            lines.append(Line(start: start, contentsEnd: contentsEnd, indent: indent))
            index = end
        } while index < text.length

        let written = lines.filter { !$0.isBlank }
        let targets = written.isEmpty ? lines : written
        let prefix = syntax.prefix as NSString
        let suffix = syntax.suffix as NSString

        /// Where the suffix starts on a line, ignoring trailing whitespace;
        /// nil when the line does not end with it.
        func suffixStart(of line: Line) -> Int? {
            guard suffix.length > 0 else { return line.contentsEnd }
            var end = line.contentsEnd
            while end > line.start + line.indent {
                let character = text.character(at: end - 1)
                guard character == 0x20 || character == 0x09 else { break }
                end -= 1
            }
            let start = end - suffix.length
            guard start >= line.start + line.indent + prefix.length,
                  text.substring(with: NSRange(location: start, length: suffix.length))
                    == syntax.suffix else { return nil }
            return start
        }
        func isCommented(_ line: Line) -> Bool {
            let first = line.start + line.indent
            guard !line.isBlank, first + prefix.length <= line.contentsEnd,
                  text.substring(with: NSRange(location: first, length: prefix.length))
                    == syntax.prefix else { return false }
            return suffixStart(of: line) != nil
        }

        var edits: [Edit] = []
        if !written.isEmpty && written.allSatisfy(isCommented) {
            for line in written {
                // The opening, and the one space written after it if it is there.
                let opening = line.start + line.indent
                var openingLength = prefix.length
                if opening + openingLength < line.contentsEnd,
                   text.character(at: opening + openingLength) == 0x20 {
                    openingLength += 1
                }
                edits.append(Edit(location: opening, length: openingLength,
                                  replacement: "", carriesCaret: false))
                // The closing, and the one space written before it.
                if suffix.length > 0, var closing = suffixStart(of: line) {
                    var closingLength = suffix.length
                    if closing - 1 >= opening + openingLength,
                       text.character(at: closing - 1) == 0x20 {
                        closing -= 1
                        closingLength += 1
                    }
                    edits.append(Edit(location: closing, length: closingLength,
                                      replacement: "", carriesCaret: false))
                }
            }
        } else {
            let column = targets.map(\.indent).min() ?? 0
            for line in targets {
                edits.append(Edit(location: line.start + column, length: 0,
                                  replacement: syntax.prefix + " ", carriesCaret: true))
                if suffix.length > 0 {
                    edits.append(Edit(location: line.contentsEnd, length: 0,
                                      replacement: " " + syntax.suffix, carriesCaret: false))
                }
            }
        }
        return edits
    }

    static func apply(_ edits: [Edit], to block: String) -> String {
        let result = NSMutableString(string: block)
        // Back to front, so every edit still addresses the text it was made
        // for; two at one place land in the order they were listed.
        for edit in edits.reversed() {
            result.replaceCharacters(in: NSRange(location: edit.location, length: edit.length),
                                     with: edit.replacement)
        }
        return result as String
    }

    /// Where an offset in the block ends up once the edits are made.
    ///
    /// `carryingAtPoint` is for a caret, which moves past a comment opened
    /// right where it stands. The start of a selection does not: it stays put,
    /// so the selection still covers the whole of the lines it covered.
    static func map(_ offset: Int, through edits: [Edit],
                    carryingAtPoint: Bool = true) -> Int {
        var delta = 0
        for edit in edits {
            let inserted = (edit.replacement as NSString).length
            if edit.length == 0 {
                if edit.location < offset
                    || (edit.location == offset && edit.carriesCaret && carryingAtPoint) {
                    delta += inserted
                }
            } else if edit.location + edit.length <= offset {
                delta += inserted - edit.length
            } else if edit.location < offset {
                // Inside what was taken out: to where it was.
                return edit.location + delta
            }
        }
        return offset + delta
    }
}

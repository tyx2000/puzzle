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

    /// Paint a whole diff buffer.
    static func apply(to storage: NSTextStorage) {
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
                // Cover the whole line so the change reads as a block.
                storage.addAttribute(.backgroundColor, value: bg, range: lineRange)
            }
            if kind == .hunkHeader || kind == .fileHeader {
                let bold = NSFontManager.shared.convert(Theme.editorFont(),
                                                        toHaveTrait: .boldFontMask)
                storage.addAttribute(.font, value: bold, range: lineRange)
            }
        }
        storage.endEditing()
    }

    /// Counts for the tab subtitle / status line.
    static func stats(in text: String) -> (added: Int, removed: Int) {
        var added = 0, removed = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            switch kind(of: String(line)) {
            case .added: added += 1
            case .removed: removed += 1
            default: break
            }
        }
        return (added, removed)
    }
}

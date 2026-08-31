import AppKit

/// User settings, stored as JSON at ~/.config/puzzle/settings.json (Zed-style
/// key names). The Settings button opens this file in the editor; saving it
/// re-applies the display config live.
final class Settings {
    static let shared = Settings()
    static let didChange = Notification.Name("PuzzleSettingsDidChange")

    // Editor (buffer) font
    var fontFamily = "Monaco"
    var fontSize: CGFloat = 12
    var fontWeight: CGFloat = 400
    /// Exact height of one code row, in points.
    var codeLineHeight: CGFloat = 27
    var tabSize = 4
    var showInlineBlame = true

    // UI font — the left panel, tabs, git/search panels
    var uiFontFamily = "Monaco"
    var uiFontSize: CGFloat = 12
    var uiFontWeight: CGFloat = 400
    /// Exact height of one file-tree row, in points.
    var treeLineHeight: CGFloat = 22

    private var needsAbsoluteLineHeightMigration = false

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/puzzle/settings.json")
    }

    /// Every configurable key, rendered with the values currently in effect.
    /// Used both to create the file and to upgrade an older one in place.
    /// The documented settings.json this build writes.
    var documentedContentsForTesting: String { contents() }

    private func contents() -> String {
        func num(_ v: CGFloat) -> String {
            v == v.rounded() ? String(Int(v)) : String(format: "%g", Double(v))
        }
        return """
        {
          // ───────────────────────────────────────────────────────────────────────
          // Puzzle settings. Save this file (⌘S) to apply changes immediately.
          // Every property below is listed with its current value.
          // `//` comments are allowed.
          // ───────────────────────────────────────────────────────────────────────

          // ── Editor (buffer) text ───────────────────────────────────────────────

          // Font family for code in the editor. Any installed font name,
          // e.g. "Monaco", "Menlo", "SF Mono", "JetBrains Mono".  Default: "Monaco"
          "buffer_font_family": "\(fontFamily)",

          // Code font size in points. Range 6–72.  Default: 12
          "buffer_font_size": \(num(fontSize)),

          // Code font weight. 400 = regular, 600+ renders bold.  Default: 400
          "buffer_font_weight": \(num(fontWeight)),

          // Exact height of one code row in points. Range 8–200.  Default: 27
          "code_line_height": \(num(codeLineHeight)),

          // Width of a tab character, in characters. Range 1–16.  Default: 4
          "tab_size": \(tabSize),

          // Show git blame (author, time, subject) after the cursor's line.  Default: true
          "show_inline_blame": \(showInlineBlame),

          // ── UI text: left panel (file tree, search, git), tabs ─────────────────

          // Font family for the left panel, tabs and panels.  Default: "Monaco"
          "ui_font_family": "\(uiFontFamily)",

          // Base UI font size in points. Scales the whole panel/tab type
          // hierarchy proportionally (smaller labels stay relatively
          // smaller), and row heights grow to match. Range 8–32.  Default: 12
          "ui_font_size": \(num(uiFontSize)),

          // UI font weight. 400 = regular, 600+ renders bold.  Default: 400
          "ui_font_weight": \(num(uiFontWeight)),

          // Exact height of one file-tree row in points. Range 8–200.  Default: 22
          "tree_line_height": \(num(treeLineHeight))
        }
        """
    }

    /// Keys we know about; used to detect a settings file written by an older
    /// build that predates some options.
    private static let knownKeys = [
        "buffer_font_family", "buffer_font_size", "buffer_font_weight",
        "code_line_height",
        "tab_size", "show_inline_blame",
        "ui_font_family", "ui_font_size", "ui_font_weight", "tree_line_height",
    ]

    /// Accepted by older settings files but no longer backed by UI behavior.
    private static let retiredKeys = [
        "show_wrap_guides", "wrap_column", "show_indent_guides", "show_completion",
        "buffer_line_height", "ui_line_height",
        "active_code_foreground", "active_code_background",
        "active_file_foreground", "active_file_background",
        // The app paints one palette now, so a pinned theme has nothing to
        // select; an existing settings.json is rewritten without it.
        "theme",
    ]

    /// A file written by an earlier build won't contain options added since, so
    /// those options are invisible and look "missing". Rewrite it with the full
    /// documented set, preserving every value already loaded.
    func upgradeFileIfNeeded() {
        guard let text = try? String(contentsOf: Self.fileURL, encoding: .utf8) else { return }
        let missing = Self.knownKeys.filter { !text.contains("\"\($0)\"") }
        let retired = Self.retiredKeys.filter { text.contains("\"\($0)\"") }
        guard !missing.isEmpty || !retired.isEmpty || needsAbsoluteLineHeightMigration else {
            return
        }
        try? contents().write(to: Self.fileURL, atomically: true, encoding: .utf8)
        var changes: [String] = []
        if !missing.isEmpty { changes.append("added \(missing.joined(separator: ", "))") }
        if !retired.isEmpty { changes.append("removed \(retired.joined(separator: ", "))") }
        if needsAbsoluteLineHeightMigration {
            changes.append("converted line heights to absolute points")
            needsAbsoluteLineHeightMigration = false
        }
        FileHandle.standardError.write(Data("puzzle: updated settings: \(changes.joined(separator: "; "))\n".utf8))
    }


    /// Create the file with defaults if it doesn't exist, and return its URL.
    @discardableResult
    func ensureFileExists() -> URL {
        let url = Self.fileURL
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            try? contents().write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    /// Strip `//` comments (Zed's settings are JSONC) without touching slashes
    /// inside string values. Scanning per character is what makes a line like
    ///
    ///     "ui_font_family": "Iosevka // Term",   // my font
    ///
    /// work: the first `//` sits inside the string, only the second ends the
    /// line. Giving up on such a line left the trailing comment in place and
    /// made the whole file unparseable, which silently reverted every setting.
    static func strippingComments(_ raw: String) -> String {
        raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String(strippingComment(in: $0)) }
            .joined(separator: "\n")
    }

    /// JSON strings never span lines, so the string state starts fresh on each.
    private static func strippingComment(in line: Substring) -> Substring {
        var inString = false
        var escaped = false
        var previousWasSlash = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
                previousWasSlash = false
            } else if character == "/" {
                if previousWasSlash { return line[line.startIndex..<line.index(before: index)] }
                previousWasSlash = true
            } else {
                previousWasSlash = false
            }
            index = line.index(after: index)
        }
        return line
    }

    func load() {
        needsAbsoluteLineHeightMigration = false
        guard let raw = try? String(contentsOf: Self.fileURL, encoding: .utf8) else { return }
        let stripped = Self.strippingComments(raw)
        guard let data = stripped.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any] else {
            // Silently keeping the defaults hides a typo: the whole file is
            // ignored and every setting appears to have been forgotten.
            FileHandle.standardError.write(Data(
                "puzzle: \(Self.fileURL.path) is not valid JSON; keeping current settings\n".utf8))
            return
        }

        func number(_ key: String) -> CGFloat? {
            (json[key] as? NSNumber).map { CGFloat($0.doubleValue) }
        }
        if let v = json["buffer_font_family"] as? String, !v.isEmpty { fontFamily = v }
        if let v = number("buffer_font_size"), v >= 6, v <= 72 { fontSize = v }
        if let v = number("buffer_font_weight") { fontWeight = v }
        if let v = number("code_line_height") ?? number("buffer_line_height") {
            if v >= 8, v <= 200 {
                codeLineHeight = v
            } else if v >= 1, v <= 3 {
                codeLineHeight = NSLayoutManager().defaultLineHeight(for: editorFont()) * v
                needsAbsoluteLineHeightMigration = true
            }
        }
        if let v = number("tab_size"), v >= 1, v <= 16 { tabSize = Int(v) }
        if let v = json["show_inline_blame"] as? Bool { showInlineBlame = v }

        if let v = json["ui_font_family"] as? String, !v.isEmpty { uiFontFamily = v }
        if let v = number("ui_font_size"), v >= 8, v <= 32 { uiFontSize = v }
        if let v = number("ui_font_weight") { uiFontWeight = v }
        if let v = number("tree_line_height") ?? number("ui_line_height") {
            if v >= 8, v <= 200 {
                treeLineHeight = v
            } else if v >= 1, v <= 3 {
                let natural = ceil(uiFont(baseline: 12).boundingRectForFont.height)
                treeLineHeight = natural * v
                needsAbsoluteLineHeightMigration = true
            }
        }
    }

    /// Resolve a UI font. `size` is interpreted relative to a 12pt baseline so
    /// the small/large hierarchy is preserved while `ui_font_size` scales it.
    func uiFont(baseline size: CGFloat) -> NSFont {
        let resolved = max(8, uiFontSize + (size - 12))
        var font = NSFont(name: uiFontFamily, size: resolved)
            ?? NSFont.systemFont(ofSize: resolved)
        if uiFontWeight >= 600,
           let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) as NSFont? {
            font = bold
        }
        return font
    }

    /// Reload from disk and notify the UI.
    func reload() {
        load()
        Theme.invalidateCaches()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Resolve the configured editor font, honouring weight.
    func editorFont() -> NSFont {
        let size = fontSize
        var font = NSFont(name: fontFamily, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        if fontWeight >= 600 {
            let manager = NSFontManager.shared
            if let bold = manager.convert(font, toHaveTrait: .boldFontMask) as NSFont? { font = bold }
        }
        return font
    }
}

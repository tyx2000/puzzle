import Foundation

/// Lightweight, language-agnostic Command-click navigation. File references
/// are resolved first; symbols then prefer the nearest declaration in the
/// current file before searching source files in the opened project.
enum DefinitionNavigator {
    struct Destination: Equatable {
        let url: URL
        let utf16Location: Int
    }

    private static let sourceExtensions: Set<String> = [
        "c", "cc", "cpp", "cxx", "h", "hpp", "m", "mm", "swift",
        "js", "jsx", "mjs", "cjs", "ts", "tsx", "json", "css", "scss",
        "html", "htm", "xml", "py", "rb", "php", "go", "rs", "java",
        "kt", "kts", "sh", "bash", "zsh", "fish", "sql", "toml", "yaml",
        "yml", "md", "markdown"
    ]
    private static let pathExtensions = [
        "swift", "ts", "tsx", "js", "jsx", "mjs", "cjs", "json", "css",
        "scss", "html", "htm", "xml", "py", "go", "rs", "c", "h", "cpp",
        "hpp", "java", "kt", "sql", "toml", "yaml", "yml", "md"
    ]
    private static let skippedDirectories: Set<String> = [
        ".git", ".build", ".obj", "build", "DerivedData", "node_modules",
        "Pods", "vendor", ".next", "dist", "coverage"
    ]

    static func resolve(text: String, sourceURL: URL, projectRoot: URL,
                        utf16Location: Int) -> Destination? {
        let source = text as NSString
        guard source.length > 0 else { return nil }
        let location = min(max(0, utf16Location), source.length - 1)

        if let reference = pathReference(in: source, at: location),
           let destination = resolvePath(reference, from: sourceURL,
                                         projectRoot: projectRoot) {
            return destination
        }

        guard let symbol = symbol(at: location, in: source), symbol.count > 1 else {
            return nil
        }
        if let range = bestDeclaration(of: symbol, in: text, near: location) {
            return Destination(url: sourceURL, utf16Location: range.location)
        }

        let sourceDirectory = sourceURL.deletingLastPathComponent().standardizedFileURL
        let candidates = projectSourceFiles(in: projectRoot).sorted { lhs, rhs in
            let lhsSameDirectory = lhs.deletingLastPathComponent().standardizedFileURL == sourceDirectory
            let rhsSameDirectory = rhs.deletingLastPathComponent().standardizedFileURL == sourceDirectory
            if lhsSameDirectory != rhsSameDirectory { return lhsSameDirectory }
            let lhsSameExtension = lhs.pathExtension.lowercased() == sourceURL.pathExtension.lowercased()
            let rhsSameExtension = rhs.pathExtension.lowercased() == sourceURL.pathExtension.lowercased()
            if lhsSameExtension != rhsSameExtension { return lhsSameExtension }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
        for candidate in candidates where candidate.standardizedFileURL != sourceURL.standardizedFileURL {
            guard let values = try? candidate.resourceValues(forKeys: [.fileSizeKey]),
                  (values.fileSize ?? 0) <= 2 * 1024 * 1024,
                  let candidateText = try? String(contentsOf: candidate, encoding: .utf8),
                  let range = bestDeclaration(of: symbol, in: candidateText, near: nil) else {
                continue
            }
            return Destination(url: candidate, utf16Location: range.location)
        }
        return nil
    }

    static func hasNavigableToken(in text: String, utf16Location: Int) -> Bool {
        let source = text as NSString
        guard source.length > 0 else { return false }
        let location = min(max(0, utf16Location), source.length - 1)
        return pathReference(in: source, at: location) != nil
            || symbol(at: location, in: source) != nil
    }

    private static func pathReference(in text: NSString, at location: Int) -> String? {
        let line = text.lineRange(for: NSRange(location: location, length: 0))
        let lineText = text.substring(with: line) as NSString
        let local = location - line.location

        // Quoted import/require strings are the least ambiguous path form.
        for quote in ["\"", "'", "`"] {
            let scalar = (quote as NSString).character(at: 0)
            var left = local
            while left >= 0, lineText.character(at: left) != scalar { left -= 1 }
            guard left >= 0 else { continue }
            var right = max(local, left + 1)
            while right < lineText.length, lineText.character(at: right) != scalar { right += 1 }
            if right < lineText.length, left < local, local <= right {
                return lineText.substring(with: NSRange(location: left + 1,
                                                        length: right - left - 1))
            }
        }

        // Also support unquoted paths such as Sources/Foo.swift:42.
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "_./@~+#:-"))
        var left = location
        while left > 0,
              let scalar = UnicodeScalar(text.character(at: left - 1)),
              allowed.contains(scalar) { left -= 1 }
        var right = location
        while right < text.length,
              let scalar = UnicodeScalar(text.character(at: right)),
              allowed.contains(scalar) { right += 1 }
        guard right > left else { return nil }
        let candidate = text.substring(with: NSRange(location: left, length: right - left))
        return candidate.contains("/") || (candidate as NSString).pathExtension.count > 0
            ? candidate : nil
    }

    private static func resolvePath(_ rawReference: String, from sourceURL: URL,
                                    projectRoot: URL) -> Destination? {
        var reference = rawReference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty, !reference.hasPrefix("http://"),
              !reference.hasPrefix("https://") else { return nil }

        var requestedLine = 1
        if let match = reference.range(of: #"(?::|#L)(\d+)(?::\d+)?$"#,
                                       options: .regularExpression) {
            let suffix = String(reference[match])
            let digits = suffix.filter(\.isNumber)
            requestedLine = Int(digits) ?? 1
            reference.removeSubrange(match)
        }
        if let query = reference.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            reference = String(reference[..<query])
        }

        let root = projectRoot.standardizedFileURL
        let sourceDirectory = sourceURL.deletingLastPathComponent().standardizedFileURL
        var bases: [URL] = []
        if reference.hasPrefix("@/") || reference.hasPrefix("~/") {
            bases.append(root.appendingPathComponent(String(reference.dropFirst(2))))
        } else if reference.hasPrefix("/") {
            bases.append(root.appendingPathComponent(String(reference.dropFirst())))
        } else {
            bases.append(sourceDirectory.appendingPathComponent(reference))
            if !reference.hasPrefix(".") { bases.append(root.appendingPathComponent(reference)) }
        }

        for base in bases {
            for candidate in expandedPathCandidates(base) {
                let standardized = candidate.standardizedFileURL
                let values = try? standardized.resourceValues(forKeys: [.isDirectoryKey])
                guard standardized.path == root.path
                        || standardized.path.hasPrefix(root.path + "/"),
                      FileManager.default.fileExists(atPath: standardized.path),
                      values?.isDirectory != true
                else { continue }
                let contents = (try? String(contentsOf: standardized, encoding: .utf8)) ?? ""
                return Destination(url: standardized,
                                   utf16Location: location(ofLine: requestedLine, in: contents))
            }
        }
        return nil
    }

    private static func expandedPathCandidates(_ base: URL) -> [URL] {
        var result = [base]
        if base.pathExtension.isEmpty {
            result.append(contentsOf: pathExtensions.map { base.appendingPathExtension($0) })
            result.append(contentsOf: pathExtensions.map {
                base.appendingPathComponent("index").appendingPathExtension($0)
            })
        }
        return result
    }

    private static func symbol(at location: Int, in text: NSString) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_$"))
        var left = location
        if let scalar = UnicodeScalar(text.character(at: left)), !allowed.contains(scalar), left > 0 {
            left -= 1
        }
        while left > 0,
              let scalar = UnicodeScalar(text.character(at: left - 1)),
              allowed.contains(scalar) { left -= 1 }
        var right = left
        while right < text.length,
              let scalar = UnicodeScalar(text.character(at: right)),
              allowed.contains(scalar) { right += 1 }
        guard right > left else { return nil }
        let value = text.substring(with: NSRange(location: left, length: right - left))
        guard value.first?.isNumber != true else { return nil }
        return value
    }

    private static func bestDeclaration(of symbol: String, in text: String,
                                        near location: Int?) -> NSRange? {
        let escaped = NSRegularExpression.escapedPattern(for: symbol)
        let patterns = [
            #"(?m)^[\t ]*(?:(?:public|private|internal|open|static|final|export|default|async|declare|override|mutating|nonmutating)\s+)*(?:func|function|class|struct|enum|protocol|actor|typealias|interface|type|def|fn|trait|const|let|var|namespace|module)\s+"# + escaped + #"\b"#,
            #"(?m)^[\t ]*func\s*(?:\([^\n)]*\)\s*)?"# + escaped + #"\s*\("#,
            #"(?m)^[\t ]*(?:[A-Za-z_][A-Za-z0-9_<>,:*&?\[\] ]+\s+)+"# + escaped + #"\s*\([^;\n]*\)\s*(?:\{|$)"#
        ]
        let ns = text as NSString
        var matches: [NSRange] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let declaration = ns.substring(with: match.range) as NSString
                let tokenRange = declaration.range(of: symbol, options: .backwards)
                if tokenRange.location != NSNotFound {
                    matches.append(NSRange(location: match.range.location + tokenRange.location,
                                           length: tokenRange.length))
                }
            }
        }
        guard !matches.isEmpty else { return nil }
        let unique = Dictionary(grouping: matches, by: \.location).compactMap(\.value.first)
        guard let location else { return unique.min { $0.location < $1.location } }
        let preceding = unique.filter { $0.location <= location }
        return preceding.max { $0.location < $1.location }
            ?? unique.min { abs($0.location - location) < abs($1.location - location) }
    }

    private static func projectSourceFiles(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var result: [URL] = []
        while let url = enumerator.nextObject() as? URL, result.count < 20_000 {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                if skippedDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            if sourceExtensions.contains(url.pathExtension.lowercased()) {
                result.append(preservingRootSpelling(of: url, root: root))
            }
        }
        return result
    }

    /// FileManager canonicalizes `/var` to `/private/var` (and may do the same
    /// for a symlinked project root). Keep destinations in the spelling used by
    /// the editor so Command-click activates an existing tab instead of opening
    /// a duplicate URL for the same file.
    private static func preservingRootSpelling(of url: URL, root: URL) -> URL {
        let requestedRoot = root.standardizedFileURL
        let resolvedRoot = requestedRoot.resolvingSymlinksInPath()
        let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedURL.path.hasPrefix(resolvedRoot.path + "/") else { return url }
        let relative = String(resolvedURL.path.dropFirst(resolvedRoot.path.count + 1))
        return requestedRoot.appendingPathComponent(relative)
    }

    private static func location(ofLine requestedLine: Int, in text: String) -> Int {
        guard requestedLine > 1 else { return 0 }
        let ns = text as NSString
        var line = 1
        var location = 0
        while location < ns.length, line < requestedLine {
            let range = ns.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            line += 1
        }
        return min(location, ns.length)
    }
}

import Foundation

/// An EPUB opened for reading: its spine (the chapters, in reading order), its
/// table of contents, and access to the bytes of anything inside it.
///
/// An EPUB is a ZIP holding XHTML documents plus an OPF package file that lists
/// them and puts them in order. The package files are strict XML by
/// specification, so they are parsed with `XMLDocument`; the chapters
/// themselves are handed to `EPUBRenderer`, which is far more forgiving.
struct EPUBBook {
    /// One document in the spine — a chapter, a cover page, a notes section.
    struct Chapter {
        let id: String
        /// Archive-relative path, ready to hand to `ZipArchive`.
        let path: String
        let title: String
    }

    /// One line of the table of contents. `level` is nesting depth from 0, and
    /// `chapterIndex` is the spine entry the link lands in.
    struct TOCEntry {
        let title: String
        let level: Int
        let chapterIndex: Int
    }

    let title: String
    let author: String?
    let chapters: [Chapter]
    let contents: [TOCEntry]
    /// Directory the OPF lives in; every href in the package resolves against
    /// it, and so does every relative link inside a chapter.
    let packageDirectory: String
    private let archive: ZipArchive

    /// Bytes of an entry, by archive-relative path. Used for chapter XHTML and
    /// for the images a chapter references.
    func data(at path: String) -> Data? { archive.data(for: path) }

    init?(url: URL) {
        guard let archive = ZipArchive(url: url) else { return nil }
        self.init(archive: archive)
    }

    init?(archive: ZipArchive) {
        self.archive = archive

        // META-INF/container.xml is the one file at a fixed location. It points
        // at the package document; everything else is found from there.
        guard let containerData = archive.data(for: "META-INF/container.xml"),
              let container = try? XMLDocument(data: containerData),
              let rootfile = try? container.nodes(forXPath: "//rootfile").first
                as? XMLElement,
              let opfPath = rootfile.attribute(forName: "full-path")?.stringValue,
              !opfPath.isEmpty,
              let opfData = archive.data(for: opfPath),
              let opf = try? XMLDocument(data: opfData),
              let package = opf.rootElement() else { return nil }

        packageDirectory = Self.directory(of: opfPath)
        let base = packageDirectory

        title = (try? package.nodes(forXPath: "//*[local-name()='title']"))?
            .first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? url_lastComponentFallback(opfPath)
        author = (try? package.nodes(forXPath: "//*[local-name()='creator']"))?
            .first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty

        // manifest: id -> (href, media-type, properties)
        var hrefByID: [String: String] = [:]
        var mediaTypeByID: [String: String] = [:]
        var navigationID: String?
        for case let item as XMLElement
            in (try? package.nodes(forXPath: "//*[local-name()='item']")) ?? [] {
            guard let id = item.attribute(forName: "id")?.stringValue,
                  let href = item.attribute(forName: "href")?.stringValue else { continue }
            hrefByID[id] = Self.resolve(href, against: base)
            mediaTypeByID[id] = item.attribute(forName: "media-type")?.stringValue
            // EPUB 3 marks its navigation document here.
            if item.attribute(forName: "properties")?.stringValue?
                .split(separator: " ").contains("nav") == true {
                navigationID = id
            }
        }

        // spine: the reading order, as idrefs into the manifest.
        var spine: [Chapter] = []
        var spineIndexByPath: [String: Int] = [:]
        var tocID: String?
        if let spineElement = (try? package.nodes(forXPath: "//*[local-name()='spine']"))?
            .first as? XMLElement {
            // EPUB 2 points at its NCX from here.
            tocID = spineElement.attribute(forName: "toc")?.stringValue
        }
        for case let itemref as XMLElement
            in (try? package.nodes(forXPath: "//*[local-name()='itemref']")) ?? [] {
            guard let idref = itemref.attribute(forName: "idref")?.stringValue,
                  let path = hrefByID[idref], archive.contains(path) else { continue }
            // The navigation document is a chapter only if the spine says so;
            // most books list it as non-linear or leave it out entirely.
            spineIndexByPath[path] = spine.count
            spine.append(Chapter(id: idref, path: path,
                                 title: Self.fallbackTitle(for: path, number: spine.count + 1)))
        }
        guard !spine.isEmpty else { return nil }

        // Table of contents: EPUB 3's nav document first, then EPUB 2's NCX.
        var entries: [TOCEntry] = []
        if let navigationID, let navigationPath = hrefByID[navigationID],
           let navigationData = archive.data(for: navigationPath) {
            entries = Self.parseNavigation(navigationData,
                                           base: Self.directory(of: navigationPath),
                                           spineIndexByPath: spineIndexByPath)
        }
        if entries.isEmpty, let tocID, let ncxPath = hrefByID[tocID],
           let ncxData = archive.data(for: ncxPath) {
            entries = Self.parseNCX(ncxData, base: Self.directory(of: ncxPath),
                                    spineIndexByPath: spineIndexByPath)
        }

        // Name the spine entries after the contents wherever the two line up,
        // so the chapter header reads "Chapter One" and not "part0007.xhtml".
        var named = spine
        for entry in entries where named.indices.contains(entry.chapterIndex) {
            let chapter = named[entry.chapterIndex]
            guard chapter.title.hasPrefix(Self.untitledPrefix) else { continue }
            named[entry.chapterIndex] = Chapter(id: chapter.id, path: chapter.path,
                                                title: entry.title)
        }
        chapters = named
        // With no usable contents at all, the spine itself is the contents.
        contents = entries.isEmpty
            ? named.enumerated().map { TOCEntry(title: $1.title, level: 0, chapterIndex: $0) }
            : entries
    }

    // MARK: - Navigation documents

    /// EPUB 3: an XHTML `<nav epub:type="toc">` holding nested `<ol><li><a>`.
    private static func parseNavigation(_ data: Data, base: String,
                                        spineIndexByPath: [String: Int]) -> [TOCEntry] {
        guard let document = try? XMLDocument(data: data, options: [.documentTidyHTML]),
              let root = document.rootElement() else { return [] }
        // Prefer the navigation marked as the table of contents; a nav document
        // may also carry a landmarks or page-list nav we do not want.
        let navigations = (try? root.nodes(forXPath: "//*[local-name()='nav']"))?
            .compactMap { $0 as? XMLElement } ?? []
        let toc = navigations.first {
            let type = $0.attribute(forName: "epub:type")?.stringValue
                ?? $0.attribute(forName: "type")?.stringValue
            return type?.contains("toc") == true
        } ?? navigations.first
        guard let toc else { return [] }

        var entries: [TOCEntry] = []
        func walk(_ list: XMLElement, level: Int) {
            for case let item as XMLElement in list.children ?? []
            where item.name?.lowercased() == "li" {
                if let link = (try? item.nodes(forXPath: "./*[local-name()='a']"))?
                    .first as? XMLElement,
                   let href = link.attribute(forName: "href")?.stringValue,
                   let index = spineIndexByPath[resolve(stripFragment(href), against: base)] {
                    let label = (link.stringValue ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if let label = label.nonEmpty {
                        entries.append(TOCEntry(title: label, level: level,
                                                chapterIndex: index))
                    }
                }
                for case let nested as XMLElement in item.children ?? []
                where nested.name?.lowercased() == "ol" || nested.name?.lowercased() == "ul" {
                    walk(nested, level: level + 1)
                }
            }
        }
        for case let list as XMLElement in toc.children ?? []
        where list.name?.lowercased() == "ol" || list.name?.lowercased() == "ul" {
            walk(list, level: 0)
        }
        return entries
    }

    /// EPUB 2: an NCX file, `<navMap>` of nested `<navPoint>`s.
    private static func parseNCX(_ data: Data, base: String,
                                 spineIndexByPath: [String: Int]) -> [TOCEntry] {
        guard let document = try? XMLDocument(data: data),
              let map = (try? document.nodes(forXPath: "//*[local-name()='navMap']"))?
                .first as? XMLElement else { return [] }

        var entries: [TOCEntry] = []
        func walk(_ parent: XMLElement, level: Int) {
            for case let point as XMLElement in parent.children ?? []
            where point.name?.lowercased().hasSuffix("navpoint") == true {
                let label = (try? point.nodes(forXPath:
                    "./*[local-name()='navLabel']/*[local-name()='text']"))?
                    .first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                let href = ((try? point.nodes(forXPath: "./*[local-name()='content']"))?
                    .first as? XMLElement)?.attribute(forName: "src")?.stringValue
                if let label = label?.nonEmpty, let href,
                   let index = spineIndexByPath[resolve(stripFragment(href), against: base)] {
                    entries.append(TOCEntry(title: label, level: level, chapterIndex: index))
                }
                walk(point, level: level + 1)
            }
        }
        walk(map, level: 0)
        return entries
    }

    // MARK: - Path arithmetic

    static let untitledPrefix = "\u{0}chapter "

    private static func fallbackTitle(for path: String, number: Int) -> String {
        // Marked so a contents entry can claim it later; the marker is stripped
        // for display.
        untitledPrefix + "\(number)"
    }

    /// Display form of a title that no contents entry claimed.
    static func displayTitle(_ title: String) -> String {
        guard title.hasPrefix(untitledPrefix) else { return title }
        return "Chapter " + title.dropFirst(untitledPrefix.count)
    }

    static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    static func stripFragment(_ href: String) -> String {
        guard let hash = href.firstIndex(of: "#") else { return href }
        return String(href[..<hash])
    }

    /// Resolve an href against a directory inside the archive, collapsing the
    /// `../` that books use constantly (`../images/cover.jpg` from `text/`) and
    /// undoing the percent-encoding a ZIP entry name never has.
    static func resolve(_ href: String, against directory: String) -> String {
        let decoded = href.removingPercentEncoding ?? href
        if decoded.hasPrefix("/") { return String(decoded.dropFirst()) }
        var components = directory.isEmpty ? [] : directory.components(separatedBy: "/")
        for part in decoded.components(separatedBy: "/") {
            switch part {
            case "", ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(part)
            }
        }
        return components.joined(separator: "/")
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// Last resort when a package carries no title at all.
private func url_lastComponentFallback(_ path: String) -> String {
    (path as NSString).lastPathComponent
}

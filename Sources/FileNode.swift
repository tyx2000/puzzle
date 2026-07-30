import AppKit

/// A lazily-populated node in the project file tree.
///
/// Memory note: a node stores only its **name**, not a full `URL`. Names are
/// usually short enough for Swift's inline small-string storage, so they cost no
/// heap allocation at all; a per-node `URL` measured ~7× larger (0.49 vs
/// 0.07 KB/node), which matters once a large project is expanded. Only the root
/// keeps a URL — descendants derive theirs by walking up the parent chain.
final class FileNode {
    let name: String
    let isDirectory: Bool
    weak var parent: FileNode?
    private var loadedChildren: [FileNode]?
    /// Set only on the root node.
    private let rootURL: URL?

    /// Root node.
    init(url: URL, isDirectory: Bool, parent: FileNode? = nil) {
        self.rootURL = url
        self.name = url.lastPathComponent
        self.isDirectory = isDirectory
        self.parent = parent
    }

    /// Child node — derives its URL from `parent`.
    private init(name: String, isDirectory: Bool, parent: FileNode) {
        self.rootURL = nil
        self.name = name
        self.isDirectory = isDirectory
        self.parent = parent
    }

    var url: URL {
        if let rootURL { return rootURL }
        guard let parent else { return URL(fileURLWithPath: name) }
        return parent.url.appendingPathComponent(name)
    }

    /// Directory children, loaded on first access and cached.
    var children: [FileNode] {
        if let loadedChildren { return loadedChildren }
        let loaded = Self.loadChildren(of: url, parent: self)
        loadedChildren = loaded
        return loaded
    }

    /// Drop the cache so the next access re-reads from disk.
    func invalidate() {
        loadedChildren = nil
    }

    /// Free this subtree's cached nodes (called when a directory collapses).
    /// Without this, expanding a big folder once kept every node alive for the
    /// life of the window even though the rows are no longer visible.
    func releaseChildren() {
        guard let kids = loadedChildren else { return }
        for k in kids { k.releaseChildren() }
        loadedChildren = nil
    }

    /// Never shown: version-control internals and OS bookkeeping. Matches the
    /// set Zed hides by default.
    private static let excludedNames: Set<String> = [
        ".git", ".svn", ".hg", "CVS", ".DS_Store", "Thumbs.db",
    ]

    private static func loadChildren(of directory: URL, parent: FileNode) -> [FileNode] {
        let fm = FileManager.default
        // Dotfiles are shown. `.skipsHiddenFiles` hid every one of them —
        // .gitignore, .eslintrc.js, .env, .storybook — which in a JS project is
        // most of the configuration. Only VCS metadata and OS junk are dropped.
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return [] }

        let nodes: [FileNode] = entries.compactMap { url -> FileNode? in
            guard !excludedNames.contains(url.lastPathComponent) else { return nil }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            // Keep only the name: the URLs handed back by
            // `contentsOfDirectory(includingPropertiesForKeys:)` also carry a
            // cached resource-value dictionary, which is pure overhead to retain.
            return FileNode(name: url.lastPathComponent, isDirectory: isDir, parent: parent)
        }

        // Directories first, then files, each alphabetical (case-insensitive).
        return nodes.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}

import AppKit

/// Material Icon Theme icons for the file tree and the Git panel.
///
/// `build.sh` bundles the mapping (`file-icons.json`) and the SVGs it needs
/// (`icons/`) from the vendored theme. Everything is loaded lazily and cached:
/// a tree row asks for its icon on every redraw, and decoding an SVG is far too
/// expensive to repeat. When the resources are missing — the regression-test
/// binary runs outside an app bundle — every lookup returns nil and callers fall
/// back to their SF Symbol.
enum FileIcons {
    private struct Manifest: Decodable {
        let names: [String: String]
        let extensions: [String: String]
        let folders: [String: String]
        let light: [String]
    }

    private static var resources: URL? = Bundle.main.resourceURL
    private static var loaded = false
    private static var manifestStorage: Manifest?
    private static var lightVariants: Set<String> = []
    /// Decoded images, keyed by icon name and appearance — the `_light` variants
    /// exist precisely because one image cannot serve both.
    private static var cache: [String: NSImage?] = [:]

    private static var manifest: Manifest? {
        if loaded { return manifestStorage }
        loaded = true
        guard let url = resources?.appendingPathComponent("file-icons.json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Manifest.self, from: data) else {
            return nil
        }
        manifestStorage = decoded
        lightVariants = Set(decoded.light)
        return decoded
    }

    private static var iconDirectory: URL? {
        resources?.appendingPathComponent("icons")
    }

    /// Point the provider at another resource directory. Regression tests build
    /// one with Tools/generate-file-icons.py, since the test binary runs outside
    /// an app bundle.
    static func useResources(at url: URL?) {
        resources = url
        loaded = false
        manifestStorage = nil
        lightVariants = []
        cache.removeAll(keepingCapacity: false)
        // Must go with the cache it indexes: stale keys would absorb every
        // eviction and the size cap would stop holding.
        lastUsed.removeAll(keepingCapacity: false)
    }

    /// True when Puzzle has its icon resources; the tree keeps its SF Symbols
    /// otherwise.
    static var isAvailable: Bool { manifest != nil }

    /// The icon name for a file, by whole name first (`package.json`,
    /// `Dockerfile`) and then by extension, longest compound suffix first so
    /// `.d.ts` wins over `.ts`. Falls back to the generic file icon.
    ///
    /// Names are resolved when a row is configured; the image itself is only
    /// looked up while drawing, so a row never holds on to a rendered icon.
    static func fileIconName(for name: String) -> String? {
        guard let manifest else { return nil }
        let lowered = name.lowercased()
        if let icon = manifest.names[lowered] { return icon }
        var suffix = Substring(lowered)
        while let dot = suffix.firstIndex(of: ".") {
            suffix = suffix[suffix.index(after: dot)...]
            if let icon = manifest.extensions[String(suffix)] { return icon }
        }
        return "file"
    }

    /// The icon name for a folder. Upstream ships no open variant for the named
    /// folders (`folder-src` and friends are generated at release time), so only
    /// the plain folder opens and closes; the disclosure chevron carries that
    /// state for the rest.
    static func folderIconName(for name: String, expanded: Bool) -> String? {
        guard let manifest else { return nil }
        if let icon = manifest.folders[name.lowercased()] { return icon }
        return expanded ? "folder-open" : "folder"
    }

    static func image(named icon: String, dark: Bool) -> NSImage? {
        let file = (!dark && lightVariants.contains(icon)) ? icon + "_light" : icon
        if let hit = cache[file] {
            lastUsed[file] = nextTick()
            return hit
        }
        let loaded = iconDirectory
            .map { $0.appendingPathComponent(file + ".svg") }
            .flatMap { NSImage(contentsOf: $0) }
        loaded?.isTemplate = false
        cache[file] = loaded
        lastUsed[file] = nextTick()
        evictIfNeeded()
        return loaded
    }

    /// A decoded icon keeps its parsed SVG alive, so a tree with many file types
    /// would otherwise accumulate them for the life of the process. Only the
    /// icons on screen (plus recent scrolling) need to stay.
    static var maxCachedImages = 160
    private static var lastUsed: [String: UInt64] = [:]
    private static var tick: UInt64 = 0

    private static func nextTick() -> UInt64 {
        tick += 1
        return tick
    }

    /// Drop the least recently drawn quarter once over the cap, so eviction is
    /// occasional rather than on every miss past the limit.
    private static func evictIfNeeded() {
        guard cache.count > maxCachedImages else { return }
        let excess = cache.count - (maxCachedImages * 3 / 4)
        let doomed = lastUsed.sorted { $0.value < $1.value }.prefix(excess).map(\.key)
        for key in doomed {
            cache.removeValue(forKey: key)
            lastUsed.removeValue(forKey: key)
        }
    }

    /// Drop decoded images when the window is miniaturised or memory is tight.
    static func releaseTransientMemory() {
        cache.removeAll(keepingCapacity: false)
        lastUsed.removeAll(keepingCapacity: false)
    }

    static var cachedImageCountForTesting: Int { cache.count }
    static var lastUsedCountForTesting: Int { lastUsed.count }
}

import AppKit

/// Zed-matched theme. By default colors are dynamic (One Light / One Dark) and
/// follow the system appearance, exactly like Zed does when no theme is pinned.
/// Light values are sampled from Zed's One Light on this Mac; syntax hues are
/// One Light / One Dark. `theme` in settings.json can pin Ayu Dark instead.
/// Font and exact row heights also come from settings.json.
enum Theme {
    private static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255.0,
                green: CGFloat((v >> 8) & 0xff) / 255.0,
                blue: CGFloat(v & 0xff) / 255.0, alpha: 1.0)
    }

    /// Which palette paints the app.
    enum Name: String {
        /// Zed's default: One Light or One Dark, following the system.
        case one
        /// Ayu Dark, ported from ayu-theme/vscode-ayu (MIT). Always dark.
        case ayuDark = "ayu-dark"
    }

    /// A color that resolves to `light` or `dark` per the current appearance.
    private static func dyn(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return hex(isDark ? dark : light)
        }
    }

    /// One colour of the palette: the One Light/One Dark pair, plus the value
    /// Ayu Dark uses for the same role.
    ///
    /// Colours are resolved per access rather than stored, so switching themes
    /// in settings.json takes effect without AppKit's cached dynamic-colour
    /// resolutions going stale. `colorCache` keeps that from allocating an
    /// NSColor inside every draw call.
    private static func themed(_ light: UInt32, _ dark: UInt32, ayu: UInt32) -> NSColor {
        let isAyu = Settings.shared.theme == .ayuDark
        let key = isAyu ? 1 << 56 | UInt64(ayu) : UInt64(light) << 24 | UInt64(dark)
        if let hit = colorCache[key] { return hit }
        let made = isAyu ? hex(ayu) : dyn(light, dark)
        colorCache[key] = made
        return made
    }

    /// True when the app is painting dark — either because the system is dark or
    /// because the pinned theme is.
    static func isDark(_ appearance: NSAppearance = NSApp?.effectiveAppearance ?? .init(named: .aqua)!) -> Bool {
        if Settings.shared.theme == .ayuDark { return true }
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// Pin AppKit's own appearance to the theme, so scrollers, menus and text
    /// selection match a theme that does not follow the system.
    static func applyAppearance() {
        NSApp?.appearance = Settings.shared.theme == .ayuDark
            ? NSAppearance(named: .darkAqua)
            : nil
    }

    // Surfaces
    static var editorBackground: NSColor { themed(0xfbfbfb, 0x282c34, ayu: 0x0d1017) }
    static var panelBackground: NSColor  { themed(0xefefef, 0x21252b, ayu: 0x0d1017) }
    static var barBackground: NSColor    { themed(0xefefef, 0x21252b, ayu: 0x0d1017) }
    static var activityBar: NSColor      { themed(0xe4e4e5, 0x21252b, ayu: 0x0d1017) }
    static var border: NSColor           { themed(0xdcdcdd, 0x181a1f, ayu: 0x1b1f29) }
    static var selection: NSColor        { themed(0xd4d4d5, 0x3e4451, ayu: 0x193155) }
    static var lineHighlight: NSColor    { themed(0xf0f0f0, 0x2c313c, ayu: 0x232a36) }
    // Ayu's code area matches the panel, so the active tab cannot also match the
    // editor without vanishing into the tab strip: it keeps the surface one step
    // lighter, which is the only thing marking which tab is open.
    static var activeTab: NSColor        { themed(0xffffff, 0x282c34, ayu: 0x161a24) }
    static var inactiveTab: NSColor      { themed(0xefefef, 0x21252b, ayu: 0x0d1017) }
    static var hover: NSColor            { themed(0xe0e0e1, 0x2f343e, ayu: 0x1c212b) }
    /// active file in the tree
    static var activeRow: NSColor        { themed(0xdadadb, 0x2f343e, ayu: 0x232a36) }
    /// matched text in search results
    static var searchMatch: NSColor      { themed(0xc5d5f5, 0x3a4a63, ayu: 0x4c4126) }

    // Text
    static var foreground: NSColor   { themed(0x383a42, 0xc8ccd4, ayu: 0xbfbdb6) }
    static var dimText: NSColor      { themed(0xa0a1a7, 0x828997, ayu: 0x5a6378) }
    static var gutter: NSColor       { themed(0xb6b6b8, 0x4b5263, ayu: 0x404758) }
    static var gutterActive: NSColor { themed(0x383a42, 0xc8ccd4, ayu: 0x5a6378) }
    static var cursor: NSColor       { themed(0x526fff, 0x528bff, ayu: 0xe6b450) }
    /// collapsed folder icon
    static var folderClosed: NSColor { themed(0x9a9aa0, 0x6b7280, ayu: 0x5a6378) }

    // Search / find input
    static var inputBackground: NSColor    { themed(0xffffff, 0x2f343e, ayu: 0x10141c) }
    static var inputBorder: NSColor        { themed(0xd0d0d3, 0x3f4653, ayu: 0x1a1f2a) }
    static var inputBorderFocused: NSColor { themed(0xb4b4b8, 0x51596a, ayu: 0x5a6378) }
    static var toggleActiveBackground: NSColor { themed(0xdcdcdf, 0x3f4653, ayu: 0x232a36) }
    // Git diff (One Light / One Dark tuned; Ayu's markup.inserted/deleted)
    static var diffAddedText: NSColor   { themed(0x216e3f, 0x98c379, ayu: 0x70bf56) }
    static var diffRemovedText: NSColor { themed(0xa8322a, 0xe06c75, ayu: 0xf26d78) }
    static var diffAddedBackground: NSColor   { themed(0xe3f7e8, 0x2b3a2e, ayu: 0x18251b) }
    static var diffRemovedBackground: NSColor { themed(0xfdeaea, 0x3d2b2d, ayu: 0x2a1a1d) }

    static var findMatch: NSColor        { themed(0xfaeaa6, 0x5b5333, ayu: 0x4c4126) }
    static var findMatchCurrent: NSColor { themed(0xf5c451, 0x8a6d1f, ayu: 0x806b3e) }

    // Accent hues (One Light / One Dark / Ayu Dark). These name a *hue*: the
    // panels use them for git status, links and markers, so red stays red in
    // every theme.
    static var red: NSColor     { themed(0xe45649, 0xe06c75, ayu: 0xf07178) }
    static var green: NSColor   { themed(0x50a14f, 0x98c379, ayu: 0xaad94c) }
    static var yellow: NSColor  { themed(0xc18401, 0xe5c07b, ayu: 0xffb454) }
    static var orange: NSColor  { themed(0x986801, 0xd19a66, ayu: 0xff8f40) }
    static var blue: NSColor    { themed(0x4078f2, 0x61afef, ayu: 0x39bae6) }
    static var purple: NSColor  { themed(0xa626a4, 0xc678dd, ayu: 0xd2a6ff) }
    static var cyan: NSColor    { themed(0x0184bc, 0x56b6c2, ayu: 0x95e6cb) }
    static var comment: NSColor { themed(0xa0a1a7, 0x5c6370, ayu: 0x5a6673) }
    static var punct: NSColor   { themed(0x9ca0a4, 0x8b929e, ayu: 0x8a8983) }

    // Syntax roles whose hue is not the same in every theme: One paints types
    // yellow and calls blue, Ayu does the reverse; One's keywords are purple
    // and its numbers orange, Ayu's the other way round. Naming the role rather
    // than the hue keeps both themes honest.
    static var syntaxType: NSColor     { themed(0xc18401, 0xe5c07b, ayu: 0x39bae6) }
    static var syntaxFunction: NSColor { themed(0x4078f2, 0x61afef, ayu: 0xffb454) }
    static var syntaxKeyword: NSColor  { themed(0xa626a4, 0xc678dd, ayu: 0xff8f40) }
    static var syntaxConstant: NSColor { themed(0x986801, 0xd19a66, ayu: 0xd2a6ff) }

    /// macOS window corner radius on this OS — action buttons and file tabs use
    /// the same value so their corners read as part of the same window.
    static let cornerRadius: CGFloat = 10

    // Font + exact row metrics come from settings.json.

    static func editorFont() -> NSFont {
        if let cachedFont { return cachedFont }
        let f = Settings.shared.editorFont()
        cachedFont = f
        return f
    }

    /// UI font for the left panel / tabs / panels. `size` is a 12pt-baseline
    /// hint; `ui_font_size` in settings.json scales the whole hierarchy.
    static func uiFont(_ size: CGFloat = 12) -> NSFont {
        Settings.shared.uiFont(baseline: size)
    }

    /// Exact file-tree row height in points.
    static func treeRowHeight() -> CGFloat {
        Settings.shared.treeLineHeight
    }

    /// Natural vs. target line height. The layout-manager delegate fixes every
    /// fragment to this target and centers its baseline inside the line box.
    static func lineMetrics() -> (natural: CGFloat, target: CGFloat) {
        let font = editorFont()
        let natural = NSLayoutManager().defaultLineHeight(for: font)
        return (natural, Settings.shared.codeLineHeight)
    }

    /// Width of one character (the editor font is monospaced).
    static func characterWidth() -> CGFloat {
        if let cachedCharWidth { return cachedCharWidth }
        let w = ("0" as NSString).size(withAttributes: [.font: editorFont()]).width
        cachedCharWidth = w
        return w
    }

    // Font, paragraph style and the editor attribute dictionary are immutable
    // for a given settings generation, and are asked for constantly (every
    // document open, every re-highlight, every gutter draw). Building them each
    // time meant a font lookup plus a text measurement per call, and a fresh
    // NSParagraphStyle object retained by every attribute run in every buffer.
    // Cache them and invalidate when settings change.
    private static var cachedFont: NSFont?
    private static var cachedParagraph: NSParagraphStyle?
    private static var cachedCharWidth: CGFloat?
    private static var cachedAttributes: [NSColor: [NSAttributedString.Key: Any]] = [:]
    private static var cachedSymbols: [String: NSImage] = [:]
    private static var colorCache: [UInt64: NSColor] = [:]

    /// Called from Settings.reload() so cached metrics don't go stale.
    static func invalidateCaches() {
        cachedFont = nil
        cachedParagraph = nil
        cachedCharWidth = nil
        cachedAttributes.removeAll()
        colorCache.removeAll()
        // Symbols are appearance-independent templates, but clearing here also
        // bounds the cache if future settings add configurable symbol sizes.
        cachedSymbols.removeAll()
    }

    static func paragraphStyle() -> NSParagraphStyle {
        if let cachedParagraph { return cachedParagraph }
        let p = NSMutableParagraphStyle()
        let target = lineMetrics().target
        p.minimumLineHeight = target
        p.maximumLineHeight = target
        p.defaultTabInterval = characterWidth() * CGFloat(Settings.shared.tabSize)
        p.tabStops = []
        let frozen = p.copy() as! NSParagraphStyle
        cachedParagraph = frozen
        return frozen
    }

    /// Attributes shared by the editor text and the gutter numbers, so both sit
    /// on the same baseline.
    static func textAttributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        if let hit = cachedAttributes[color] { return hit }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: editorFont(),
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle(),
        ]
        cachedAttributes[color] = attrs
        return attrs
    }

    /// SF Symbols are immutable template images. Creating them repeatedly in
    /// table-cell configuration builds CoreSVG representations and internal
    /// SwiftUI state, so share one image for every distinct configuration.
    static func symbol(_ name: String, accessibilityDescription: String? = nil,
                       pointSize: CGFloat? = nil,
                       weight: NSFont.Weight = .regular) -> NSImage? {
        let key = "\(name)|\(pointSize ?? 0)|\(weight.rawValue)|\(accessibilityDescription ?? "")"
        if let image = cachedSymbols[key] { return image }
        guard var image = NSImage(systemSymbolName: name,
                                  accessibilityDescription: accessibilityDescription) else {
            return nil
        }
        if let pointSize {
            image = image.withSymbolConfiguration(
                .init(pointSize: pointSize, weight: weight)) ?? image
        }
        cachedSymbols[key] = image
        return image
    }
}

/// A flat, appearance-adaptive background view (replaces layer-backed fills so
/// colors update live when the system switches light/dark).
class FlatView: NSView {
    var fillColor: NSColor = .clear { didSet { needsDisplay = true } }
    var bottomBorder = false
    var topBorder = false
    var rightBorder = false

    override func draw(_ dirtyRect: NSRect) {
        fillColor.setFill()
        bounds.fill()
        Theme.border.setFill()
        if bottomBorder { NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill() }
        if topBorder { NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill() }
        if rightBorder { NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

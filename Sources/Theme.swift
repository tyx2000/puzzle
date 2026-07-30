import AppKit

/// Zed-matched theme. Colors are dynamic (One Light / One Dark) and follow the
/// system appearance, exactly like Zed does when no theme is pinned.
/// Light values are sampled from Zed's One Light on this Mac; syntax hues are
/// One Light / One Dark. Font + line height match this Mac's Zed settings
/// (Monaco 12, buffer_line_height 1.8).
enum Theme {
    private static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255.0,
                green: CGFloat((v >> 8) & 0xff) / 255.0,
                blue: CGFloat(v & 0xff) / 255.0, alpha: 1.0)
    }

    /// A color that resolves to `light` or `dark` per the current appearance.
    private static func dyn(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return hex(isDark ? dark : light)
        }
    }

    static func isDark(_ appearance: NSAppearance = NSApp?.effectiveAppearance ?? .init(named: .aqua)!) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    // Surfaces
    static let editorBackground = dyn(0xfbfbfb, 0x282c34)
    static let panelBackground  = dyn(0xefefef, 0x21252b)
    static let barBackground    = dyn(0xefefef, 0x21252b)
    static let activityBar      = dyn(0xe4e4e5, 0x21252b)
    static let border           = dyn(0xdcdcdd, 0x181a1f)
    static let selection        = dyn(0xd4d4d5, 0x3e4451)
    static let lineHighlight    = dyn(0xf0f0f0, 0x2c313c)
    static let activeTab        = dyn(0xffffff, 0x282c34)
    static let inactiveTab      = dyn(0xefefef, 0x21252b)
    static let hover            = dyn(0xe0e0e1, 0x2f343e)
    static let activeRow        = dyn(0xdadadb, 0x2f343e)  // active file in the tree
    static let searchMatch      = dyn(0xc5d5f5, 0x3a4a63)  // matched text in search results

    // Text
    static let foreground   = dyn(0x383a42, 0xc8ccd4)
    static let dimText      = dyn(0xa0a1a7, 0x828997)
    static let gutter       = dyn(0xb6b6b8, 0x4b5263)
    static let gutterActive = dyn(0x383a42, 0xc8ccd4)
    static let cursor       = dyn(0x526fff, 0x528bff)
    static let folderClosed = dyn(0x9a9aa0, 0x6b7280)  // collapsed folder icon

    // Search / find input
    static let inputBackground     = dyn(0xffffff, 0x2f343e)
    static let inputBorder         = dyn(0xd0d0d3, 0x3f4653)
    static let inputBorderFocused  = dyn(0xb4b4b8, 0x51596a)
    static let toggleActiveBackground = dyn(0xdcdcdf, 0x3f4653)
    // Git diff (One Light / One Dark tuned)
    static let diffAddedText        = dyn(0x216e3f, 0x98c379)
    static let diffRemovedText      = dyn(0xa8322a, 0xe06c75)
    static let diffAddedBackground  = dyn(0xe3f7e8, 0x2b3a2e)
    static let diffRemovedBackground = dyn(0xfdeaea, 0x3d2b2d)

    static let findMatch        = dyn(0xfaeaa6, 0x5b5333)
    static let findMatchCurrent = dyn(0xf5c451, 0x8a6d1f)

    // Syntax (One Light / One Dark)
    static let red     = dyn(0xe45649, 0xe06c75)  // tags, properties, variables.builtin
    static let green   = dyn(0x50a14f, 0x98c379)  // strings
    static let yellow  = dyn(0xc18401, 0xe5c07b)  // types, classes
    static let orange  = dyn(0x986801, 0xd19a66)  // numbers, constants, params
    static let blue    = dyn(0x4078f2, 0x61afef)  // functions
    static let purple  = dyn(0xa626a4, 0xc678dd)  // keywords
    static let cyan    = dyn(0x0184bc, 0x56b6c2)  // escapes, operators, builtins
    static let comment = dyn(0xa0a1a7, 0x5c6370)  // comments
    static let punct   = dyn(0x9ca0a4, 0x8b929e)  // punctuation

    /// macOS window corner radius on this OS — action buttons and file tabs use
    /// the same value so their corners read as part of the same window.
    static let cornerRadius: CGFloat = 10

    // Font + metrics come from settings.json (defaults match this Mac's Zed:
    // Monaco 12, line height 1.8).
    static var lineHeightMultiple: CGFloat { Settings.shared.lineHeight }

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

    /// File-tree row height: the UI font's height times `ui_line_height`.
    static func treeRowHeight() -> CGFloat {
        let font = uiFont(12)
        let natural = ceil(font.boundingRectForFont.height)
        return max(14, ceil(natural * Settings.shared.uiLineHeight))
    }

    /// Natural vs. target line height.
    ///
    /// NOTE: `lineHeightMultiple` puts the extra leading *above* the glyphs, so
    /// text sits low in the line box. We deliberately do NOT correct this with
    /// `.baselineOffset` — that inflates the line fragment height (measured:
    /// 28pt → 39.5pt) and would desync the gutter. Instead the current-line band
    /// is centered on the glyphs (see PuzzleTextView).
    static func lineMetrics() -> (natural: CGFloat, target: CGFloat) {
        let font = editorFont()
        let natural = NSLayoutManager().defaultLineHeight(for: font)
        return (natural, natural * lineHeightMultiple)
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

    /// Called from Settings.reload() so cached metrics don't go stale.
    static func invalidateCaches() {
        cachedFont = nil
        cachedParagraph = nil
        cachedCharWidth = nil
        cachedAttributes.removeAll()
        // Symbols are appearance-independent templates, but clearing here also
        // bounds the cache if future settings add configurable symbol sizes.
        cachedSymbols.removeAll()
    }

    static func paragraphStyle() -> NSParagraphStyle {
        if let cachedParagraph { return cachedParagraph }
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = lineHeightMultiple
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

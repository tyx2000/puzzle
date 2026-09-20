import AppKit

/// Ayu Dark, ported from ayu-theme/vscode-ayu (MIT), and the only palette the
/// app paints. Every colour is one fixed value: nothing here follows the system
/// appearance and there is no theme setting, so a token means the same thing
/// everywhere it is read and views may cache what they are built with.
enum Theme {
    /// Colours are stored, not computed: one NSColor per token for the life of
    /// the process, so a draw call never allocates one.
    private static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255.0,
                green: CGFloat((v >> 8) & 0xff) / 255.0,
                blue: CGFloat(v & 0xff) / 255.0, alpha: 1.0)
    }

    /// The palette is dark, so AppKit's own chrome — menus, text selection,
    /// scrollers, sheets — has to be told as much, whatever the system is set
    /// to.
    static func applyAppearance() {
        NSApp?.appearance = NSAppearance(named: .darkAqua)
    }

    // Surfaces
    static let diffBackground = hex(0x0d1017)
    static let panelBackground = hex(0x0d1017)
    static let barBackground = hex(0x0d1017)
    /// Scrollbars. AppKit's dark knob is a fixed light grey, which these near
    /// black surfaces turn into the brightest thing on screen.
    static let scrollerKnob = hex(0x39404e)
    static let scrollerSlot = hex(0x11151d)
    static let border = hex(0x1b1f29)
    /// Behind a diff's hunk headers.
    static let lineHighlight = hex(0x232a36)
    /// A surface one step lighter than the bar: a live button's ground.
    static let activeTab = hex(0x161a24)
    /// Behind whatever is selected: the open diff's tab, the project being
    /// shown. One token so the two read as the same state.
    static let selectedControl = hex(0x232a36)
    static let selectedControlText = hex(0xe6e9ef)
    static let inactiveTab = hex(0x0d1017)
    static let hover = hex(0x1c212b)
    /// Every other row of a list read across — branches, commits — so the eye
    /// keeps its line over a wide row. A step off the panel, well short of
    /// `hover`, so a stripe is never mistaken for the row under the pointer.
    static let stripedRow = hex(0x131721)
    /// The row a list has selected, and the hunk headers in a diff.
    static let activeRow = hex(0x232a36)
    // Text
    static let foreground = hex(0xbfbdb6)
    static let dimText = hex(0x5a6378)
    static let gutter = hex(0x404758)
    /// Ayu's accent: the branch in a commit row, the ↑ on one not pushed, the
    /// mark on the change the diff's ↑↓ buttons are on.
    static let accent = hex(0xe6b450)

    // Git diff: Ayu's markup.inserted / markup.deleted, with backgrounds mixed
    // down to sit under code without drowning it.
    static let diffAddedText = hex(0x70bf56)
    static let diffRemovedText = hex(0xf26d78)
    static let diffAddedBackground = hex(0x18251b)
    static let diffRemovedBackground = hex(0x2a1a1d)

    // Accent hues. These name a *hue*: the panels use them for git status and
    // the regions' frames.
    static let red = hex(0xf07178)
    static let green = hex(0xaad94c)
    static let yellow = hex(0xffb454)
    static let orange = hex(0xff8f40)
    static let blue = hex(0x39bae6)
    static let purple = hex(0xd2a6ff)

    /// Distinct categorical tracks, as in VS Code's SCM graph. Use the Ayu
    /// hues already present in Gift; graph colours denote ancestry, not status.
    static let gitGraphColors: [NSColor] = [blue, purple, green, yellow, red, orange]

    // Fonts and row metrics are fixed: Gift has no settings.

    /// Monaco 12 for diff text and line numbers.
    static func monoFont() -> NSFont {
        if let cachedFont { return cachedFont }
        let f = NSFont(name: "Monaco", size: 12)
            ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        cachedFont = f
        return f
    }

    /// UI font for the panel, tabs and headers. `size` is the point size.
    static func uiFont(_ size: CGFloat = 12) -> NSFont {
        if let hit = cachedUIFonts[size] { return hit }
        let resolved = max(8, size)
        let font = NSFont(name: "Monaco", size: resolved) ?? NSFont.systemFont(ofSize: resolved)
        cachedUIFonts[size] = font
        return font
    }

    /// Exact list row height in points.
    static func treeRowHeight() -> CGFloat { 22 }

    /// Exact diff row height in points.
    static func diffRowHeight() -> CGFloat { 22 }

    private static var cachedFont: NSFont?
    private static var cachedUIFonts: [CGFloat: NSFont] = [:]
    private static var cachedSymbols: [String: NSImage] = [:]

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

/// A flat background view. Drawn rather than layer-backed so a fill is one
/// paint in the theme's own colour, with no layer tree to keep in step.
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

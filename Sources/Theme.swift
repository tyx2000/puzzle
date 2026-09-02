import AppKit

/// Ayu Dark, ported from ayu-theme/vscode-ayu (MIT), and the only palette the
/// app paints. Every colour is one fixed value: nothing here follows the system
/// appearance and there is no theme setting, so a token means the same thing
/// everywhere it is read and views may cache what they are built with.
/// Font and exact row heights still come from settings.json.
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
    static let editorBackground = hex(0x0d1017)
    static let panelBackground = hex(0x0d1017)
    static let barBackground = hex(0x0d1017)
    static let activityBar = hex(0x0d1017)
    /// Scrollbars. AppKit's dark knob is a fixed light grey, which these near
    /// black surfaces turn into the brightest thing on screen.
    static let scrollerKnob = hex(0x39404e)
    static let scrollerSlot = hex(0x11151d)
    static let border = hex(0x1b1f29)
    static let selection = hex(0x193155)
    static let lineHighlight = hex(0x232a36)
    // The code area matches the panel, so the active tab cannot also match the
    // editor without vanishing into the tab strip: it keeps the surface one step
    // lighter, which is the only thing marking which tab is open.
    static let activeTab = hex(0x161a24)
    /// Behind whatever is selected in a strip of controls: the panel tab, the
    /// activity-bar button, the open file's tab. One token so the three read as
    /// the same state, and far enough from the bar behind them to be seen —
    /// `activeTab` sits a couple of percent off its background, which was
    /// barely a shadow.
    /// Kept in the same family as `activeRow`, the tone the file tree already
    /// selects with, rather than a brighter one of its own.
    static let selectedControl = hex(0x232a36)
    static let selectedControlText = hex(0xe6e9ef)
    static let inactiveTab = hex(0x0d1017)
    static let hover = hex(0x1c212b)
    /// active file in the tree
    static let activeRow = hex(0x232a36)
    /// matched text in search results
    /// A match, wherever it is found: drawn as a rounded outline, never a fill.
    /// Nothing is painted over the text, so code keeps its syntax colours and a
    /// result row keeps its own contrast.
    static let matchOutline = hex(0x8a6f22)
    static let matchOutlineWidth: CGFloat = 1
    /// The match the ↑↓ buttons are on gets the same colour, drawn heavier.
    static let currentMatchOutlineWidth: CGFloat = 2

    // Text
    static let foreground = hex(0xbfbdb6)
    static let dimText = hex(0x5a6378)
    static let gutter = hex(0x404758)
    static let gutterActive = hex(0x5a6378)
    static let cursor = hex(0xe6b450)
    /// collapsed folder icon
    static let folderClosed = hex(0x5a6378)

    // Search / find input
    static let inputBackground = hex(0x10141c)
    static let inputBorder = hex(0x1a1f2a)
    static let inputBorderFocused = hex(0x5a6378)
    static let toggleActiveBackground = hex(0x232a36)
    // Git diff: Ayu's markup.inserted / markup.deleted, with backgrounds mixed
    // down to sit under code without drowning it.
    static let diffAddedText = hex(0x70bf56)
    static let diffRemovedText = hex(0xf26d78)
    static let diffAddedBackground = hex(0x18251b)
    static let diffRemovedBackground = hex(0x2a1a1d)

    /// Corner radius shared by every match highlight.
    static let matchCornerRadius: CGFloat = 5

    // Accent hues. These name a *hue*: the panels use them for git status,
    // links and markers.
    static let red = hex(0xf07178)
    static let green = hex(0xaad94c)
    static let yellow = hex(0xffb454)
    static let blue = hex(0x39bae6)
    static let purple = hex(0xd2a6ff)
    static let cyan = hex(0x95e6cb)
    static let comment = hex(0x5a6673)
    static let punct = hex(0x8a8983)

    // Syntax roles are named for the role, not the hue: Ayu paints types blue
    // and calls yellow, which is the reverse of most palettes, and code that
    // asked for `blue` would have to know that.
    static let syntaxType = hex(0x39bae6)
    static let syntaxFunction = hex(0xffb454)
    static let syntaxKeyword = hex(0xff8f40)
    static let syntaxConstant = hex(0xd2a6ff)

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

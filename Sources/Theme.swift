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
    /// Every other row of a list read across — branches, commits — so the eye
    /// keeps its line over a wide row. A step off the panel, well short of
    /// `hover`, so a stripe is never mistaken for the row under the pointer.
    static let stripedRow = hex(0x131721)
    /// active file in the tree
    static let activeRow = hex(0x232a36)
    /// A match, wherever it is found, is underlined — never boxed and never
    /// washed. An outline steals a couple of points on every side of the text
    /// and a background competes with both the syntax colours over it and the
    /// selection under it; a rule below the baseline touches neither.
    static let matchUnderline = red
    static let matchUnderlineWidth: CGFloat = 2
    /// The match the ↑↓ buttons are on: the same rule in the accent yellow.
    static let currentMatchUnderline = yellow
    /// How far under the text baseline the first rule sits.
    static let matchUnderlineOffset: CGFloat = 2

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
    /// The words that changed inside a changed line: the line's colour, a
    /// third of the way from its band to its text.
    static let diffAddedWordBackground = hex(0x375b30)
    static let diffRemovedWordBackground = hex(0x70373d)

    // Accent hues. These name a *hue*: the panels use them for git status,
    // links and markers.
    static let red = hex(0xf07178)
    static let green = hex(0xaad94c)
    static let yellow = hex(0xffb454)
    /// Ayu's own orange — the hue it paints keywords in, named here as a hue
    /// so a panel can ask for it without asking for "keyword".
    static let orange = hex(0xff8f40)
    static let blue = hex(0x39bae6)
    static let purple = hex(0xd2a6ff)
    /// Shared with Gift's graph: colours identify ancestry tracks, not status.
    static let gitGraphColors: [NSColor] = [blue, purple, green, yellow, red, orange]
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
        MarkdownLiveStyler.invalidateCaches()
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

    // MARK: - Rendered Markdown

    /// Prose in a rendered Markdown document is set in the system's text face,
    /// a step above the editor's size. A monospaced face gives every letter the
    /// same width — right for code, where columns mean something, and slow to
    /// read as sentences. Chinese falls back to the system's own CJK face.
    static func markdownFont() -> NSFont {
        NSFont.systemFont(ofSize: markdownFontSize())
    }

    static func markdownFontSize() -> CGFloat {
        (editorFont().pointSize * 1.15).rounded()
    }

    /// One line of prose: 1.6 times the type, the leading text wants and code
    /// does not.
    static func markdownLineHeight() -> CGFloat {
        (markdownFontSize() * 1.6).rounded()
    }

    /// A blank source line is the gap between two blocks, not a line of text:
    /// three quarters of the type, where a whole row left every paragraph
    /// floating a full line away from the next.
    static func markdownBlankLineHeight() -> CGFloat {
        (markdownFontSize() * 0.75).rounded()
    }

    /// The column prose is set in, which follows the pane: as wide as the pane
    /// leaves between margins of 3 em, up to 50 em — about 50 Chinese
    /// characters a line, 90 or so Latin ones, and room for a line of code —
    /// and down to 30, the margins giving way before the column does. A fixed
    /// 40 em left a wide pane mostly empty and squeezed the code blocks.
    static func markdownColumn() -> MarkdownColumn {
        let size = markdownFontSize()
        return MarkdownColumn(minimum: (size * 30).rounded(), maximum: (size * 50).rounded(),
                              margin: (size * 3).rounded())
    }

    /// Heading sizes, as multiples of the prose size, H1 to H6. Far enough
    /// apart that each level reads as its own; H5 and H6 are told apart by
    /// weight and colour instead.
    static let markdownHeadingScales: [CGFloat] = [1.75, 1.4, 1.2, 1.05, 1.0, 0.9]

    static func markdownHeadingSize(level: Int) -> CGFloat {
        let index = max(1, min(6, level)) - 1
        return (markdownFontSize() * markdownHeadingScales[index]).rounded()
    }

    /// Space above a heading, beyond the blank line before it, so a heading
    /// sits nearer the text it heads than the text it ends.
    static func markdownHeadingSpaceBefore(level: Int) -> CGFloat {
        let ems: [CGFloat] = [1.0, 0.9, 0.6, 0.5, 0.4, 0.4]
        return (markdownFontSize() * ems[max(1, min(6, level)) - 1]).rounded()
    }

    /// How far a list item's text sits in from its container, one step per
    /// level; the marker hangs in that space, to the left of the text.
    static func markdownListIndent() -> CGFloat {
        (markdownFontSize() * 1.6).rounded()
    }

    /// How far a quote's text sits in from its bar.
    static func markdownQuoteIndent() -> CGFloat {
        (markdownFontSize() * 1.0).rounded()
    }

    /// Room inside a code block's box, around the code: across, and the
    /// height its fence lines are given above and below.
    static let markdownCodePaddingX: CGFloat = 12
    static let markdownCodePaddingY: CGFloat = 8

    /// Space between the top of the pane and a rendered document's first line.
    static let markdownTopInset: CGFloat = 24

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

/// A flat background view: one colour, and optionally a 1pt edge.
///
/// A plain fill is the layer's background colour, not a drawing. Drawn, it
/// cost a bitmap the size of the view — a whole window, for the views that are
/// their window's ground — to hold one colour the layer shows for nothing.
/// A view with an edge, or a subclass that draws something of its own, still
/// draws; `draw(_:)` also stays the way the view is rendered off screen.
class FlatView: NSView {
    var fillColor: NSColor = .clear { didSet { needsDisplay = true } }
    var bottomBorder = false
    var topBorder = false
    var rightBorder = false

    override var wantsUpdateLayer: Bool {
        !(bottomBorder || topBorder || rightBorder) && !Self.drawsItself(type(of: self))
    }

    override func updateLayer() {
        layer?.backgroundColor = fillColor.cgColor
    }

    /// Whether a subclass draws over the fill. The runtime is asked rather
    /// than each subclass trusted to say so, so a new one that overrides
    /// `draw(_:)` cannot lose its drawing to the layer colour.
    private static func drawsItself(_ type: FlatView.Type) -> Bool {
        let selector = #selector(NSView.draw(_:))
        return class_getMethodImplementation(type, selector)
            != class_getMethodImplementation(FlatView.self, selector)
    }

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

/// A list row that is one flat colour in every state it has. The colour is the
/// layer's background, like `FlatView`'s, so a row costs no bitmap of its own;
/// only what its cell draws does. A list holds one row view per visible row,
/// each as wide as the list, so drawn they added up to megabytes of one colour.
class FlatRowView: NSTableRowView {
    /// The colour the row shows now, selection and hover included.
    var ground: NSColor { Theme.panelBackground }

    override var isSelected: Bool {
        didSet { if isSelected != oldValue { needsDisplay = true } }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = ground.cgColor
    }

    /// The row as it renders off screen — a snapshot, a drag image.
    override func drawBackground(in dirtyRect: NSRect) {
        ground.setFill()
        bounds.fill()
    }

    /// Selection is part of `ground`.
    override func drawSelection(in dirtyRect: NSRect) {}
}

extension NSView {
    /// Settle replaced content in instead of swapping it in one frame.
    ///
    /// For a list that has just been rebuilt wholesale — a different project's
    /// files, a different tab of the Git panel — where `reloadData` otherwise
    /// reads as a blink. Only ever for a change the reader asked for: content
    /// that arrives on its own, from a Git refresh or the file-system watcher,
    /// is left alone, because an animation there pulls the eye to something
    /// nobody touched.
    ///
    /// A view with no window is not animated at all, so an offscreen rebuild
    /// does not leave itself half-faded waiting for a run loop that never comes.
    func settleIn(from startAlpha: CGFloat = 0.55, duration: TimeInterval = 0.1) {
        guard window != nil else {
            alphaValue = 1
            return
        }
        // Layer-backed first. Fading a view that is not leaves AppKit redrawing
        // it and everything behind it every frame, and anything that does not
        // repaint in time stays on screen — the trail of old rows left under a
        // list that had just been replaced.
        wantsLayer = true
        alphaValue = startAlpha
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }
}

/// A column of rendered prose, centred in a pane of any width.
struct MarkdownColumn: Equatable {
    let minimum: CGFloat
    let maximum: CGFloat
    /// Either side of the column while the pane has room for it.
    let margin: CGFloat

    /// How far in from each side the column starts in a pane `width` wide,
    /// never less than `base`, the pane's own margin.
    func inset(forWidth width: CGFloat, base: CGFloat) -> CGFloat {
        let column = min(maximum, max(width - margin * 2, min(minimum, width - base * 2)))
        return max(base, ((width - column) / 2).rounded(.down))
    }
}

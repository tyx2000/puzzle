import AppKit

/// The palettes Puzzle can paint, one chosen by settings.json's "theme" — at
/// launch, and again whenever the file is saved with another. A palette is
/// every colour token `Theme` hands out, so a theme cannot leave one
/// undefined: the compiler asks for each.
struct ThemePalette {
    /// The value settings.json names it by.
    let id: String
    /// What the settings file says of it, beside the id.
    let summary: String
    /// Dark palettes ask AppKit's own chrome — menus, selection, sheets — to
    /// be dark too; light ones ask for light.
    let isDark: Bool

    // Surfaces
    let editorBackground: UInt32
    let panelBackground: UInt32
    let barBackground: UInt32
    let activityBar: UInt32
    let scrollerKnob: UInt32
    let scrollerSlot: UInt32
    let border: UInt32
    let selection: UInt32
    let lineHighlight: UInt32
    let activeTab: UInt32
    let selectedControl: UInt32
    let selectedControlText: UInt32
    let inactiveTab: UInt32
    let hover: UInt32
    let stripedRow: UInt32
    let activeRow: UInt32

    // Text
    let foreground: UInt32
    let dimText: UInt32
    let gutter: UInt32
    let gutterActive: UInt32
    let cursor: UInt32
    let folderClosed: UInt32

    // Inputs
    let inputBackground: UInt32
    let inputBorder: UInt32
    let inputBorderFocused: UInt32
    let toggleActiveBackground: UInt32

    // Diffs
    let diffAddedText: UInt32
    let diffRemovedText: UInt32
    let raisedSurface: UInt32
    let raisedEdge: UInt32
    let diffAddedBackground: UInt32
    let diffRemovedBackground: UInt32
    let diffAddedWordBackground: UInt32
    let diffRemovedWordBackground: UInt32

    // Accent hues
    let red: UInt32
    let green: UInt32
    let yellow: UInt32
    let orange: UInt32
    let blue: UInt32
    let purple: UInt32
    let cyan: UInt32
    let comment: UInt32
    let punct: UInt32

    // Syntax roles
    let syntaxType: UInt32
    let syntaxFunction: UInt32
    let syntaxKeyword: UInt32
    let syntaxConstant: UInt32
    let syntaxString: UInt32
    let syntaxProperty: UInt32

    /// What every light palette's code reads at against its code area, as WCAG
    /// contrast ratios. Thin dark strokes on white read lighter than the same
    /// contrast does on black, and code is read for hours: syntax colours meet
    /// AAA, comments stay a step back from the code, line numbers further.
    static let minimumContrast = (code: 7.0, comment: 5.5, text: 10.0, gutter: 3.0, diffText: 4.5)

    /// Every palette, in the order the settings file lists them.
    static let all: [ThemePalette] = [.ayuDark, .ayuLight, .githubLight,
                                      .materialTeal, .materialIndigo, .materialYou]
    static let `default` = ThemePalette.ayuDark

    /// The palette a settings value names: "ayu-light", or "Ayu Light" the
    /// way Zed writes a theme. Nil for a name no palette has.
    static func named(_ value: String) -> ThemePalette? {
        let key = value.lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "_" || $0 == "-" })
            .joined(separator: "-")
        return all.first { $0.id == key }
    }
}

extension ThemePalette {
    /// Ayu Dark, ported from ayu-theme/vscode-ayu (MIT): the palette Puzzle has
    /// always painted, and the default.
    static let ayuDark = ThemePalette(
        id: "ayu-dark", summary: "dark, warm accents — the default", isDark: true,
        editorBackground: 0x0d1017, panelBackground: 0x0d1017, barBackground: 0x0d1017,
        activityBar: 0x0d1017, scrollerKnob: 0x39404e, scrollerSlot: 0x11151d, border: 0x1b1f29,
        selection: 0x193155, lineHighlight: 0x232a36, activeTab: 0x161a24,
        selectedControl: 0x232a36, selectedControlText: 0xe6e9ef, inactiveTab: 0x0d1017,
        hover: 0x1c212b, stripedRow: 0x131721, activeRow: 0x232a36, foreground: 0xbfbdb6,
        dimText: 0x5a6378, gutter: 0x404758, gutterActive: 0x5a6378, cursor: 0xe6b450,
        folderClosed: 0x5a6378, inputBackground: 0x10141c, inputBorder: 0x1a1f2a,
        inputBorderFocused: 0x5a6378, toggleActiveBackground: 0x232a36, diffAddedText: 0x70bf56,
        diffRemovedText: 0xf26d78, raisedSurface: 0x161b24, raisedEdge: 0x2d3442,
        diffAddedBackground: 0x18251b, diffRemovedBackground: 0x2a1a1d,
        diffAddedWordBackground: 0x375b30, diffRemovedWordBackground: 0x70373d, red: 0xf07178,
        green: 0xaad94c, yellow: 0xffb454, orange: 0xff8f40, blue: 0x39bae6, purple: 0xd2a6ff,
        cyan: 0x95e6cb, comment: 0x5a6673, punct: 0x8a8983, syntaxType: 0x39bae6,
        syntaxFunction: 0xffb454, syntaxKeyword: 0xff8f40, syntaxConstant: 0xd2a6ff,
        syntaxString: 0xaad94c, syntaxProperty: 0xf07178)

    /// Ayu Light, from the same source: Ayu's hues on a near-white surface, flat
    /// like Ayu Dark — the panel is the code area's colour. Ayu's own light
    /// colours read at 2:1 or less on white; each is darkened, its hue kept,
    /// to the contrast every light palette meets (see `minimumContrast`).
    static let ayuLight = ThemePalette(
        id: "ayu-light", summary: "light, Ayu's warm hues, flat", isDark: false,
        editorBackground: 0xfcfcfc, panelBackground: 0xfcfcfc, barBackground: 0xfcfcfc,
        activityBar: 0xfcfcfc, scrollerKnob: 0xcdd1d6, scrollerSlot: 0xf0f1f3, border: 0xe6e8eb,
        selection: 0xd3e1f5, lineHighlight: 0xeceff2, activeTab: 0xf1f3f5,
        selectedControl: 0xeceff2, selectedControlText: 0x33373c, inactiveTab: 0xfcfcfc,
        hover: 0xf0f2f4, stripedRow: 0xf7f8f9, activeRow: 0xeceff2, foreground: 0x3c4045,
        dimText: 0x8a9199, gutter: 0x8f9297, gutterActive: 0x8a9199, cursor: 0xffaa33,
        folderClosed: 0x8a9199, inputBackground: 0xf3f4f6, inputBorder: 0xe3e6e9,
        inputBorderFocused: 0x8a9199, toggleActiveBackground: 0xeceff2, diffAddedText: 0x377c02,
        diffRemovedText: 0xc13a50, raisedSurface: 0xffffff, raisedEdge: 0xd8dce1,
        diffAddedBackground: 0xe9f5e1, diffRemovedBackground: 0xfdebed,
        diffAddedWordBackground: 0xc6e6b2, diffRemovedWordBackground: 0xf9c8cd, red: 0xa22831,
        green: 0x465f00, yellow: 0x774e04, orange: 0x894303, blue: 0x035b8f, purple: 0x6d4592,
        cyan: 0x03634a, comment: 0x656669, punct: 0x53575c, syntaxType: 0x035b8f,
        syntaxFunction: 0x774e04, syntaxKeyword: 0x894303, syntaxConstant: 0x6d4592,
        syntaxString: 0x465f00, syntaxProperty: 0xa22831)

    /// GitHub Light, after GitHub's Primer colours: a white code area on a pale
    /// grey panel. Primer's hues are deepened where they fell short of the
    /// light palettes' contrast.
    static let githubLight = ThemePalette(
        id: "github-light", summary: "light, a white editor, high contrast", isDark: false,
        editorBackground: 0xffffff, panelBackground: 0xf6f8fa, barBackground: 0xf6f8fa,
        activityBar: 0xf6f8fa, scrollerKnob: 0xc5cbd2, scrollerSlot: 0xeef1f4, border: 0xd8dee4,
        selection: 0xc8e1ff, lineHighlight: 0xf3f5f7, activeTab: 0xffffff,
        selectedControl: 0xe6eaef, selectedControlText: 0x1f2328, inactiveTab: 0xf6f8fa,
        hover: 0xeaeef2, stripedRow: 0xfafbfc, activeRow: 0xddf4ff, foreground: 0x1f2328,
        dimText: 0x656d76, gutter: 0x8c959f, gutterActive: 0x1f2328, cursor: 0x0969da,
        folderClosed: 0x656d76, inputBackground: 0xffffff, inputBorder: 0xd0d7de,
        inputBorderFocused: 0x0969da, toggleActiveBackground: 0xe6eaef, diffAddedText: 0x1a7f37,
        diffRemovedText: 0xcf222e, raisedSurface: 0xffffff, raisedEdge: 0xd0d7de,
        diffAddedBackground: 0xe6ffec, diffRemovedBackground: 0xffebe9,
        diffAddedWordBackground: 0xabf2bc, diffRemovedWordBackground: 0xffcecb, red: 0xb5001d,
        green: 0x006726, yellow: 0x785002, orange: 0x963c03, blue: 0x0254b4, purple: 0x6c35c4,
        cyan: 0x05636a, comment: 0x606972, punct: 0x515a64, syntaxType: 0x953800,
        syntaxFunction: 0x6c35c4, syntaxKeyword: 0xb5001d, syntaxConstant: 0x0550ae,
        syntaxString: 0x0a3069, syntaxProperty: 0x0550ae)

    /// Material Teal: Material Design's colours on a faint mint surface, teal
    /// keywords and a teal caret. Original to Puzzle, not a port.
    static let materialTeal = ThemePalette(
        id: "material-teal", summary: "light, mint surfaces, teal accents", isDark: false,
        editorBackground: 0xfbfefd, panelBackground: 0xeef6f5, barBackground: 0xeef6f5,
        activityBar: 0xeef6f5, scrollerKnob: 0xb9cdca, scrollerSlot: 0xe6f0ee, border: 0xd9e6e4,
        selection: 0xc6e9e5, lineHighlight: 0xecf6f4, activeTab: 0xfbfefd,
        selectedControl: 0xd4ece9, selectedControlText: 0x1c2b2a, inactiveTab: 0xeef6f5,
        hover: 0xe2efed, stripedRow: 0xf5faf9, activeRow: 0xd4ece9, foreground: 0x263238,
        dimText: 0x6d8086, gutter: 0x869699, gutterActive: 0x37474f, cursor: 0x00897b,
        folderClosed: 0x6d8086, inputBackground: 0xffffff, inputBorder: 0xcfdfdc,
        inputBorderFocused: 0x00897b, toggleActiveBackground: 0xd4ece9, diffAddedText: 0x2e7d32,
        diffRemovedText: 0xc62828, raisedSurface: 0xffffff, raisedEdge: 0xcbdcd9,
        diffAddedBackground: 0xe8f5e9, diffRemovedBackground: 0xffebee,
        diffAddedWordBackground: 0xc8e6c9, diffRemovedWordBackground: 0xffcdd2, red: 0xb40011,
        green: 0x016613, yellow: 0x7a4e01, orange: 0x854700, blue: 0x00599e, purple: 0x8c22a8,
        cyan: 0x03606b, comment: 0x576b71, punct: 0x405c69, syntaxType: 0x5e35b1,
        syntaxFunction: 0x00599e, syntaxKeyword: 0x056359, syntaxConstant: 0xa42d02,
        syntaxString: 0x016613, syntaxProperty: 0xaf044f)

    /// Material Indigo: the classic Material pairing — indigo, with pink for
    /// keywords — on a white code area. Original to Puzzle.
    static let materialIndigo = ThemePalette(
        id: "material-indigo", summary: "light, a white editor, indigo and pink", isDark: false,
        editorBackground: 0xffffff, panelBackground: 0xf4f5fa, barBackground: 0xf4f5fa,
        activityBar: 0xf4f5fa, scrollerKnob: 0xc3c8dc, scrollerSlot: 0xeceef6, border: 0xdfe2ee,
        selection: 0xd6daf2, lineHighlight: 0xf3f4fb, activeTab: 0xffffff,
        selectedControl: 0xe3e6f6, selectedControlText: 0x1a1c2e, inactiveTab: 0xf4f5fa,
        hover: 0xeaecf7, stripedRow: 0xf9f9fd, activeRow: 0xe3e6f6, foreground: 0x212121,
        dimText: 0x737a8c, gutter: 0x9094a5, gutterActive: 0x3f51b5, cursor: 0x3f51b5,
        folderClosed: 0x737a8c, inputBackground: 0xffffff, inputBorder: 0xd5d9e8,
        inputBorderFocused: 0x3f51b5, toggleActiveBackground: 0xe3e6f6, diffAddedText: 0x2e7d32,
        diffRemovedText: 0xc62828, raisedSurface: 0xffffff, raisedEdge: 0xd0d4e6,
        diffAddedBackground: 0xe8f5e9, diffRemovedBackground: 0xffebee,
        diffAddedWordBackground: 0xc8e6c9, diffRemovedWordBackground: 0xffcdd2, red: 0xb60011,
        green: 0x016813, yellow: 0x7b4f03, orange: 0x874902, blue: 0x035a9f, purple: 0x5e35b1,
        cyan: 0x00626b, comment: 0x60697a, punct: 0x595959, syntaxType: 0x3949ab,
        syntaxFunction: 0x056359, syntaxKeyword: 0xb2004b, syntaxConstant: 0x934001,
        syntaxString: 0x016813, syntaxProperty: 0x5e35b1)

    /// Material You: Material 3's baseline scheme — tonal lavender surfaces and
    /// a purple primary. Original to Puzzle.
    static let materialYou = ThemePalette(
        id: "material-you", summary: "light, lavender tones (Material 3)", isDark: false,
        editorBackground: 0xfffbff, panelBackground: 0xf3edf7, barBackground: 0xf3edf7,
        activityBar: 0xf3edf7, scrollerKnob: 0xcbc3d6, scrollerSlot: 0xece6f0, border: 0xe7e0ec,
        selection: 0xeaddff, lineHighlight: 0xf6f1fa, activeTab: 0xfffbff,
        selectedControl: 0xe8def8, selectedControlText: 0x1d192b, inactiveTab: 0xf3edf7,
        hover: 0xece5f3, stripedRow: 0xf9f5fb, activeRow: 0xe8def8, foreground: 0x1d1b20,
        dimText: 0x79747e, gutter: 0x968f9e, gutterActive: 0x49454f, cursor: 0x6750a4,
        folderClosed: 0x79747e, inputBackground: 0xffffff, inputBorder: 0xdcd4e3,
        inputBorderFocused: 0x6750a4, toggleActiveBackground: 0xe8def8, diffAddedText: 0x386a20,
        diffRemovedText: 0xb3261e, raisedSurface: 0xffffff, raisedEdge: 0xd6cedf,
        diffAddedBackground: 0xe8f5e9, diffRemovedBackground: 0xffebee,
        diffAddedWordBackground: 0xc8e6c9, diffRemovedWordBackground: 0xffcdd2, red: 0xaa1b15,
        green: 0x306116, yellow: 0x814a01, orange: 0x8a4202, blue: 0x025a98, purple: 0x5f479a,
        cyan: 0x036060, comment: 0x68646e, punct: 0x5b546a, syntaxType: 0x814a01,
        syntaxFunction: 0x025a98, syntaxKeyword: 0x5f479a, syntaxConstant: 0x90395a,
        syntaxString: 0x306116, syntaxProperty: 0x754b59)
}

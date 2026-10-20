import AppKit

/// The palettes Puzzle can paint, one chosen by settings.json's "theme" when
/// the app starts. A palette is every colour token `Theme` hands out, so a
/// theme cannot leave one undefined: the compiler asks for each.
///
/// The choice holds for the life of the process. Views cache the colours they
/// are built with, and a colour that changed under them would leave half a
/// window in the old theme; a new theme takes effect at the next launch.
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

    /// Every palette, in the order the settings file lists them.
    static let all: [ThemePalette] = [.ayuDark, .ayuLight, .githubLight]
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

    /// Ayu Light, from the same source: Ayu Dark's hues on a near-white surface,
    /// flat like it — the panel is the code area's colour.
    static let ayuLight = ThemePalette(
        id: "ayu-light", summary: "light, soft and flat", isDark: false,
        editorBackground: 0xfcfcfc, panelBackground: 0xfcfcfc, barBackground: 0xfcfcfc,
        activityBar: 0xfcfcfc, scrollerKnob: 0xcdd1d6, scrollerSlot: 0xf0f1f3, border: 0xe6e8eb,
        selection: 0xd3e1f5, lineHighlight: 0xeceff2, activeTab: 0xf1f3f5,
        selectedControl: 0xeceff2, selectedControlText: 0x33373c, inactiveTab: 0xfcfcfc,
        hover: 0xf0f2f4, stripedRow: 0xf7f8f9, activeRow: 0xeceff2, foreground: 0x5c6166,
        dimText: 0x8a9199, gutter: 0xc5c9ce, gutterActive: 0x8a9199, cursor: 0xffaa33,
        folderClosed: 0x8a9199, inputBackground: 0xf3f4f6, inputBorder: 0xe3e6e9,
        inputBorderFocused: 0x8a9199, toggleActiveBackground: 0xeceff2, diffAddedText: 0x6cbf43,
        diffRemovedText: 0xff7383, raisedSurface: 0xffffff, raisedEdge: 0xd8dce1,
        diffAddedBackground: 0xe9f5e1, diffRemovedBackground: 0xfdebed,
        diffAddedWordBackground: 0xc6e6b2, diffRemovedWordBackground: 0xf9c8cd, red: 0xf07171,
        green: 0x86b300, yellow: 0xf2ae49, orange: 0xfa8d3e, blue: 0x399ee6, purple: 0xa37acc,
        cyan: 0x4cbf99, comment: 0xadaeb1, punct: 0x8d9196, syntaxType: 0x399ee6,
        syntaxFunction: 0xf2ae49, syntaxKeyword: 0xfa8d3e, syntaxConstant: 0xa37acc,
        syntaxString: 0x86b300, syntaxProperty: 0xf07171)

    /// GitHub Light, after GitHub's Primer colours: a white code area on a pale
    /// grey panel, and the highest contrast of the three.
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
        diffAddedWordBackground: 0xabf2bc, diffRemovedWordBackground: 0xffcecb, red: 0xcf222e,
        green: 0x1a7f37, yellow: 0x9a6700, orange: 0xbc4c00, blue: 0x0969da, purple: 0x8250df,
        cyan: 0x1b7c83, comment: 0x6e7781, punct: 0x57606a, syntaxType: 0x953800,
        syntaxFunction: 0x8250df, syntaxKeyword: 0xcf222e, syntaxConstant: 0x0550ae,
        syntaxString: 0x0a3069, syntaxProperty: 0x0550ae)
}

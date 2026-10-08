// Ayu Dark, ported from ayu-theme/vscode-ayu (MIT), and the only palette the
// app paints. Every colour is one fixed value: nothing here follows the system
// appearance and there is no theme setting, so a token means the same thing
// everywhere it is read. Font and exact row heights still come from
// settings.json (Theme.swift).
#pragma once

#include "render.h"

namespace Theme {

// Surfaces
inline const Color editorBackground = Color::hex(0x0d1017);
inline const Color panelBackground = Color::hex(0x0d1017);
inline const Color barBackground = Color::hex(0x0d1017);
inline const Color activityBar = Color::hex(0x0d1017);
/// Diffs are drawn on the editor's own ground.
inline const Color diffBackground = editorBackground;
/// Scrollbars: the system's own are a light grey that would be the brightest
/// thing on these near-black surfaces.
inline const Color scrollerKnob = Color::hex(0x39404e);
inline const Color scrollerSlot = Color::hex(0x11151d);
inline const Color border = Color::hex(0x1b1f29);
inline const Color selection = Color::hex(0x193155);
inline const Color lineHighlight = Color::hex(0x232a36);
/// The code area matches the panel, so the active tab keeps the surface one
/// step lighter.
inline const Color activeTab = Color::hex(0x161a24);
/// Behind whatever is selected in a strip of controls: the panel tab, the
/// activity-bar button, the open file's tab.
inline const Color selectedControl = Color::hex(0x232a36);
inline const Color selectedControlText = Color::hex(0xe6e9ef);
inline const Color inactiveTab = Color::hex(0x0d1017);
inline const Color hover = Color::hex(0x1c212b);
/// Every other row of a list read across — branches, commits.
inline const Color stripedRow = Color::hex(0x131721);
/// The active file in the tree.
inline const Color activeRow = Color::hex(0x232a36);

// Text
inline const Color foreground = Color::hex(0xbfbdb6);
inline const Color dimText = Color::hex(0x5a6378);
inline const Color gutter = Color::hex(0x404758);
inline const Color gutterActive = Color::hex(0x5a6378);
inline const Color cursor = Color::hex(0xe6b450);
/// Collapsed folder icon.
inline const Color folderClosed = Color::hex(0x5a6378);
/// Ayu's accent — the same yellow as the caret.
inline const Color accent = cursor;

// Search / find input
inline const Color inputBackground = Color::hex(0x10141c);
inline const Color inputBorder = Color::hex(0x1a1f2a);
inline const Color inputBorderFocused = Color::hex(0x5a6378);
inline const Color toggleActiveBackground = Color::hex(0x232a36);

// Git diff: Ayu's markup.inserted / markup.deleted.
inline const Color diffAddedText = Color::hex(0x70bf56);
inline const Color diffRemovedText = Color::hex(0xf26d78);
inline const Color diffAddedBackground = Color::hex(0x18251b);
inline const Color diffRemovedBackground = Color::hex(0x2a1a1d);

// Accent hues: the panels use them for git status, links and markers.
inline const Color red = Color::hex(0xf07178);
inline const Color green = Color::hex(0xaad94c);
inline const Color yellow = Color::hex(0xffb454);
inline const Color orange = Color::hex(0xff8f40);
inline const Color blue = Color::hex(0x39bae6);
inline const Color purple = Color::hex(0xd2a6ff);
inline const Color cyan = Color::hex(0x95e6cb);
inline const Color comment = Color::hex(0x5a6673);
inline const Color punct = Color::hex(0x8a8983);

/// Distinct categorical tracks for the history graph.
inline const Color gitGraphColors[6] = {blue, purple, green, yellow, red, orange};

// Syntax roles are named for the role, not the hue.
inline const Color syntaxType = Color::hex(0x39bae6);
inline const Color syntaxFunction = Color::hex(0xffb454);
inline const Color syntaxKeyword = Color::hex(0xff8f40);
inline const Color syntaxConstant = Color::hex(0xd2a6ff);

/// A match, wherever it is found, is underlined — never boxed or washed.
inline const Color matchUnderline = red;
inline constexpr float matchUnderlineWidth = 2;
/// The match the ↑↓ buttons are on.
inline const Color currentMatchUnderline = yellow;
/// How far under the text baseline the rule sits.
inline constexpr float matchUnderlineOffset = 2;

// Window chrome that has no Ayu counterpart.
inline const Color menuBackground = Color::hex(0x141821);
inline const Color closeHover = Color::hex(0xc42b1c);

// ── Fonts and metrics (settings.json) ──

/// The editor (buffer) font, honouring `buffer_font_*`.
Font editorFont();
/// The same font in bold, for diff headers.
Font editorBoldFont();
/// The family the editor font actually resolved to on this machine — the
/// name handed to Scintilla.
std::wstring editorFamily();
/// The code font for diff text and line numbers.
inline Font monoFont() { return editorFont(); }
/// UI font for the left panel, tabs and panels. `size` is a 12-point baseline
/// hint; `ui_font_size` scales the whole hierarchy.
Font uiFont(float size = 12);
/// The bold weight of the UI font.
Font uiBoldFont(float size);
const std::wstring& uiFamily();

/// Exact file-tree row height in DIPs.
float treeRowHeight();
/// Exact diff row height in DIPs.
inline float diffRowHeight() { return 22; }
/// Natural and target code row height (`code_line_height`).
struct LineMetrics {
    float natural;
    float target;
};
LineMetrics lineMetrics();
/// Width of one character of the (monospaced) editor font.
float characterWidth();

/// Settings changed: cached fonts and metrics are stale.
void invalidateCaches();

/// The user's Windows accent colour, for the default button.
Color systemAccent();

}  // namespace Theme

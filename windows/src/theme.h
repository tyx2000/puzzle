// Ayu Dark, ported from ayu-theme/vscode-ayu (MIT), and the only palette the
// app paints. Every colour is one fixed value: nothing here follows the system
// theme and there is no theme setting.
#pragma once

#include "render.h"

namespace Theme {

// Surfaces
inline const Color diffBackground = Color::hex(0x0d1017);
inline const Color panelBackground = Color::hex(0x0d1017);
inline const Color barBackground = Color::hex(0x0d1017);
/// Scrollbars: the system's own are a light grey that would be the brightest
/// thing on these near-black surfaces.
inline const Color scrollerKnob = Color::hex(0x39404e);
inline const Color scrollerSlot = Color::hex(0x11151d);
inline const Color border = Color::hex(0x1b1f29);
/// Behind a diff's hunk headers.
inline const Color lineHighlight = Color::hex(0x232a36);
/// A surface one step lighter than the bar: a live button's ground.
inline const Color activeTab = Color::hex(0x161a24);
/// Behind whatever is selected: the open diff's tab, the project being shown.
inline const Color selectedControl = Color::hex(0x232a36);
inline const Color selectedControlText = Color::hex(0xe6e9ef);
inline const Color inactiveTab = Color::hex(0x0d1017);
inline const Color hover = Color::hex(0x1c212b);
/// Every other row of a list read across.
inline const Color stripedRow = Color::hex(0x131721);
/// The row a list has selected, and the hunk headers in a diff.
inline const Color activeRow = Color::hex(0x232a36);
// Text
inline const Color foreground = Color::hex(0xbfbdb6);
inline const Color dimText = Color::hex(0x5a6378);
inline const Color gutter = Color::hex(0x404758);
/// Ayu's accent.
inline const Color accent = Color::hex(0xe6b450);

// Git diff: Ayu's markup.inserted / markup.deleted.
inline const Color diffAddedText = Color::hex(0x70bf56);
inline const Color diffRemovedText = Color::hex(0xf26d78);
inline const Color diffAddedBackground = Color::hex(0x18251b);
inline const Color diffRemovedBackground = Color::hex(0x2a1a1d);

// Accent hues.
inline const Color red = Color::hex(0xf07178);
inline const Color green = Color::hex(0xaad94c);
inline const Color yellow = Color::hex(0xffb454);
inline const Color orange = Color::hex(0xff8f40);
inline const Color blue = Color::hex(0x39bae6);
inline const Color purple = Color::hex(0xd2a6ff);

/// Distinct categorical tracks for the history graph.
inline const Color gitGraphColors[6] = {blue, purple, green, yellow, red, orange};

// Window chrome that has no Ayu counterpart.
inline const Color menuBackground = Color::hex(0x141821);
inline const Color closeHover = Color::hex(0xc42b1c);

/// The code font for diff text and line numbers — Monaco on the Mac, whose
/// nearest Windows counterpart is Consolas.
Font monoFont();
/// The UI font for the panel, tabs and headers, at `size` DIPs.
Font uiFont(float size = 12);
/// The bold weight of the UI font.
Font uiBoldFont(float size);
/// The family both use.
const std::wstring& uiFamily();

/// Exact list row height in DIPs.
inline float treeRowHeight() { return 22; }
/// Exact diff row height in DIPs.
inline float diffRowHeight() { return 22; }

/// The user's Windows accent colour, for the default button.
Color systemAccent();

}  // namespace Theme

// The images the lists draw: Material Icon Theme SVGs, rendered once per
// size and kept while they are drawn, and the handful of SF Symbols the
// AppKit views used, redrawn here as vector strokes.
#pragma once

#include "render.h"

enum class Symbol {
    Plus,
    XMark,
    ChevronUp,
    ChevronDown,
    ChevronRight,
    ChevronLeft,
    SplitRectangle,  // rectangle.split.2x1
    Rectangle,       // rectangle
    Prompt,          // >_
    Document,        // doc.text
    MenuLines,       // the app menu
    Gear,
    Folder,          // folder (the Projects mark)
    Photo,           // photo
    Waveform,        // waveform
    UturnBackward,   // arrow.uturn.backward (discard)
};

/// Strokes `symbol` centred in `rect`. `weight` scales the stroke.
void drawSymbol(Graphics& g, Symbol symbol, const Rect& rect, const Color& color,
                float weight = 1.0f);

namespace FileIcons {

/// Point the provider at the folder holding file-icons.json and icons\.
void useResources(const std::wstring& directory);
/// The icon for a file name: whole names first (`package.json`), then the
/// longest extension. "file" when nothing matches; empty without resources.
std::string fileIconName(const std::string& name);
std::string folderIconName(const std::string& name, bool expanded);
/// The icon rendered for `rect` at the graphics' scale; nullptr when missing.
ID2D1Bitmap* bitmap(const std::string& icon, const Rect& rect, float scale);
/// Draws the icon fitted into `rect`. False when there is no such icon.
bool draw(Graphics& g, const std::string& icon, const Rect& rect);
/// Let go of every rendered icon (memory pressure, a window minimised).
void releaseTransientMemory();

}  // namespace FileIcons

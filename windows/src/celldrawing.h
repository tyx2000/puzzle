// What the sidebar rows draw besides their text: a name followed by its dim
// folder, and a file's icon (SidebarCellDrawing).
#pragma once

#include "icons.h"
#include "widgets.h"
#include "theme.h"

namespace CellDrawing {

/// A primary name at its natural width; the dim secondary text takes (and
/// truncates from its head inside) whatever is left.
void primaryAndSecondary(Graphics& g, const std::wstring& primary, const Font& primaryFont,
                         const Color& primaryColor, const std::wstring& secondary,
                         const Font& secondaryFont, const Color& secondaryColor, const Rect& rect,
                         float gap = 6, LineBreak primaryLineBreak = LineBreak::TruncatingTail);

/// The Material icon for a file name, or the document symbol without one.
/// `opacity` below 1 fades it — an ignored file's, with its name.
void fileIcon(Graphics& g, const std::string& fileName, const Rect& rect, float opacity = 1);

/// Where `leadingAndTrailing` put each of its three texts; empty for one it
/// had nothing to draw for.
struct LeadingAndTrailingRects {
    Rect leading;
    Rect trailing;
    Rect pinned;
};

/// A row that reads left to right and ends with its metadata. All three sit
/// on the leading font's baseline. Space is given out from the right:
/// `trailingPinned` (the timestamp) keeps its natural width, `trailing` (the
/// name) takes what is left of the metadata's share and truncates, and the
/// leading text gets the rest.
LeadingAndTrailingRects leadingAndTrailing(Graphics& g, const std::wstring& leading, const Font& leadingFont,
                                           const Color& leadingColor, const std::wstring& trailing,
                                           const Font& trailingFont, const Color& trailingColor,
                                           const std::wstring& trailingPinned, const Rect& rect, float gap = 8,
                                           float trailingShare = 0.6f,
                                           LineBreak leadingLineBreak = LineBreak::TruncatingTail);

/// A label with its count badge after it, sharing one baseline, laid out in
/// `rect` with `align`.
void labelWithBadge(Graphics& g, const std::wstring& label, const std::wstring& badge, const Font& font,
                    const Color& colour, const Color& badgeBackground, const Color& badgeForeground,
                    const Rect& rect, Align align = Align::Left);

}  // namespace CellDrawing

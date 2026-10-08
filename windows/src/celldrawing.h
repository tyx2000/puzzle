// What the sidebar rows draw besides their text: a name followed by its dim
// folder, and a file's icon (SidebarCellDrawing).
#pragma once

#include "icons.h"
#include "theme.h"

namespace CellDrawing {

/// A primary name at its natural width; the dim secondary text takes (and
/// truncates from its head inside) whatever is left.
void primaryAndSecondary(Graphics& g, const std::wstring& primary, const Font& primaryFont,
                         const Color& primaryColor, const std::wstring& secondary,
                         const Font& secondaryFont, const Color& secondaryColor, const Rect& rect,
                         float gap = 6, LineBreak primaryLineBreak = LineBreak::TruncatingTail);

/// The Material icon for a file name, or the document symbol without one.
void fileIcon(Graphics& g, const std::string& fileName, const Rect& rect);

}  // namespace CellDrawing

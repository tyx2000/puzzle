#include "celldrawing.h"

namespace CellDrawing {

void primaryAndSecondary(Graphics& g, const std::wstring& primary, const Font& primaryFont,
                         const Color& primaryColor, const std::wstring& secondary,
                         const Font& secondaryFont, const Color& secondaryColor, const Rect& rect,
                         float gap, LineBreak primaryLineBreak) {
    if (rect.w <= 0) return;
    float baseline = Text::centeredBaseline(primaryFont, rect);
    if (secondary.empty()) {
        g.text(primary, primaryFont, primaryColor, baseline, rect, primaryLineBreak);
        return;
    }
    float natural = std::ceil(Text::width(primary, primaryFont));
    float primaryWidth = std::min(natural, std::max(0.0f, rect.w - gap));
    g.text(primary, primaryFont, primaryColor, baseline, Rect(rect.x, rect.y, primaryWidth, rect.h),
           primaryLineBreak);
    float secondaryX = rect.x + primaryWidth + gap;
    g.text(secondary, secondaryFont, secondaryColor, baseline,
           Rect(secondaryX, rect.y, std::max(0.0f, rect.maxX() - secondaryX), rect.h),
           LineBreak::TruncatingHead);
}

void fileIcon(Graphics& g, const std::string& fileName, const Rect& rect) {
    std::string icon = FileIcons::fileIconName(fileName);
    if (!icon.empty() && FileIcons::draw(g, icon, rect)) return;
    drawSymbol(g, Symbol::Document, rect, Theme::dimText);
}

}  // namespace CellDrawing

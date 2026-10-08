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

void fileIcon(Graphics& g, const std::string& fileName, const Rect& rect, float opacity) {
    std::string icon = FileIcons::fileIconName(fileName);
    if (!icon.empty()) {
        if (opacity < 1) {
            if (ID2D1Bitmap* bitmap = FileIcons::bitmap(icon, rect, g.scale())) {
                g.drawBitmap(bitmap, rect, opacity);
                return;
            }
        } else if (FileIcons::draw(g, icon, rect)) {
            return;
        }
    }
    drawSymbol(g, Symbol::Document, rect, Theme::dimText.withAlpha(opacity));
}

LeadingAndTrailingRects leadingAndTrailing(Graphics& g, const std::wstring& leading, const Font& leadingFont,
                                           const Color& leadingColor, const std::wstring& trailing,
                                           const Font& trailingFont, const Color& trailingColor,
                                           const std::wstring& trailingPinned, const Rect& rect, float gap,
                                           float trailingShare, LineBreak leadingLineBreak) {
    LeadingAndTrailingRects drawn;
    if (rect.w <= 0 || rect.h <= 0) return drawn;
    float baseline = Text::centeredBaseline(leadingFont, rect);
    // A point of slack: the measured advance rounds a hair under what is drawn.
    auto width = [&](const std::wstring& s) { return std::ceil(Text::width(s, trailingFont)) + 2; };
    float budget = std::floor(rect.w * trailingShare);
    float metadataX = rect.maxX();
    if (!trailingPinned.empty()) {
        float pinnedWidth = std::min(width(trailingPinned), budget);
        Rect pinned(rect.maxX() - pinnedWidth, rect.y, pinnedWidth, rect.h);
        g.text(trailingPinned, trailingFont, trailingColor, baseline, pinned, LineBreak::Clipping, Align::Right);
        drawn.pinned = pinned;
        metadataX = pinned.x;
    }
    if (!trailing.empty()) {
        // The gap belongs between the name and the timestamp.
        float separation = trailingPinned.empty() ? 0 : gap;
        float remaining = std::max(0.0f, budget - (rect.maxX() - metadataX) - separation);
        float nameWidth = std::min(width(trailing), remaining);
        Rect name(metadataX - separation - nameWidth, rect.y, nameWidth, rect.h);
        g.text(trailing, trailingFont, trailingColor, baseline, name, LineBreak::TruncatingTail, Align::Right);
        drawn.trailing = name;
        metadataX = name.x;
    }
    float leadingWidth = std::max(0.0f, metadataX - gap - rect.x);
    drawn.leading = Rect(rect.x, rect.y, leadingWidth, rect.h);
    g.text(leading, leadingFont, leadingColor, baseline, drawn.leading, leadingLineBreak);
    return drawn;
}

void labelWithBadge(Graphics& g, const std::wstring& label, const std::wstring& badge, const Font& font,
                    const Color& colour, const Color& badgeBackground, const Color& badgeForeground,
                    const Rect& rect, Align align) {
    float baseline = Text::centeredBaseline(font, rect);
    float titleWidth = std::ceil(Text::width(label, font));
    float diameter = badge.empty() ? 0 : Badge::diameter(badge, font);
    float total = titleWidth + (badge.empty() ? 0 : Badge::gap + diameter);
    float x = rect.x;
    if (align == Align::Center) x = rect.x + std::max(0.0f, (rect.w - total) / 2);
    else if (align == Align::Right) x = rect.maxX() - std::min(total, rect.w);
    float labelRoom = std::max(0.0f, std::min(titleWidth, rect.maxX() - x - (badge.empty() ? 0 : Badge::gap + diameter)));
    g.text(label, font, colour, baseline, Rect(x, rect.y, labelRoom + 1, rect.h), LineBreak::TruncatingTail);
    if (badge.empty()) return;
    Point centre(x + labelRoom + Badge::gap + diameter / 2, baseline - font.capHeight() / 2);
    Badge::draw(g, badge, centre, font, badgeBackground, badgeForeground);
}

}  // namespace CellDrawing

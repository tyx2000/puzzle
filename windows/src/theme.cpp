#include "theme.h"

#include "settings.h"

namespace Theme {

namespace {
std::optional<Font> gEditorFont;
std::optional<Font> gEditorBold;
std::optional<float> gCharacterWidth;
std::wstring gUIFamily;

std::wstring resolvedFamily(const std::wstring& wanted) {
    if (!wanted.empty() && Fonts::exists(wanted)) return wanted;
    // Monaco is the Mac's; Consolas is on every Windows machine.
    return Fonts::exists(L"Consolas") ? L"Consolas" : L"Cascadia Mono";
}
}  // namespace

void invalidateCaches() {
    gEditorFont.reset();
    gEditorBold.reset();
    gCharacterWidth.reset();
    gUIFamily.clear();
}

std::wstring editorFamily() { return resolvedFamily(Settings::shared().fontFamily); }

Font editorFont() {
    if (gEditorFont) return *gEditorFont;
    auto& s = Settings::shared();
    gEditorFont = Fonts::get(editorFamily(), s.fontSize, s.fontWeight >= 600 ? 700 : 400);
    return *gEditorFont;
}

Font editorBoldFont() {
    if (gEditorBold) return *gEditorBold;
    gEditorBold = Fonts::get(editorFamily(), Settings::shared().fontSize, 700);
    return *gEditorBold;
}

const std::wstring& uiFamily() {
    if (gUIFamily.empty()) gUIFamily = resolvedFamily(Settings::shared().uiFontFamily);
    return gUIFamily;
}

Font uiFont(float size) {
    auto& s = Settings::shared();
    float resolved = std::max(8.0f, s.uiFontSize + (size - 12));
    return Fonts::get(uiFamily(), resolved, s.uiFontWeight >= 600 ? 700 : 400);
}

Font uiBoldFont(float size) {
    auto& s = Settings::shared();
    float resolved = std::max(8.0f, s.uiFontSize + (size - 12));
    return Fonts::get(uiFamily(), resolved, 700);
}

float treeRowHeight() { return Settings::shared().treeLineHeight; }

LineMetrics lineMetrics() {
    Font font = editorFont();
    return {std::ceil(font.lineHeight()), Settings::shared().codeLineHeight};
}

float characterWidth() {
    if (gCharacterWidth) return *gCharacterWidth;
    gCharacterWidth = Text::width(L"0", editorFont());
    return *gCharacterWidth;
}

Color systemAccent() {
    static std::optional<Color> cached;
    if (cached) return *cached;
    DWORD value = 0, size = sizeof value;
    Color result = Color::hex(0x0078d4);
    if (RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\DWM", L"AccentColor",
                     RRF_RT_REG_DWORD, nullptr, &value, &size) == ERROR_SUCCESS) {
        // Stored as 0xAABBGGRR.
        result = Color((value & 0xff) / 255.0f, ((value >> 8) & 0xff) / 255.0f,
                       ((value >> 16) & 0xff) / 255.0f, 1);
    }
    cached = result;
    return result;
}

}  // namespace Theme

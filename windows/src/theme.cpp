#include "theme.h"

namespace Theme {

const std::wstring& uiFamily() {
    // Monaco is the Mac's; Windows has Consolas everywhere and Cascadia Mono
    // only on some installs, so the one every machine renders the same wins.
    static const std::wstring family = Fonts::exists(L"Consolas") ? L"Consolas" : L"Cascadia Mono";
    return family;
}

Font monoFont() { return Fonts::get(uiFamily(), 12); }

Font uiFont(float size) { return Fonts::get(uiFamily(), std::max(8.0f, size)); }

Font uiBoldFont(float size) { return Fonts::get(uiFamily(), std::max(8.0f, size), 700); }

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

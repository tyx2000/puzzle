#include "menu.h"

#include "render.h"
#include "theme.h"

MenuItem& Menu::add(const std::wstring& title, std::function<void()> action, bool enabled) {
    MenuItem item;
    item.title = title;
    item.action = std::move(action);
    item.enabled = enabled;
    items.push_back(std::move(item));
    return items.back();
}

MenuItem& Menu::addSubmenu(const std::wstring& title, std::shared_ptr<Menu> submenu, bool enabled) {
    MenuItem item;
    item.title = title;
    item.submenu = std::move(submenu);
    item.enabled = enabled;
    items.push_back(std::move(item));
    return items.back();
}

void Menu::addSeparator() {
    MenuItem item;
    item.separator = true;
    items.push_back(std::move(item));
}

namespace {

struct DrawnItem {
    MenuItem* item = nullptr;
    float titleSize = 11;
    float detailSize = 9.5f;
};

/// Items of the menu being shown; their addresses ride on the HMENU entries.
std::vector<std::unique_ptr<DrawnItem>> gDrawn;
std::unordered_map<UINT, MenuItem*> gCommands;
UINT gNextCommand = 1;
HBRUSH gBackground = nullptr;
Com<ID2D1DCRenderTarget> gDCTarget;

constexpr float kGutter = 26;
constexpr float kTrailing = 28;
constexpr float kRowHeight = 24;
constexpr float kTwoLineHeight = 36;
constexpr float kSeparatorHeight = 9;

HMENU build(Menu& menu) {
    HMENU handle = CreatePopupMenu();
    MENUINFO info{sizeof info};
    info.fMask = MIM_BACKGROUND;
    info.hbrBack = gBackground;
    SetMenuInfo(handle, &info);
    for (auto& item : menu.items) {
        auto drawn = std::make_unique<DrawnItem>();
        drawn->item = &item;
        drawn->titleSize = item.titleSize > 0 ? item.titleSize : menu.titleSize;
        drawn->detailSize = menu.detailSize;
        MENUITEMINFOW mii{sizeof mii};
        mii.fMask = MIIM_FTYPE | MIIM_DATA | MIIM_STATE | MIIM_ID;
        mii.fType = MFT_OWNERDRAW | (item.separator ? MFT_SEPARATOR : 0);
        mii.dwItemData = (ULONG_PTR)drawn.get();
        mii.fState = (item.enabled ? MFS_ENABLED : MFS_DISABLED) | (item.checked ? MFS_CHECKED : 0);
        mii.wID = gNextCommand++;
        gCommands[mii.wID] = &item;
        if (item.submenu) {
            mii.fMask |= MIIM_SUBMENU;
            mii.hSubMenu = build(*item.submenu);
        }
        InsertMenuItemW(handle, GetMenuItemCount(handle), TRUE, &mii);
        gDrawn.push_back(std::move(drawn));
    }
    return handle;
}

float dpiScale(HWND hwnd) { return (hwnd ? GetDpiForWindow(hwnd) : 96) / 96.0f; }

}  // namespace

bool Menu::popup(HWND owner, POINT screen) {
    if (items.empty()) return false;
    if (!gBackground) gBackground = CreateSolidBrush(Theme::menuBackground.colorref());
    gDrawn.clear();
    gCommands.clear();
    gNextCommand = 1;
    HMENU handle = build(*this);
    // Without the owner in front, the menu does not close when the user
    // clicks elsewhere.
    SetForegroundWindow(owner);
    UINT chosen = (UINT)TrackPopupMenuEx(handle,
                                         TPM_RETURNCMD | TPM_LEFTALIGN | TPM_TOPALIGN
                                             | TPM_RIGHTBUTTON,
                                         screen.x, screen.y, owner, nullptr);
    PostMessageW(owner, WM_NULL, 0, 0);
    DestroyMenu(handle);
    std::function<void()> action;
    if (chosen) {
        auto it = gCommands.find(chosen);
        if (it != gCommands.end() && it->second->action) action = it->second->action;
    }
    gDrawn.clear();
    gCommands.clear();
    if (action) action();
    return (bool)action;
}

namespace Menus {

void enableDarkMenus() {
    // uxtheme's SetPreferredAppMode (ordinal 135) and FlushMenuThemes (136):
    // undocumented, present since Windows 10 1903, and what makes a menu's
    // frame dark. Missing, menus keep a light frame around dark items.
    HMODULE uxtheme = LoadLibraryExW(L"uxtheme.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!uxtheme) return;
    using SetPreferredAppMode = int(WINAPI*)(int);
    using FlushMenuThemes = void(WINAPI*)();
    auto setMode = reinterpret_cast<SetPreferredAppMode>(
        reinterpret_cast<void*>(GetProcAddress(uxtheme, MAKEINTRESOURCEA(135))));
    auto flush = reinterpret_cast<FlushMenuThemes>(
        reinterpret_cast<void*>(GetProcAddress(uxtheme, MAKEINTRESOURCEA(136))));
    OSVERSIONINFOW version{};
    // Only on builds that have the export with this meaning (1903+).
    using RtlGetVersion = LONG(WINAPI*)(OSVERSIONINFOW*);
    auto getVersion = reinterpret_cast<RtlGetVersion>(reinterpret_cast<void*>(
        GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "RtlGetVersion")));
    version.dwOSVersionInfoSize = sizeof version;
    if (getVersion) getVersion(&version);
    if (version.dwBuildNumber < 18362) return;
    if (setMode) setMode(2);  // ForceDark
    if (flush) flush();
}

bool handleOwnerMessage(HWND hwnd, UINT message, WPARAM, LPARAM lParam, LRESULT* result) {
    if (message == WM_MEASUREITEM) {
        auto* measure = reinterpret_cast<MEASUREITEMSTRUCT*>(lParam);
        if (measure->CtlType != ODT_MENU || !measure->itemData) return false;
        auto* drawn = reinterpret_cast<DrawnItem*>(measure->itemData);
        float s = dpiScale(hwnd);
        MenuItem& item = *drawn->item;
        if (item.separator) {
            measure->itemWidth = (UINT)(40 * s);
            measure->itemHeight = (UINT)(kSeparatorHeight * s);
        } else {
            float width = Text::width(item.title, Theme::uiFont(drawn->titleSize));
            if (!item.detail.empty()) {
                width = std::max(width, Text::width(item.detail, Theme::uiFont(drawn->detailSize)));
            }
            if (!item.shortcut.empty()) {
                width += 24 + Text::width(item.shortcut, Theme::uiFont(drawn->detailSize + 0.5f));
            }
            // The system adds the width of a check mark to every owner-drawn
            // item; the gutters here already hold it.
            int systemCheck = GetSystemMetrics(SM_CXMENUCHECK);
            measure->itemWidth = (UINT)std::max(0.0f, (kGutter + width + kTrailing) * s - systemCheck);
            measure->itemHeight = (UINT)((item.detail.empty() ? kRowHeight : kTwoLineHeight) * s);
        }
        *result = TRUE;
        return true;
    }
    if (message == WM_DRAWITEM) {
        auto* draw = reinterpret_cast<DRAWITEMSTRUCT*>(lParam);
        if (draw->CtlType != ODT_MENU || !draw->itemData) return false;
        auto* drawn = reinterpret_cast<DrawnItem*>(draw->itemData);
        MenuItem& item = *drawn->item;
        if (!gDCTarget) {
            D2D1_RENDER_TARGET_PROPERTIES props = D2D1::RenderTargetProperties(
                D2D1_RENDER_TARGET_TYPE_DEFAULT,
                D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE));
            Render::d2d()->CreateDCRenderTarget(&props, gDCTarget.put());
        }
        if (!gDCTarget) return false;
        RECT rc = draw->rcItem;
        if (FAILED(gDCTarget->BindDC(draw->hDC, &rc))) return false;
        auto dc = gDCTarget.as<ID2D1DeviceContext>();
        if (!dc) return false;
        float dpi = 96 * dpiScale(hwnd);
        float s = dpi / 96;
        dc->SetDpi(dpi, dpi);
        dc->BeginDraw();
        dc->SetTransform(D2D1::Matrix3x2F::Identity());
        {
            Graphics g(dc.get(), dpi);
            Rect bounds(0, 0, (rc.right - rc.left) / s, (rc.bottom - rc.top) / s);
            bool selected = (draw->itemState & ODS_SELECTED) && item.enabled && !item.separator;
            g.fillRect(bounds, selected ? Theme::selectedControl : Theme::menuBackground);
            if (item.separator) {
                g.fillRect(Rect(8, std::floor(bounds.midY()), bounds.w - 16, 1), Theme::border);
            } else {
                Color ink = !item.enabled ? Theme::dimText
                    : selected ? Theme::selectedControlText
                    : item.dimTitle ? Theme::dimText
                                    : Theme::foreground;
                Font titleFont = Theme::uiFont(drawn->titleSize);
                Font detailFont = Theme::uiFont(drawn->detailSize);
                if (item.checked) {
                    float cy = item.detail.empty() ? bounds.midY() : 12;
                    g.polyline({Point(9, cy), Point(12, cy + 3), Point(17, cy - 3.5f)}, ink, 1.4f);
                }
                float right = bounds.w - kTrailing;
                if (!item.shortcut.empty()) {
                    Font keyFont = Theme::uiFont(drawn->detailSize + 0.5f);
                    float w = Text::width(item.shortcut, keyFont);
                    g.text(item.shortcut, keyFont, Theme::dimText,
                           Rect(right - w, 0, w + 1, bounds.h), LineBreak::Clipping);
                    right -= w + 24;
                }
                if (item.detail.empty()) {
                    g.text(item.title, titleFont, ink, Rect(kGutter, 0, right - kGutter, bounds.h));
                } else {
                    g.text(item.title, titleFont, ink, Rect(kGutter, 3, right - kGutter, 17));
                    g.text(item.detail, detailFont, Theme::dimText,
                           Rect(kGutter, 18, right - kGutter, 15));
                }
                if (item.submenu) {
                    float cx = bounds.w - 14, cy = bounds.midY();
                    g.polyline({Point(cx - 2, cy - 4), Point(cx + 2, cy), Point(cx - 2, cy + 4)}, ink,
                               1.2f);
                }
            }
        }
        dc->EndDraw();
        // The system would paint its own submenu arrow over ours.
        ExcludeClipRect(draw->hDC, rc.left, rc.top, rc.right, rc.bottom);
        *result = TRUE;
        return true;
    }
    return false;
}

}  // namespace Menus

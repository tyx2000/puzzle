// Popup menus: native Win32 menus whose items are drawn by the app, so they
// carry its font and palette, and items can be two lines tall the way the
// branch menu's attributed titles were.
#pragma once

#include "geometry.h"
#include "base.h"

class Menu;

struct MenuItem {
    std::wstring title;
    /// A second, smaller line under the title.
    std::wstring detail;
    /// Right-aligned key text ("Ctrl+W").
    std::wstring shortcut;
    bool enabled = true;
    bool checked = false;
    bool separator = false;
    /// Dims the title, as an unavailable branch is drawn.
    bool dimTitle = false;
    /// Overrides the menu's title size for this item.
    float titleSize = 0;
    std::function<void()> action;
    std::shared_ptr<Menu> submenu;
};

class Menu {
public:
    MenuItem& add(const std::wstring& title, std::function<void()> action, bool enabled = true);
    MenuItem& addSubmenu(const std::wstring& title, std::shared_ptr<Menu> submenu,
                         bool enabled = true);
    void addSeparator();
    bool empty() const { return items.empty(); }

    std::vector<MenuItem> items;
    float titleSize = 11;
    float detailSize = 9.5f;

    /// Shows the menu with its top-left at `screen` and runs the chosen item
    /// once the menu has closed. Returns whether an item was chosen.
    bool popup(HWND owner, POINT screen);
};

namespace Menus {

/// Dark borders and scroll arrows for every menu the process shows.
void enableDarkMenus();
/// Measures and draws owner-drawn items; called from the owner's window procedure.
bool handleOwnerMessage(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam, LRESULT* result);

}  // namespace Menus

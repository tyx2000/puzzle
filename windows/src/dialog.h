// NSAlert's counterpart: a dark modal window with a message, its detail, an
// optional accessory (the new-branch name and base), and a row of buttons.
#pragma once

#include "widgets.h"

class Alert {
public:
    enum class Style { Informational, Warning };
    std::wstring messageText;
    std::wstring informativeText;
    Style style = Style::Informational;
    /// The first is the default (↩); one titled "Cancel" answers Esc.
    std::vector<std::wstring> buttons;
    /// Laid out under the text at `accessorySize`; not owned.
    View* accessory = nullptr;
    Size accessorySize;
    /// Gets the keyboard once the alert is on screen.
    TextField* initialFocus = nullptr;

    /// Shows the alert over `owner` (which is disabled meanwhile) and returns
    /// the index of the button chosen, or -1 when it was closed otherwise.
    int runModal(HWND owner);
    /// The same for an alert with one "OK" button.
    static void inform(HWND owner, const std::wstring& message, const std::wstring& detail,
                       Style style = Style::Informational);
};

/// NSPopUpButton: the chosen title, and a menu of the others on a click.
class PopupButton : public View {
public:
    std::vector<std::wstring> items;
    int selected = 0;
    std::function<void(int)> onChange;
    std::wstring selectedTitle() const {
        return selected >= 0 && selected < (int)items.size() ? items[selected] : L"";
    }
    void draw(Graphics& g) override;
    bool mouseDown(const MouseEvent&) override;
};

// The flat, rounded search field with Aa / wd / .* toggles, shared by the
// project search panel and the in-file find bar (SearchInputView.swift,
// SearchSupport.swift).
#pragma once

#include "widgets.h"

struct SearchOptions {
    bool caseSensitive = false;
    bool wholeWord = false;
    bool regex = false;
    bool operator==(const SearchOptions& o) const {
        return caseSensitive == o.caseSensitive && wholeWord == o.wholeWord && regex == o.regex;
    }
    bool operator!=(const SearchOptions& o) const { return !(*this == o); }
};

class SearchInputView : public View {
public:
    SearchInputView();
    std::function<void(const std::wstring&, const SearchOptions&)> onChange;
    std::function<void(const std::wstring&, const SearchOptions&)> onSubmit;
    std::function<void()> onCancel;
    /// ↑ / ↓ in the field; unset leaves the keys to the field.
    std::function<void(int)> onNavigate;

    std::wstring text() const { return field_.text(); }
    void setText(const std::wstring& text);
    void setPlaceholder(const std::wstring& placeholder);
    const SearchOptions& options() const { return options_; }
    void setOptions(const SearchOptions& options, bool notify = true);
    /// Inline editors reuse the chrome without the toggles.
    bool showsOptions = true;
    void focus(bool selectAll = false);
    bool hasKeyboardFocus() const { return field_.isFocused(); }
    void clear();
    void refreshFonts();

    void layout() override;
    void draw(Graphics& g) override;
    bool mouseDown(const MouseEvent& e) override;
    void mouseMoved(const MouseEvent& e) override;
    void mouseExited() override;
    Cursor cursorAt(Point p) override;
    std::wstring tooltipAt(Point p) override;

    static constexpr float height = 30;

private:
    Rect clearRect() const;
    Rect toggleRect(int index) const;
    void changed();
    TextField field_;
    SearchOptions options_;
    bool focused_ = false;
    bool clearHovered_ = false;
    bool settingText_ = false;
};

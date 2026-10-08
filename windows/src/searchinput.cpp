#include "searchinput.h"

#include "theme.h"

namespace {
const wchar_t* kGlyphs[3] = {L"Aa", L"wd", L".*"};
const wchar_t* kTips[3] = {L"Match case", L"Whole word", L"Regular expression"};
}  // namespace

SearchInputView::SearchInputView() {
    field_.font = Theme::uiFont(12);
    field_.textColor = Theme::foreground;
    field_.fillColor = Theme::inputBackground;
    field_.placeholderColor = Theme::dimText;
    field_.horizontalInset = 0;
    field_.onChange = [this] {
        if (settingText_) return;
        changed();
    };
    field_.onSubmit = [this] {
        if (onSubmit) onSubmit(field_.text(), options_);
    };
    field_.onEscape = [this] {
        if (onCancel) onCancel();
    };
    field_.onKey = [this](UINT key) {
        if (!onNavigate) return false;
        if (key == VK_UP) {
            onNavigate(-1);
            return true;
        }
        if (key == VK_DOWN) {
            onNavigate(1);
            return true;
        }
        return false;
    };
    field_.onFocusChange = [this](bool on) {
        focused_ = on;
        setNeedsDisplay();
    };
    addSubview(&field_);
}

void SearchInputView::changed() {
    setNeedsLayout();
    setNeedsDisplay();
    if (onChange) onChange(field_.text(), options_);
}

void SearchInputView::setText(const std::wstring& text) {
    settingText_ = true;
    field_.setText(text);
    settingText_ = false;
    setNeedsLayout();
    setNeedsDisplay();
}

void SearchInputView::setPlaceholder(const std::wstring& placeholder) {
    field_.placeholder = placeholder;
    field_.setNeedsDisplay();
}

void SearchInputView::setOptions(const SearchOptions& options, bool notify) {
    if (options == options_) return;
    options_ = options;
    setNeedsDisplay();
    if (notify && onChange) onChange(field_.text(), options_);
}

void SearchInputView::focus(bool selectAll) {
    field_.focus();
    if (selectAll) field_.selectAll();
}

void SearchInputView::clear() {
    if (field_.text().empty()) return;
    setText(L"");
    if (onChange) onChange(L"", options_);
    focus();
}

void SearchInputView::refreshFonts() {
    field_.font = Theme::uiFont(12);
    field_.dpiChanged();
    setNeedsLayout();
    setNeedsDisplay();
}

Rect SearchInputView::toggleRect(int index) const {
    Rect b = bounds();
    // Right to left: .* is nearest the edge.
    float x = b.w - 9 - 20 - (2 - index) * (20 + 8);
    return Rect(x, (b.h - 18) / 2, 20, 18);
}

Rect SearchInputView::clearRect() const {
    Rect b = bounds();
    float right = showsOptions ? toggleRect(0).x - 8 : b.w - 10;
    return Rect(right - 16, (b.h - 18) / 2, 16, 18);
}

void SearchInputView::layout() {
    Rect b = bounds();
    bool hasText = !field_.text().empty();
    float right = showsOptions ? toggleRect(0).x - 8 : b.w - 10;
    if (hasText) right = clearRect().x - 8;
    field_.setFrame(Rect(10, 0, std::max(0.0f, right - 10), b.h));
}

void SearchInputView::draw(Graphics& g) {
    Rect box = bounds().inset(0.5f, 0.5f);
    g.fillRoundedRect(box, 7, Theme::inputBackground);
    g.strokeRoundedRect(box, 7, focused_ ? Theme::inputBorderFocused : Theme::inputBorder, 1);
    if (!field_.text().empty()) {
        Rect r = clearRect();
        if (clearHovered_) {
            Rect disc(std::floor(r.midX() - 8), std::floor(r.midY() - 8), 16, 16);
            g.fillEllipse(disc, Theme::toggleActiveBackground);
        }
        Point c(r.midX(), r.midY());
        Color ink = clearHovered_ ? Theme::foreground : Theme::dimText;
        g.line(Point(c.x - 3.5f, c.y - 3.5f), Point(c.x + 3.5f, c.y + 3.5f), ink, 1.25f, true);
        g.line(Point(c.x + 3.5f, c.y - 3.5f), Point(c.x - 3.5f, c.y + 3.5f), ink, 1.25f, true);
    }
    if (!showsOptions) return;
    bool on[3] = {options_.caseSensitive, options_.wholeWord, options_.regex};
    Font font = Theme::uiFont(11);
    for (int i = 0; i < 3; ++i) {
        Rect r = toggleRect(i);
        if (on[i]) g.fillRoundedRect(r, 4, Theme::toggleActiveBackground);
        Color ink = on[i] ? Theme::foreground : Theme::dimText;
        g.text(kGlyphs[i], font, ink, r, LineBreak::Clipping, Align::Center);
        if (i == 1) {
            float w = Text::width(kGlyphs[i], font);
            float baseline = Text::centeredBaseline(font, r);
            g.fillRect(Rect(r.midX() - w / 2, std::round(baseline + 1.5f), w, 1), ink);
        }
    }
}

bool SearchInputView::mouseDown(const MouseEvent& e) {
    if (!field_.text().empty() && clearRect().contains(e.location)) {
        clear();
        return true;
    }
    if (showsOptions) {
        for (int i = 0; i < 3; ++i) {
            if (!toggleRect(i).contains(e.location)) continue;
            SearchOptions next = options_;
            if (i == 0) next.caseSensitive = !next.caseSensitive;
            if (i == 1) next.wholeWord = !next.wholeWord;
            if (i == 2) next.regex = !next.regex;
            setOptions(next);
            return true;
        }
    }
    field_.focus();
    return true;
}

void SearchInputView::mouseMoved(const MouseEvent& e) {
    bool hovered = !field_.text().empty() && clearRect().contains(e.location);
    if (hovered != clearHovered_) {
        clearHovered_ = hovered;
        setNeedsDisplay();
    }
}

void SearchInputView::mouseExited() {
    if (clearHovered_) {
        clearHovered_ = false;
        setNeedsDisplay();
    }
}

Cursor SearchInputView::cursorAt(Point p) {
    if (!field_.text().empty() && clearRect().contains(p)) return Cursor::Arrow;
    if (showsOptions) {
        for (int i = 0; i < 3; ++i) {
            if (toggleRect(i).contains(p)) return Cursor::Arrow;
        }
    }
    return Cursor::IBeam;
}

std::wstring SearchInputView::tooltipAt(Point p) {
    if (!field_.text().empty() && clearRect().contains(p)) return L"Clear";
    if (showsOptions) {
        for (int i = 0; i < 3; ++i) {
            if (toggleRect(i).contains(p)) return kTips[i];
        }
    }
    return L"";
}

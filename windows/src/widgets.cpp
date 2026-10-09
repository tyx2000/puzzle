#include "widgets.h"

#include "theme.h"

#include <commctrl.h>

// ── ScrollArea ─────────────────────────────────────────────────────────────

namespace {
constexpr float kScrollerHit = 12;
constexpr float kKnobIdle = 6;
constexpr float kKnobHot = 9;
constexpr float kKnobMinimum = 24;
}  // namespace

ScrollArea::ScrollArea() { clipsToBounds = true; }

void ScrollArea::setContentSize(Size size) {
    if (size == contentSize_) return;
    contentSize_ = size;
    setContentOffset(offset_);
    setNeedsDisplay();
}

Point ScrollArea::maximumOffset() const {
    Rect b = bounds();
    return Point(std::max(0.0f, contentSize_.w - b.w), std::max(0.0f, contentSize_.h - b.h));
}

Rect ScrollArea::visibleContentRect() const {
    Rect b = bounds();
    return Rect(offset_.x, offset_.y, b.w, b.h);
}

void ScrollArea::setContentOffset(Point offset, bool flash) {
    Point limit = maximumOffset();
    Point clamped(std::clamp(offset.x, 0.0f, limit.x), std::clamp(offset.y, 0.0f, limit.y));
    if (flash) flashScrollers();
    if (clamped == offset_) return;
    offset_ = clamped;
    setNeedsDisplay();
    offsetChanged();
    if (onScroll) onScroll();
}

void ScrollArea::layout() { setContentOffset(offset_); }

bool ScrollArea::showsScroller(Axis axis) const {
    Rect b = bounds();
    if (axis == Axis::Vertical && (!hasVerticalScroller || contentSize_.h <= b.h)) return false;
    if (axis == Axis::Horizontal && (!hasHorizontalScroller || contentSize_.w <= b.w)) return false;
    return flashing_ || hot_ == axis || dragging_ == axis;
}

Rect ScrollArea::trackRect(Axis axis) const {
    Rect b = bounds();
    bool both = hasVerticalScroller && hasHorizontalScroller && contentSize_.h > b.h
        && contentSize_.w > b.w;
    float thickness = (hot_ == axis || dragging_ == axis) ? kKnobHot : kKnobIdle;
    if (axis == Axis::Vertical) {
        return Rect(b.w - thickness - 2, 2, thickness, b.h - 4 - (both ? kScrollerHit : 0));
    }
    return Rect(2, b.h - thickness - 2, b.w - 4 - (both ? kScrollerHit : 0), thickness);
}

Rect ScrollArea::knobRect(Axis axis) const {
    Rect track = trackRect(axis);
    Rect b = bounds();
    Point limit = maximumOffset();
    if (axis == Axis::Vertical) {
        if (contentSize_.h <= 0) return {};
        float length = std::max(kKnobMinimum, track.h * b.h / contentSize_.h);
        length = std::min(length, track.h);
        float position = limit.y > 0 ? (track.h - length) * offset_.y / limit.y : 0;
        return Rect(track.x, track.y + position, track.w, length);
    }
    if (contentSize_.w <= 0) return {};
    float length = std::max(kKnobMinimum, track.w * b.w / contentSize_.w);
    length = std::min(length, track.w);
    float position = limit.x > 0 ? (track.w - length) * offset_.x / limit.x : 0;
    return Rect(track.x + position, track.y, length, track.h);
}

ScrollArea::Axis ScrollArea::scrollerAt(Point p) const {
    Rect b = bounds();
    if (hasVerticalScroller && contentSize_.h > b.h && p.x >= b.w - kScrollerHit) return Axis::Vertical;
    if (hasHorizontalScroller && contentSize_.w > b.w && p.y >= b.h - kScrollerHit)
        return Axis::Horizontal;
    return Axis::None;
}

void ScrollArea::flashScrollers() {
    flashing_ = true;
    setNeedsDisplay();
    if (flashEnd_) flashEnd_->cancel();
    flashEnd_ = Dispatch::after(1.0, [this, alive = life_.weak()] {
        if (alive.expired()) return;
        flashing_ = false;
        setNeedsDisplay();
    });
}

void ScrollArea::draw(Graphics& g) {
    g.pushOffset(-offset_.x, -offset_.y);
    drawContent(g, visibleContentRect());
    g.popOffset();
}

void ScrollArea::drawOver(Graphics& g) {
    for (Axis axis : {Axis::Vertical, Axis::Horizontal}) {
        if (!showsScroller(axis)) continue;
        if (hot_ == axis || dragging_ == axis) {
            Rect track = trackRect(axis);
            g.fillRoundedRect(track.inset(-1, -1), (std::min(track.w, track.h) + 2) / 2,
                              Theme::scrollerSlot);
        }
        Rect knob = knobRect(axis);
        float inset = std::min(1.0f, std::min(knob.w, knob.h) / 6);
        Rect paint = axis == Axis::Vertical ? knob.inset(inset, 0) : knob.inset(0, inset);
        g.fillRoundedRect(paint, std::min(paint.w, paint.h) / 2, Theme::scrollerKnob);
    }
}

bool ScrollArea::scrollWheel(float dx, float dy, const MouseEvent&) {
    Point limit = maximumOffset();
    bool vertical = dy != 0 && hasVerticalScroller && limit.y > 0;
    bool horizontal = dx != 0 && hasHorizontalScroller && limit.x > 0;
    if (!vertical && !horizontal) return false;
    setContentOffset(Point(offset_.x + (horizontal ? dx : 0), offset_.y + (vertical ? dy : 0)), true);
    return true;
}

bool ScrollArea::mouseDown(const MouseEvent& e) {
    Axis axis = scrollerAt(e.location);
    if (axis != Axis::None) {
        Rect knob = knobRect(axis);
        bool onKnob = axis == Axis::Vertical
            ? (e.location.y >= knob.y && e.location.y < knob.maxY())
            : (e.location.x >= knob.x && e.location.x < knob.maxX());
        if (!onKnob) {
            // A click in the slot pages towards it.
            Rect b = bounds();
            if (axis == Axis::Vertical) {
                float page = e.location.y < knob.y ? -b.h : b.h;
                setContentOffset(Point(offset_.x, offset_.y + page), true);
            } else {
                float page = e.location.x < knob.x ? -b.w : b.w;
                setContentOffset(Point(offset_.x + page, offset_.y), true);
            }
        }
        dragging_ = axis;
        dragStart_ = axis == Axis::Vertical ? e.location.y : e.location.x;
        dragOffsetStart_ = axis == Axis::Vertical ? offset_.y : offset_.x;
        setNeedsDisplay();
        return true;
    }
    contentPressed_ = contentMouseDown(e, toContent(e.location));
    return contentPressed_;
}

void ScrollArea::mouseDragged(const MouseEvent& e) {
    if (dragging_ != Axis::None) {
        Rect track = trackRect(dragging_);
        Rect knob = knobRect(dragging_);
        Point limit = maximumOffset();
        if (dragging_ == Axis::Vertical) {
            float travel = track.h - knob.h;
            float delta = e.location.y - dragStart_;
            if (travel > 0) setContentOffset(Point(offset_.x, dragOffsetStart_ + delta * limit.y / travel));
        } else {
            float travel = track.w - knob.w;
            float delta = e.location.x - dragStart_;
            if (travel > 0) setContentOffset(Point(dragOffsetStart_ + delta * limit.x / travel, offset_.y));
        }
        return;
    }
    if (contentPressed_) contentMouseDragged(e, toContent(e.location));
}

void ScrollArea::mouseUp(const MouseEvent& e) {
    if (dragging_ != Axis::None) {
        dragging_ = Axis::None;
        flashScrollers();
        return;
    }
    if (contentPressed_) {
        contentPressed_ = false;
        contentMouseUp(e, toContent(e.location));
    }
}

void ScrollArea::mouseMoved(const MouseEvent& e) {
    Axis axis = scrollerAt(e.location);
    if (axis != hot_) {
        hot_ = axis;
        setNeedsDisplay();
    }
    if (axis == Axis::None) contentMouseMoved(toContent(e.location));
    else contentMouseExited();
}

void ScrollArea::mouseExited() {
    if (hot_ != Axis::None) {
        hot_ = Axis::None;
        setNeedsDisplay();
    }
    contentMouseExited();
}

// ── ListView ───────────────────────────────────────────────────────────────

ListView::ListView() { hasVerticalScroller = true; }

void ListView::updateContentSize() {
    Rect b = bounds();
    setContentSize(Size(std::max(b.w, minimumContentWidth), rowCount_ * rowHeight));
}

void ListView::layout() {
    updateContentSize();
    ScrollArea::layout();
}

void ListView::reloadData() {
    rowCount_ = numberOfRows ? std::max(0, numberOfRows()) : 0;
    if (selected_ >= rowCount_) selected_ = rowCount_ - 1;
    if (hovered_ >= rowCount_) hovered_ = -1;
    updateContentSize();
    setNeedsDisplay();
    refreshHoverState();
}

int ListView::rowAt(Point p) const {
    if (p.y < 0 || rowHeight <= 0) return -1;
    int row = (int)std::floor(p.y / rowHeight);
    return row < rowCount_ ? row : -1;
}

Rect ListView::rectOfRow(int row) const {
    return Rect(0, row * rowHeight, std::max(bounds().w, minimumContentWidth), rowHeight);
}

void ListView::setHoveredRow(int row) {
    int next = row >= 0 && row < rowCount_ ? row : -1;
    if (next == hovered_) return;
    int previous = hovered_;
    hovered_ = next;
    Point o = contentOffset();
    if (previous >= 0) setNeedsDisplay(rectOfRow(previous).offset(-o.x, -o.y));
    if (next >= 0) setNeedsDisplay(rectOfRow(next).offset(-o.x, -o.y));
}

void ListView::refreshHoverState() {
    WindowHost* host = window();
    if (!host || !isVisibleInWindow()) {
        setHoveredRow(-1);
        return;
    }
    Point local = convertFromWindow(host->mouseLocation());
    POINT cursor{};
    GetCursorPos(&cursor);
    bool inside = bounds().contains(local) && WindowFromPoint(cursor) == host->hwnd();
    setHoveredRow(inside ? rowAt(toContent(local)) : -1);
}

void ListView::setSelectedRow(int row, bool scroll) {
    int next = row >= 0 && row < rowCount_ ? row : -1;
    if (next == selected_) return;
    selected_ = next;
    if (scroll && next >= 0) scrollRowToVisible(next);
    setNeedsDisplay();
}

void ListView::scrollRowToVisible(int row) {
    Rect r = rectOfRow(row);
    Rect visible = visibleContentRect();
    if (r.y < visible.y) setContentOffset(Point(visible.x, r.y));
    else if (r.maxY() > visible.maxY()) setContentOffset(Point(visible.x, r.maxY() - visible.h));
}

void ListView::centerRow(int row) {
    if (row < 0 || row >= rowCount_) return;
    Rect r = rectOfRow(row);
    Rect visible = visibleContentRect();
    setContentOffset(Point(visible.x, r.midY() - visible.h / 2), true);
}

void ListView::drawContent(Graphics& g, const Rect& visible) {
    if (rowCount_ == 0 || rowHeight <= 0) return;
    int first = std::max(0, (int)std::floor(visible.y / rowHeight));
    int last = std::min(rowCount_ - 1, (int)std::ceil(visible.maxY() / rowHeight));
    for (int row = first; row <= last; ++row) {
        Rect r = rectOfRow(row);
        if (rowBackground) g.fillRect(r, rowBackground(row));
        if (drawRow) drawRow(g, row, r);
    }
}

bool ListView::contentMouseDown(const MouseEvent& e, Point p) {
    pressedRow_ = rowAt(p);
    if (e.clickCount >= 2 && pressedRow_ >= 0 && onDoubleClick) {
        onDoubleClick(pressedRow_);
        pressedRow_ = -1;
    }
    return true;
}

void ListView::contentMouseUp(const MouseEvent&, Point p) {
    int row = rowAt(p);
    int pressed = pressedRow_;
    pressedRow_ = -1;
    if (row < 0 || row != pressed) return;
    if (keyboardNavigation) setSelectedRow(row, false);
    if (onClick) onClick(row);
}

void ListView::contentMouseMoved(Point p) { setHoveredRow(rowAt(p)); }

void ListView::contentMouseExited() { setHoveredRow(-1); }

void ListView::offsetChanged() { refreshHoverState(); }

bool ListView::rightMouseDown(const MouseEvent& e) {
    int row = rowAt(toContent(e.location));
    if (row < 0 || !onContextMenu) return false;
    WindowHost* host = window();
    if (!host) return false;
    onContextMenu(row, host->screenPoint(e.windowLocation));
    return true;
}

std::wstring ListView::tooltipAt(Point local) {
    if (!tooltipForRow) return tooltip;
    Point p = toContent(local);
    int row = rowAt(p);
    if (row < 0) return L"";
    Rect r = rectOfRow(row);
    return tooltipForRow(row, Point(p.x - r.x, p.y - r.y));
}

bool ListView::keyDown(const KeyEvent& e) {
    if (!keyboardNavigation || e.control || e.alt) return false;
    if (e.key == VK_UP || e.key == VK_DOWN) {
        if (rowCount_ == 0) return true;
        int start = selected_ >= 0 ? selected_ : (hovered_ >= 0 ? hovered_ : -1);
        int next = e.key == VK_DOWN ? start + 1 : (start < 0 ? rowCount_ - 1 : start - 1);
        setSelectedRow(std::clamp(next, 0, rowCount_ - 1));
        return true;
    }
    if (e.key == VK_RETURN) {
        if (selected_ >= 0) {
            if (onActivate) onActivate(selected_);
            else if (onClick) onClick(selected_);
        }
        return true;
    }
    return false;
}

// ── Label ──────────────────────────────────────────────────────────────────

void Label::draw(Graphics& g) {
    if (text.empty() || !font) return;
    if (wraps) {
        g.wrappedText(text, font, color, bounds(), align);
        return;
    }
    g.text(text, font, color, bounds(), lineBreak, align);
}

float Label::fittingWidth() const { return std::ceil(Text::width(text, font)); }

float Label::fittingHeight(float width) const {
    if (!wraps) return std::ceil(font.lineHeight());
    return std::ceil(Text::wrappedHeight(text, font, width));
}

// ── TextField ──────────────────────────────────────────────────────────────

TextField::TextField() {
    font = Theme::uiFont(11);
    textColor = Theme::foreground;
    fillColor = Theme::activeTab;
    placeholderColor = Theme::dimText;
}

TextField::~TextField() {
    if (edit_) {
        RemoveWindowSubclass(edit_, &TextField::editProc, 1);
        RemovePropW(edit_, kNativeColorProperty);
        DestroyWindow(edit_);
    }
    if (gdiFont_) DeleteObject(gdiFont_);
    if (brush_) DeleteObject(brush_);
}

void TextField::makeFont() {
    WindowHost* host = window();
    float scale = host ? host->scale() : 1;
    if (gdiFont_) DeleteObject(gdiFont_);
    gdiFont_ = CreateFontW(-(int)std::lround(font.size() * scale), 0, 0, 0, font.weight(), FALSE,
                           FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                           CLEARTYPE_QUALITY, FF_DONTCARE, font.family().c_str());
    if (edit_) {
        SendMessageW(edit_, WM_SETFONT, (WPARAM)gdiFont_, TRUE);
        SendMessageW(edit_, EM_SETMARGINS, EC_LEFTMARGIN | EC_RIGHTMARGIN, 0);
    }
}

void TextField::createEdit() {
    WindowHost* host = window();
    if (!host || edit_) return;
    edit_ = CreateWindowExW(0, L"EDIT", pendingText_.c_str(),
                            WS_CHILD | ES_AUTOHSCROLL | ES_LEFT | WS_TABSTOP, 0, 0, 10, 10,
                            host->hwnd(), nullptr, GetModuleHandleW(nullptr), nullptr);
    pendingText_.clear();
    SetPropW(edit_, kNativeColorProperty, static_cast<NativeColorProvider*>(this));
    SetWindowSubclass(edit_, &TextField::editProc, 1, (DWORD_PTR)this);
    SendMessageW(edit_, EM_SETREADONLY, editable_ ? FALSE : TRUE, 0);
    makeFont();
}

void TextField::updateNative() {
    WindowHost* host = window();
    if (!host) {
        if (edit_) ShowWindow(edit_, SW_HIDE);
        return;
    }
    if (!edit_) createEdit();
    if (!edit_) return;
    bool visible = isVisibleInWindow() && bounds().w > 2 * horizontalInset;
    float scale = host->scale();
    Rect r = convertToWindow(bounds());
    // The edit is one line tall and centred in the field, which is how the
    // AppKit cell set its text in the middle of the strip.
    HDC dc = GetDC(edit_);
    HGDIOBJ old = SelectObject(dc, gdiFont_);
    TEXTMETRICW metrics{};
    GetTextMetricsW(dc, &metrics);
    SelectObject(dc, old);
    ReleaseDC(edit_, dc);
    int lineHeight = metrics.tmHeight + 2;
    int x = (int)std::lround((r.x + horizontalInset) * scale);
    int width = (int)std::lround((r.w - 2 * horizontalInset) * scale);
    int y = (int)std::lround(r.midY() * scale - lineHeight / 2.0f);
    SetWindowPos(edit_, nullptr, x, y, std::max(1, width), lineHeight,
                 SWP_NOZORDER | SWP_NOACTIVATE | (visible ? SWP_SHOWWINDOW : SWP_HIDEWINDOW));
}

void TextField::dpiChanged() {
    makeFont();
    updateNative();
}

std::wstring TextField::text() const {
    if (!edit_) return pendingText_;
    int length = GetWindowTextLengthW(edit_);
    std::wstring out(length + 1, L'\0');
    GetWindowTextW(edit_, out.data(), length + 1);
    out.resize(length);
    return out;
}

void TextField::setText(const std::wstring& value) {
    if (!edit_) {
        pendingText_ = value;
        if (onChange) onChange();
        return;
    }
    if (value == text()) {
        if (onChange) onChange();
        return;
    }
    SetWindowTextW(edit_, value.c_str());  // EN_CHANGE reaches onChange
    InvalidateRect(edit_, nullptr, TRUE);
}

void TextField::setEditable(bool editable) {
    editable_ = editable;
    if (edit_) SendMessageW(edit_, EM_SETREADONLY, editable ? FALSE : TRUE, 0);
}

void TextField::focus() {
    if (!edit_) updateNative();
    if (edit_) SetFocus(edit_);
}

bool TextField::isFocused() const { return edit_ && GetFocus() == edit_; }

void TextField::selectAll() {
    if (edit_) SendMessageW(edit_, EM_SETSEL, 0, -1);
}

void TextField::draw(Graphics& g) {
    if (borderColor.isClear()) {
        g.fillRect(bounds(), fillColor);
        return;
    }
    Rect b = bounds().inset(0.5f, 0.5f);
    g.fillRoundedRect(b, 4, fillColor);
    g.strokeRoundedRect(b, 4, isFocused() ? Theme::systemAccent() : borderColor, 1);
}

bool TextField::mouseDown(const MouseEvent&) {
    // The padding around the text is part of the field: a click there starts
    // typing, as a click on the text would.
    focus();
    return true;
}

HBRUSH TextField::controlColor(HDC dc) {
    SetTextColor(dc, textColor.colorref());
    SetBkColor(dc, fillColor.colorref());
    if (!brush_ || brushColor_ != fillColor) {
        if (brush_) DeleteObject(brush_);
        brush_ = CreateSolidBrush(fillColor.colorref());
        brushColor_ = fillColor;
    }
    return brush_;
}

void TextField::controlCommand(WORD code) {
    if (code == EN_CHANGE && onChange) onChange();
}

LRESULT CALLBACK TextField::editProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam,
                                     UINT_PTR, DWORD_PTR data) noexcept {
    auto* field = reinterpret_cast<TextField*>(data);
    switch (message) {
    case WM_KEYDOWN: {
        bool control = GetKeyState(VK_CONTROL) < 0;
        bool shift = GetKeyState(VK_SHIFT) < 0;
        bool alt = GetKeyState(VK_MENU) < 0;
        if (wParam == VK_RETURN && !alt) {
            if (control && shift) {
                if (field->onPushShortcut) field->onPushShortcut();
                else MessageBeep(MB_OK);
            } else if (control) {
                if (field->onCommitShortcut) field->onCommitShortcut();
                else MessageBeep(MB_OK);
            } else if (field->onSubmit) {
                field->onSubmit();
            }
            return 0;
        }
        if (wParam == VK_ESCAPE && field->onEscape) {
            field->onEscape();
            return 0;
        }
        if (field->onKey && field->onKey((UINT)wParam)) return 0;
        if (control && wParam == 'A') {
            SendMessageW(hwnd, EM_SETSEL, 0, -1);
            return 0;
        }
        break;
    }
    case WM_CHAR:
        // Return, Escape and the Ctrl+Backspace control character would beep
        // or type garbage in a one-line field.
        if (wParam == L'\r' || wParam == L'\n' || wParam == 27 || wParam == 0x7f || wParam == 1) {
            return 0;
        }
        break;
    case WM_SETFOCUS:
        if (WindowHost* host = field->window()) host->setFocusedView(nullptr);
        InvalidateRect(hwnd, nullptr, TRUE);
        field->setNeedsDisplay();
        break;
    case WM_KILLFOCUS:
        InvalidateRect(hwnd, nullptr, TRUE);
        field->setNeedsDisplay();
        break;
    case WM_PAINT: {
        LRESULT result = DefSubclassProc(hwnd, message, wParam, lParam);
        if (GetWindowTextLengthW(hwnd) == 0 && !field->placeholder.empty()) {
            HDC dc = GetDC(hwnd);
            HGDIOBJ old = SelectObject(dc, field->gdiFont_);
            SetTextColor(dc, field->placeholderColor.colorref());
            SetBkMode(dc, TRANSPARENT);
            RECT rc{};
            SendMessageW(hwnd, EM_GETRECT, 0, (LPARAM)&rc);
            DrawTextW(dc, field->placeholder.c_str(), -1, &rc,
                      DT_SINGLELINE | DT_LEFT | DT_TOP | DT_NOPREFIX | DT_END_ELLIPSIS);
            SelectObject(dc, old);
            ReleaseDC(hwnd, dc);
        }
        return result;
    }
    case WM_NCDESTROY: {
        // The window holding the field went first (an alert closing): keep
        // what was typed, for whoever asks after.
        int length = GetWindowTextLengthW(hwnd);
        std::wstring text(length + 1, L'\0');
        GetWindowTextW(hwnd, text.data(), length + 1);
        text.resize(length);
        field->pendingText_ = text;
        RemoveWindowSubclass(hwnd, &TextField::editProc, 1);
        RemovePropW(hwnd, kNativeColorProperty);
        field->edit_ = nullptr;
        break;
    }
    default:
        break;
    }
    LRESULT result = DefSubclassProc(hwnd, message, wParam, lParam);
    if (message == WM_CHAR || message == WM_PASTE || message == WM_CUT || message == WM_CLEAR
        || message == WM_UNDO || message == EM_UNDO || message == WM_SETTEXT
        || (message == WM_KEYDOWN && (wParam == VK_DELETE || wParam == VK_BACK))) {
        // Repaint so the placeholder comes and goes with the first character.
        InvalidateRect(hwnd, nullptr, TRUE);
    }
    return result;
}

// ── SymbolButton ───────────────────────────────────────────────────────────

void SymbolButton::draw(Graphics& g) {
    Rect b = bounds();
    if (hoverBackground && enabled && (hovered_ || pressed_)) {
        g.fillRoundedRect(b, 5, pressed_ ? Theme::activeRow : Theme::hover);
    }
    Color ink = tint.isClear() ? Theme::dimText : tint;
    if (!enabled) ink = ink.withAlpha(ink.a * 0.4f);
    else if (pressed_ && !hoverBackground) ink = ink.blended(0.35f, Theme::foreground);
    else if (hovered_ && !hoverBackground) ink = ink.blended(0.25f, Theme::foreground);
    float size = std::min({symbolSize, b.w, b.h});
    drawSymbol(g, symbol, Rect(b.midX() - size / 2, b.midY() - size / 2, size, size), ink, weight);
}

bool SymbolButton::mouseDown(const MouseEvent&) {
    if (!enabled) return true;
    pressed_ = true;
    setNeedsDisplay();
    return true;
}

void SymbolButton::mouseUp(const MouseEvent& e) {
    bool was = pressed_;
    pressed_ = false;
    setNeedsDisplay();
    if (was && enabled && bounds().contains(e.location) && onClick) onClick();
}

// ── Badge ──────────────────────────────────────────────────────────────────

namespace Badge {

Font font(const Font& labelFont) { return Theme::uiFont(std::max(9.0f, labelFont.size() - 1.5f)); }

float diameter(const std::wstring& value, const Font& labelFont) {
    if (value.empty()) return 0;
    Font f = font(labelFont);
    float width = std::ceil(Text::width(value, f));
    float cap = std::ceil(f.capHeight());
    return std::max(minimumDiameter, std::max(width + horizontalPadding * 2, cap + verticalPadding * 2));
}

void draw(Graphics& g, const std::wstring& value, Point centre, const Font& labelFont,
          const Color& background, const Color& foreground) {
    if (value.empty()) return;
    float d = diameter(value, labelFont);
    Rect circle(roundHalf(centre.x - d / 2), roundHalf(centre.y - d / 2), d, d);
    g.fillEllipse(circle, background);
    Font f = font(labelFont);
    float width = Text::width(value, f);
    float baseline = roundHalf(circle.midY() + f.capHeight() / 2);
    g.text(value, f, foreground, baseline,
           Rect(roundHalf(circle.midX() - width / 2), circle.y, width + 2, circle.h),
           LineBreak::Clipping);
}

}  // namespace Badge

// ── BadgeButton ────────────────────────────────────────────────────────────

Font BadgeButton::labelFont() const { return Theme::uiFont(10.5f); }

float BadgeButton::intrinsicWidth() const {
    float titleWidth = std::ceil(Text::width(title, labelFont()));
    float badgeWidth = badge.empty() ? 0 : Badge::gap + Badge::diameter(badge, labelFont());
    return 20 + titleWidth + badgeWidth;
}

void BadgeButton::draw(Graphics& g) {
    Rect b = bounds();
    bool lit = enabled && (pressed_ || hovered_);
    Color badgeGround;
    if (style == Style::Bordered) {
        Rect shape = b.inset(0.5f, 0.5f);
        g.fillRoundedRect(shape, 5, enabled ? Theme::activeTab : Theme::inactiveTab);
        if (lit) g.fillRoundedRect(shape, 5, Theme::hover);
        g.strokeRoundedRect(shape, 5, enabled ? Theme::border : Theme::border.withAlpha(0.6f), 1);
        badgeGround = Theme::activeRow;
    } else {
        if (lit) g.fillRoundedRect(b, 5, Theme::activeRow);
        badgeGround = Theme::panelBackground;
    }
    Color ink = enabled ? Theme::foreground : Theme::dimText;
    Font f = labelFont();
    float titleWidth = Text::width(title, f);
    float d = Badge::diameter(badge, f);
    float total = titleWidth + (badge.empty() ? 0 : Badge::gap + d);
    float x = std::round((b.w - total) / 2);
    float baseline = Text::centeredBaseline(f, b);
    g.text(title, f, ink, baseline, Rect(x, 0, titleWidth + 2, b.h), LineBreak::Clipping);
    if (!badge.empty()) {
        Point centre(x + titleWidth + Badge::gap + d / 2, baseline - f.capHeight() / 2);
        Badge::draw(g, badge, centre, f, badgeGround, ink);
    }
}

bool BadgeButton::mouseDown(const MouseEvent&) {
    if (!enabled) return true;
    pressed_ = true;
    setNeedsDisplay();
    return true;
}

void BadgeButton::mouseUp(const MouseEvent& e) {
    bool was = pressed_;
    pressed_ = false;
    setNeedsDisplay();
    if (was && enabled && bounds().contains(e.location) && onClick) onClick();
}

// ── PushButton ─────────────────────────────────────────────────────────────

float PushButton::intrinsicWidth() const {
    Font f = font ? font : Theme::uiFont(12);
    return std::max(64.0f, std::ceil(Text::width(title, f)) + 28);
}

void PushButton::draw(Graphics& g) {
    Rect b = bounds().inset(0.5f, 0.5f);
    Font f = font ? font : Theme::uiFont(12);
    Color ground, ink;
    if (!enabled) {
        ground = Color::hex(0x1a1e27);
        ink = Theme::dimText;
    } else if (isDefault) {
        Color accent = Theme::systemAccent();
        ground = pressed_ ? accent.blended(0.25f, Color(0, 0, 0))
                          : hovered_ ? accent.blended(0.12f, Color(1, 1, 1)) : accent;
        ink = Color(1, 1, 1);
    } else {
        ground = pressed_ ? Color::hex(0x3a4150) : hovered_ ? Color::hex(0x323845) : Color::hex(0x2a2f3a);
        ink = Theme::selectedControlText;
    }
    g.fillRoundedRect(b, 5, ground);
    g.text(title, f, ink, bounds(), LineBreak::TruncatingTail, Align::Center);
}

bool PushButton::mouseDown(const MouseEvent&) {
    if (!enabled) return true;
    pressed_ = true;
    setNeedsDisplay();
    return true;
}

void PushButton::mouseUp(const MouseEvent& e) {
    bool was = pressed_;
    pressed_ = false;
    setNeedsDisplay();
    if (was && enabled && bounds().contains(e.location) && onClick) onClick();
}

// ── CheckBox ───────────────────────────────────────────────────────────────

void CheckBox::draw(Graphics& g) {
    Rect b = bounds();
    float size = 14;
    Rect box = g.snapped(Rect(std::round(b.midX() - size / 2), std::round(b.midY() - size / 2), size, size));
    if (checked) {
        g.fillRoundedRect(box, 3, Theme::systemAccent());
        g.polyline({Point(box.x + 3.5f, box.midY()), Point(box.x + 6, box.maxY() - 4),
                    Point(box.maxX() - 3.5f, box.y + 4)},
                   Color(1, 1, 1), 1.6f);
    } else {
        g.fillRoundedRect(box, 3, pressed_ ? Color::hex(0x2a2f3a) : Color::hex(0x1a1e27));
        g.strokeRoundedRect(box.inset(0.5f, 0.5f), 3, hovered_ ? Theme::dimText.blended(0.3f, Theme::foreground)
                                                               : Theme::dimText, 1);
    }
}

bool CheckBox::mouseDown(const MouseEvent&) {
    pressed_ = true;
    setNeedsDisplay();
    return true;
}

void CheckBox::mouseUp(const MouseEvent& e) {
    bool was = pressed_;
    pressed_ = false;
    setNeedsDisplay();
    if (was && bounds().contains(e.location)) toggle();
}

void CheckBox::toggle() {
    checked = !checked;
    setNeedsDisplay();
    if (onToggle) onToggle(checked);
}

// ── ProgressShimmer ────────────────────────────────────────────────────────

void ProgressShimmer::start() {
    setHidden(false);
    if (timer_.running()) return;
    phase_ = 0;
    timer_.start(1.0 / 60.0, [this] {
        phase_ = std::fmod(phase_ + 0.015f, 1.0f);
        setNeedsDisplay();
    });
}

void ProgressShimmer::stop() {
    timer_.stop();
    setHidden(true);
    setNeedsDisplay();
}

void ProgressShimmer::draw(Graphics& g) {
    Rect b = bounds();
    g.fillRect(b, Theme::border);
    float sweep = std::max(48.0f, b.w * 0.24f);
    float travel = b.w + sweep;
    float x = -sweep + travel * phase_;
    g.fillGradient(Rect(x, 0, sweep, b.h),
                   {{0, Theme::accent.withAlpha(0)}, {0.5f, Theme::accent.withAlpha(0.95f)},
                    {1, Theme::accent.withAlpha(0)}},
                   false);
}

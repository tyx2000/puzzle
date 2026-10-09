#include "window.h"

#include "menu.h"
#include "theme.h"

#include <commctrl.h>
#include <dwmapi.h>
#include <uxtheme.h>
#include <windowsx.h>

#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

// ── Caption buttons ────────────────────────────────────────────────────────

CaptionButtonsView::CaptionButtonsView() { clipsToBounds = true; }

Rect CaptionButtonsView::rectFor(int code) const {
    float x = bounds().w;
    if (code == HTCLOSE) return Rect(x - buttonWidth, 0, buttonWidth, buttonHeight);
    x -= buttonWidth;
    if (showsMaximize) {
        if (code == HTMAXBUTTON) return Rect(x - buttonWidth, 0, buttonWidth, buttonHeight);
        x -= buttonWidth;
    }
    if (showsMinimize && code == HTMINBUTTON) return Rect(x - buttonWidth, 0, buttonWidth, buttonHeight);
    return {};
}

int CaptionButtonsView::hitCode(Point p) const {
    for (int code : {HTCLOSE, HTMAXBUTTON, HTMINBUTTON}) {
        if (rectFor(code).contains(p)) return code;
    }
    return HTNOWHERE;
}

void CaptionButtonsView::setHot(int code) {
    if (code == hot_) return;
    hot_ = code;
    setNeedsDisplay();
}

void CaptionButtonsView::setPressed(int code) {
    if (code == pressed_) return;
    pressed_ = code;
    setNeedsDisplay();
}

void CaptionButtonsView::draw(Graphics& g) {
    WindowHost* host = window();
    bool active = host && host->isActive();
    Color ink = active ? Theme::foreground : Theme::dimText;
    for (int code : {HTMINBUTTON, HTMAXBUTTON, HTCLOSE}) {
        Rect r = rectFor(code);
        if (r.isEmpty()) continue;
        bool hot = hot_ == code, down = pressed_ == code;
        Color glyph = ink;
        if (code == HTCLOSE && (hot || down)) {
            g.fillRect(r, down ? Theme::closeHover.blended(0.2f, Color(0, 0, 0)) : Theme::closeHover);
            glyph = Color(1, 1, 1);
        } else if (hot || down) {
            g.fillRect(r, down ? Theme::activeRow : Theme::hover);
            glyph = Theme::selectedControlText;
        }
        float s = 10;
        float px = 1 / g.scale();
        float cx = std::round(r.midX() * g.scale()) / g.scale();
        float cy = std::round(r.midY() * g.scale()) / g.scale();
        float half = s / 2;
        if (code == HTMINBUTTON) {
            g.line(Point(cx - half, cy + 0.5f * px), Point(cx + half, cy + 0.5f * px), glyph, 1);
        } else if (code == HTMAXBUTTON) {
            if (host && host->isMaximized()) {
                // Restore: two overlapping frames.
                Rect front(cx - half, cy - half + 2, s - 2, s - 2);
                g.strokeRect(front, glyph, 1);
                g.polyline({Point(cx - half + 2, cy - half + 2 - 0.5f), Point(cx - half + 2, cy - half + 0.5f),
                            Point(cx + half - 0.5f, cy - half + 0.5f),
                            Point(cx + half - 0.5f, cy + half - 2 - 0.5f),
                            Point(cx + half - 2, cy + half - 2 - 0.5f)},
                           glyph, 1, false);
            } else {
                g.strokeRect(Rect(cx - half, cy - half, s, s), glyph, 1);
            }
        } else {
            g.line(Point(cx - half, cy - half), Point(cx + half, cy + half), glyph, 1);
            g.line(Point(cx + half, cy - half), Point(cx - half, cy + half), glyph, 1);
        }
    }
}

// ── Window host ────────────────────────────────────────────────────────────

namespace {

constexpr wchar_t kHostProperty[] = L"Gift.Host";

ATOM registerClass() {
    static ATOM atom = 0;
    if (atom) return atom;
    WNDCLASSEXW wc{sizeof(wc)};
    wc.style = CS_DBLCLKS;
    wc.lpfnWndProc = [](HWND h, UINT m, WPARAM w, LPARAM l) -> LRESULT {
        return DefWindowProcW(h, m, w, l);
    };
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.hIcon = LoadIconW(wc.hInstance, MAKEINTRESOURCEW(1));
    wc.hIconSm = (HICON)LoadImageW(wc.hInstance, MAKEINTRESOURCEW(1), IMAGE_ICON,
                                   GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), 0);
    wc.hCursor = nullptr;
    wc.lpszClassName = APP_WINDOW_CLASS;
    atom = RegisterClassExW(&wc);
    return atom;
}

}  // namespace

WindowHost::WindowHost() = default;

WindowHost::~WindowHost() {
    if (hwnd_) {
        RemovePropW(hwnd_, kHostProperty);
        SetWindowLongPtrW(hwnd_, GWLP_WNDPROC, (LONG_PTR)DefWindowProcW);
        DestroyWindow(hwnd_);
        hwnd_ = nullptr;
    }
    if (root_) root_->window_ = nullptr;
}

WindowHost* WindowHost::fromHwnd(HWND hwnd) {
    return hwnd ? static_cast<WindowHost*>(GetPropW(hwnd, kHostProperty)) : nullptr;
}

void WindowHost::createWindow(const std::wstring& title, DWORD style, DWORD exStyle, HWND owner,
                              const RECT& frame) {
    registerClass();
    hwnd_ = CreateWindowExW(exStyle, APP_WINDOW_CLASS, title.c_str(), style, frame.left, frame.top,
                            frame.right - frame.left, frame.bottom - frame.top, owner, nullptr,
                            GetModuleHandleW(nullptr), nullptr);
    SetPropW(hwnd_, kHostProperty, this);
    SetWindowLongPtrW(hwnd_, GWLP_WNDPROC, (LONG_PTR)&WindowHost::windowProc);
    dpi_ = (float)GetDpiForWindow(hwnd_);
    surface_ = std::make_unique<Surface>(hwnd_);

    BOOL dark = TRUE;
    DwmSetWindowAttribute(hwnd_, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, sizeof dark);
    // A one-pixel frame keeps the system shadow and the snap animations of a
    // captioned window while the caption itself is drawn by the views.
    MARGINS margins{0, 0, 1, 0};
    DwmExtendFrameIntoClientArea(hwnd_, &margins);
    SetWindowPos(hwnd_, nullptr, 0, 0, 0, 0,
                 SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);

    tooltip_ = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TRANSPARENT, TOOLTIPS_CLASSW, nullptr,
                               WS_POPUP | TTS_NOPREFIX | TTS_ALWAYSTIP, CW_USEDEFAULT,
                               CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, hwnd_, nullptr,
                               GetModuleHandleW(nullptr), nullptr);
    if (tooltip_) {
        SetWindowTheme(tooltip_, L"DarkMode_Explorer", nullptr);
        TOOLINFOW info{};
        info.cbSize = sizeof info;
        info.uFlags = TTF_TRANSPARENT;
        info.hwnd = hwnd_;
        info.uId = 1;
        info.lpszText = LPSTR_TEXTCALLBACKW;
        GetClientRect(hwnd_, &info.rect);
        SendMessageW(tooltip_, TTM_ADDTOOLW, 0, (LPARAM)&info);
        SendMessageW(tooltip_, TTM_SETMAXTIPWIDTH, 0, 640);
    }
}

void WindowHost::setRootView(View* root) {
    if (root_) root_->window_ = nullptr;
    root_ = root;
    if (root_) {
        root_->window_ = this;
        root_->attach(this);
    }
    setNeedsLayout();
    invalidateAll();
}

Size WindowHost::clientSize() const {
    RECT r{};
    if (hwnd_) GetClientRect(hwnd_, &r);
    return Size((r.right - r.left) / scale(), (r.bottom - r.top) / scale());
}

void WindowHost::show(int command) { ShowWindow(hwnd_, command); }

void WindowHost::performClose() {
    if (!hwnd_) return;
    if (windowShouldClose()) destroy();
}

void WindowHost::destroy() {
    if (hwnd_) DestroyWindow(hwnd_);
}

void WindowHost::setTitle(const std::wstring& title) {
    if (hwnd_) SetWindowTextW(hwnd_, title.c_str());
}

void WindowHost::bringToFront() {
    if (!hwnd_) return;
    if (IsIconic(hwnd_)) ShowWindow(hwnd_, SW_RESTORE);
    SetForegroundWindow(hwnd_);
}

bool WindowHost::isActive() const { return hwnd_ && GetActiveWindow() == hwnd_; }
bool WindowHost::isMinimized() const { return hwnd_ && IsIconic(hwnd_); }
bool WindowHost::isMaximized() const { return hwnd_ && IsZoomed(hwnd_); }

void WindowHost::invalidate(const Rect& r) {
    if (!hwnd_ || r.isEmpty()) return;
    float s = scale();
    RECT pixels{(LONG)std::floor(r.x * s) - 1, (LONG)std::floor(r.y * s) - 1,
                (LONG)std::ceil(r.maxX() * s) + 1, (LONG)std::ceil(r.maxY() * s) + 1};
    InvalidateRect(hwnd_, &pixels, FALSE);
}

void WindowHost::invalidateAll() {
    if (hwnd_) InvalidateRect(hwnd_, nullptr, FALSE);
}

void WindowHost::setNeedsLayout() {
    if (needsLayout_ || !hwnd_) {
        needsLayout_ = true;
        return;
    }
    needsLayout_ = true;
    // Layout runs at the start of the next paint; make sure there is one.
    RECT tiny{0, 0, 1, 1};
    InvalidateRect(hwnd_, &tiny, FALSE);
}

void WindowHost::setNeedsNativeUpdate() {
    needsNativeUpdate_ = true;
    if (hwnd_) {
        RECT tiny{0, 0, 1, 1};
        InvalidateRect(hwnd_, &tiny, FALSE);
    }
}

void WindowHost::displayIfNeeded() {
    if (hwnd_) UpdateWindow(hwnd_);
}

void WindowHost::setFocusedView(View* view) {
    if (view == focused_) {
        if (view && GetFocus() != hwnd_) SetFocus(hwnd_);
        return;
    }
    View* previous = focused_;
    focused_ = view;
    if (previous) previous->focusChanged(false);
    if (view) {
        if (GetFocus() != hwnd_) SetFocus(hwnd_);
        view->focusChanged(true);
    }
}

void WindowHost::viewWillLeave(View* view, bool keepingTree) {
    (void)keepingTree;
    auto inside = [view](View* v) { return v && v->isDescendant(view); };
    bool hoverChanged = false;
    for (View* v : hoverChain_) {
        if (inside(v)) {
            v->hovered_ = false;
            hoverChanged = true;
        }
    }
    if (hoverChanged) {
        hoverChain_.erase(std::remove_if(hoverChain_.begin(), hoverChain_.end(), inside),
                          hoverChain_.end());
    }
    if (inside(pressed_)) pressed_ = nullptr;
    if (inside(focused_)) focused_ = nullptr;
    layoutChangedTree_ = true;
}

Point WindowHost::mouseLocation() const {
    POINT p{};
    GetCursorPos(&p);
    ScreenToClient(hwnd_, &p);
    return Point(p.x / scale(), p.y / scale());
}

POINT WindowHost::screenPoint(Point windowPoint) const {
    POINT p{(LONG)std::lround(windowPoint.x * scale()), (LONG)std::lround(windowPoint.y * scale())};
    ClientToScreen(hwnd_, &p);
    return p;
}

bool WindowHost::isTextInputFocused() const {
    HWND focus = GetFocus();
    return focus && focus != hwnd_ && IsChild(hwnd_, focus);
}

Point WindowHost::pointFromLParam(LPARAM lParam) const {
    return Point(GET_X_LPARAM(lParam) / scale(), GET_Y_LPARAM(lParam) / scale());
}

// ── Painting ───────────────────────────────────────────────────────────────

void WindowHost::updateNatives(View* view) {
    if (!view) return;
    view->updateNative();
    for (View* child : view->subviews_) updateNatives(child);
}

void WindowHost::paint() {
    if (!root_) {
        ValidateRect(hwnd_, nullptr);
        return;
    }
    Size size = clientSize();
    if (root_->frame() != Rect(0, 0, size.w, size.h)) root_->setFrame(Rect(0, 0, size.w, size.h));
    // A layout pass may ask for another (a list sized from its rows): settle
    // within a few rounds.
    for (int round = 0; round < 4 && needsLayout_; ++round) {
        needsLayout_ = false;
        root_->layoutSubtreeIfNeeded();
        layoutChangedTree_ = true;
        needsNativeUpdate_ = true;
    }
    if (needsNativeUpdate_) {
        needsNativeUpdate_ = false;
        updateNatives(root_);
    }
    if (layoutChangedTree_) {
        layoutChangedTree_ = false;
        refreshHover();
    }

    PAINTSTRUCT ps;
    BeginPaint(hwnd_, &ps);
    float s = scale();
    Rect dirty(ps.rcPaint.left / s, ps.rcPaint.top / s, (ps.rcPaint.right - ps.rcPaint.left) / s,
               (ps.rcPaint.bottom - ps.rcPaint.top) / s);
    painting_ = true;
    ID2D1DeviceContext* dc = surface_->begin(dpi_);
    if (dc && surface_->consumeNeedsFullRedraw()) {
        Size full = clientSize();
        dirty = Rect(0, 0, full.w, full.h);
    }
    if (dc) {
        Graphics g(dc, dpi_);
        g.pushClip(dirty);
        g.fillRect(dirty, root_->backgroundColor.isClear() ? Theme::panelBackground
                                                            : root_->backgroundColor);
        drawView(root_, g, dirty);
        g.popClip();
        if (!surface_->end()) InvalidateRect(hwnd_, nullptr, FALSE);
    }
    painting_ = false;
    EndPaint(hwnd_, &ps);
}

void WindowHost::drawView(View* view, Graphics& g, const Rect& dirty) {
    if (view->hidden_) return;
    const Rect& f = view->frame_;
    if (view->clipsToBounds && !f.intersects(dirty)) return;
    g.pushOffset(f.x, f.y);
    if (view->clipsToBounds) g.pushClip(view->bounds());
    if (!view->backgroundColor.isClear()) g.fillRect(view->bounds(), view->backgroundColor);
    view->draw(g);
    Rect local = dirty.offset(-f.x, -f.y);
    for (View* child : view->subviews_) drawView(child, g, local);
    view->drawOver(g);
    if (view->clipsToBounds) g.popClip();
    g.popOffset();
}

// ── Mouse ──────────────────────────────────────────────────────────────────

MouseEvent WindowHost::makeEvent(View* view, Point windowPoint, int clicks) const {
    MouseEvent e;
    e.windowLocation = windowPoint;
    e.location = view ? view->convertFromWindow(windowPoint) : windowPoint;
    e.clickCount = clicks;
    e.shift = GetKeyState(VK_SHIFT) < 0;
    e.control = GetKeyState(VK_CONTROL) < 0;
    e.alt = GetKeyState(VK_MENU) < 0;
    return e;
}

void WindowHost::setHoverChain(std::vector<View*> chain, Point windowPoint) {
    (void)windowPoint;
    // Leaving, innermost first.
    for (View* old : hoverChain_) {
        if (std::find(chain.begin(), chain.end(), old) == chain.end()) {
            old->hovered_ = false;
            old->mouseExited();
        }
    }
    // Entering, outermost first.
    for (auto it = chain.rbegin(); it != chain.rend(); ++it) {
        View* v = *it;
        if (std::find(hoverChain_.begin(), hoverChain_.end(), v) == hoverChain_.end()) {
            v->hovered_ = true;
            v->mouseEntered();
        }
    }
    hoverChain_ = std::move(chain);
}

void WindowHost::mouseMoved(Point p) {
    if (!root_) return;
    View* leaf = root_->hitTest(p);
    std::vector<View*> chain;
    for (View* v = leaf; v; v = v->superview_) chain.push_back(v);
    setHoverChain(chain, p);
    if (leaf) leaf->mouseMoved(makeEvent(leaf, p, 0));
}

void WindowHost::refreshHover() {
    if (!hwnd_ || !root_) return;
    POINT cursor{};
    GetCursorPos(&cursor);
    if (WindowFromPoint(cursor) != hwnd_ || pressed_) {
        if (!pressed_) setHoverChain({}, Point());
        return;
    }
    mouseMoved(mouseLocation());
}

void WindowHost::mouseDown(Point p, int clicks) {
    if (!root_) return;
    View* leaf = root_->hitTest(p);
    // Focus goes to the nearest view that takes it; a click elsewhere leaves
    // the text being typed where it is, as AppKit's first responder does.
    for (View* v = leaf; v; v = v->superview_) {
        if (v->acceptsFocus()) {
            setFocusedView(v);
            break;
        }
    }
    pressed_ = nullptr;
    for (View* v = leaf; v; v = v->superview_) {
        if (v->mouseDown(makeEvent(v, p, clicks))) {
            // The handler may have torn the tree down under the press.
            if (v->window() == this) pressed_ = v;
            break;
        }
    }
    if (pressed_) SetCapture(hwnd_);
}

void WindowHost::mouseUp(Point p) {
    View* target = pressed_;
    pressed_ = nullptr;
    if (GetCapture() == hwnd_) ReleaseCapture();
    if (target) target->mouseUp(makeEvent(target, p, 1));
    mouseMoved(p);
}

void WindowHost::rightMouseDown(Point p) {
    if (!root_) return;
    View* leaf = root_->hitTest(p);
    for (View* v = leaf; v; v = v->superview_) {
        if (v->rightMouseDown(makeEvent(v, p, 1))) break;
    }
}

void WindowHost::wheel(float dx, float dy, Point p) {
    if (!root_) return;
    View* leaf = root_->hitTest(p);
    for (View* v = leaf; v; v = v->superview_) {
        if (v->scrollWheel(dx, dy, makeEvent(v, p, 0))) break;
    }
    mouseMoved(p);
}

void WindowHost::updateTooltip(Point p) {
    if (!tooltip_) return;
    std::wstring text;
    for (View* v : hoverChain_) {
        text = v->tooltipAt(v->convertFromWindow(p));
        if (!text.empty()) break;
    }
    if (text == tooltipText_) return;
    tooltipText_ = text;
    SendMessageW(tooltip_, TTM_POP, 0, 0);
    TOOLINFOW info{};
    info.cbSize = sizeof info;
    info.hwnd = hwnd_;
    info.uId = 1;
    info.lpszText = LPSTR_TEXTCALLBACKW;
    SendMessageW(tooltip_, TTM_UPDATETIPTEXTW, 0, (LPARAM)&info);
}

int WindowHost::nonClientHit(Point p) {
    Size size = clientSize();
    if (!isMaximized() && resizeBorder > 0) {
        float t = resizeBorder, c = 16;
        bool left = p.x < t, right = p.x >= size.w - t;
        bool top = p.y < t, bottom = p.y >= size.h - t;
        bool nearLeft = p.x < c, nearRight = p.x >= size.w - c;
        bool nearTop = p.y < c, nearBottom = p.y >= size.h - c;
        if ((top && nearLeft) || (left && nearTop)) return HTTOPLEFT;
        if ((top && nearRight) || (right && nearTop)) return HTTOPRIGHT;
        if ((bottom && nearLeft) || (left && nearBottom)) return HTBOTTOMLEFT;
        if ((bottom && nearRight) || (right && nearBottom)) return HTBOTTOMRIGHT;
        if (left) return HTLEFT;
        if (right) return HTRIGHT;
        if (top) return HTTOP;
        if (bottom) return HTBOTTOM;
    }
    if (captionButtons && captionButtons->isVisibleInWindow()) {
        Point local = captionButtons->convertFromWindow(p);
        if (captionButtons->bounds().contains(local)) {
            int code = captionButtons->hitCode(local);
            if (code != HTNOWHERE) return code;
        }
    }
    if (root_) {
        View* hit = root_->hitTest(p);
        if (hit && hit->isWindowDragArea(hit->convertFromWindow(p))) return HTCAPTION;
    }
    return HTCLIENT;
}

// ── Keys ───────────────────────────────────────────────────────────────────

namespace {
/// Keys a text field keeps for itself even with Ctrl held.
bool isEditingKey(const KeyEvent& e) {
    if (!e.control && !e.alt) return e.key != VK_ESCAPE;
    if (e.alt) return false;
    switch (e.key) {
    case 'A': case 'C': case 'V': case 'X': case 'Z': case 'Y':
    case VK_LEFT: case VK_RIGHT: case VK_UP: case VK_DOWN: case VK_HOME: case VK_END:
    case VK_BACK: case VK_DELETE: case VK_INSERT: case VK_RETURN:
        return true;
    default:
        return false;
    }
}
}  // namespace

bool WindowHost::preTranslateKey(const MSG& message) {
    if (message.message != WM_KEYDOWN && message.message != WM_SYSKEYDOWN) return false;
    KeyEvent e;
    e.key = (UINT)message.wParam;
    e.shift = GetKeyState(VK_SHIFT) < 0;
    e.control = GetKeyState(VK_CONTROL) < 0;
    e.alt = GetKeyState(VK_MENU) < 0;
    e.repeat = (message.lParam & (1 << 30)) != 0;
    if (message.hwnd != hwnd_) {
        // A native field has the focus: its own keys stay with it.
        if (isEditingKey(e)) return false;
        return handleShortcut(e);
    }
    for (View* v = focused_; v; v = v->superview_) {
        if (v->keyDown(e)) return true;
    }
    return handleShortcut(e);
}

// ── Messages ───────────────────────────────────────────────────────────────

// noexcept: an exception escaping into user32 is lost and takes the process
// with it unrecorded; this way it ends in std::terminate, which ExceptionLog
// writes down.
LRESULT CALLBACK WindowHost::windowProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) noexcept {
    WindowHost* host = fromHwnd(hwnd);
    if (!host) return DefWindowProcW(hwnd, message, wParam, lParam);
    return host->handleMessage(message, wParam, lParam);
}

LRESULT WindowHost::defaultHandling(UINT message, WPARAM wParam, LPARAM lParam) {
    return DefWindowProcW(hwnd_, message, wParam, lParam);
}

LRESULT WindowHost::handleMessage(UINT message, WPARAM wParam, LPARAM lParam) {
    LRESULT menuResult = 0;
    if (Menus::handleOwnerMessage(hwnd_, message, wParam, lParam, &menuResult)) return menuResult;

    switch (message) {
    case WM_NCCALCSIZE:
        if (wParam) {
            if (IsZoomed(hwnd_)) {
                // A maximised window hangs its frame off the screen's edges;
                // the content must not.
                auto* params = reinterpret_cast<NCCALCSIZE_PARAMS*>(lParam);
                UINT dpi = GetDpiForWindow(hwnd_);
                int frameX = GetSystemMetricsForDpi(SM_CXFRAME, dpi)
                    + GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
                int frameY = GetSystemMetricsForDpi(SM_CYFRAME, dpi)
                    + GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
                params->rgrc[0].left += frameX;
                params->rgrc[0].right -= frameX;
                params->rgrc[0].top += frameY;
                params->rgrc[0].bottom -= frameY;
            }
            return 0;
        }
        break;
    case WM_NCACTIVATE:
        if (root_) invalidateAll();
        return DefWindowProcW(hwnd_, message, wParam, -1);
    case WM_NCHITTEST: {
        POINT screen{GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)};
        ScreenToClient(hwnd_, &screen);
        return nonClientHit(Point(screen.x / scale(), screen.y / scale()));
    }
    case WM_NCMOUSEMOVE: {
        int code = (int)wParam;
        bool button = code == HTMINBUTTON || code == HTMAXBUTTON || code == HTCLOSE;
        if (captionButtons) captionButtons->setHot(button ? code : HTNOWHERE);
        if (!trackingNonClientLeave_) {
            TRACKMOUSEEVENT track{sizeof track, TME_LEAVE | TME_NONCLIENT, hwnd_, 0};
            TrackMouseEvent(&track);
            trackingNonClientLeave_ = true;
        }
        if (!pressed_) setHoverChain({}, Point());
        if (button) return 0;
        break;
    }
    case WM_NCMOUSELEAVE:
        trackingNonClientLeave_ = false;
        if (captionButtons) {
            captionButtons->setHot(HTNOWHERE);
            captionButtons->setPressed(HTNOWHERE);
        }
        break;
    case WM_NCLBUTTONDOWN:
    case WM_NCLBUTTONDBLCLK: {
        int code = (int)wParam;
        if (code == HTMINBUTTON || code == HTMAXBUTTON || code == HTCLOSE) {
            if (captionButtons) captionButtons->setPressed(code);
            return 0;
        }
        break;
    }
    case WM_NCLBUTTONUP: {
        int code = (int)wParam;
        if (code == HTMINBUTTON || code == HTMAXBUTTON || code == HTCLOSE) {
            bool fire = captionButtons && captionButtons->pressed() == code;
            if (captionButtons) captionButtons->setPressed(HTNOWHERE);
            if (fire) {
                if (code == HTMINBUTTON) PostMessageW(hwnd_, WM_SYSCOMMAND, SC_MINIMIZE, 0);
                else if (code == HTMAXBUTTON)
                    PostMessageW(hwnd_, WM_SYSCOMMAND, IsZoomed(hwnd_) ? SC_RESTORE : SC_MAXIMIZE, 0);
                else PostMessageW(hwnd_, WM_SYSCOMMAND, SC_CLOSE, 0);
            }
            return 0;
        }
        break;
    }
    case WM_ERASEBKGND:
        return 1;
    case WM_PAINT:
        paint();
        return 0;
    case WM_SIZE:
        if (wParam == SIZE_MINIMIZED) {
            windowDidMinimize();
            return 0;
        }
        if (surface_) surface_->resize();
        needsLayout_ = true;
        needsNativeUpdate_ = true;
        InvalidateRect(hwnd_, nullptr, FALSE);
        if (tooltip_) {
            TOOLINFOW info{};
            info.cbSize = sizeof info;
            info.hwnd = hwnd_;
            info.uId = 1;
            GetClientRect(hwnd_, &info.rect);
            SendMessageW(tooltip_, TTM_NEWTOOLRECTW, 0, (LPARAM)&info);
        }
        windowDidResize();
        return 0;
    case WM_DPICHANGED: {
        dpi_ = (float)HIWORD(wParam);
        auto* suggested = reinterpret_cast<RECT*>(lParam);
        SetWindowPos(hwnd_, nullptr, suggested->left, suggested->top,
                     suggested->right - suggested->left, suggested->bottom - suggested->top,
                     SWP_NOZORDER | SWP_NOACTIVATE);
        std::function<void(View*)> notify = [&](View* v) {
            v->dpiChanged();
            for (View* child : v->subviews_) notify(child);
        };
        if (root_) notify(root_);
        needsLayout_ = true;
        needsNativeUpdate_ = true;
        InvalidateRect(hwnd_, nullptr, FALSE);
        return 0;
    }
    case WM_GETMINMAXINFO: {
        auto* info = reinterpret_cast<MINMAXINFO*>(lParam);
        info->ptMinTrackSize.x = (LONG)(minimumSize.w * scale());
        info->ptMinTrackSize.y = (LONG)(minimumSize.h * scale());
        return 0;
    }
    case WM_SETCURSOR:
        if (LOWORD(lParam) == HTCLIENT && root_) {
            Point p = mouseLocation();
            View* view = pressed_ ? pressed_ : root_->hitTest(p);
            Cursor cursor = view ? view->cursorAt(view->convertFromWindow(p)) : Cursor::Arrow;
            LPCWSTR id = IDC_ARROW;
            switch (cursor) {
            case Cursor::Hand: id = IDC_HAND; break;
            case Cursor::ResizeLeftRight: id = IDC_SIZEWE; break;
            case Cursor::ResizeUpDown: id = IDC_SIZENS; break;
            case Cursor::IBeam: id = IDC_IBEAM; break;
            default: break;
            }
            SetCursor(LoadCursorW(nullptr, id));
            return TRUE;
        }
        break;
    case WM_MOUSEMOVE: {
        Point p = pointFromLParam(lParam);
        if (!trackingLeave_) {
            TRACKMOUSEEVENT track{sizeof track, TME_LEAVE, hwnd_, 0};
            TrackMouseEvent(&track);
            trackingLeave_ = true;
        }
        if (captionButtons) captionButtons->setHot(HTNOWHERE);
        if (tooltip_) {
            MSG relay{hwnd_, message, wParam, lParam};
            SendMessageW(tooltip_, TTM_RELAYEVENT, 0, (LPARAM)&relay);
        }
        if (pressed_) {
            pressed_->mouseDragged(makeEvent(pressed_, p, 1));
        } else {
            mouseMoved(p);
        }
        updateTooltip(p);
        return 0;
    }
    case WM_MOUSELEAVE:
        trackingLeave_ = false;
        if (!pressed_) setHoverChain({}, Point());
        updateTooltip(Point(-1, -1));
        return 0;
    case WM_LBUTTONDOWN:
    case WM_LBUTTONDBLCLK: {
        if (tooltip_) {
            MSG relay{hwnd_, message, wParam, lParam};
            SendMessageW(tooltip_, TTM_RELAYEVENT, 0, (LPARAM)&relay);
        }
        mouseDown(pointFromLParam(lParam), message == WM_LBUTTONDBLCLK ? 2 : 1);
        return 0;
    }
    case WM_LBUTTONUP:
        mouseUp(pointFromLParam(lParam));
        return 0;
    case WM_CAPTURECHANGED:
        if ((HWND)lParam != hwnd_ && pressed_) {
            View* target = pressed_;
            pressed_ = nullptr;
            target->mouseUp(makeEvent(target, mouseLocation(), 1));
        }
        return 0;
    case WM_RBUTTONUP:
        rightMouseDown(pointFromLParam(lParam));
        return 0;
    case WM_MOUSEWHEEL:
    case WM_MOUSEHWHEEL: {
        POINT screen{GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)};
        ScreenToClient(hwnd_, &screen);
        Point p(screen.x / scale(), screen.y / scale());
        float notches = GET_WHEEL_DELTA_WPARAM(wParam) / (float)WHEEL_DELTA;
        UINT lines = 3;
        SystemParametersInfoW(SPI_GETWHEELSCROLLLINES, 0, &lines, 0);
        float step = notches * (float)std::max<UINT>(1, std::min<UINT>(lines, 20)) * 19.0f;
        if (message == WM_MOUSEHWHEEL) wheel(step, 0, p);
        else if (GetKeyState(VK_SHIFT) < 0) wheel(-step, 0, p);
        else wheel(0, -step, p);
        return 0;
    }
    case WM_NOTIFY: {
        auto* header = reinterpret_cast<NMHDR*>(lParam);
        if (header->hwndFrom == tooltip_ && header->code == TTN_GETDISPINFOW) {
            auto* info = reinterpret_cast<NMTTDISPINFOW*>(lParam);
            info->lpszText = tooltipText_.empty() ? const_cast<wchar_t*>(L"")
                                                  : tooltipText_.data();
            return 0;
        }
        break;
    }
    case WM_COMMAND:
        if (lParam) {
            if (auto* provider = static_cast<NativeColorProvider*>(
                    GetPropW((HWND)lParam, kNativeColorProperty))) {
                provider->controlCommand(HIWORD(wParam));
                return 0;
            }
        }
        break;
    case WM_CTLCOLOREDIT:
    case WM_CTLCOLORSTATIC: {
        if (auto* provider = static_cast<NativeColorProvider*>(
                GetPropW((HWND)lParam, kNativeColorProperty))) {
            return (LRESULT)provider->controlColor((HDC)wParam);
        }
        break;
    }
    case WM_ACTIVATE:
        invalidateAll();
        windowDidActivate(LOWORD(wParam) != WA_INACTIVE);
        return 0;
    case WM_CLOSE:
        performClose();
        return 0;
    case WM_DESTROY:
        if (tooltip_) {
            DestroyWindow(tooltip_);
            tooltip_ = nullptr;
        }
        windowWillClose();
        return 0;
    case WM_NCDESTROY: {
        RemovePropW(hwnd_, kHostProperty);
        HWND gone = hwnd_;
        hwnd_ = nullptr;
        return DefWindowProcW(gone, message, wParam, lParam);
    }
    default:
        break;
    }
    return DefWindowProcW(hwnd_, message, wParam, lParam);
}

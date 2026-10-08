#include "popover.h"

#include "theme.h"

#include <dwmapi.h>

namespace {
std::vector<PopupWindow*>& openPopups() {
    static auto* list = new std::vector<PopupWindow*>();
    return *list;
}

RECT workAreaFor(const RECT& anchor) {
    HMONITOR monitor = MonitorFromRect(&anchor, MONITOR_DEFAULTTONEAREST);
    MONITORINFO info{sizeof info};
    GetMonitorInfoW(monitor, &info);
    return info.rcWork;
}

float dpiScaleAt(const RECT& anchor) {
    HMONITOR monitor = MonitorFromRect(&anchor, MONITOR_DEFAULTTONEAREST);
    UINT dx = 96, dy = 96;
    using GetDpiForMonitorFn = HRESULT(WINAPI*)(HMONITOR, int, UINT*, UINT*);
    static auto fn = reinterpret_cast<GetDpiForMonitorFn>(
        reinterpret_cast<void*>(GetProcAddress(LoadLibraryW(L"shcore.dll"), "GetDpiForMonitor")));
    if (fn) fn(monitor, 0, &dx, &dy);
    return dx / 96.0f;
}
}  // namespace

// ── PopupWindow ────────────────────────────────────────────────────────────

PopupWindow::PopupWindow() {
    RECT frame{0, 0, 10, 10};
    createWindow(L"", WS_POPUP, WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TOPMOST, nullptr, frame);
    resizeBorder = 0;
    // Rounded corners and a shadow, as a menu has on Windows 11.
    DWORD corner = 3;  // DWMWCP_ROUNDSMALL
    DwmSetWindowAttribute(hwnd(), 33 /* DWMWA_WINDOW_CORNER_PREFERENCE */, &corner, sizeof corner);
}

PopupWindow::~PopupWindow() {
    auto& list = openPopups();
    list.erase(std::remove(list.begin(), list.end(), this), list.end());
    setRootView(nullptr);
    if (hwnd()) DestroyWindow(hwnd());
}

void PopupWindow::setContent(View* content) {
    content_ = content;
    setRootView(content);
}

void PopupWindow::showAt(HWND owner, const RECT& screen) {
    if (owner) SetWindowLongPtrW(hwnd(), GWLP_HWNDPARENT, (LONG_PTR)owner);
    SetWindowPos(hwnd(), HWND_TOPMOST, screen.left, screen.top, screen.right - screen.left,
                 screen.bottom - screen.top, SWP_NOACTIVATE | SWP_SHOWWINDOW);
    setNeedsLayout();
    invalidateAll();
    if (!open_) {
        open_ = true;
        openPopups().push_back(this);
    }
}

void PopupWindow::close() {
    if (!open_) return;
    open_ = false;
    auto& list = openPopups();
    list.erase(std::remove(list.begin(), list.end(), this), list.end());
    ShowWindow(hwnd(), SW_HIDE);
    if (onClose) onClose();
}

bool PopupWindow::containsCursor() const {
    if (!open_) return false;
    POINT p;
    GetCursorPos(&p);
    RECT r;
    GetWindowRect(hwnd(), &r);
    InflateRect(&r, 6, 6);
    return PtInRect(&r, p);
}

LRESULT PopupWindow::handleMessage(UINT message, WPARAM wParam, LPARAM lParam) {
    if (message == WM_MOUSEACTIVATE) return MA_NOACTIVATE;
    if (message == WM_CLOSE) {
        close();
        return 0;
    }
    return WindowHost::handleMessage(message, wParam, lParam);
}

void PopupWindow::preTranslate(const MSG& m) {
    auto& list = openPopups();
    if (list.empty()) return;
    bool press = m.message == WM_LBUTTONDOWN || m.message == WM_RBUTTONDOWN || m.message == WM_MBUTTONDOWN
        || m.message == WM_NCLBUTTONDOWN || m.message == WM_NCRBUTTONDOWN;
    bool escape = m.message == WM_KEYDOWN && m.wParam == VK_ESCAPE;
    if (!press && !escape) return;
    HWND root = GetAncestor(m.hwnd, GA_ROOT);
    std::vector<PopupWindow*> snapshot = list;
    for (PopupWindow* popup : snapshot) {
        if (!popup->transient && !escape) continue;
        if (press && root == popup->hwnd()) continue;
        popup->close();
    }
}

void PopupWindow::closeAll() {
    std::vector<PopupWindow*> snapshot = openPopups();
    for (PopupWindow* popup : snapshot) popup->close();
}

// ── LinkCard ───────────────────────────────────────────────────────────────

struct LinkCard::Label : public View {
    std::wstring text;
    std::function<void()> onClick;
    Font font() const { return Theme::uiFont(11.5f); }
    Size fittingSize() const {
        Font f = font();
        return Size(std::min(std::ceil(Text::width(text, f)) + padding * 2, maximumWidth),
                    std::ceil(f.lineHeight()) + padding * 2);
    }
    void draw(Graphics& g) override {
        Rect b = bounds();
        g.fillRoundedRect(b.inset(0.5f, 0.5f), 6, Theme::panelBackground);
        g.strokeRoundedRect(b.inset(0.5f, 0.5f), 6, Theme::border, 1);
        Rect inner = b.inset(padding, padding);
        Font f = font();
        g.text(text, f, Theme::blue, inner);
        float width = std::min(Text::width(text, f), inner.w);
        float baseline = Text::centeredBaseline(f, inner);
        g.fillRect(Rect(inner.x, std::round(baseline + 1.5f), width, 1), Theme::blue);
    }
    bool mouseDown(const MouseEvent&) override {
        if (onClick) onClick();
        return true;
    }
    Cursor cursorAt(Point) override { return Cursor::Hand; }
};

LinkCard::LinkCard() : window_(std::make_unique<PopupWindow>()), label_(std::make_unique<Label>()) {
    window_->transient = false;
    label_->backgroundColor = Theme::panelBackground;
    label_->onClick = [this] {
        if (onOpen) onOpen();
    };
    window_->setContent(label_.get());
}

LinkCard::~LinkCard() { window_->setContent(nullptr); }

void LinkCard::show(const std::wstring& destination, const RECT& anchor, HWND owner) {
    label_->text = destination;
    float s = dpiScaleAt(anchor);
    Size size = label_->fittingSize();
    int w = (int)std::lround(size.w * s), h = (int)std::lround(size.h * s);
    int g = (int)std::lround(gap * s);
    RECT work = workAreaFor(anchor);
    // Above the text, left edges aligned, kept on the screen it is on.
    int x = std::clamp((int)anchor.left, (int)work.left + 4, std::max((int)work.left + 4, (int)work.right - w - 4));
    int y = anchor.top - g - h;
    if (y < work.top) y = anchor.bottom + g;
    y = std::max((int)work.top + 4, y);
    window_->showAt(owner, RECT{x, y, x + w, y + h});
    label_->setNeedsDisplay();
}

void LinkCard::close() { window_->close(); }
bool LinkCard::isVisible() const { return window_->isOpen(); }
bool LinkCard::containsCursor() const { return window_->containsCursor(); }

// ── GitChangePopover ───────────────────────────────────────────────────────

struct GitChangePopover::Body : public ScrollArea {
    struct Line {
        std::wstring marker;
        std::wstring text;
        Color color;
        bool note = false;
    };
    std::wstring heading;
    std::vector<Line> lines;
    bool canRevert = false;
    std::function<void()> onRevert;
    bool revertHot = false;

    float rowHeight() const { return std::ceil(Theme::editorFont().lineHeight()) + 2; }
    float footer() const { return canRevert ? 22 + padding : 0; }
    float contentHeight() const { return padding * 2 + rowHeight() * (1 + lines.size()); }
    float naturalWidth() const {
        float widest = Text::width(heading, Theme::uiFont(10.5f));
        Font code = Theme::editorFont();
        for (auto& l : lines) {
            float w = Text::width(l.marker + L" ", code)
                + Text::width(l.text, l.note ? Theme::uiFont(10.5f) : code);
            widest = std::max(widest, w);
        }
        return widest;
    }
    Rect revertRect() const {
        Rect b = bounds();
        float w = Text::width(L"Revert", Theme::uiFont(11)) + 4;
        return Rect(padding, b.h - padding - 22 + (canRevert ? 0 : 0) + contentOffset().y, w, 22);
    }

    void drawContent(Graphics& g, const Rect& visible) override {
        float row = rowHeight();
        float y = padding;
        Font code = Theme::editorFont();
        g.text(heading, Theme::uiFont(10.5f), Theme::dimText, Rect(padding, y, bounds().w - padding * 2, row));
        y += row;
        for (auto& l : lines) {
            float markerWidth = Text::width(l.marker + L" ", code);
            g.text(l.marker, code, l.color, Rect(padding, y, markerWidth, row), LineBreak::Clipping);
            g.text(l.text, l.note ? Theme::uiFont(10.5f) : code, l.note ? Theme::dimText : l.color,
                   Rect(padding + markerWidth, y, bounds().w - padding * 2 - markerWidth, row));
            y += row;
        }
    }
    void drawOver(Graphics& g) override {
        ScrollArea::drawOver(g);
        if (!canRevert) return;
        Rect b = bounds();
        Rect r(padding, b.h - padding - 22, Text::width(L"Revert", Theme::uiFont(11)) + 4, 22);
        g.fillRect(Rect(0, b.h - footer(), b.w, footer()), Theme::editorBackground);
        g.text(L"Revert", Theme::uiFont(11), revertHot ? Theme::foreground : Theme::blue, r);
    }
    bool contentMouseDown(const MouseEvent& e, Point) override {
        if (!canRevert) return false;
        Rect b = bounds();
        Rect r(padding, b.h - padding - 22, Text::width(L"Revert", Theme::uiFont(11)) + 4, 22);
        if (r.contains(e.location)) {
            if (onRevert) onRevert();
            return true;
        }
        return false;
    }
    void contentMouseMoved(Point) override {
        Point p = window() ? convertFromWindow(window()->mouseLocation()) : Point();
        Rect b = bounds();
        Rect r(padding, b.h - padding - 22, Text::width(L"Revert", Theme::uiFont(11)) + 4, 22);
        bool hot = canRevert && r.contains(p);
        if (hot != revertHot) {
            revertHot = hot;
            setNeedsDisplay();
        }
    }
    Cursor cursorAt(Point p) override {
        Rect b = bounds();
        Rect r(padding, b.h - padding - 22, Text::width(L"Revert", Theme::uiFont(11)) + 4, 22);
        return canRevert && r.contains(p) ? Cursor::Hand : Cursor::Arrow;
    }
};

GitChangePopover::GitChangePopover(const GitLineChanges::Change& change, bool canRevert)
    : window_(std::make_unique<PopupWindow>()), body_(std::make_unique<Body>()) {
    body_->backgroundColor = Theme::editorBackground;
    body_->canRevert = canRevert;
    body_->onRevert = [this] {
        if (onRevert) onRevert();
    };
    auto range = [&](const wchar_t* single, const wchar_t* many) {
        if (change.first == change.last) return std::wstring(single) + std::to_wstring(change.first);
        return std::wstring(many) + std::to_wstring(change.first) + L"–" + std::to_wstring(change.last);
    };
    switch (change.kind) {
    case GitLineChanges::Change::Kind::Added:
        body_->heading = range(L"Line ", L"Lines ") + L" added";
        break;
    case GitLineChanges::Change::Kind::Modified:
        body_->heading = range(L"Line ", L"Lines ") + L" modified";
        break;
    case GitLineChanges::Change::Kind::Deleted:
        body_->heading = change.removed.size() == 1
            ? L"1 line deleted above line " + std::to_wstring(change.first)
            : std::to_wstring(change.removed.size()) + L" lines deleted above line " + std::to_wstring(change.first);
        break;
    }
    auto append = [&](const wchar_t* marker, const std::string& line, const Color& colour) {
        Body::Line l;
        l.marker = marker;
        l.color = colour;
        bool blank = trim(line).empty();
        l.note = blank;
        l.text = blank ? (line.empty() ? L"(blank line)" : L"(whitespace only)") : replaceAll(W(line), L"\t", L"    ");
        body_->lines.push_back(l);
    };
    for (auto& line : change.removed) append(L"-", line, Theme::diffRemovedText);
    for (auto& line : change.added) append(L"+", line, Theme::diffAddedText);
    window_->setContent(body_.get());
}

GitChangePopover::~GitChangePopover() { window_->setContent(nullptr); }

void GitChangePopover::show(const RECT& anchor, HWND owner) {
    float s = dpiScaleAt(anchor);
    float width = std::min(std::max(minimumWidth, std::ceil(body_->naturalWidth()) + padding * 2 + 4), 720.0f);
    float height = std::min(body_->contentHeight(), 320.0f) + body_->footer();
    body_->setContentSize(Size(width, body_->contentHeight() + body_->footer()));
    int w = (int)std::lround(width * s), h = (int)std::lround(height * s);
    RECT work = workAreaFor(anchor);
    int x = anchor.right + (int)std::lround(6 * s);
    if (x + w > work.right) x = std::max((int)work.left, (int)anchor.left - w - (int)std::lround(6 * s));
    int y = (anchor.top + anchor.bottom) / 2 - h / 2;
    y = std::clamp(y, (int)work.top + 4, std::max((int)work.top + 4, (int)work.bottom - h - 4));
    window_->showAt(owner, RECT{x, y, x + w, y + h});
}

void GitChangePopover::close() { window_->close(); }
bool GitChangePopover::isOpen() const { return window_->isOpen(); }

#include "dialog.h"

#include "menu.h"
#include "theme.h"

#include <wincodec.h>

namespace {

/// The app's icon as a bitmap on the shared device, for the alert's corner.
ID2D1Bitmap* appIconBitmap() {
    static Com<ID2D1Bitmap1> cached;
    static uint64_t generation = 0;
    if (cached && generation == Render::generation()) return cached.get();
    cached.reset();
    generation = Render::generation();
    HICON icon = (HICON)LoadImageW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(1), IMAGE_ICON, 256,
                                   256, LR_DEFAULTCOLOR);
    if (!icon) return nullptr;
    Com<IWICImagingFactory> wic;
    if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                                __uuidof(IWICImagingFactory), reinterpret_cast<void**>(wic.put())))) {
        DestroyIcon(icon);
        return nullptr;
    }
    Com<IWICBitmap> bitmap;
    Com<IWICFormatConverter> converter;
    if (SUCCEEDED(wic->CreateBitmapFromHICON(icon, bitmap.put()))
        && SUCCEEDED(wic->CreateFormatConverter(converter.put()))
        && SUCCEEDED(converter->Initialize(bitmap.get(), GUID_WICPixelFormat32bppPBGRA,
                                           WICBitmapDitherTypeNone, nullptr, 0,
                                           WICBitmapPaletteTypeMedianCut))) {
        if (auto* scratch = Render::scratchContext()) {
            scratch->CreateBitmapFromWicBitmap(converter.get(), nullptr, cached.put());
        }
    }
    DestroyIcon(icon);
    return cached.get();
}

class AlertWindow;

class AlertRoot : public View {
public:
    explicit AlertRoot(AlertWindow* owner) : owner_(owner) {}
    void draw(Graphics& g) override;
    bool isWindowDragArea(Point) override { return true; }
    bool warning = false;
private:
    AlertWindow* owner_;
};

class AlertWindow : public WindowHost {
public:
    AlertWindow(Alert& alert) : alert_(alert), root_(this) {
        root_.backgroundColor = Theme::menuBackground;
        root_.warning = alert.style == Alert::Style::Warning;
        message_.text = alert.messageText;
        message_.font = Theme::uiBoldFont(12.5f);
        message_.color = Theme::selectedControlText;
        message_.wraps = true;
        detail_.text = alert.informativeText;
        detail_.font = Theme::uiFont(11);
        detail_.color = Theme::foreground;
        detail_.wraps = true;
        root_.addSubview(&message_);
        root_.addSubview(&detail_);
        if (alert.accessory) root_.addSubview(alert.accessory);
        std::vector<std::wstring> titles = alert.buttons;
        if (titles.empty()) titles.push_back(L"OK");
        for (size_t i = 0; i < titles.size(); ++i) {
            auto button = std::make_unique<PushButton>();
            button->title = titles[i];
            button->isDefault = i == 0;
            button->font = Theme::uiFont(11.5f);
            button->onClick = [this, i] { finish((int)i); };
            root_.addSubview(button.get());
            buttons_.push_back(std::move(button));
        }
        resizeBorder = 0;
    }

    ~AlertWindow() override {
        if (alert_.accessory) alert_.accessory->removeFromSuperview();
        setRootView(nullptr);
    }

    static constexpr float kWidth = 440;
    static constexpr float kPadding = 20;
    static constexpr float kIcon = 44;

    float textX() const { return kPadding + kIcon + 16; }
    float textWidth() const { return kWidth - textX() - kPadding; }

    float layoutContent() {
        float y = kPadding;
        float w = textWidth();
        float h = message_.fittingHeight(w);
        message_.setFrame(Rect(textX(), y, w, h));
        y += h + 8;
        if (!detail_.text.empty()) {
            float dh = detail_.fittingHeight(w);
            detail_.setFrame(Rect(textX(), y, w, dh));
            y += dh + 8;
        }
        y = std::max(y, kPadding + kIcon + 8);
        if (alert_.accessory) {
            alert_.accessory->setFrame(Rect(textX(), y + 4, alert_.accessorySize.w,
                                            alert_.accessorySize.h));
            y += alert_.accessorySize.h + 16;
        }
        y += 6;
        float x = kWidth - kPadding;
        for (auto it = buttons_.rbegin(); it != buttons_.rend(); ++it) {
            float bw = std::max(80.0f, (*it)->intrinsicWidth());
            x -= bw;
            (*it)->setFrame(Rect(x, y, bw, 26));
            x -= 8;
        }
        return y + 26 + kPadding;
    }

    void open(HWND owner) {
        float height = layoutContent();
        RECT ownerRect{};
        if (owner) GetWindowRect(owner, &ownerRect);
        else SystemParametersInfoW(SPI_GETWORKAREA, 0, &ownerRect, 0);
        UINT dpi = owner ? GetDpiForWindow(owner) : GetDpiForSystem();
        auto place = [&](float scale) {
            int w = (int)(kWidth * scale), h = (int)(height * scale);
            int x = ownerRect.left + ((ownerRect.right - ownerRect.left) - w) / 2;
            int y = ownerRect.top
                + std::max<int>(0, std::min<int>((int)(120 * scale),
                                                 ((ownerRect.bottom - ownerRect.top) - h) / 2));
            return RECT{x, y, x + w, y + h};
        };
        RECT frame = place(dpi / 96.0f);
        createWindow(alert_.messageText, WS_POPUP | WS_CAPTION | WS_SYSMENU, 0, owner, frame);
        // The window may have landed on a monitor of another scale.
        RECT placed = place(scale());
        SetWindowPos(hwnd(), nullptr, placed.left, placed.top, placed.right - placed.left,
                     placed.bottom - placed.top, SWP_NOZORDER | SWP_NOACTIVATE);
        setRootView(&root_);
        show(SW_SHOW);
        SetForegroundWindow(hwnd());
        // Laid out and painted now, so the field to focus is on screen.
        displayIfNeeded();
        if (alert_.initialFocus) {
            alert_.initialFocus->updateNative();
            alert_.initialFocus->focus();
        } else {
            SetFocus(hwnd());
        }
    }

    void finish(int index) {
        if (done_) return;
        done_ = true;
        result_ = index;
    }

    int cancelIndex() const {
        for (size_t i = 0; i < buttons_.size(); ++i) {
            if (buttons_[i]->title == L"Cancel") return (int)i;
        }
        return buttons_.size() == 1 ? 0 : -1;
    }

    bool done() const { return done_; }
    int result() const { return result_; }

protected:
    bool handleShortcut(const KeyEvent& e) override {
        if (e.key == VK_RETURN && !e.control && !e.alt) {
            finish(0);
            return true;
        }
        if (e.key == VK_ESCAPE) {
            finish(cancelIndex());
            return true;
        }
        return false;
    }
    bool windowShouldClose() override {
        finish(cancelIndex());
        return false;
    }

private:
    Alert& alert_;
    AlertRoot root_;
    Label message_;
    Label detail_;
    std::vector<std::unique_ptr<PushButton>> buttons_;
    bool done_ = false;
    int result_ = -1;
};

void AlertRoot::draw(Graphics& g) {
    Rect b = bounds();
    g.strokeRect(b, Theme::border, 1);
    Rect icon(AlertWindow::kPadding, AlertWindow::kPadding, AlertWindow::kIcon, AlertWindow::kIcon);
    if (ID2D1Bitmap* bitmap = appIconBitmap()) g.drawBitmap(bitmap, icon);
    if (warning) {
        // The caution badge NSAlert sets on the app icon for a warning.
        Rect badge(icon.maxX() - 20, icon.maxY() - 18, 20, 18);
        g.polyline({Point(badge.midX(), badge.y), Point(badge.maxX(), badge.maxY()),
                    Point(badge.x, badge.maxY())},
                   Theme::yellow, 2.0f, true, true);
        Com<ID2D1PathGeometry> path;
        Render::d2d()->CreatePathGeometry(path.put());
        Com<ID2D1GeometrySink> sink;
        path->Open(sink.put());
        sink->BeginFigure(D2D1::Point2F(badge.midX(), badge.y), D2D1_FIGURE_BEGIN_FILLED);
        sink->AddLine(D2D1::Point2F(badge.maxX(), badge.maxY()));
        sink->AddLine(D2D1::Point2F(badge.x, badge.maxY()));
        sink->EndFigure(D2D1_FIGURE_END_CLOSED);
        sink->Close();
        g.context()->FillGeometry(path.get(), g.brush(Theme::yellow));
        g.line(Point(badge.midX(), badge.y + 6), Point(badge.midX(), badge.maxY() - 6),
               Color::hex(0x1b1f29), 2.0f, true);
        g.fillEllipse(Rect(badge.midX() - 1.2f, badge.maxY() - 4.2f, 2.4f, 2.4f), Color::hex(0x1b1f29));
    }
}

}  // namespace

int Alert::runModal(HWND owner) {
    if (owner) owner = GetAncestor(owner, GA_ROOT);
    AlertWindow window(*this);
    if (owner) EnableWindow(owner, FALSE);
    window.open(owner);
    MSG message;
    bool quit = false;
    int quitCode = 0;
    while (!window.done()) {
        if (!GetMessageW(&message, nullptr, 0, 0)) {
            quit = true;
            quitCode = (int)message.wParam;
            break;
        }
        if (WindowHost* host = WindowHost::fromHwnd(GetAncestor(message.hwnd, GA_ROOT))) {
            if (host == &window && window.preTranslateKey(message)) continue;
        }
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    if (owner) {
        EnableWindow(owner, TRUE);
        SetActiveWindow(owner);
    }
    int result = window.result();
    window.destroy();
    if (quit) PostQuitMessage(quitCode);
    return result;
}

void Alert::inform(HWND owner, const std::wstring& message, const std::wstring& detail, Style style) {
    Alert alert;
    alert.messageText = message;
    alert.informativeText = detail;
    alert.style = style;
    alert.buttons = {L"OK"};
    alert.runModal(owner);
}

// ── PopupButton ────────────────────────────────────────────────────────────

void PopupButton::draw(Graphics& g) {
    Rect b = bounds().inset(0.5f, 0.5f);
    g.fillRoundedRect(b, 5, hovered_ ? Color::hex(0x323845) : Color::hex(0x2a2f3a));
    Font f = Theme::uiFont(11.5f);
    g.text(selectedTitle(), f, Theme::selectedControlText, Rect(10, 0, b.w - 34, bounds().h));
    float cx = b.maxX() - 13, cy = bounds().midY();
    g.polyline({Point(cx - 3.5f, cy - 1.5f), Point(cx, cy + 2), Point(cx + 3.5f, cy - 1.5f)},
               Theme::foreground, 1.3f);
}

bool PopupButton::mouseDown(const MouseEvent&) {
    WindowHost* host = window();
    if (!host || items.empty()) return true;
    Menu menu;
    menu.titleSize = 11.5f;
    for (size_t i = 0; i < items.size(); ++i) {
        auto& item = menu.add(items[i], [this, i] {
            selected = (int)i;
            setNeedsDisplay();
            if (onChange) onChange((int)i);
        });
        item.checked = (int)i == selected;
    }
    POINT screen = host->screenPoint(convertToWindow(Point(0, bounds().h)));
    menu.popup(host->hwnd(), screen);
    return false;
}

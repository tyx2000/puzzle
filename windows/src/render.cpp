#include "render.h"

#include <list>

// ── Factories and the device ───────────────────────────────────────────────

namespace {

Com<ID2D1Factory1> gD2D;
Com<IDWriteFactory> gDWrite;
Com<ID3D11Device> gD3D;
Com<ID2D1Device> gDevice;
Com<ID2D1DeviceContext> gScratch;
uint64_t gGeneration = 1;

bool createDevice() {
    gScratch.reset();
    gDevice.reset();
    gD3D.reset();
    D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0,
                                  D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0,
                                  D3D_FEATURE_LEVEL_9_3,  D3D_FEATURE_LEVEL_9_2,
                                  D3D_FEATURE_LEVEL_9_1};
    UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
    HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags, levels,
                                   ARRAYSIZE(levels), D3D11_SDK_VERSION, gD3D.put(), nullptr,
                                   nullptr);
    if (FAILED(hr)) {
        // No usable GPU (a VM, a remote session): the software rasteriser.
        hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, flags, levels,
                               ARRAYSIZE(levels), D3D11_SDK_VERSION, gD3D.put(), nullptr,
                               nullptr);
    }
    if (FAILED(hr)) return false;
    auto dxgi = gD3D.as<IDXGIDevice>();
    if (!dxgi || FAILED(gD2D->CreateDevice(dxgi.get(), gDevice.put()))) return false;
    gDevice->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, gScratch.put());
    ++gGeneration;
    return true;
}

}  // namespace

namespace Render {

bool initialize() {
    D2D1_FACTORY_OPTIONS options{};
    if (FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, __uuidof(ID2D1Factory1),
                                 &options, reinterpret_cast<void**>(gD2D.put())))) {
        return false;
    }
    if (FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
                                   reinterpret_cast<IUnknown**>(gDWrite.put())))) {
        return false;
    }
    return createDevice();
}

ID2D1Factory1* d2d() { return gD2D.get(); }
ID3D11Device* d3dDevice() { return gD3D.get(); }
IDWriteFactory* dwrite() { return gDWrite.get(); }
ID2D1Device* device() { return gDevice.get(); }
uint64_t generation() { return gGeneration; }
ID2D1DeviceContext* scratchContext() { return gScratch.get(); }

void deviceLost() { createDevice(); }

}  // namespace Render

// ── Surface ────────────────────────────────────────────────────────────────

Surface::Surface(HWND hwnd) : hwnd_(hwnd) {}

Surface::~Surface() { release(); }

void Surface::release() {
    if (context_) context_->SetTarget(nullptr);
    target_.reset();
    swapChain_.reset();
    context_.reset();
}

bool Surface::create() {
    release();
    if (!Render::device()) return false;
    if (FAILED(Render::device()->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE,
                                                     context_.put()))) {
        return false;
    }
    auto dxgiDevice = gD3D.as<IDXGIDevice>();
    Com<IDXGIAdapter> adapter;
    if (!dxgiDevice || FAILED(dxgiDevice->GetAdapter(adapter.put()))) return false;
    Com<IDXGIFactory2> factory;
    if (FAILED(adapter->GetParent(__uuidof(IDXGIFactory2),
                                  reinterpret_cast<void**>(factory.put())))) {
        return false;
    }
    RECT client{};
    GetClientRect(hwnd_, &client);
    width_ = std::max<UINT>(1, client.right - client.left);
    height_ = std::max<UINT>(1, client.bottom - client.top);
    // The blit model, sequential: GDI children (the text fields) draw over it
    // the way they draw over any window, and the back buffer keeps the last
    // frame, so a paint redraws only what was invalidated.
    DXGI_SWAP_CHAIN_DESC1 desc{};
    desc.Width = width_;
    desc.Height = height_;
    desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = 1;
    desc.Scaling = DXGI_SCALING_STRETCH;
    desc.SwapEffect = DXGI_SWAP_EFFECT_SEQUENTIAL;
    desc.AlphaMode = DXGI_ALPHA_MODE_UNSPECIFIED;
    if (FAILED(factory->CreateSwapChainForHwnd(gD3D.get(), hwnd_, &desc, nullptr, nullptr,
                                               swapChain_.put()))) {
        return false;
    }
    factory->MakeWindowAssociation(hwnd_, DXGI_MWA_NO_ALT_ENTER | DXGI_MWA_NO_WINDOW_CHANGES);
    generation_ = Render::generation();
    needsFullRedraw_ = true;
    return true;
}

ID2D1DeviceContext* Surface::begin(float dpi) {
    if (!swapChain_ || generation_ != Render::generation()) {
        if (!create()) return nullptr;
    }
    RECT client{};
    GetClientRect(hwnd_, &client);
    UINT w = std::max<LONG>(1, client.right - client.left);
    UINT h = std::max<LONG>(1, client.bottom - client.top);
    if (w != width_ || h != height_ || !target_) {
        context_->SetTarget(nullptr);
        target_.reset();
        if (w != width_ || h != height_) {
            if (FAILED(swapChain_->ResizeBuffers(0, w, h, DXGI_FORMAT_UNKNOWN, 0))) {
                Render::deviceLost();
                return nullptr;
            }
            width_ = w;
            height_ = h;
            needsFullRedraw_ = true;
        }
        Com<IDXGISurface> backBuffer;
        if (FAILED(swapChain_->GetBuffer(0, __uuidof(IDXGISurface),
                                         reinterpret_cast<void**>(backBuffer.put())))) {
            return nullptr;
        }
        D2D1_BITMAP_PROPERTIES1 props = D2D1::BitmapProperties1(
            D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
            D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE), dpi, dpi);
        if (FAILED(context_->CreateBitmapFromDxgiSurface(backBuffer.get(), &props,
                                                         target_.put()))) {
            return nullptr;
        }
    }
    context_->SetTarget(target_.get());
    context_->SetDpi(dpi, dpi);
    context_->BeginDraw();
    context_->SetTransform(D2D1::Matrix3x2F::Identity());
    context_->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE);
    return context_.get();
}

bool Surface::end() {
    HRESULT hr = context_->EndDraw();
    if (hr == D2DERR_RECREATE_TARGET) {
        Render::deviceLost();
        return false;
    }
    hr = swapChain_->Present(0, 0);
    if (hr == DXGI_ERROR_DEVICE_REMOVED || hr == DXGI_ERROR_DEVICE_RESET) {
        Render::deviceLost();
        return false;
    }
    return true;
}

void Surface::resize() {
    // The next begin() notices the new client size.
    if (context_) context_->SetTarget(nullptr);
    target_.reset();
}

// ── Fonts ──────────────────────────────────────────────────────────────────

struct FontData {
    Com<IDWriteTextFormat> format;
    Com<IDWriteInlineObject> ellipsis;
    std::wstring family;
    float size = 12;
    int weight = 400;
    float ascender = 0, descender = 0, leading = 0, capHeight = 0;
};

IDWriteTextFormat* Font::format() const { return data_ ? data_->format.get() : nullptr; }
float Font::size() const { return data_ ? data_->size : 0; }
float Font::ascender() const { return data_ ? data_->ascender : 0; }
float Font::descender() const { return data_ ? data_->descender : 0; }
float Font::leading() const { return data_ ? data_->leading : 0; }
float Font::capHeight() const { return data_ ? data_->capHeight : 0; }
float Font::lineHeight() const {
    return data_ ? data_->ascender - data_->descender + data_->leading : 0;
}
const std::wstring& Font::family() const {
    static std::wstring empty;
    return data_ ? data_->family : empty;
}
int Font::weight() const { return data_ ? data_->weight : 400; }

namespace Fonts {

namespace {
std::map<std::wstring, Font> gFonts;
Com<IDWriteFontCollection> gCollection;

IDWriteFontCollection* collection() {
    if (!gCollection) Render::dwrite()->GetSystemFontCollection(gCollection.put(), FALSE);
    return gCollection.get();
}
}  // namespace

bool exists(const std::wstring& family) {
    UINT32 index = 0;
    BOOL found = FALSE;
    if (!collection()) return false;
    collection()->FindFamilyName(family.c_str(), &index, &found);
    return found;
}

Font get(const std::wstring& requested, float size, int weight, bool italic) {
    wchar_t keyBuffer[64];
    swprintf(keyBuffer, 64, L"|%.2f|%d|%d", size, weight, italic ? 1 : 0);
    std::wstring key = requested + keyBuffer;
    auto hit = gFonts.find(key);
    if (hit != gFonts.end()) return hit->second;

    auto data = std::make_shared<FontData>();
    std::wstring family = requested;
    if (!exists(family)) family = exists(L"Consolas") ? L"Consolas" : L"Segoe UI";
    data->family = family;
    data->size = size;
    data->weight = weight;
    DWRITE_FONT_WEIGHT dw = (DWRITE_FONT_WEIGHT)std::clamp(weight, 100, 900);
    DWRITE_FONT_STYLE style = italic ? DWRITE_FONT_STYLE_ITALIC : DWRITE_FONT_STYLE_NORMAL;
    Render::dwrite()->CreateTextFormat(family.c_str(), nullptr, dw, style,
                                       DWRITE_FONT_STRETCH_NORMAL, size, L"",
                                       data->format.put());
    if (data->format) {
        data->format->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
        data->format->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_NEAR);
        Render::dwrite()->CreateEllipsisTrimmingSign(data->format.get(), data->ellipsis.put());
    }
    // Metrics from the face itself, scaled to the size: what NSFont's
    // ascender, descender, leading and capHeight report.
    UINT32 index = 0;
    BOOL found = FALSE;
    if (collection()) collection()->FindFamilyName(family.c_str(), &index, &found);
    if (found) {
        Com<IDWriteFontFamily> fontFamily;
        Com<IDWriteFont> font;
        if (SUCCEEDED(collection()->GetFontFamily(index, fontFamily.put()))
            && SUCCEEDED(fontFamily->GetFirstMatchingFont(dw, DWRITE_FONT_STRETCH_NORMAL, style,
                                                          font.put()))) {
            DWRITE_FONT_METRICS m{};
            font->GetMetrics(&m);
            float unit = size / std::max<UINT16>(1, m.designUnitsPerEm);
            data->ascender = m.ascent * unit;
            data->descender = -(float)m.descent * unit;
            data->leading = m.lineGap * unit;
            data->capHeight = m.capHeight * unit;
        }
    }
    if (data->ascender <= 0) {
        data->ascender = size * 0.8f;
        data->descender = -size * 0.2f;
        data->capHeight = size * 0.7f;
    }
    Font out(data);
    gFonts[key] = out;
    return out;
}

}  // namespace Fonts

// ── Text layout caches ─────────────────────────────────────────────────────

namespace {

struct LayoutEntry {
    Com<IDWriteTextLayout> layout;
    float baseline = 0;
};

std::unordered_map<std::wstring, LayoutEntry> gLayouts;
std::unordered_map<std::wstring, float> gWidths;

std::wstring cacheKey(const std::wstring& text, const Font& font, float width, int mode) {
    wchar_t prefix[96];
    swprintf(prefix, 96, L"%llx|%.2f|%d|", (unsigned long long)font.identity(), width, mode);
    return prefix + text;
}

LayoutEntry* layoutFor(const std::wstring& text, const Font& font, float width, Align align,
                       bool trimTail, bool wrap) {
    int mode = (int)align | (trimTail ? 8 : 0) | (wrap ? 16 : 0);
    std::wstring key = cacheKey(text, font, width, mode);
    auto hit = gLayouts.find(key);
    if (hit != gLayouts.end()) return &hit->second;
    if (gLayouts.size() > 4096) gLayouts.clear();
    LayoutEntry entry;
    if (FAILED(Render::dwrite()->CreateTextLayout(text.c_str(), (UINT32)text.size(),
                                                  font.format(), std::max(0.0f, width), 100000.0f,
                                                  entry.layout.put()))) {
        return nullptr;
    }
    entry.layout->SetWordWrapping(wrap ? DWRITE_WORD_WRAPPING_WRAP : DWRITE_WORD_WRAPPING_NO_WRAP);
    entry.layout->SetTextAlignment(align == Align::Center ? DWRITE_TEXT_ALIGNMENT_CENTER
                                   : align == Align::Right ? DWRITE_TEXT_ALIGNMENT_TRAILING
                                                           : DWRITE_TEXT_ALIGNMENT_LEADING);
    if (trimTail) {
        DWRITE_TRIMMING trimming{DWRITE_TRIMMING_GRANULARITY_CHARACTER, 0, 0};
        Com<IDWriteInlineObject> sign;
        Render::dwrite()->CreateEllipsisTrimmingSign(entry.layout.get(), sign.put());
        entry.layout->SetTrimming(&trimming, sign.get());
    }
    DWRITE_LINE_METRICS line{};
    UINT32 count = 0;
    entry.layout->GetLineMetrics(&line, 1, &count);
    entry.baseline = count ? line.baseline : font.ascender();
    auto inserted = gLayouts.emplace(key, std::move(entry));
    return &inserted.first->second;
}

bool isHighSurrogate(wchar_t c) { return c >= 0xD800 && c < 0xDC00; }
bool isLowSurrogate(wchar_t c) { return c >= 0xDC00 && c < 0xE000; }

}  // namespace

namespace Text {

float width(const std::wstring& text, const Font& font) {
    if (text.empty() || !font) return 0;
    std::wstring key = cacheKey(text, font, 0, 0);
    auto hit = gWidths.find(key);
    if (hit != gWidths.end()) return hit->second;
    if (gWidths.size() > 16384) gWidths.clear();
    Com<IDWriteTextLayout> layout;
    float result = 0;
    if (SUCCEEDED(Render::dwrite()->CreateTextLayout(text.c_str(), (UINT32)text.size(),
                                                     font.format(), 100000.0f, 1000.0f,
                                                     layout.put()))) {
        DWRITE_TEXT_METRICS metrics{};
        layout->GetMetrics(&metrics);
        result = metrics.widthIncludingTrailingWhitespace;
    }
    gWidths[key] = result;
    return result;
}

float wrappedHeight(const std::wstring& text, const Font& font, float width) {
    if (text.empty()) return 0;
    auto entry = layoutFor(text, font, width, Align::Left, false, true);
    if (!entry) return 0;
    DWRITE_TEXT_METRICS metrics{};
    entry->layout->GetMetrics(&metrics);
    return metrics.height;
}

std::wstring truncated(const std::wstring& text, const Font& font, float available,
                       LineBreak lineBreak) {
    if (text.empty() || width(text, font) <= available) return text;
    const std::wstring ellipsis = L"…";
    if (lineBreak == LineBreak::Clipping) return text;
    size_t length = text.size();
    auto build = [&](size_t keep) -> std::wstring {
        if (lineBreak == LineBreak::TruncatingHead) {
            size_t start = length - keep;
            if (start < length && isLowSurrogate(text[start])) ++start;
            return ellipsis + text.substr(start);
        }
        if (lineBreak == LineBreak::TruncatingMiddle) {
            size_t head = (keep + 1) / 2;
            size_t tail = keep - head;
            if (head > 0 && isHighSurrogate(text[head - 1])) --head;
            size_t start = length - tail;
            if (start < length && isLowSurrogate(text[start])) ++start;
            return text.substr(0, head) + ellipsis + text.substr(start);
        }
        size_t end = keep;
        if (end > 0 && isHighSurrogate(text[end - 1])) --end;
        return text.substr(0, end) + ellipsis;
    };
    size_t lo = 0, hi = length;
    while (lo < hi) {
        size_t mid = (lo + hi + 1) / 2;
        if (width(build(mid), font) <= available) lo = mid;
        else hi = mid - 1;
    }
    return build(lo);
}

float centeredBaseline(const Font& font, const Rect& rect) {
    return roundHalf(rect.midY() + font.capHeight() / 2);
}

std::pair<float, float> inkExtent(const std::wstring& text, const Font& font) {
    auto entry = layoutFor(text, font, 100000.0f, Align::Left, false, false);
    if (!entry) return {-font.capHeight(), 0};
    DWRITE_OVERHANG_METRICS overhang{};
    DWRITE_TEXT_METRICS metrics{};
    entry->layout->GetOverhangMetrics(&overhang);
    entry->layout->GetMetrics(&metrics);
    float top = -overhang.top;
    float bottom = metrics.height + overhang.bottom;
    // GetOverhangMetrics measures against the layout box, which is the full
    // max width; the vertical extents are what is wanted here.
    return {top - entry->baseline, bottom - entry->baseline};
}

void purgeCaches() {
    gLayouts.clear();
    gWidths.clear();
}

}  // namespace Text

// ── Graphics ───────────────────────────────────────────────────────────────

namespace {
D2D1_COLOR_F d2dColor(const Color& c) { return D2D1::ColorF(c.r, c.g, c.b, c.a); }
D2D1_RECT_F d2dRect(const Rect& r) { return D2D1::RectF(r.x, r.y, r.maxX(), r.maxY()); }
}  // namespace

Graphics::Graphics(ID2D1DeviceContext* context, float dpi) : dc_(context), dpi_(dpi) {
    dc_->CreateSolidColorBrush(D2D1::ColorF(0, 0, 0, 1), brush_.put());
}

ID2D1SolidColorBrush* Graphics::brush(const Color& color) {
    brush_->SetColor(d2dColor(color));
    return brush_.get();
}

void Graphics::pushOffset(float dx, float dy) {
    offsets_.push_back(offset_);
    offset_ = {offset_.x + dx, offset_.y + dy};
    dc_->SetTransform(D2D1::Matrix3x2F::Translation(offset_.x, offset_.y));
}

void Graphics::popOffset() {
    if (offsets_.empty()) return;
    offset_ = offsets_.back();
    offsets_.pop_back();
    dc_->SetTransform(D2D1::Matrix3x2F::Translation(offset_.x, offset_.y));
}

void Graphics::pushClip(const Rect& rect) {
    Rect absolute = rect.offset(offset_.x, offset_.y);
    if (!clips_.empty()) absolute = absolute.intersection(clips_.back());
    clips_.push_back(absolute);
    dc_->PushAxisAlignedClip(d2dRect(rect), D2D1_ANTIALIAS_MODE_ALIASED);
}

void Graphics::popClip() {
    if (clips_.empty()) return;
    clips_.pop_back();
    dc_->PopAxisAlignedClip();
}

Rect Graphics::clip() const {
    if (clips_.empty()) return Rect(-offset_.x, -offset_.y, 100000, 100000);
    return clips_.back().offset(-offset_.x, -offset_.y);
}

Rect Graphics::snapped(const Rect& r) const {
    float s = scale();
    float x = std::round((offset_.x + r.x) * s) / s - offset_.x;
    float y = std::round((offset_.y + r.y) * s) / s - offset_.y;
    return Rect(x, y, std::round(r.w * s) / s, std::round(r.h * s) / s);
}

void Graphics::fillRect(const Rect& rect, const Color& color) {
    if (rect.isEmpty() || color.isClear()) return;
    dc_->FillRectangle(d2dRect(rect), brush(color));
}

void Graphics::strokeRect(const Rect& rect, const Color& color, float width) {
    if (rect.isEmpty() || color.isClear()) return;
    Rect inner = rect.inset(width / 2, width / 2);
    dc_->DrawRectangle(d2dRect(inner), brush(color), width);
}

void Graphics::fillRoundedRect(const Rect& rect, float radius, const Color& color) {
    if (rect.isEmpty() || color.isClear()) return;
    dc_->FillRoundedRectangle(D2D1::RoundedRect(d2dRect(rect), radius, radius), brush(color));
}

void Graphics::strokeRoundedRect(const Rect& rect, float radius, const Color& color, float width) {
    if (rect.isEmpty() || color.isClear()) return;
    dc_->DrawRoundedRectangle(D2D1::RoundedRect(d2dRect(rect), radius, radius), brush(color),
                              width);
}

void Graphics::fillEllipse(const Rect& rect, const Color& color) {
    if (color.isClear()) return;
    dc_->FillEllipse(D2D1::Ellipse(D2D1::Point2F(rect.midX(), rect.midY()), rect.w / 2, rect.h / 2),
                     brush(color));
}

void Graphics::strokeEllipse(const Rect& rect, const Color& color, float width) {
    if (color.isClear()) return;
    dc_->DrawEllipse(D2D1::Ellipse(D2D1::Point2F(rect.midX(), rect.midY()), rect.w / 2, rect.h / 2),
                     brush(color), width);
}

namespace {
Com<ID2D1StrokeStyle> roundStroke() {
    static Com<ID2D1StrokeStyle> style;
    if (!style) {
        D2D1_STROKE_STYLE_PROPERTIES props = D2D1::StrokeStyleProperties(
            D2D1_CAP_STYLE_ROUND, D2D1_CAP_STYLE_ROUND, D2D1_CAP_STYLE_ROUND,
            D2D1_LINE_JOIN_ROUND);
        Render::d2d()->CreateStrokeStyle(props, nullptr, 0, style.put());
    }
    return style;
}
}  // namespace

void Graphics::line(Point a, Point b, const Color& color, float width, bool roundCaps) {
    if (color.isClear()) return;
    dc_->DrawLine(D2D1::Point2F(a.x, a.y), D2D1::Point2F(b.x, b.y), brush(color), width,
                  roundCaps ? roundStroke().get() : nullptr);
}

void Graphics::polyline(const std::vector<Point>& points, const Color& color, float width,
                        bool roundCaps, bool closed) {
    if (points.size() < 2 || color.isClear()) return;
    Com<ID2D1PathGeometry> path;
    Render::d2d()->CreatePathGeometry(path.put());
    Com<ID2D1GeometrySink> sink;
    path->Open(sink.put());
    sink->BeginFigure(D2D1::Point2F(points[0].x, points[0].y), D2D1_FIGURE_BEGIN_HOLLOW);
    for (size_t i = 1; i < points.size(); ++i) {
        sink->AddLine(D2D1::Point2F(points[i].x, points[i].y));
    }
    sink->EndFigure(closed ? D2D1_FIGURE_END_CLOSED : D2D1_FIGURE_END_OPEN);
    sink->Close();
    dc_->DrawGeometry(path.get(), brush(color), width, roundCaps ? roundStroke().get() : nullptr);
}

void Graphics::bezier(Point from, Point c1, Point c2, Point to, const Color& color, float width,
                      bool roundCaps) {
    Com<ID2D1PathGeometry> path;
    Render::d2d()->CreatePathGeometry(path.put());
    Com<ID2D1GeometrySink> sink;
    path->Open(sink.put());
    sink->BeginFigure(D2D1::Point2F(from.x, from.y), D2D1_FIGURE_BEGIN_HOLLOW);
    sink->AddBezier(D2D1::BezierSegment(D2D1::Point2F(c1.x, c1.y), D2D1::Point2F(c2.x, c2.y),
                                        D2D1::Point2F(to.x, to.y)));
    sink->EndFigure(D2D1_FIGURE_END_OPEN);
    sink->Close();
    dc_->DrawGeometry(path.get(), brush(color), width, roundCaps ? roundStroke().get() : nullptr);
}

namespace {
Com<ID2D1LinearGradientBrush> gradientBrush(ID2D1DeviceContext* dc, const Rect& rect,
                                            const std::vector<std::pair<float, Color>>& stops,
                                            bool vertical) {
    std::vector<D2D1_GRADIENT_STOP> d2dStops;
    for (auto& [position, color] : stops) d2dStops.push_back({position, d2dColor(color)});
    Com<ID2D1GradientStopCollection> collection;
    dc->CreateGradientStopCollection(d2dStops.data(), (UINT32)d2dStops.size(), collection.put());
    Com<ID2D1LinearGradientBrush> brush;
    D2D1_POINT_2F start = D2D1::Point2F(rect.x, rect.y);
    D2D1_POINT_2F end = vertical ? D2D1::Point2F(rect.x, rect.maxY())
                                 : D2D1::Point2F(rect.maxX(), rect.y);
    dc->CreateLinearGradientBrush(D2D1::LinearGradientBrushProperties(start, end),
                                  collection.get(), brush.put());
    return brush;
}
}  // namespace

void Graphics::fillGradient(const Rect& rect, const std::vector<std::pair<float, Color>>& stops,
                            bool vertical) {
    if (rect.isEmpty()) return;
    auto brush = gradientBrush(dc_, rect, stops, vertical);
    if (brush) dc_->FillRectangle(d2dRect(rect), brush.get());
}

void Graphics::drawBitmap(ID2D1Bitmap* bitmap, const Rect& rect, float opacity) {
    if (!bitmap || rect.isEmpty()) return;
    dc_->DrawBitmap(bitmap, d2dRect(rect), opacity, D2D1_INTERPOLATION_MODE_HIGH_QUALITY_CUBIC,
                    nullptr, nullptr);
}

void Graphics::fillMask(ID2D1Bitmap* mask, const Rect& rect, const Color& color) {
    if (!mask || rect.isEmpty()) return;
    D2D1_ANTIALIAS_MODE previous = dc_->GetAntialiasMode();
    dc_->SetAntialiasMode(D2D1_ANTIALIAS_MODE_ALIASED);
    D2D1_RECT_F dest = d2dRect(rect);
    dc_->FillOpacityMask(mask, brush(color), &dest, nullptr);
    dc_->SetAntialiasMode(previous);
}

void Graphics::fillMaskGradient(ID2D1Bitmap* mask, const Rect& rect, const Rect& gradientRect,
                                const std::vector<std::pair<float, Color>>& stops,
                                bool vertical) {
    if (!mask || rect.isEmpty()) return;
    auto brush = gradientBrush(dc_, gradientRect, stops, vertical);
    if (!brush) return;
    D2D1_ANTIALIAS_MODE previous = dc_->GetAntialiasMode();
    dc_->SetAntialiasMode(D2D1_ANTIALIAS_MODE_ALIASED);
    D2D1_RECT_F dest = d2dRect(rect);
    dc_->FillOpacityMask(mask, brush.get(), &dest, nullptr);
    dc_->SetAntialiasMode(previous);
}

void Graphics::text(const std::wstring& string, const Font& font, const Color& color,
                    float baseline, const Rect& rect, LineBreak lineBreak, Align align) {
    if (rect.w <= 0 || rect.h <= 0 || string.empty() || !font || color.isClear()) return;
    std::wstring drawn = string;
    bool trimTail = lineBreak == LineBreak::TruncatingTail;
    if (lineBreak == LineBreak::TruncatingHead || lineBreak == LineBreak::TruncatingMiddle) {
        drawn = Text::truncated(string, font, rect.w, lineBreak);
    }
    // Tabs and newlines draw as nothing in one line of a list.
    for (auto& c : drawn) {
        if (c == L'\t') c = L' ';
        else if (c == L'\n' || c == L'\r') c = L' ';
    }
    LayoutEntry* entry = layoutFor(drawn, font, rect.w, align, trimTail, false);
    if (!entry) return;
    D2D1_POINT_2F origin = D2D1::Point2F(rect.x, baseline - entry->baseline);
    D2D1_DRAW_TEXT_OPTIONS options = D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT;
    if (lineBreak == LineBreak::Clipping) {
        pushClip(Rect(rect.x, origin.y - 4, rect.w, font.lineHeight() + 8));
        dc_->DrawTextLayout(origin, entry->layout.get(), brush(color), options);
        popClip();
        return;
    }
    dc_->DrawTextLayout(origin, entry->layout.get(), brush(color), options);
}

void Graphics::text(const std::wstring& string, const Font& font, const Color& color,
                    const Rect& rect, LineBreak lineBreak, Align align) {
    text(string, font, color, Text::centeredBaseline(font, rect), rect, lineBreak, align);
}

float Graphics::wrappedText(const std::wstring& string, const Font& font, const Color& color,
                            const Rect& rect, Align align) {
    if (string.empty() || rect.w <= 0) return 0;
    LayoutEntry* entry = layoutFor(string, font, rect.w, align, false, true);
    if (!entry) return 0;
    dc_->DrawTextLayout(D2D1::Point2F(rect.x, rect.y), entry->layout.get(), brush(color),
                        D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
    DWRITE_TEXT_METRICS metrics{};
    entry->layout->GetMetrics(&metrics);
    return metrics.height;
}

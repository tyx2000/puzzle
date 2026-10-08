// Direct2D and DirectWrite: one device shared by every window, so a cached
// icon bitmap serves them all, and the drawing calls the AppKit views made
// through NSBezierPath and NSAttributedString.draw.
#pragma once

#include "base.h"
#include "geometry.h"

#include <d2d1_1.h>
#include <d2d1_1helper.h>
#include <d3d11.h>
#include <dwrite.h>
#include <dxgi1_2.h>

/// A minimal owning COM pointer.
template <class T>
class Com {
public:
    Com() = default;
    Com(std::nullptr_t) {}
    explicit Com(T* raw) : p_(raw) {}
    Com(const Com& o) : p_(o.p_) { if (p_) p_->AddRef(); }
    Com(Com&& o) noexcept : p_(o.p_) { o.p_ = nullptr; }
    ~Com() { reset(); }
    Com& operator=(const Com& o) {
        if (this != &o) {
            if (o.p_) o.p_->AddRef();
            reset();
            p_ = o.p_;
        }
        return *this;
    }
    Com& operator=(Com&& o) noexcept {
        if (this != &o) {
            reset();
            p_ = o.p_;
            o.p_ = nullptr;
        }
        return *this;
    }
    void reset() {
        if (p_) p_->Release();
        p_ = nullptr;
    }
    T* get() const { return p_; }
    T* operator->() const { return p_; }
    T** put() {
        reset();
        return &p_;
    }
    explicit operator bool() const { return p_ != nullptr; }
    template <class Q>
    Com<Q> as() const {
        Com<Q> out;
        if (p_) p_->QueryInterface(__uuidof(Q), reinterpret_cast<void**>(out.put()));
        return out;
    }
private:
    T* p_ = nullptr;
};

// ── Fonts ──────────────────────────────────────────────────────────────────

struct FontData;

/// A font at one size, with the metrics the AppKit code read off NSFont.
class Font {
public:
    Font() = default;
    explicit Font(std::shared_ptr<FontData> data) : data_(std::move(data)) {}
    IDWriteTextFormat* format() const;
    float size() const;
    float ascender() const;
    float descender() const;  // negative, as NSFont reports it
    float leading() const;
    float capHeight() const;
    float lineHeight() const;  // ascender - descender + leading
    const std::wstring& family() const;
    int weight() const;
    uintptr_t identity() const { return reinterpret_cast<uintptr_t>(data_.get()); }
    explicit operator bool() const { return (bool)data_; }
private:
    std::shared_ptr<FontData> data_;
};

namespace Fonts {
/// A font from the system collection; falls back along `fallbacks` when the
/// family is missing. Cached per (family, size, weight).
Font get(const std::wstring& family, float size, int weight = 400, bool italic = false);
/// Whether the system has this family.
bool exists(const std::wstring& family);
}  // namespace Fonts

// ── Device ─────────────────────────────────────────────────────────────────

namespace Render {

bool initialize();
ID2D1Factory1* d2d();
IDWriteFactory* dwrite();
ID2D1Device* device();
/// The Direct3D device under it (the PDF renderer draws through it).
ID3D11Device* d3dDevice();
/// Bumped whenever the device had to be recreated; caches holding device
/// bitmaps compare against it.
uint64_t generation();
/// The device was lost: build another and tell every surface.
void deviceLost();
/// A device context for work outside any window (rendering an icon).
ID2D1DeviceContext* scratchContext();

}  // namespace Render

/// The swap chain and context drawing one window.
class Surface {
public:
    explicit Surface(HWND hwnd);
    ~Surface();
    /// Returns the context ready to draw, or nullptr when it cannot draw now.
    ID2D1DeviceContext* begin(float dpi);
    /// Presents. False when the device was lost and drawing must be retried.
    bool end();
    void resize();
    /// True once after the back buffer was made or resized: its contents
    /// are undefined, so the whole window has to be drawn.
    bool consumeNeedsFullRedraw() {
        bool full = needsFullRedraw_;
        needsFullRedraw_ = false;
        return full;
    }
private:
    bool create();
    void release();
    HWND hwnd_;
    Com<ID2D1DeviceContext> context_;
    Com<IDXGISwapChain1> swapChain_;
    Com<ID2D1Bitmap1> target_;
    uint64_t generation_ = 0;
    UINT width_ = 0, height_ = 0;
    bool needsFullRedraw_ = true;
};

// ── Drawing ────────────────────────────────────────────────────────────────

/// How a single line of text gives way when it does not fit.
enum class LineBreak { TruncatingTail, TruncatingHead, TruncatingMiddle, Clipping };
enum class Align { Left, Center, Right };

class Graphics {
public:
    Graphics(ID2D1DeviceContext* context, float dpi);
    ID2D1DeviceContext* context() const { return dc_; }
    float scale() const { return dpi_ / 96.0f; }

    // Coordinate stack: views draw in their own space.
    void pushOffset(float dx, float dy);
    void popOffset();
    Point offset() const { return offset_; }
    void pushClip(const Rect& rect);
    void popClip();
    /// The clip in current coordinates.
    Rect clip() const;
    /// `rect` moved and sized onto whole device pixels.
    Rect snapped(const Rect& rect) const;

    void fillRect(const Rect& rect, const Color& color);
    /// A 1pt (or `width`) frame drawn inside the rect.
    void strokeRect(const Rect& rect, const Color& color, float width = 1);
    void fillRoundedRect(const Rect& rect, float radius, const Color& color);
    void strokeRoundedRect(const Rect& rect, float radius, const Color& color, float width = 1);
    void fillEllipse(const Rect& rect, const Color& color);
    void strokeEllipse(const Rect& rect, const Color& color, float width);
    void line(Point a, Point b, const Color& color, float width = 1, bool roundCaps = false);
    /// A polyline through `points`.
    void polyline(const std::vector<Point>& points, const Color& color, float width,
                  bool roundCaps = true, bool closed = false);
    void bezier(Point from, Point c1, Point c2, Point to, const Color& color, float width,
                bool roundCaps = true);
    /// Stops are (position 0…1, colour); `angle` 0 runs left to right, 90 top to bottom.
    void fillGradient(const Rect& rect, const std::vector<std::pair<float, Color>>& stops,
                      bool vertical);
    void drawBitmap(ID2D1Bitmap* bitmap, const Rect& rect, float opacity = 1);
    /// Fill `color` wherever `mask` is opaque, as `.sourceAtop` did over an icon.
    void fillMask(ID2D1Bitmap* mask, const Rect& rect, const Color& color);
    void fillMaskGradient(ID2D1Bitmap* mask, const Rect& rect, const Rect& gradientRect,
                          const std::vector<std::pair<float, Color>>& stops, bool vertical);

    /// One line of text with its baseline at `baseline`, inside `rect`'s width.
    void text(const std::wstring& string, const Font& font, const Color& color, float baseline,
              const Rect& rect, LineBreak lineBreak = LineBreak::TruncatingTail,
              Align align = Align::Left);
    /// The same, its cap-height optically centred in `rect`.
    void text(const std::wstring& string, const Font& font, const Color& color, const Rect& rect,
              LineBreak lineBreak = LineBreak::TruncatingTail, Align align = Align::Left);
    /// Wrapped text from the top of `rect`; returns the height used.
    float wrappedText(const std::wstring& string, const Font& font, const Color& color,
                      const Rect& rect, Align align = Align::Left);

    ID2D1SolidColorBrush* brush(const Color& color);

private:
    ID2D1DeviceContext* dc_;
    float dpi_;
    Point offset_;
    std::vector<Point> offsets_;
    std::vector<Rect> clips_;  // in absolute coordinates
    Com<ID2D1SolidColorBrush> brush_;
};

namespace Text {
/// The advance of one line of text.
float width(const std::wstring& string, const Font& font);
/// Height a wrapped block takes at `width`.
float wrappedHeight(const std::wstring& string, const Font& font, float width);
/// The string as it will be drawn in `width`, ellipsis and all.
std::wstring truncated(const std::wstring& string, const Font& font, float width,
                       LineBreak lineBreak);
/// Baseline whose cap-height is optically centred in `rect`.
float centeredBaseline(const Font& font, const Rect& rect);
/// Ink bounds of `string` relative to its baseline (top is negative).
std::pair<float, float> inkExtent(const std::wstring& string, const Font& font);
void purgeCaches();
}  // namespace Text

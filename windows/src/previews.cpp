#include "previews.h"

#include "theme.h"

void drawCheckerboard(Graphics& g, const Rect& frame) {
    if (frame.w <= 1 || frame.h <= 1) return;
    const float square = 8;
    g.fillRect(frame, Color(0.22f, 0.22f, 0.22f));
    Color light(0.27f, 0.27f, 0.27f);
    int row = 0;
    for (float y = frame.y; y < frame.maxY(); y += square, ++row) {
        for (float x = frame.x + (row % 2 == 0 ? 0 : square); x < frame.maxX(); x += square * 2) {
            g.fillRect(Rect(x, y, std::min(square, frame.maxX() - x), std::min(square, frame.maxY() - y)), light);
        }
    }
}

// ── ImagePreviewView ───────────────────────────────────────────────────────

ImagePreviewView::ImagePreviewView() { backgroundColor = Theme::editorBackground; }

void ImagePreviewView::show(const std::wstring& path, Size pixelSize, const std::wstring& caption) {
    clear();
    path_ = path;
    pixelSize_ = pixelSize;
    caption_ = caption;
    setNeedsLayout();
    setNeedsDisplay();
}

void ImagePreviewView::clear() {
    if (resizeWork_) resizeWork_->cancel();
    resizeWork_.reset();
    path_.clear();
    pixelSize_ = Size();
    caption_.clear();
    source_.reset();
    bitmap_.reset();
    decodedMaximum_ = 0;
    setNeedsDisplay();
}

void ImagePreviewView::refreshFonts() { setNeedsDisplay(); }

Rect ImagePreviewView::imageFrame() const {
    Rect b = bounds();
    if (pixelSize_.w <= 0 || pixelSize_.h <= 0) return {};
    float fit = std::min({1.0f, std::max(0.0f, b.w - 48) / pixelSize_.w, std::max(0.0f, b.h - 80) / pixelSize_.h});
    Size size(pixelSize_.w * fit, pixelSize_.h * fit);
    return Rect(std::round(b.midX() - size.w / 2), std::round(b.midY() - size.h / 2 - 14), size.w, size.h);
}

void ImagePreviewView::decode(UINT maximum) {
    if (path_.empty()) return;
    source_ = Imaging::decodeFile(path_, maximum);
    bitmap_.reset();
    decodedMaximum_ = maximum;
    setNeedsDisplay();
}

void ImagePreviewView::layout() {
    Rect frame = imageFrame();
    if (path_.empty() || frame.w <= 0 || frame.h <= 0) return;
    float scale = window() ? window()->scale() : 1;
    float pixels = std::max(frame.w, frame.h) * scale;
    UINT target = std::min<UINT>(4096, (UINT)std::ceil(pixels / 64) * 64);
    if (resizeWork_) resizeWork_->cancel();
    resizeWork_.reset();
    if (target == decodedMaximum_) return;
    if (source_) {
        // Keep scaling the current bitmap until a resize settles.
        resizeWork_ = Dispatch::after(0.12, [this, target, alive = life_.weak()] {
            if (!alive.expired()) decode(target);
        });
    } else {
        decode(target);
    }
}

void ImagePreviewView::draw(Graphics& g) {
    Rect frame = imageFrame();
    if (source_ && frame.w > 1 && frame.h > 1) {
        drawCheckerboard(g, frame);
        if (!bitmap_ || bitmapGeneration_ != Render::generation()) {
            bitmap_ = Imaging::bitmap(g.context(), source_.get());
            bitmapGeneration_ = Render::generation();
        }
        if (bitmap_) g.drawBitmap(bitmap_.get(), frame);
    }
    if (!caption_.empty()) {
        Rect b = bounds();
        float y = frame.h > 0 ? frame.maxY() + 12 : b.midY();
        g.text(caption_, Theme::uiFont(10.5f), Theme::dimText, Rect(16, y, std::max(0.0f, b.w - 32), 18),
               LineBreak::TruncatingMiddle, Align::Center);
    }
}

// ── SVGPreviewView ─────────────────────────────────────────────────────────

namespace {
constexpr float kPadding = 12;
constexpr float kTitleHeight = 16;

std::wstring trimmedNumber(float value) {
    if (value == std::round(value)) return std::to_wstring((long long)value);
    wchar_t buffer[32];
    swprintf(buffer, 32, L"%g", (double)value);
    return buffer;
}

Size fitted(Size image, Size available) {
    if (image.w <= 0 || image.h <= 0) return Size();
    float scale = std::min({1.0f, available.w / image.w, available.h / image.h});
    return Size(std::floor(image.w * scale), std::floor(image.h * scale));
}
}  // namespace

SVGPreviewView::SVGPreviewView() { backgroundColor = Theme::editorBackground; }

std::optional<SVGImage> SVGPreviewView::render(const std::string& text) {
    if (text.empty()) return std::nullopt;
    auto size = Imaging::svgSize(text);
    if (!size || size->w <= 0 || size->h <= 0 || !std::isfinite(size->w) || !std::isfinite(size->h)) {
        return std::nullopt;
    }
    // Direct2D refuses what it cannot parse: a half-typed tag draws nothing.
    if (!Imaging::renderSVG(text, 8, 8)) return std::nullopt;
    return SVGImage{text, *size};
}

std::wstring SVGPreviewView::caption(const std::optional<std::wstring>& name, const std::optional<SVGImage>& image,
                                     size_t bytes) {
    std::vector<std::wstring> parts;
    if (name) parts.push_back(*name);
    if (image) parts.push_back(trimmedNumber(image->size.w) + L" × " + trimmedNumber(image->size.h));
    parts.push_back(formatByteCount(bytes));
    return join(parts, L"  ·  ");
}

void SVGPreviewView::show(std::vector<Pane> panes) {
    panes_ = std::move(panes);
    rendered_.assign(panes_.size(), Rendered{});
    setNeedsDisplay();
}

void SVGPreviewView::clear() {
    panes_.clear();
    rendered_.clear();
    setNeedsDisplay();
}

void SVGPreviewView::draw(Graphics& g) {
    Rect b = bounds();
    // The seam between the picture and the source under it.
    g.fillRect(Rect(0, b.h - 1, b.w, 1), Theme::border);
    if (panes_.empty()) return;
    float width = (b.w - kPadding * (panes_.size() + 1)) / panes_.size();
    if (width <= 1) return;
    for (size_t i = 0; i < panes_.size(); ++i) {
        float x = kPadding + (width + kPadding) * i;
        drawPane(g, panes_[i], Rect(x, kPadding, width, std::max(1.0f, b.h - kPadding * 2)), i);
        if (i > 0) {
            g.fillRect(Rect(x - kPadding / 2, kPadding, 1, std::max(1.0f, b.h - kPadding * 2)), Theme::border);
        }
    }
}

void SVGPreviewView::drawPane(Graphics& g, Pane& pane, const Rect& rect, size_t index) {
    Rect content = rect;
    Font font = Theme::uiFont(10.5f);
    if (pane.title) {
        g.text(*pane.title, font, Theme::dimText, Rect(rect.x, rect.y, rect.w, kTitleHeight), LineBreak::TruncatingTail,
               Align::Center);
        content.y += kTitleHeight + 4;
        content.h -= kTitleHeight + 4;
    }
    float footer = rect.maxY();
    if (pane.caption) {
        footer -= kTitleHeight;
        g.text(*pane.caption, font, Theme::dimText, Rect(rect.x, footer, rect.w, kTitleHeight),
               LineBreak::TruncatingMiddle, Align::Center);
        content.h -= kTitleHeight;
    }
    if (pane.note) {
        footer -= kTitleHeight + 2;
        g.text(*pane.note, font, pane.image ? Theme::yellow : Theme::dimText, Rect(rect.x, footer, rect.w, kTitleHeight),
               LineBreak::TruncatingTail, Align::Center);
        content.h -= kTitleHeight + 2;
    }
    if (!pane.image || content.w <= 1 || content.h <= 1) return;
    Size size = fitted(pane.image->size, content.size());
    if (size.w < 1 || size.h < 1) return;
    Rect frame(std::round(content.midX() - size.w / 2), std::round(content.midY() - size.h / 2), size.w, size.h);
    drawCheckerboard(g, frame);
    float scale = g.scale();
    UINT pw = (UINT)std::max(1.0f, std::round(size.w * scale)), ph = (UINT)std::max(1.0f, std::round(size.h * scale));
    Rendered& r = rendered_[index];
    if (!r.bitmap || r.width != pw || r.height != ph || r.generation != Render::generation()) {
        r.bitmap = Imaging::renderSVG(pane.image->source, pw, ph);
        r.width = pw;
        r.height = ph;
        r.generation = Render::generation();
    }
    if (r.bitmap) g.drawBitmap(r.bitmap.get(), frame);
}

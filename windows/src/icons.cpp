#include "icons.h"

#include "json.h"

#include <d2d1_3.h>
#include <shlwapi.h>

// ── Symbols ────────────────────────────────────────────────────────────────

void drawSymbol(Graphics& g, Symbol symbol, const Rect& rect, const Color& color, float weight) {
    float s = std::min(rect.w, rect.h);
    float cx = rect.midX(), cy = rect.midY();
    switch (symbol) {
    case Symbol::Plus: {
        float h = s * 0.42f;
        g.line(Point(cx - h, cy), Point(cx + h, cy), color, 1.3f * weight, true);
        g.line(Point(cx, cy - h), Point(cx, cy + h), color, 1.3f * weight, true);
        break;
    }
    case Symbol::XMark: {
        float h = s * 0.3f;
        g.line(Point(cx - h, cy - h), Point(cx + h, cy + h), color, 1.4f * weight, true);
        g.line(Point(cx + h, cy - h), Point(cx - h, cy + h), color, 1.4f * weight, true);
        break;
    }
    case Symbol::ChevronUp: {
        float w = s * 0.42f, h = s * 0.22f;
        g.polyline({Point(cx - w, cy + h), Point(cx, cy - h), Point(cx + w, cy + h)}, color,
                   1.5f * weight);
        break;
    }
    case Symbol::ChevronDown: {
        float w = s * 0.42f, h = s * 0.22f;
        g.polyline({Point(cx - w, cy - h), Point(cx, cy + h), Point(cx + w, cy - h)}, color,
                   1.5f * weight);
        break;
    }
    case Symbol::ChevronRight: {
        float w = s * 0.22f, h = s * 0.42f;
        g.polyline({Point(cx - w, cy - h), Point(cx + w, cy), Point(cx - w, cy + h)}, color,
                   1.5f * weight);
        break;
    }
    case Symbol::SplitRectangle:
    case Symbol::Rectangle: {
        float w = s * 1.15f, h = s * 0.85f;
        Rect frame(cx - w / 2, cy - h / 2, w, h);
        g.strokeRoundedRect(frame.inset(0.6f, 0.6f), 2, color, 1.2f * weight);
        if (symbol == Symbol::SplitRectangle) {
            g.line(Point(cx, frame.y + 0.6f), Point(cx, frame.maxY() - 0.6f), color, 1.2f * weight);
        }
        break;
    }
    case Symbol::Prompt: {
        // The prompt mark Gift draws beside its `+`: a chevron and the
        // cursor's underscore, laid out on a 14-point square.
        float k = s / 14.0f;
        float ox = cx - 7 * k, oy = cy - 7 * k;
        g.polyline({Point(ox + 3 * k, oy + 3.75f * k), Point(ox + 6.5f * k, oy + 7 * k),
                    Point(ox + 3 * k, oy + 10.25f * k)},
                   color, 1.3f * weight);
        g.line(Point(ox + 8 * k, oy + 10.25f * k), Point(ox + 11.5f * k, oy + 10.25f * k), color,
               1.3f * weight, true);
        break;
    }
    case Symbol::Document: {
        float w = s * 0.62f, h = s * 0.8f;
        float l = cx - w / 2, t = cy - h / 2, r = cx + w / 2, b = cy + h / 2;
        float fold = w * 0.35f;
        g.polyline({Point(l, t), Point(r - fold, t), Point(r, t + fold), Point(r, b), Point(l, b)},
                   color, 1.1f * weight, true, true);
        g.polyline({Point(r - fold, t), Point(r - fold, t + fold), Point(r, t + fold)}, color,
                   1.1f * weight);
        break;
    }
    case Symbol::MenuLines: {
        float w = s * 0.42f;
        for (float dy : {-4.0f, 0.0f, 4.0f}) {
            g.line(Point(cx - w, cy + dy), Point(cx + w, cy + dy), color, 1.2f * weight, true);
        }
        break;
    }
    case Symbol::Gear: {
        float r = s * 0.24f;
        g.strokeEllipse(Rect(cx - r, cy - r, 2 * r, 2 * r), color, 1.3f * weight);
        float inner = s * 0.33f, outer = s * 0.45f;
        for (int i = 0; i < 8; ++i) {
            float a = i * 3.14159265f / 4;
            g.line(Point(cx + std::cos(a) * inner, cy + std::sin(a) * inner),
                   Point(cx + std::cos(a) * outer, cy + std::sin(a) * outer), color,
                   1.8f * weight, true);
        }
        g.strokeEllipse(Rect(cx - inner, cy - inner, 2 * inner, 2 * inner), color, 1.3f * weight);
        break;
    }
    }
}

// ── File icons ─────────────────────────────────────────────────────────────

namespace FileIcons {

namespace {

std::wstring gResources;
bool gLoaded = false;
bool gHaveManifest = false;
std::unordered_map<std::string, std::string> gNames, gExtensions, gFolders;

struct Cached {
    Com<ID2D1Bitmap1> bitmap;
    uint64_t lastUsed = 0;
    uint64_t generation = 0;
};
std::unordered_map<std::string, Cached> gCache;
std::unordered_map<std::string, std::optional<std::string>> gSources;
uint64_t gTick = 0;
constexpr size_t kMaxCached = 160;

void loadManifest() {
    if (gLoaded) return;
    gLoaded = true;
    if (gResources.empty()) return;
    auto text = readFile(pathJoin(gResources, L"file-icons.json"));
    if (!text) return;
    auto json = parseJson(*text);
    if (!json || !json->isObject()) return;
    auto fill = [&](const char* key, std::unordered_map<std::string, std::string>& map) {
        if (const JsonValue* table = json->get(key); table && table->isObject()) {
            for (auto& [name, value] : table->object) {
                if (value.isString()) map[name] = value.string;
            }
        }
    };
    fill("names", gNames);
    fill("extensions", gExtensions);
    fill("folders", gFolders);
    gHaveManifest = true;
}

/// The SVG text, root size attributes removed so the viewport given to
/// Direct2D decides the size and the viewBox scales into it.
std::optional<std::string> source(const std::string& icon) {
    auto hit = gSources.find(icon);
    if (hit != gSources.end()) return hit->second;
    std::optional<std::string> text = readFile(pathJoin(pathJoin(gResources, L"icons"), W(icon) + L".svg"));
    if (text) {
        size_t open = text->find("<svg");
        size_t close = open == std::string::npos ? std::string::npos : text->find('>', open);
        if (open != std::string::npos && close != std::string::npos) {
            std::string tag = text->substr(open, close - open);
            for (const char* attribute : {" width=\"", " height=\""}) {
                size_t at = tag.find(attribute);
                if (at == std::string::npos) continue;
                size_t end = tag.find('"', at + strlen(attribute));
                if (end != std::string::npos) tag.erase(at, end + 1 - at);
            }
            text->replace(open, close - open, tag);
        }
    }
    gSources[icon] = text;
    return text;
}

Com<ID2D1Bitmap1> render(const std::string& icon, UINT pixels) {
    auto text = source(icon);
    if (!text) return {};
    ID2D1DeviceContext* scratch = Render::scratchContext();
    if (!scratch) return {};
    Com<ID2D1DeviceContext5> context;
    scratch->QueryInterface(__uuidof(ID2D1DeviceContext5), reinterpret_cast<void**>(context.put()));
    if (!context) return {};
    Com<IStream> stream(SHCreateMemStream(reinterpret_cast<const BYTE*>(text->data()),
                                          (UINT)text->size()));
    if (!stream) return {};
    Com<ID2D1SvgDocument> document;
    if (FAILED(context->CreateSvgDocument(stream.get(), D2D1::SizeF((float)pixels, (float)pixels),
                                          document.put()))) {
        return {};
    }
    Com<ID2D1Bitmap1> bitmap;
    D2D1_BITMAP_PROPERTIES1 props = D2D1::BitmapProperties1(
        D2D1_BITMAP_OPTIONS_TARGET,
        D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96, 96);
    if (FAILED(context->CreateBitmap(D2D1::SizeU(pixels, pixels), nullptr, 0, &props,
                                     bitmap.put()))) {
        return {};
    }
    context->SetTarget(bitmap.get());
    context->SetDpi(96, 96);
    context->BeginDraw();
    context->SetTransform(D2D1::Matrix3x2F::Identity());
    context->Clear(D2D1::ColorF(0, 0, 0, 0));
    context->DrawSvgDocument(document.get());
    HRESULT hr = context->EndDraw();
    context->SetTarget(nullptr);
    if (FAILED(hr)) return {};
    return bitmap;
}

void evictIfNeeded() {
    if (gCache.size() <= kMaxCached) return;
    // Drop the least recently drawn quarter, so eviction is occasional.
    std::vector<std::pair<uint64_t, std::string>> order;
    for (auto& [key, cached] : gCache) order.emplace_back(cached.lastUsed, key);
    std::sort(order.begin(), order.end());
    size_t excess = gCache.size() - kMaxCached * 3 / 4;
    for (size_t i = 0; i < excess && i < order.size(); ++i) gCache.erase(order[i].second);
}

}  // namespace

void useResources(const std::wstring& directory) {
    gResources = directory;
    gLoaded = false;
    gHaveManifest = false;
    gNames.clear();
    gExtensions.clear();
    gFolders.clear();
    gCache.clear();
    gSources.clear();
}

std::string fileIconName(const std::string& name) {
    loadManifest();
    if (!gHaveManifest) return "";
    std::string lowered = lowercased(name);
    if (auto it = gNames.find(lowered); it != gNames.end()) return it->second;
    size_t dot = lowered.find('.');
    while (dot != std::string::npos) {
        std::string suffix = lowered.substr(dot + 1);
        if (auto it = gExtensions.find(suffix); it != gExtensions.end()) return it->second;
        dot = lowered.find('.', dot + 1);
    }
    return "file";
}

std::string folderIconName(const std::string& name, bool expanded) {
    loadManifest();
    if (!gHaveManifest) return "";
    if (auto it = gFolders.find(lowercased(name)); it != gFolders.end()) return it->second;
    return expanded ? "folder-open" : "folder";
}

ID2D1Bitmap* bitmap(const std::string& icon, const Rect& rect, float scale) {
    if (icon.empty() || gResources.empty()) return nullptr;
    UINT pixels = (UINT)std::max(1.0f, std::round(std::min(rect.w, rect.h) * scale));
    std::string key = icon + "@" + std::to_string(pixels);
    auto it = gCache.find(key);
    if (it != gCache.end() && it->second.generation == Render::generation()) {
        it->second.lastUsed = ++gTick;
        return it->second.bitmap.get();
    }
    Cached cached;
    cached.bitmap = render(icon, pixels);
    cached.lastUsed = ++gTick;
    cached.generation = Render::generation();
    gCache[key] = std::move(cached);
    evictIfNeeded();
    auto again = gCache.find(key);
    return again == gCache.end() ? nullptr : again->second.bitmap.get();
}

bool draw(Graphics& g, const std::string& icon, const Rect& rect) {
    float size = std::min(rect.w, rect.h);
    Rect fitted = g.snapped(
        Rect(std::floor(rect.midX() - size / 2), std::floor(rect.midY() - size / 2), size, size));
    ID2D1Bitmap* image = bitmap(icon, fitted, g.scale());
    if (!image) return false;
    g.drawBitmap(image, fitted);
    return true;
}

void releaseTransientMemory() {
    gCache.clear();
    gSources.clear();
}

}  // namespace FileIcons

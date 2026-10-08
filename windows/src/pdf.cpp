#include "previews.h"

#include "prefs.h"
#include "theme.h"

#include <asyncinfo.h>
#include <inspectable.h>
#include <roapi.h>
#include <shcore.h>
#include <thread>
#include <winstring.h>

// ── Windows.Data.Pdf, declared by hand (mingw ships no header for it) ──────

namespace {

struct PdfSize {
    FLOAT Width;
    FLOAT Height;
};

struct IAsyncOperationPdf : public IInspectable {
    virtual HRESULT STDMETHODCALLTYPE put_Completed(IUnknown* handler) = 0;
    virtual HRESULT STDMETHODCALLTYPE get_Completed(IUnknown** handler) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetResults(IInspectable** results) = 0;
};

struct IPdfPage : public IInspectable {
    virtual HRESULT STDMETHODCALLTYPE RenderToStreamAsync(IUnknown* stream, IUnknown** action) = 0;
    virtual HRESULT STDMETHODCALLTYPE RenderWithOptionsToStreamAsync(IUnknown*, IUnknown*, IUnknown**) = 0;
    virtual HRESULT STDMETHODCALLTYPE PreparePageAsync(IUnknown** action) = 0;
    virtual HRESULT STDMETHODCALLTYPE get_Index(UINT32* index) = 0;
    virtual HRESULT STDMETHODCALLTYPE get_Size(PdfSize* size) = 0;
};

struct IPdfDocument : public IInspectable {
    virtual HRESULT STDMETHODCALLTYPE GetPage(UINT32 index, IPdfPage** page) = 0;
    virtual HRESULT STDMETHODCALLTYPE get_PageCount(UINT32* count) = 0;
    virtual HRESULT STDMETHODCALLTYPE get_IsPasswordProtected(boolean* value) = 0;
};

struct IPdfDocumentStatics : public IInspectable {
    virtual HRESULT STDMETHODCALLTYPE LoadFromFileAsync(IUnknown* file, IAsyncOperationPdf** op) = 0;
    virtual HRESULT STDMETHODCALLTYPE LoadFromFileWithPasswordAsync(IUnknown* file, HSTRING password,
                                                                    IAsyncOperationPdf** op) = 0;
    virtual HRESULT STDMETHODCALLTYPE LoadFromStreamAsync(IUnknown* stream, IAsyncOperationPdf** op) = 0;
};

struct PDF_RENDER_PARAMS {
    D2D1_RECT_F SourceRect;
    UINT32 DestinationWidth;
    UINT32 DestinationHeight;
    D2D1_COLOR_F BackgroundColor;
    BOOLEAN IgnoreHighContrast;
};

struct IPdfRendererNative : public IUnknown {
    virtual HRESULT STDMETHODCALLTYPE RenderPageToSurface(IUnknown* page, IDXGISurface* surface, POINT offset,
                                                          PDF_RENDER_PARAMS* params) = 0;
    virtual HRESULT STDMETHODCALLTYPE RenderPageToDeviceContext(IUnknown* page, ID2D1DeviceContext* context,
                                                                PDF_RENDER_PARAMS* params) = 0;
};

const IID kIPdfDocumentStatics = {0x433A0B5F, 0xC007, 0x4788, {0x90, 0xF2, 0x08, 0x14, 0x3D, 0x92, 0x25, 0x99}};
const IID kIPdfDocument = {0xAC7EBEDD, 0x80FA, 0x4089, {0x84, 0x6E, 0x81, 0xB7, 0x7F, 0xF5, 0xA8, 0x6C}};
const IID kIRandomAccessStream = {0x905A0FE1, 0xBC53, 0x11DF, {0x8C, 0x49, 0x00, 0x1E, 0x4F, 0xC6, 0x86, 0xDA}};

using PdfCreateRendererFn = HRESULT(WINAPI*)(IDXGIDevice*, IPdfRendererNative**);

constexpr float kHeaderHeight = 30;
constexpr float kThumbnailColumn = 150;
constexpr float kPageGap = 10;
constexpr wchar_t kPositionKey[] = L"PuzzlePDFPages";

}  // namespace

/// The loaded document: its pages and their sizes, read once.
struct PDFPreviewView::Document {
    Com<IPdfDocument> document;
    std::vector<Com<IPdfPage>> pages;
    std::vector<Size> sizes;
    bool locked = false;
    std::wstring error;
};

namespace {

std::shared_ptr<PDFPreviewView::Document> loadDocument(const std::wstring& path) {
    auto out = std::make_shared<PDFPreviewView::Document>();
    Com<IUnknown> stream;
    // FileAccessMode.Read is 0.
    if (FAILED(CreateRandomAccessStreamOnFile(path.c_str(), 0, kIRandomAccessStream,
                                              reinterpret_cast<void**>(stream.put())))) {
        out->error = L"This PDF could not be opened. It may be damaged or contain no pages.";
        return out;
    }
    HSTRING className = nullptr;
    const wchar_t* name = L"Windows.Data.Pdf.PdfDocument";
    WindowsCreateString(name, (UINT32)wcslen(name), &className);
    Com<IPdfDocumentStatics> statics;
    HRESULT hr = RoGetActivationFactory(className, kIPdfDocumentStatics, reinterpret_cast<void**>(statics.put()));
    WindowsDeleteString(className);
    if (FAILED(hr) || !statics) {
        out->error = L"Windows could not load its PDF reader on this computer.";
        return out;
    }
    Com<IAsyncOperationPdf> operation;
    if (FAILED(statics->LoadFromStreamAsync(stream.get(), operation.put())) || !operation) {
        out->error = L"This PDF could not be opened. It may be damaged or contain no pages.";
        return out;
    }
    Com<IAsyncInfo> info = operation.as<IAsyncInfo>();
    AsyncStatus status = Started;
    for (int i = 0; info && i < 6000; ++i) {
        if (FAILED(info->get_Status(&status)) || status != Started) break;
        Sleep(10);
    }
    if (status != Completed) {
        HRESULT code = S_OK;
        if (info) info->get_ErrorCode(&code);
        // A password stops the load outright: say why rather than "damaged".
        bool password = code == HRESULT_FROM_WIN32(ERROR_WRONG_PASSWORD) || code == (HRESULT)0x8007052B;
        out->locked = password;
        out->error = password ? L"This PDF is password-protected. Open an unlocked copy to read it here."
                              : L"This PDF could not be opened. It may be damaged or contain no pages.";
        return out;
    }
    Com<IInspectable> result;
    if (FAILED(operation->GetResults(result.put())) || !result) {
        out->error = L"This PDF could not be opened. It may be damaged or contain no pages.";
        return out;
    }
    result->QueryInterface(kIPdfDocument, reinterpret_cast<void**>(out->document.put()));
    if (!out->document) {
        out->error = L"This PDF could not be opened. It may be damaged or contain no pages.";
        return out;
    }
    UINT32 count = 0;
    out->document->get_PageCount(&count);
    if (count == 0) {
        out->error = L"This PDF could not be opened. It may be damaged or contain no pages.";
        return out;
    }
    for (UINT32 i = 0; i < count; ++i) {
        Com<IPdfPage> page;
        out->document->GetPage(i, page.put());
        PdfSize size{612, 792};
        if (page) page->get_Size(&size);
        out->pages.push_back(page);
        out->sizes.push_back(Size(std::max(1.0f, size.Width), std::max(1.0f, size.Height)));
    }
    return out;
}

IPdfRendererNative* renderer() {
    static Com<IPdfRendererNative> made;
    static uint64_t generation = 0;
    if (made && generation == Render::generation()) return made.get();
    made.reset();
    static PdfCreateRendererFn create = reinterpret_cast<PdfCreateRendererFn>(reinterpret_cast<void*>(
        GetProcAddress(LoadLibraryW(L"Windows.Data.Pdf.dll"), "PdfCreateRenderer")));
    ID3D11Device* d3d = Render::d3dDevice();
    if (!create || !d3d) return nullptr;
    Com<IDXGIDevice> dxgi;
    d3d->QueryInterface(__uuidof(IDXGIDevice), reinterpret_cast<void**>(dxgi.put()));
    if (!dxgi || FAILED(create(dxgi.get(), made.put()))) return nullptr;
    generation = Render::generation();
    return made.get();
}

/// One page drawn at `width × height` pixels into a bitmap on the shared device.
Com<ID2D1Bitmap1> renderPage(IPdfPage* page, UINT width, UINT height) {
    IPdfRendererNative* native = renderer();
    ID2D1DeviceContext* context = Render::scratchContext();
    if (!native || !context || !page || !width || !height) return {};
    Com<ID2D1Bitmap1> bitmap;
    D2D1_BITMAP_PROPERTIES1 props = D2D1::BitmapProperties1(
        D2D1_BITMAP_OPTIONS_TARGET, D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96, 96);
    if (FAILED(context->CreateBitmap(D2D1::SizeU(width, height), nullptr, 0, &props, bitmap.put()))) return {};
    context->SetTarget(bitmap.get());
    context->SetDpi(96, 96);
    context->BeginDraw();
    context->SetTransform(D2D1::Matrix3x2F::Identity());
    context->Clear(D2D1::ColorF(1, 1, 1, 1));
    PDF_RENDER_PARAMS params{};
    params.DestinationWidth = width;
    params.DestinationHeight = height;
    params.BackgroundColor = D2D1::ColorF(1, 1, 1, 1);
    params.IgnoreHighContrast = TRUE;
    HRESULT hr = native->RenderPageToDeviceContext(page, context, &params);
    HRESULT end = context->EndDraw();
    context->SetTarget(nullptr);
    if (FAILED(hr) || FAILED(end)) return {};
    return bitmap;
}

/// Bitmaps of rendered pages, newest last, a handful kept.
struct PageCache {
    struct Entry {
        int index;
        UINT width;
        Com<ID2D1Bitmap1> bitmap;
        uint64_t generation;
    };
    std::vector<Entry> entries;
    size_t limit = 14;
    ID2D1Bitmap1* find(int index, UINT width) {
        for (size_t i = 0; i < entries.size(); ++i) {
            if (entries[i].index == index && entries[i].width == width
                && entries[i].generation == Render::generation()) {
                Entry e = entries[i];
                entries.erase(entries.begin() + i);
                entries.push_back(e);
                return entries.back().bitmap.get();
            }
        }
        return nullptr;
    }
    void add(int index, UINT width, Com<ID2D1Bitmap1> bitmap) {
        entries.push_back({index, width, std::move(bitmap), Render::generation()});
        while (entries.size() > limit) entries.erase(entries.begin());
    }
    void clear() { entries.clear(); }
};

}  // namespace

// ── The pages, scrolled as one column ──────────────────────────────────────

class PDFPreviewView::Pages : public ScrollArea {
public:
    std::shared_ptr<Document> document;
    std::function<void()> onPageChanged;
    PageCache cache;
    std::set<int> pending;
    int lastPage = -1;
    Lifetime life;

    Pages() {
        backgroundColor = Theme::editorBackground;
        onScroll = [this] { noteScroll(); };
    }

    float pageWidth() const { return std::max(40.0f, bounds().w - kPageGap * 2); }

    std::vector<Rect> frames() const {
        std::vector<Rect> out;
        if (!document) return out;
        float y = kPageGap;
        float width = pageWidth();
        for (auto& size : document->sizes) {
            float height = width * size.h / size.w;
            out.push_back(Rect(kPageGap, y, width, height));
            y += height + kPageGap;
        }
        return out;
    }

    void relayout() {
        auto f = frames();
        setContentSize(Size(bounds().w, f.empty() ? 0 : f.back().maxY() + kPageGap));
        setNeedsDisplay();
    }

    void layout() override {
        ScrollArea::layout();
        relayout();
    }

    int currentPage() const {
        auto f = frames();
        float probe = contentOffset().y + bounds().h * 0.3f;
        for (size_t i = 0; i < f.size(); ++i) {
            if (probe < f[i].maxY() + kPageGap) return (int)i;
        }
        return f.empty() ? 0 : (int)f.size() - 1;
    }

    void goTo(int index) {
        auto f = frames();
        if (index < 0 || index >= (int)f.size()) return;
        setContentOffset(Point(0, f[index].y - kPageGap), true);
        noteScroll();
    }

    void noteScroll() {
        int page = currentPage();
        if (page != lastPage) {
            lastPage = page;
            if (onPageChanged) onPageChanged();
        }
    }

    void schedule(int index, UINT width) {
        if (pending.count(index)) return;
        pending.insert(index);
        // One page per turn of the loop, so scrolling stays responsive.
        Dispatch::main([this, index, width, alive = life.weak(), doc = document] {
            if (alive.expired() || doc != document) return;
            pending.erase(index);
            if (!document || index >= (int)document->pages.size()) return;
            const Size& size = document->sizes[index];
            UINT height = (UINT)std::max(1.0f, std::round(width * size.h / size.w));
            if (auto bitmap = renderPage(document->pages[index].get(), width, height)) {
                cache.add(index, width, bitmap);
                setNeedsDisplay();
            }
        });
    }

    void drawContent(Graphics& g, const Rect& visible) override {
        if (!document) return;
        float scale = g.scale();
        auto f = frames();
        for (size_t i = 0; i < f.size(); ++i) {
            if (!f[i].intersects(visible)) continue;
            g.fillRect(f[i].inset(-1, -1), Theme::border);
            UINT width = (UINT)std::max(1.0f, std::round(f[i].w * scale));
            if (ID2D1Bitmap1* bitmap = cache.find((int)i, width)) {
                g.drawBitmap(bitmap, f[i]);
            } else {
                g.fillRect(f[i], Color(1, 1, 1));
                schedule((int)i, width);
            }
        }
    }
};

// ── Thumbnails down the side ───────────────────────────────────────────────

class PDFPreviewView::Thumbnails : public ScrollArea {
public:
    std::shared_ptr<Document> document;
    std::function<void(int)> onSelect;
    int current = 0;
    PageCache cache;
    std::set<int> pending;
    Lifetime life;
    static constexpr float cell = 150;

    Thumbnails() {
        backgroundColor = Theme::panelBackground;
        cache.limit = 40;
    }

    Rect thumbFrame(int index) const {
        if (!document) return {};
        const Size& size = document->sizes[index];
        float scale = std::min(108 / size.w, 140 / size.h);
        Size fitted(size.w * scale, size.h * scale);
        float top = index * cell + 4;
        return Rect(std::round((bounds().w - fitted.w) / 2), top + (140 - fitted.h) / 2, fitted.w, fitted.h);
    }

    void relayout() {
        setContentSize(Size(bounds().w, document ? document->sizes.size() * cell + 8 : 0));
        setNeedsDisplay();
    }

    void layout() override {
        ScrollArea::layout();
        relayout();
    }

    void reveal(int index) {
        float top = index * cell, bottom = top + cell;
        Rect v = visibleContentRect();
        if (top < v.y) setContentOffset(Point(0, top));
        else if (bottom > v.maxY()) setContentOffset(Point(0, bottom - v.h));
    }

    void drawContent(Graphics& g, const Rect& visible) override {
        if (!document) return;
        float scale = g.scale();
        for (int i = 0; i < (int)document->sizes.size(); ++i) {
            Rect cellRect(4, i * cell, bounds().w - 8, cell);
            if (!cellRect.intersects(visible)) continue;
            if (i == current) g.fillRoundedRect(cellRect.inset(0, 2), 5, Theme::selectedControl);
            Rect f = thumbFrame(i);
            g.fillRect(f.inset(-1, -1), Theme::border);
            UINT width = (UINT)std::max(1.0f, std::round(f.w * scale));
            if (ID2D1Bitmap1* bitmap = cache.find(i, width)) {
                g.drawBitmap(bitmap, f);
            } else {
                g.fillRect(f, Color(1, 1, 1));
                if (!pending.count(i)) {
                    pending.insert(i);
                    Dispatch::main([this, i, width, alive = life.weak(), doc = document] {
                        if (alive.expired() || doc != document) return;
                        pending.erase(i);
                        const Size& size = document->sizes[i];
                        UINT height = (UINT)std::max(1.0f, std::round(width * size.h / size.w));
                        if (auto bitmap = renderPage(document->pages[i].get(), width, height)) {
                            cache.add(i, width, bitmap);
                            setNeedsDisplay();
                        }
                    });
                }
            }
            g.text(std::to_wstring(i + 1), Theme::uiFont(10), Theme::dimText,
                   Rect(cellRect.x, i * cell + 146 - 4, cellRect.w, 0.01f), LineBreak::Clipping, Align::Center);
        }
    }

    bool contentMouseDown(const MouseEvent&, Point p) override {
        if (!document) return false;
        int index = (int)(p.y / cell);
        if (index >= 0 && index < (int)document->sizes.size() && onSelect) onSelect(index);
        return true;
    }
};

// ── PDFPreviewView ─────────────────────────────────────────────────────────

PDFPreviewView::PDFPreviewView() : pages_(std::make_unique<Pages>()), thumbnails_(std::make_unique<Thumbnails>()) {
    backgroundColor = Theme::editorBackground;
    auto configure = [this](SymbolButton& b, Symbol symbol, const wchar_t* tip, std::function<void()> action) {
        b.symbol = symbol;
        b.symbolSize = 11;
        b.weight = 1.1f;
        b.tint = Theme::dimText;
        b.hoverBackground = true;
        b.tooltip = tip;
        b.onClick = std::move(action);
        addSubview(&b);
    };
    configure(thumbnailsButton_, Symbol::SplitRectangle, L"Page thumbnails",
              [this] { setThumbnailsVisible(!showsThumbnails_); });
    configure(previousButton_, Symbol::ChevronLeft, L"Previous page", [this] { goToPage(currentPageIndex() - 1); });
    configure(nextButton_, Symbol::ChevronRight, L"Next page", [this] { goToPage(currentPageIndex() + 1); });
    addSubview(thumbnails_.get());
    addSubview(pages_.get());
    pages_->onPageChanged = [this] {
        updatePageLabel();
        rememberPage();
    };
    thumbnails_->onSelect = [this](int index) { goToPage(index); };
}

PDFPreviewView::~PDFPreviewView() { clear(); }

void PDFPreviewView::layout() {
    Rect b = bounds();
    float y = std::floor((kHeaderHeight - 22) / 2);
    thumbnailsButton_.setFrame(Rect(6, y, 28, 22));
    nextButton_.setFrame(Rect(b.w - 28 - 6, y, 28, 22));
    previousButton_.setFrame(Rect(nextButton_.frame().x - 28, y, 28, 22));
    bool thumbs = showsThumbnails_ && document_ && notice_.empty();
    float left = thumbs ? kThumbnailColumn : 0;
    thumbnails_->setHidden(!thumbs);
    thumbnails_->setFrame(Rect(0, kHeaderHeight, kThumbnailColumn, std::max(0.0f, b.h - kHeaderHeight)));
    pages_->setHidden(!document_ || !notice_.empty());
    pages_->setFrame(Rect(left, kHeaderHeight, std::max(0.0f, b.w - left), std::max(0.0f, b.h - kHeaderHeight)));
}

void PDFPreviewView::draw(Graphics& g) {
    Rect b = bounds();
    g.fillRect(Rect(0, 0, b.w, kHeaderHeight), Theme::barBackground);
    g.fillRect(Rect(0, kHeaderHeight - 1, b.w, 1), Theme::border);
    float left = thumbnailsButton_.frame().maxX() + 8;
    float right = previousButton_.frame().x - 8;
    float pageWidth = 86;
    g.text(title_, Theme::uiFont(11.5f), Theme::foreground,
           Rect(left, 0, std::max(0.0f, right - left - pageWidth - 8), kHeaderHeight), LineBreak::TruncatingMiddle);
    g.text(pageLabel_, Theme::uiFont(10.5f), Theme::dimText, Rect(std::max(left, right - pageWidth), 0, pageWidth, kHeaderHeight),
           LineBreak::Clipping, Align::Right);
    if (!notice_.empty()) {
        Rect area(24, kHeaderHeight, std::max(0.0f, b.w - 48), b.h - kHeaderHeight);
        float h = Text::wrappedHeight(notice_, Theme::uiFont(12), area.w);
        g.wrappedText(notice_, Theme::uiFont(12), Theme::dimText, Rect(area.x, area.midY() - h / 2, area.w, h),
                      Align::Center);
    }
}

bool PDFPreviewView::show(const std::wstring& path, const std::wstring& caption) {
    if (samePath(loadedPath_, path) && document_) return true;
    clear();
    loadedPath_ = path;
    title_ = caption;
    tooltip = path;
    notice_.clear();
    int generation = ++loadGeneration_;
    pageLabel_ = L"Loading…";
    Dispatch::background([this, path, generation, alive = life_.weak()] {
        RoInitialize(RO_INIT_MULTITHREADED);
        auto loaded = loadDocument(path);
        Dispatch::main([this, loaded, generation, alive] {
            if (alive.expired() || generation != loadGeneration_) return;
            if (!loaded->error.empty()) {
                showNotice(loaded->error);
                return;
            }
            document_ = loaded;
            pages_->document = loaded;
            pages_->cache.clear();
            thumbnails_->document = loaded;
            thumbnails_->cache.clear();
            setNeedsLayout();
            layoutSubtreeIfNeeded();
            pages_->relayout();
            thumbnails_->relayout();
            // Where the reader had got to.
            int saved = 0;
            for (auto& entry : Prefs::stringList(kPositionKey)) {
                size_t bar = entry.find(L'|');
                if (bar != std::wstring::npos && samePath(entry.substr(bar + 1), loadedPath_)) {
                    saved = _wtoi(entry.substr(0, bar).c_str());
                }
            }
            saved = std::clamp(saved, 0, (int)loaded->pages.size() - 1);
            Dispatch::main([this, saved, alive] {
                if (!alive.expired()) goToPage(saved);
            });
            updatePageLabel();
            setNeedsDisplay();
        });
    });
    setNeedsLayout();
    setNeedsDisplay();
    return true;
}

void PDFPreviewView::showNotice(const std::wstring& message) {
    notice_ = message;
    pageLabel_.clear();
    previousButton_.setEnabled(false);
    nextButton_.setEnabled(false);
    thumbnailsButton_.setEnabled(false);
    setNeedsLayout();
    setNeedsDisplay();
}

void PDFPreviewView::clear() {
    rememberPage();
    ++loadGeneration_;
    document_.reset();
    pages_->document.reset();
    pages_->cache.clear();
    pages_->lastPage = -1;
    thumbnails_->document.reset();
    thumbnails_->cache.clear();
    loadedPath_.clear();
    title_.clear();
    pageLabel_.clear();
    notice_.clear();
    thumbnailsButton_.setEnabled(true);
    setNeedsLayout();
    setNeedsDisplay();
}

void PDFPreviewView::refreshFonts() { setNeedsDisplay(); }

void PDFPreviewView::setThumbnailsVisible(bool visible) {
    showsThumbnails_ = visible;
    setNeedsLayout();
    setNeedsDisplay();
}

int PDFPreviewView::currentPageIndex() const { return document_ ? pages_->currentPage() : 0; }

void PDFPreviewView::goToPage(int index) {
    if (!document_ || index < 0 || index >= (int)document_->pages.size()) return;
    pages_->goTo(index);
    updatePageLabel();
}

void PDFPreviewView::updatePageLabel() {
    if (!document_) return;
    int index = currentPageIndex();
    int count = (int)document_->pages.size();
    pageLabel_ = std::to_wstring(index + 1) + L" / " + std::to_wstring(count);
    previousButton_.setEnabled(index > 0);
    nextButton_.setEnabled(index + 1 < count);
    thumbnails_->current = index;
    thumbnails_->reveal(index);
    thumbnails_->setNeedsDisplay();
    setNeedsDisplay();
}

void PDFPreviewView::rememberPage() {
    if (!document_ || loadedPath_.empty()) return;
    auto entries = Prefs::stringList(kPositionKey);
    std::vector<std::wstring> kept;
    for (auto& entry : entries) {
        size_t bar = entry.find(L'|');
        if (bar != std::wstring::npos && samePath(entry.substr(bar + 1), loadedPath_)) continue;
        kept.push_back(entry);
    }
    kept.push_back(std::to_wstring(currentPageIndex()) + L"|" + loadedPath_);
    while (kept.size() > 200) kept.erase(kept.begin());
    Prefs::setStringList(kPositionKey, kept);
}

// What the editor shows instead of text: pictures, SVG drawings, players,
// PDFs and books (ImagePreviewView.swift, SVGPreviewView.swift,
// MediaPreviewView.swift, PDFPreviewView.swift, EPUBReaderView.swift).
#pragma once

#include "imaging.h"
#include "widgets.h"

/// A decoded picture, centred, scaled down to fit but never up, on a
/// checkerboard, with its caption underneath.
class ImagePreviewView : public View {
public:
    ImagePreviewView();
    void show(const std::wstring& path, Size pixelSize, const std::wstring& caption);
    void clear();
    void refreshFonts();
    void layout() override;
    void draw(Graphics& g) override;
private:
    void decode(UINT maximum);
    Rect imageFrame() const;
    std::wstring path_;
    Size pixelSize_;
    std::wstring caption_;
    Com<IWICBitmapSource> source_;
    Com<ID2D1Bitmap> bitmap_;
    uint64_t bitmapGeneration_ = 0;
    UINT decodedMaximum_ = 0;
    std::shared_ptr<Dispatch::Pending> resizeWork_;
    Lifetime life_;
};

/// One picture an SVG describes.
struct SVGImage {
    std::string source;
    Size size;
};

/// The picture an SVG describes, drawn above the source; two panes for a diff.
class SVGPreviewView : public View {
public:
    struct Pane {
        std::optional<std::wstring> title;
        std::optional<SVGImage> image;
        std::optional<std::wstring> caption;
        std::optional<std::wstring> note;
    };
    SVGPreviewView();
    void show(std::vector<Pane> panes);
    void clear();
    void draw(Graphics& g) override;
    /// Nullopt when the text does not describe a picture.
    static std::optional<SVGImage> render(const std::string& text);
    static std::wstring caption(const std::optional<std::wstring>& name, const std::optional<SVGImage>& image,
                                size_t bytes);
private:
    void drawPane(Graphics& g, Pane& pane, const Rect& rect, size_t index);
    std::vector<Pane> panes_;
    struct Rendered {
        Com<ID2D1Bitmap1> bitmap;
        UINT width = 0, height = 0;
        uint64_t generation = 0;
    };
    std::vector<Rendered> rendered_;
};

/// Draws the grey squares that stand in for transparency.
void drawCheckerboard(Graphics& g, const Rect& frame);

/// A video or audio file, played by Media Foundation.
class MediaPreviewView : public View {
public:
    MediaPreviewView();
    ~MediaPreviewView() override;
    void show(const std::wstring& path, const std::wstring& caption, bool isVideo);
    void clear();
    void refreshFonts();
    const std::wstring& loadedPath() const { return loadedPath_; }
    void layout() override;
    void draw(Graphics& g) override;
    void updateNative() override;
    bool mouseDown(const MouseEvent& e) override;
    void mouseDragged(const MouseEvent& e) override;
    void mouseUp(const MouseEvent& e) override;
    Cursor cursorAt(Point p) override;

    struct Player;
    void playerEvent(int kind, HRESULT status);

    static constexpr float preferredWidth = 420;
    static constexpr float barHeight = 26;

private:
    Rect transportRect() const;
    Rect videoRect() const;
    Rect playRect() const;
    Rect railRect() const;
    void togglePlayback();
    void seek(float fraction);
    void tick();
    void describe();
    std::wstring loadedPath_;
    std::wstring baseCaption_;
    std::wstring caption_;
    bool isVideo_ = false;
    bool playing_ = false;
    double duration_ = 0;
    double elapsed_ = 0;
    bool scrubbing_ = false;
    float progress_ = 0;
    HWND videoWindow_ = nullptr;
    std::unique_ptr<Player> player_;
    Dispatch::RepeatingTimer timer_;
    Lifetime life_;
};

/// A PDF: page thumbnails on the left, the pages on the right.
class PDFPreviewView : public View {
public:
    PDFPreviewView();
    ~PDFPreviewView() override;
    bool show(const std::wstring& path, const std::wstring& caption);
    void clear();
    void refreshFonts();
    bool thumbnailsVisible() const { return showsThumbnails_; }
    void setThumbnailsVisible(bool visible);
    void layout() override;
    void draw(Graphics& g) override;

    struct Document;
private:
    class Pages;
    class Thumbnails;
    void showNotice(const std::wstring& message);
    void updatePageLabel();
    void rememberPage();
    void goToPage(int index);
    int currentPageIndex() const;

    std::wstring loadedPath_;
    std::wstring title_;
    std::wstring pageLabel_;
    std::wstring notice_;
    bool showsThumbnails_ = true;
    SymbolButton thumbnailsButton_;
    SymbolButton previousButton_;
    SymbolButton nextButton_;
    std::shared_ptr<Document> document_;
    std::unique_ptr<Pages> pages_;
    std::unique_ptr<Thumbnails> thumbnails_;
    int loadGeneration_ = 0;
    Lifetime life_;
};

class EPUBReaderView;

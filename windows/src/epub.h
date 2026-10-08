// EPUB: the ZIP container, the package that orders the chapters, a renderer
// that reads a chapter's markup for its structure, and the reader pane
// (ZipArchive.swift, EPUBBook.swift, EPUBRenderer.swift, EPUBReaderView.swift).
#pragma once

#include "widgets.h"

#include <string_view>

/// Read-only ZIP: the central directory, and single entries inflated on demand.
class ZipArchive {
public:
    static constexpr size_t maxEntryBytes = 64 * 1024 * 1024;
    static std::unique_ptr<ZipArchive> open(const std::wstring& path);
    ~ZipArchive();
    bool contains(const std::string& path) const { return entries_.count(path) > 0; }
    std::optional<std::string> data(const std::string& path) const;
    const std::vector<std::string>& paths() const { return order_; }
private:
    struct Entry {
        uint16_t method;
        size_t compressed, uncompressed, localHeader;
    };
    ZipArchive() = default;
    HANDLE file_ = INVALID_HANDLE_VALUE;
    HANDLE mapping_ = nullptr;
    const uint8_t* bytes_ = nullptr;
    size_t size_ = 0;
    std::map<std::string, Entry> entries_;
    std::vector<std::string> order_;
};

/// Raw DEFLATE into a buffer of known size; nullopt for a corrupt stream.
std::optional<std::string> inflateRaw(const uint8_t* data, size_t size, size_t expected);

/// A tolerant XML/XHTML element tree.
struct XmlNode {
    std::string name;  // lowercased, prefix kept ("epub:type" stays a name)
    std::vector<std::pair<std::string, std::string>> attributes;
    std::string text;  // for text nodes (name empty)
    std::vector<XmlNode> children;
    bool isText() const { return name.empty(); }
    std::optional<std::string> attribute(const std::string& key) const;
    /// The part after any namespace prefix.
    std::string localName() const;
    std::string textContent() const;
    void findAll(const std::string& local, std::vector<const XmlNode*>& out) const;
    const XmlNode* find(const std::string& local) const;
};
XmlNode parseXml(std::string_view source);

class EPUBBook {
public:
    struct Chapter {
        std::string id;
        std::string path;
        std::string title;
    };
    struct TOCEntry {
        std::string title;
        int level = 0;
        int chapterIndex = 0;
    };
    static std::unique_ptr<EPUBBook> open(const std::wstring& path);
    std::string title;
    std::optional<std::string> author;
    std::vector<Chapter> chapters;
    std::vector<TOCEntry> contents;
    std::string packageDirectory;
    std::optional<std::string> data(const std::string& path) const { return archive_->data(path); }

    static std::string displayTitle(const std::string& title);
    static std::string directory(const std::string& path);
    static std::string stripFragment(const std::string& href);
    static std::string resolve(const std::string& href, const std::string& directory);

private:
    std::unique_ptr<ZipArchive> archive_;
};

/// One chapter, read for its structure: paragraphs of styled runs, and pictures.
struct EPUBRun {
    std::wstring text;
    bool bold = false;
    bool italic = false;
    bool monospace = false;
    float sizeScale = 1;
    Color color;
    std::string link;  // "" none; "#frag", "epub:path#frag", or an absolute URL
};

struct EPUBBlock {
    enum class Kind { Text, Image };
    Kind kind = Kind::Text;
    std::vector<EPUBRun> runs;
    float fontSize = 13;
    float spacing = 0;
    float indent = 0;
    bool centered = false;
    bool heading = false;
    std::string imagePath;
};

struct EPUBChapter {
    std::vector<EPUBBlock> blocks;
    /// Element id → block index.
    std::map<std::string, size_t> anchors;
};

namespace EPUBRenderer {
float bodySize();
float readingWidth();
EPUBChapter render(const std::string& xhtml, const std::string& chapterPath, const EPUBBook& book);
std::string decodeEntities(const std::string& text);
}  // namespace EPUBRenderer

class EPUBReaderView : public View {
public:
    EPUBReaderView();
    ~EPUBReaderView() override;
    /// False when the file is not a readable EPUB.
    bool show(const std::wstring& path);
    void clear();
    void refreshFonts();
    bool contentsVisible() const { return showsContents_; }
    void setContentsVisible(bool visible);
    void layout() override;
    void draw(Graphics& g) override;

private:
    class Page;
    void load(int chapter, bool restoringScroll = false, const std::string& anchor = "");
    void rememberPosition();
    void openLink(const std::string& link);

    SymbolButton contentsButton_;
    SymbolButton previousButton_;
    SymbolButton nextButton_;
    ListView contents_;
    std::unique_ptr<Page> page_;
    std::unique_ptr<EPUBBook> book_;
    std::wstring path_;
    std::wstring title_;
    std::wstring position_;
    int chapterIndex_ = 0;
    bool showsContents_ = true;
};

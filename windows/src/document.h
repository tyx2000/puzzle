// An open file's buffer, shared between every pane that shows it
// (Document.swift). The text lives in a Scintilla document; this object
// holds what the editor knows about it: where it came from, how it was
// decoded, whether it may be written back, and the structure read off it.
#pragma once

#include "imaging.h"
#include "markdown.h"
#include "scidoc.h"
#include "structure.h"
#include "syntax.h"

/// The two pictures an SVG diff is about: what Git has, and what the working
/// tree has. Either can be missing.
struct SVGDiffSides {
    std::optional<std::string> before;
    std::optional<std::string> after;
};

/// A synthetic address for a generated Git preview: the window it belongs
/// to, the repository, the file, and — for History — the commit.
namespace DiffURL {
struct Parts {
    std::wstring window;
    std::wstring directory;
    std::string path;
    std::string commit;
};
std::wstring make(const std::wstring& window, const std::wstring& directory, const std::string& path,
                  const std::string& commit = "");
std::optional<Parts> parse(const std::wstring& url);
bool is(const std::wstring& url);
}  // namespace DiffURL

class Document {
public:
    static const std::set<std::string>& imageExtensions();
    static const std::set<std::string>& vectorImageExtensions();
    static const std::set<std::string>& videoExtensions();
    static const std::set<std::string>& audioExtensions();
    static const std::set<std::string>& mediaExtensions();
    static const std::set<std::string>& bookExtensions();
    static constexpr size_t maxTextFileBytes = 16 * 1024 * 1024;
    static constexpr size_t maxImageFileBytes = 32 * 1024 * 1024;
    static constexpr size_t maxDisplayLineLength = 20000;
    static constexpr size_t minifiedPreviewLength = 200000;

    /// A file on disk.
    explicit Document(const std::wstring& path);
    /// An in-memory document (a Git diff).
    Document(const std::wstring& virtualURL, const std::string& text, const std::wstring& displayName);
    ~Document();
    Document(const Document&) = delete;
    Document& operator=(const Document&) = delete;

    const std::wstring url;
    SciDoc::Handle handle() const { return sci_; }
    const LanguageSpec* languageSpec() const { return spec_; }
    std::string languageName() const { return spec_ ? spec_->name : std::string(); }

    bool isModified = false;
    /// How many editor views have this buffer attached: a buffer on screen is
    /// never evicted (a storage with layout managers, on the Mac).
    int attachedViews = 0;
    bool isUnsupported() const { return isUnsupported_; }
    bool isVirtual() const { return isVirtual_; }
    bool isImage() const { return previewImage_.has_value(); }
    const std::optional<Imaging::Info>& previewImage() const { return previewImage_; }
    bool isMedia() const { return isMedia_; }
    bool isVideoMedia() const { return isVideoMedia_; }
    bool isEPUB() const { return isEPUB_; }
    bool isPDF() const { return isPDF_; }
    bool isSVG() const;
    /// A preview view owns the pane and the buffer holds a caption.
    bool isPreviewOnly() const { return isImage() || isMedia_ || isEPUB_ || isPDF_; }
    bool isReadOnly() const { return isUnsupported_ || isVirtual_ || isPreviewOnly(); }
    bool isMinifiedPreview() const { return isMinifiedPreview_; }
    bool isDisplayFormatted() const { return isDisplayFormatted_; }
    bool isApplyingExternalChange() const { return isApplyingExternalChange_; }
    bool hasDiskConflict() const { return hasDiskConflict_; }

    std::wstring name() const { return lastPathComponent(url); }
    const std::optional<std::wstring>& displayName() const { return displayName_; }
    std::string text() const { return SciDoc::text(sci_); }
    std::string_view view() const { return SciDoc::view(sci_); }
    size_t length() const { return SciDoc::length(sci_); }
    int lineCount() const { return SciDoc::lineCount(sci_); }

    /// The two sides of an SVG diff, when this buffer is one.
    std::optional<SVGDiffSides> svgDiffSides;
    /// Full-width line tints for a diff buffer.
    std::vector<std::pair<TextRange, Color>> diffBands;
    /// The file line number for each line of a diff buffer.
    std::vector<std::optional<int>> diffLineNumbers;

    const std::vector<CodeBlock>& codeBlocks() const { return codeBlocks_; }
    const std::vector<JSXTagMatch>& jsxTagMatches() const { return jsxTagMatches_; }
    const MarkdownPresentation& markdown() const { return markdown_; }

    void refreshCodeBlocks();
    void updateJSXTagMatches(std::vector<JSXTagMatch> matches);
    void updateMarkdownPresentation(MarkdownPresentation presentation);

    /// The style bytes the highlighter painted, before any reveal — kept for
    /// Markdown so a revealed line can be put back.
    std::vector<unsigned char> baseStyles;
    /// Show the hidden Markdown syntax inside `range`, hiding it again where
    /// it was shown before.
    void applyMarkdownReveal(std::optional<TextRange> range);
    std::optional<TextRange> appliedReveal() const { return appliedReveal_; }
    void forgetReveal() { appliedReveal_.reset(); }

    /// Counts swaps of a virtual buffer's content, so a rebuild that started
    /// earlier can tell it is no longer wanted.
    int contentReplacements() const { return contentReplacements_; }
    void replaceVirtualContent(const std::string& text, const std::optional<std::wstring>& displayName);

    size_t estimatedMemoryCost() const { return std::max<size_t>(length() * 3, 1024); }

    /// Whoever is about to save has told the user and got an answer.
    void resolveDiskConflict() { hasDiskConflict_ = false; }
    /// Throw the buffer away and take what is on disk.
    bool discardEditsAndReloadFromDisk();
    /// Has the file changed since this buffer last read or wrote it?
    bool diskChangedSinceLastSync() const;
    /// Write the buffer. False with `error` explaining why.
    bool save(std::wstring* error);
    void markLocalEdit();
    /// Refresh a clean buffer from disk while preserving unsaved edits.
    bool reloadFromDiskIfLatest(int64_t observedAt = 0);

    /// What a file's bytes become on screen.
    struct Presentation {
        std::string text;
        bool isDisplayFormatted = false;
        bool isMinifiedPreview = false;
    };
    static Presentation presentation(const std::string& data, const std::string& decoded,
                                     const std::wstring& path, const LanguageSpec* spec, bool isUnsupported);
    static size_t longestLineLength(std::string_view bytes);
    /// Now, as a file time.
    static int64_t now();

private:
    void setBufferText(const std::string& text);
    static std::string unsupportedMessage(const std::wstring& path, size_t byteCount);
    static std::string unreadableMessage(const std::wstring& path, const std::wstring& error);
    static std::string largeFileMessage(const std::wstring& path, size_t byteCount, size_t limit);
    static std::string minifiedMessage(const std::wstring& path, size_t byteCount, size_t longestLine);
    static bool looksBinary(const std::string& data);

    SciDoc::Handle sci_ = nullptr;
    const LanguageSpec* spec_ = nullptr;
    bool isUnsupported_ = false;
    bool isVirtual_ = false;
    std::optional<Imaging::Info> previewImage_;
    bool isMedia_ = false;
    bool isVideoMedia_ = false;
    bool isEPUB_ = false;
    bool isPDF_ = false;
    bool isMinifiedPreview_ = false;
    bool isDisplayFormatted_ = false;
    bool isApplyingExternalChange_ = false;
    bool hasDiskConflict_ = false;
    enum class Encoding { UTF8, Latin1 } encoding_ = Encoding::UTF8;
    bool hasBOM_ = false;
    std::optional<int64_t> lastLocalEditAt_;
    std::optional<int64_t> lastKnownDiskModificationDate_;
    std::optional<std::wstring> displayName_;
    std::vector<CodeBlock> codeBlocks_;
    std::vector<JSXTagMatch> jsxTagMatches_;
    MarkdownPresentation markdown_;
    std::optional<TextRange> appliedReveal_;
    int contentReplacements_ = 0;
};

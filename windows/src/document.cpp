#include "document.h"

#include "notify.h"
#include "settings.h"

namespace DiffURL {

namespace {
constexpr wchar_t kScheme[] = L"puzzle-diff:";
}

std::wstring make(const std::wstring& window, const std::wstring& directory, const std::string& path,
                  const std::string& commit) {
    // `|` cannot appear in a Windows path, so it separates the parts.
    return std::wstring(kScheme) + window + L"|" + directory + L"|" + W(path) + L"|" + W(commit);
}

std::optional<Parts> parse(const std::wstring& url) {
    if (!is(url)) return std::nullopt;
    std::wstring rest = url.substr(wcslen(kScheme));
    std::vector<std::wstring> pieces;
    size_t start = 0;
    while (true) {
        size_t bar = rest.find(L'|', start);
        if (bar == std::wstring::npos) {
            pieces.push_back(rest.substr(start));
            break;
        }
        pieces.push_back(rest.substr(start, bar - start));
        start = bar + 1;
    }
    if (pieces.size() < 4) return std::nullopt;
    Parts parts;
    parts.window = pieces[0];
    parts.directory = pieces[1];
    parts.path = U(pieces[2]);
    parts.commit = U(pieces[3]);
    return parts;
}

bool is(const std::wstring& url) { return startsWith(url, kScheme); }

}  // namespace DiffURL

const std::set<std::string>& Document::imageExtensions() {
    static const std::set<std::string> set = {"png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff",
                                              "heic", "heif", "webp", "ico", "icns"};
    return set;
}
const std::set<std::string>& Document::vectorImageExtensions() {
    static const std::set<std::string> set = {"svg"};
    return set;
}
const std::set<std::string>& Document::videoExtensions() {
    static const std::set<std::string> set = {"mp4", "m4v", "mov"};
    return set;
}
const std::set<std::string>& Document::audioExtensions() {
    static const std::set<std::string> set = {"mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac"};
    return set;
}
const std::set<std::string>& Document::mediaExtensions() {
    static const std::set<std::string> set = [] {
        std::set<std::string> s = videoExtensions();
        s.insert(audioExtensions().begin(), audioExtensions().end());
        return s;
    }();
    return set;
}
const std::set<std::string>& Document::bookExtensions() {
    static const std::set<std::string> set = {"epub"};
    return set;
}

namespace {

std::string extensionOf(const std::wstring& path) {
    std::wstring name = lastPathComponent(path);
    size_t dot = name.rfind(L'.');
    if (dot == std::wstring::npos || dot == 0) return "";
    return lowercased(U(name.substr(dot + 1)));
}

std::string byteString(uint64_t bytes) { return U(formatByteCount(bytes)); }

std::string withThousands(size_t value) { return U(formatCount((long long)value)); }

}  // namespace

int64_t Document::now() {
    FILETIME ft;
    GetSystemTimeAsFileTime(&ft);
    return ((int64_t)ft.dwHighDateTime << 32) | ft.dwLowDateTime;
}

bool Document::looksBinary(const std::string& data) {
    // A NUL byte in the first 8 KB is the classic "this is binary" signal.
    return memchr(data.data(), 0, std::min<size_t>(data.size(), 8192)) != nullptr;
}

std::string Document::unsupportedMessage(const std::wstring& path, size_t byteCount) {
    std::string ext = extensionOf(path);
    return "Unsupported file type\n\n" + U(lastPathComponent(path)) + "\n"
        + (ext.empty() ? std::string("No extension") : "." + ext) + " · " + byteString(byteCount)
        + "\n\nThis file isn't text, so it can't be shown in the editor.";
}

std::string Document::unreadableMessage(const std::wstring& path, const std::wstring& error) {
    return "Unable to read file\n\n" + U(lastPathComponent(path)) + "\n" + U(error)
        + "\n\nThis file is read-only in Puzzle to protect its existing contents.";
}

std::string Document::largeFileMessage(const std::wstring& path, size_t byteCount, size_t limit) {
    return "Large file not loaded\n\n" + U(lastPathComponent(path)) + "\n" + byteString(byteCount)
        + " · Puzzle's in-memory editor limit is " + byteString(limit)
        + "\n\nOpen this file with a streaming or large-file editor to avoid excessive memory use.";
}

std::string Document::minifiedMessage(const std::wstring& path, size_t byteCount, size_t longestLine) {
    return U(lastPathComponent(path)) + " · " + byteString(byteCount) + " · longest line "
        + withThousands(longestLine) + " characters\n\n"
        + "This file is minified: laying it out in full would freeze the editor,\n"
        + "so the first " + std::to_string(minifiedPreviewLength / 1000) + " KB is shown and the\n"
        + "buffer is read-only. The file on disk is untouched.\n\n";
}

size_t Document::longestLineLength(std::string_view bytes) {
    size_t longest = 0, current = 0;
    for (char c : bytes) {
        if (c == '\n') {
            longest = std::max(longest, current);
            current = 0;
        } else {
            ++current;
        }
    }
    return std::max(longest, current);
}

Document::Presentation Document::presentation(const std::string& data, const std::string& decoded,
                                              const std::wstring& path, const LanguageSpec* spec,
                                              bool isUnsupported) {
    // Minified JSON is laid out before it reaches the buffer — display only.
    std::string text = decoded;
    bool isDisplayFormatted = false;
    size_t longestLine;
    std::optional<std::string> formatted;
    if (spec && spec->name == "json" && !isUnsupported
        && longestLineLength(data) > JSONFormatter::readableLineLength
        && data.size() <= JSONFormatter::maxFormattedBytes
        && (formatted = JSONFormatter::pretty(text)) && *formatted != text
        && JSONFormatter::worthFormatting(text, *formatted)) {
        text = *formatted;
        isDisplayFormatted = true;
        size_t residual = longestLineLength(text);
        longestLine = residual > JSONFormatter::maxFormattedLineLength ? residual : 0;
    } else {
        longestLine = longestLineLength(data);
    }
    // One enormous line — a source map, a minified bundle — shows a bounded,
    // read-only prefix instead.
    if (longestLine > maxDisplayLineLength && data.size() > minifiedPreviewLength) {
        size_t cut = std::min(text.size(), minifiedPreviewLength);
        while (cut > 0 && cut < text.size() && ((unsigned char)text[cut] & 0xC0) == 0x80) --cut;
        return {minifiedMessage(path, data.size(), longestLine) + text.substr(0, cut), isDisplayFormatted, true};
    }
    return {text, isDisplayFormatted, false};
}

void Document::setBufferText(const std::string& text) {
    SciDoc::setReadOnly(sci_, false);
    SciDoc::setText(sci_, text);
    // A file written with Windows line endings keeps them for new lines.
    size_t newline = text.find('\n');
    SciDoc::setEOL(sci_, newline != std::string::npos ? (newline > 0 && text[newline - 1] == '\r')
                                                       : true);
    SciDoc::setReadOnly(sci_, isReadOnly());
}

Document::Document(const std::wstring& virtualURL, const std::string& text, const std::wstring& displayName)
    : url(virtualURL) {
    sci_ = SciDoc::create();
    isVirtual_ = true;
    displayName_ = displayName;
    setBufferText(text);
}

Document::Document(const std::wstring& path) : url(path) {
    sci_ = SciDoc::create();
    spec_ = Languages::specFor(path);
    lastKnownDiskModificationDate_ = fileModificationTime(path);
    std::string ext = extensionOf(path);
    auto size = fileSize(path);

    // Media is claimed ahead of the size gate: a player streams it off disk.
    if (mediaExtensions().count(ext) && size) {
        isMedia_ = true;
        isVideoMedia_ = videoExtensions().count(ext) > 0;
        setBufferText(U(lastPathComponent(path)) + "  ·  " + byteString(*size));
        return;
    }
    // Books and PDFs too: the reader maps the file and reads it a page at a time.
    if ((bookExtensions().count(ext) || ext == "pdf") && size) {
        isEPUB_ = bookExtensions().count(ext) > 0;
        isPDF_ = ext == "pdf";
        setBufferText(U(lastPathComponent(path)) + "  ·  " + byteString(*size));
        return;
    }

    bool hasImageExtension = imageExtensions().count(ext) > 0;
    size_t byteLimit = hasImageExtension ? maxImageFileBytes : maxTextFileBytes;
    if (size && *size > byteLimit) {
        isUnsupported_ = true;
        setBufferText(largeFileMessage(path, *size, byteLimit));
        return;
    }
    auto data = readFile(path, byteLimit + 1);
    if (!data) {
        DWORD code = GetLastError();
        isUnsupported_ = true;
        setBufferText(unreadableMessage(path, fileExists(path) ? systemErrorMessage(code)
                                                               : L"The file doesn't exist."));
        return;
    }
    if (data->size() > byteLimit) {
        isUnsupported_ = true;
        setBufferText(largeFileMessage(path, data->size(), byteLimit));
        return;
    }

    // Pictures preview as images; a corrupt one stays read-only rather than
    // falling through to the permissive Latin-1 decoder.
    if (hasImageExtension) {
        if (auto info = Imaging::probe(*data)) {
            previewImage_ = info;
            setBufferText(U(lastPathComponent(path)) + "  ·  " + std::to_string((int)info->width) + " × "
                          + std::to_string((int)info->height) + "  ·  " + byteString(data->size()));
            return;
        }
        isUnsupported_ = true;
        setBufferText(unsupportedMessage(path, data->size()));
        return;
    }

    std::string text;
    std::string body = *data;
    if (startsWith(body, "\xEF\xBB\xBF")) {
        hasBOM_ = true;
        body = body.substr(3);
    }
    if (!looksBinary(*data) && isValidUTF8(body)) {
        text = body;
    } else if (!looksBinary(*data)) {
        text = latin1ToUTF8(*data);
        encoding_ = Encoding::Latin1;
        hasBOM_ = false;
    } else {
        isUnsupported_ = true;
        text = unsupportedMessage(path, data->size());
    }
    Presentation shown = presentation(*data, text, path, spec_, isUnsupported_);
    isDisplayFormatted_ = shown.isDisplayFormatted;
    if (shown.isMinifiedPreview) {
        isUnsupported_ = true;
        isMinifiedPreview_ = true;
    }
    setBufferText(shown.text);
}

Document::~Document() { SciDoc::release(sci_); }

bool Document::isSVG() const { return !isVirtual_ && vectorImageExtensions().count(extensionOf(url)) > 0; }

void Document::replaceVirtualContent(const std::string& text, const std::optional<std::wstring>& displayName) {
    if (!isVirtual_) return;
    ++contentReplacements_;
    // An edited diff is the user's work, not a cached render.
    if (isModified) return;
    displayName_ = displayName;
    setBufferText(text);
    diffBands.clear();
    diffLineNumbers.clear();
    codeBlocks_.clear();
    jsxTagMatches_.clear();
    baseStyles.clear();
    appliedReveal_.reset();
}

void Document::refreshCodeBlocks() {
    std::vector<CodeBlock> refreshed;
    if (!isVirtual_ && !isUnsupported_ && !isPreviewOnly()) {
        refreshed = CodeBlockAnalyzer::analyze(view(), languageName(), Settings::shared().tabSize);
    }
    if (refreshed == codeBlocks_) return;
    codeBlocks_ = std::move(refreshed);
    Notifications::post(Notice::DocumentStructureDidChange, this);
}

void Document::updateJSXTagMatches(std::vector<JSXTagMatch> matches) {
    if (matches == jsxTagMatches_) return;
    jsxTagMatches_ = std::move(matches);
    Notifications::post(Notice::DocumentStructureDidChange, this);
}

void Document::updateMarkdownPresentation(MarkdownPresentation presentation) {
    if (presentation == markdown_) return;
    markdown_ = std::move(presentation);
    Notifications::post(Notice::DocumentStructureDidChange, this);
}

void Document::applyMarkdownReveal(std::optional<TextRange> range) {
    size_t n = length();
    if (baseStyles.size() != n) {
        appliedReveal_.reset();
        return;
    }
    if (range == appliedReveal_) return;
    // Put the previously shown line back the way the styler painted it.
    if (appliedReveal_) {
        TextRange old = appliedReveal_->intersection(TextRange(0, n));
        if (old.length) SciDoc::setStyles(sci_, old.location, baseStyles.data() + old.location, old.length);
    }
    appliedReveal_ = range;
    if (!range) return;
    TextRange now = range->intersection(TextRange(0, n));
    if (!now.length) return;
    std::vector<unsigned char> shown(baseStyles.begin() + now.location, baseStyles.begin() + now.end());
    bool changed = false;
    for (auto& s : shown) {
        int twin = Styles::visibleTwin(s);
        if (twin != s) {
            s = (unsigned char)twin;
            changed = true;
        }
    }
    if (changed) SciDoc::setStyles(sci_, now.location, shown.data(), shown.size());
}

bool Document::discardEditsAndReloadFromDisk() {
    isModified = false;
    lastLocalEditAt_.reset();
    hasDiskConflict_ = false;
    lastKnownDiskModificationDate_.reset();
    return reloadFromDiskIfLatest();
}

bool Document::diskChangedSinceLastSync() const {
    if (isVirtual_) return false;
    auto disk = fileModificationTime(url);
    if (!disk || !lastKnownDiskModificationDate_) return false;
    return *disk > *lastKnownDiskModificationDate_;
}

bool Document::save(std::wstring* error) {
    if (isReadOnly()) {
        if (error) *error = L"This document is read-only and cannot be saved.";
        return false;
    }
    std::string current = text();
    std::string data;
    Encoding saved = encoding_;
    if (encoding_ == Encoding::Latin1) {
        // Keep the source encoding while the text fits in it; otherwise UTF-8
        // is the lossless fallback and becomes the document's encoding.
        if (auto latin = utf8ToLatin1(current)) {
            data = std::move(*latin);
        } else {
            data = current;
            saved = Encoding::UTF8;
        }
    } else {
        data = (hasBOM_ ? std::string("\xEF\xBB\xBF") : std::string()) + current;
    }
    std::wstring failure;
    if (!atomicWriteFile(url, data, &failure)) {
        if (error) *error = L"The document “" + name() + L"” could not be saved. " + failure;
        return false;
    }
    encoding_ = saved;
    lastKnownDiskModificationDate_ = fileModificationTime(url);
    lastLocalEditAt_.reset();
    isModified = false;
    hasDiskConflict_ = false;
    return true;
}

void Document::markLocalEdit() {
    if (isApplyingExternalChange_) return;
    int64_t date = now();
    if (!lastLocalEditAt_ || date > *lastLocalEditAt_) lastLocalEditAt_ = date;
    isModified = true;
}

bool Document::reloadFromDiskIfLatest(int64_t observedAt) {
    // A bounded preview still tracks its file: the build that minified it may
    // un-minify it again.
    if (isVirtual_ || (isReadOnly() && !isMinifiedPreview_)) return false;
    auto data = readFile(url, maxTextFileBytes + 1);
    if (!data || data->size() > maxTextFileBytes || looksBinary(*data)) return false;
    std::string body = *data;
    bool bom = false;
    if (startsWith(body, "\xEF\xBB\xBF")) {
        bom = true;
        body = body.substr(3);
    }
    Encoding decodedEncoding = Encoding::UTF8;
    std::string decoded;
    if (isValidUTF8(body)) {
        decoded = body;
    } else {
        decoded = latin1ToUTF8(*data);
        decodedEncoding = Encoding::Latin1;
        bom = false;
    }
    int64_t diskDate = fileModificationTime(url).value_or(observedAt ? observedAt : now());
    Presentation shown = presentation(*data, decoded, url, spec_, false);
    const std::string& incoming = shown.text;
    if (incoming == view()) {
        bool stateChanged = isModified || lastLocalEditAt_.has_value();
        lastKnownDiskModificationDate_ = diskDate;
        lastLocalEditAt_.reset();
        isModified = false;
        hasDiskConflict_ = false;
        encoding_ = decodedEncoding;
        hasBOM_ = bom;
        return stateChanged;
    }
    // Unsaved edits are the only copy that exists: record the conflict.
    if (isModified) {
        if (lastKnownDiskModificationDate_ && diskDate == *lastKnownDiskModificationDate_) return false;
        hasDiskConflict_ = true;
        lastKnownDiskModificationDate_ = diskDate;
        Notifications::post(Notice::DocumentDiskConflict, this);
        return false;
    }
    if (lastLocalEditAt_ && diskDate < *lastLocalEditAt_) {
        lastKnownDiskModificationDate_ = diskDate;
        return false;
    }
    if (lastKnownDiskModificationDate_ && diskDate < *lastKnownDiskModificationDate_) return false;

    isApplyingExternalChange_ = true;
    isDisplayFormatted_ = shown.isDisplayFormatted;
    isMinifiedPreview_ = shown.isMinifiedPreview;
    isUnsupported_ = shown.isMinifiedPreview;
    baseStyles.clear();
    appliedReveal_.reset();
    setBufferText(incoming);
    isApplyingExternalChange_ = false;
    encoding_ = decodedEncoding;
    hasBOM_ = bom;
    lastKnownDiskModificationDate_ = diskDate;
    lastLocalEditAt_.reset();
    isModified = false;
    hasDiskConflict_ = false;
    return true;
}

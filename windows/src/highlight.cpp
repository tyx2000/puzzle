#include "highlight.h"

#include "documentstore.h"
#include "notify.h"
#include "theme.h"

namespace HighlightService {

namespace {

std::map<std::string, std::unique_ptr<SyntaxHighlighter>>& cache() {
    static auto* map = new std::map<std::string, std::unique_ptr<SyntaxHighlighter>>();
    return *map;
}

std::map<std::wstring, std::shared_ptr<Dispatch::Pending>>& pending() {
    static auto* map = new std::map<std::wstring, std::shared_ptr<Dispatch::Pending>>();
    return *map;
}

SyntaxHighlighter* highlighter(const LanguageSpec& spec) {
    auto& map = cache();
    auto hit = map.find(spec.name);
    if (hit != map.end()) return hit->second.get();
    auto made = SyntaxHighlighter::make(spec);
    if (!made || !made->isUsable()) return nullptr;
    auto* raw = made.get();
    map[spec.name] = std::move(made);
    return raw;
}

/// Plain text: every byte the default style, no decoration.
void paintPlain(Document& doc) {
    size_t n = doc.length();
    std::vector<unsigned char> plain(n, 0);
    SciDoc::setStyles(doc.handle(), 0, plain.data(), n);
    SciDoc::clearIndicator(doc.handle(), Styles::kStrikeIndicator);
    SciDoc::clearMarker(doc.handle(), Styles::kMarkerCodeBlock);
    doc.baseStyles.clear();
    doc.forgetReveal();
}

void markCodeBlocks(Document& doc) {
    SciDoc::clearMarker(doc.handle(), Styles::kMarkerCodeBlock);
    for (auto& block : doc.markdown().codeBlocks) {
        if (!block.range.length) continue;
        int first = SciDoc::lineFromPosition(doc.handle(), block.range.location);
        int last = SciDoc::lineFromPosition(doc.handle(), block.range.end() - 1);
        for (int line = first; line <= last; ++line) SciDoc::addMarker(doc.handle(), line, Styles::kMarkerCodeBlock);
    }
}

}  // namespace

void highlight(Document& doc) {
    doc.refreshCodeBlocks();
    // Generated diff buffers get the diff painter, not tree-sitter.
    if (doc.isVirtual()) {
        doc.updateJSXTagMatches({});
        doc.updateMarkdownPresentation({});
        DiffHighlighter::apply(doc);
        doc.diffLineNumbers = DiffHighlighter::lineNumbers(doc.view());
        Notifications::post(Notice::DocumentRestyled, &doc);
        return;
    }
    // Size and skip-conditions before the grammar is materialised.
    const LanguageSpec* spec = doc.languageSpec();
    if (!spec || doc.isUnsupported()) {
        paintPlain(doc);
        doc.updateJSXTagMatches({});
        doc.updateMarkdownPresentation({});
        Notifications::post(Notice::DocumentRestyled, &doc);
        return;
    }
    std::string_view text = doc.view();
    bool tooLarge = text.size() > SyntaxHighlighter::maxBytes;
    // The Markdown scanner asserts past a nesting depth: plain text instead.
    bool tooDeep = spec->name == "markdown"
        && MarkdownSyntaxTree::containerDepth(text) > MarkdownSyntaxTree::maxContainerDepth;
    if (tooLarge || tooDeep) {
        if (auto hit = cache().find(spec->name); hit != cache().end()) hit->second->discardParseTree();
        paintPlain(doc);
        doc.updateJSXTagMatches({});
        doc.updateMarkdownPresentation({});
        Notifications::post(Notice::DocumentRestyled, &doc);
        return;
    }
    std::vector<CharAttr> attrs(text.size());
    std::vector<JSXTagMatch> tags;
    if (auto* hl = highlighter(*spec)) tags = hl->highlight(text, &doc, attrs);
    std::map<size_t, uint32_t> replacements;
    MarkdownPresentation presentation;
    bool markdown = spec->name == "markdown";
    if (markdown) presentation = MarkdownLiveStyler::apply(text, attrs, replacements, doc.url);
    std::vector<unsigned char> styles = Styles::resolve(attrs, replacements);
    SciDoc::setStyles(doc.handle(), 0, styles.data(), styles.size());
    SciDoc::clearIndicator(doc.handle(), Styles::kStrikeIndicator);
    for (size_t i = 0; i < attrs.size();) {
        if (!(attrs[i].flags & CharAttr::Strike)) {
            ++i;
            continue;
        }
        size_t start = i;
        while (i < attrs.size() && (attrs[i].flags & CharAttr::Strike)) ++i;
        SciDoc::fillIndicator(doc.handle(), Styles::kStrikeIndicator, start, i - start);
    }
    if (markdown) doc.baseStyles = std::move(styles);
    else doc.baseStyles.clear();
    doc.forgetReveal();
    doc.updateMarkdownPresentation(std::move(presentation));
    if (markdown) markCodeBlocks(doc);
    else SciDoc::clearMarker(doc.handle(), Styles::kMarkerCodeBlock);
    doc.updateJSXTagMatches(std::move(tags));
    Notifications::post(Notice::DocumentRestyled, &doc);
}

void scheduleHighlight(Document& doc) {
    std::wstring url = doc.url;
    cancelPending(url);
    // Markdown is formatted in place, so its visual syntax is published on
    // the next turn; other grammars keep the typing debounce.
    double delay = doc.languageName() == "markdown" ? 0 : 0.18;
    pending()[url] = Dispatch::after(delay, [url] {
        pending().erase(url);
        if (Document* doc = DocumentStore::shared().cachedDocument(url)) highlight(*doc);
    });
}

void cancelPending(const std::wstring& url) {
    auto hit = pending().find(url);
    if (hit == pending().end()) return;
    hit->second->cancel();
    pending().erase(hit);
}

void discardParseTrees() {
    for (auto& [name, hl] : cache()) hl->discardParseTree();
}

void evictUnused(const std::set<std::string>& keeping) {
    auto& map = cache();
    for (auto it = map.begin(); it != map.end();) {
        if (!keeping.count(it->first)) it = map.erase(it);
        else ++it;
    }
}

void documentWillClose(const Document& doc) {
    cancelPending(doc.url);
    for (auto& [name, hl] : cache()) hl->discardParseTree(&doc);
}

}  // namespace HighlightService

namespace DiffHighlighter {

LineKind kind(std::string_view line) {
    auto has = [&](const char* prefix) { return line.substr(0, strlen(prefix)) == prefix; };
    if (has("@@")) return LineKind::HunkHeader;
    if (has("+++") || has("---")) return LineKind::FileHeader;
    if (has("diff --git") || has("index ") || has("new file") || has("deleted file")
        || has("similarity index") || has("rename ")) {
        return LineKind::FileHeader;
    }
    if (has("+")) return LineKind::Added;
    if (has("-")) return LineKind::Removed;
    return LineKind::Context;
}

void apply(Document& doc) {
    std::string_view text = doc.view();
    std::vector<CharAttr> attrs(text.size());
    doc.diffBands.clear();
    SciDoc::clearMarker(doc.handle(), Styles::kMarkerDiffAdded);
    SciDoc::clearMarker(doc.handle(), Styles::kMarkerDiffRemoved);
    uint8_t header = Palette::index(Theme::dimText), hunk = Palette::index(Theme::blue),
            added = Palette::index(Theme::diffAddedText), removed = Palette::index(Theme::diffRemovedText);
    size_t start = 0;
    int line = 0;
    while (start < text.size()) {
        size_t end = text.find('\n', start);
        size_t next = end == std::string_view::npos ? text.size() : end + 1;
        size_t contentEnd = end == std::string_view::npos ? text.size() : end;
        std::string_view content = text.substr(start, contentEnd - start);
        LineKind k = kind(content);
        uint8_t fg = 0, flags = 0;
        switch (k) {
        case LineKind::FileHeader: fg = header; flags = CharAttr::Bold; break;
        case LineKind::HunkHeader: fg = hunk; flags = CharAttr::Bold; break;
        case LineKind::Added: fg = added; break;
        case LineKind::Removed: fg = removed; break;
        case LineKind::Context: break;
        }
        for (size_t i = start; i < next; ++i) {
            attrs[i].fg = fg;
            attrs[i].flags = flags;
        }
        if (k == LineKind::Added || k == LineKind::Removed) {
            doc.diffBands.push_back({TextRange(start, next - start),
                                     k == LineKind::Added ? Theme::diffAddedBackground : Theme::diffRemovedBackground});
            SciDoc::addMarker(doc.handle(), line,
                              k == LineKind::Added ? Styles::kMarkerDiffAdded : Styles::kMarkerDiffRemoved);
        }
        start = next;
        ++line;
    }
    auto styles = Styles::resolve(attrs);
    SciDoc::setStyles(doc.handle(), 0, styles.data(), styles.size());
}

std::vector<std::optional<int>> lineNumbers(std::string_view text) {
    std::vector<std::optional<int>> numbers;
    int oldNext = 0, newNext = 0;
    bool inHunk = false;
    size_t start = 0;
    while (true) {
        size_t end = text.find('\n', start);
        std::string_view line = text.substr(start, end == std::string_view::npos ? std::string_view::npos : end - start);
        if (!line.empty() && line.back() == '\r') line.remove_suffix(1);
        if (line.substr(0, 2) == "@@") {
            // `@@ -12,7 +14,9 @@`
            int oldStart = 0, newStart = 0;
            std::string header(line);
            size_t minus = header.find(" -"), plus = header.find(" +");
            bool ok = minus != std::string::npos && plus != std::string::npos;
            if (ok) {
                try {
                    oldStart = std::stoi(header.substr(minus + 2));
                    newStart = std::stoi(header.substr(plus + 2));
                } catch (...) {
                    ok = false;
                }
            }
            if (ok) {
                oldNext = oldStart;
                newNext = newStart;
                inHunk = true;
            } else {
                inHunk = false;
            }
            numbers.push_back(std::nullopt);
        } else if (!inHunk || line.empty()) {
            inHunk = false;
            numbers.push_back(std::nullopt);
        } else {
            switch (line[0]) {
            case '+': numbers.push_back(newNext++); break;
            case '-': numbers.push_back(oldNext++); break;
            case ' ':
                numbers.push_back(newNext++);
                ++oldNext;
                break;
            case '\\': numbers.push_back(std::nullopt); break;
            default:
                inHunk = false;
                numbers.push_back(std::nullopt);
            }
        }
        if (end == std::string_view::npos) break;
        start = end + 1;
    }
    return numbers;
}

}  // namespace DiffHighlighter

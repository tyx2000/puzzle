#include "search.h"

#include "celldrawing.h"
#include "documentstore.h"
#include "json.h"
#include "process.h"
#include "theme.h"

namespace {

/// Result caps — the panel can't usefully show more than this, and holding
/// every hit of a common word was the single largest memory spike measured.
constexpr size_t kMaxHits = 500;
/// So one file cannot fill the list.
constexpr int kMaxHitsPerFile = 80;
constexpr size_t kMaxPreviewChars = 160;
constexpr uint64_t kMaxNativeFileBytes = 2'000'000;
/// The most one ripgrep JSON record may occupy before it is dropped.
constexpr size_t kMaxSearchRecordBytes = 1'000'000;
/// A hit on a line this long is a hit inside minified or generated output.
/// Dropped from both backends, so results do not depend on whether ripgrep is
/// installed. Per line, not per file.
constexpr size_t kMaxSearchableLineLength = 1000;

/// Names that say "generated" without opening the file.
const std::vector<std::wstring>& generatedSuffixes() {
    static const std::vector<std::wstring> suffixes = {
        L".min.js", L".min.mjs", L".min.cjs", L".min.css", L".min.html",
        L"-min.js", L"-min.css", L".bundle.js", L".chunk.js", L".map",
    };
    return suffixes;
}

const std::set<std::wstring>& skipDirs() {
    static const std::set<std::wstring> dirs = {L".git", L"node_modules", L".build", L"build",
                                                L"DerivedData", L".svn", L"Pods", L".obj"};
    return dirs;
}

using RawHit = std::tuple<std::wstring, int, std::wstring>;  // relative (with /), line, preview

bool isWordChar(wchar_t c) { return c == L'_' || IsCharAlphaNumericW(c); }

std::wstring lowerString(const std::wstring& s) {
    std::wstring out = s;
    if (!out.empty()) CharLowerBuffW(out.data(), (DWORD)out.size());
    return out;
}

/// Keep a bounded preview while ensuring a late match remains visible.
std::wstring searchPreview(const std::wstring& line, const SearchMatcher& matcher) {
    std::wstring trimmed = trim(line);
    if (trimmed.size() <= kMaxPreviewChars) return trimmed;
    auto match = matcher.firstRange(trimmed);
    if (!match || match->first < kMaxPreviewChars) return trimmed.substr(0, kMaxPreviewChars);
    size_t start = match->first > kMaxPreviewChars / 3 ? match->first - kMaxPreviewChars / 3 : 0;
    size_t length = std::min(kMaxPreviewChars - 1, trimmed.size() - start);
    // Never split a surrogate pair.
    if (start > 0 && IS_LOW_SURROGATE(trimmed[start])) { ++start; if (length) --length; }
    if (length > 0 && start + length < trimmed.size() && IS_HIGH_SURROGATE(trimmed[start + length - 1])) --length;
    return L"\u2026" + trimmed.substr(start, length);
}

/// UTF-8 lines of `text`, `\r` dropped from the end of each.
template <class F>
void forEachLine(std::string_view text, F&& body) {
    size_t start = 0;
    int number = 0;
    while (start <= text.size()) {
        size_t nl = text.find('\n', start);
        std::string_view line = text.substr(start, nl == std::string_view::npos ? std::string_view::npos : nl - start);
        if (!line.empty() && line.back() == '\r') line.remove_suffix(1);
        ++number;
        if (!body(line, number)) return;
        if (nl == std::string_view::npos) break;
        start = nl + 1;
    }
}

size_t characterCount(std::string_view utf8) {
    size_t count = 0;
    for (unsigned char c : utf8) if ((c & 0xC0) != 0x80) ++count;
    return count;
}

void appendMatches(std::string_view text, const std::wstring& relative, const SearchMatcher& matcher,
                   std::vector<RawHit>& output) {
    int kept = 0;
    forEachLine(text, [&](std::string_view raw, int number) {
        // The same two rules the disk backends apply, so a file does not
        // change what it can match by having unsaved edits in it.
        if (characterCount(raw) > kMaxSearchableLineLength) return true;
        std::wstring value = W(std::string(raw));
        if (!matcher.firstRange(value)) return true;
        ++kept;
        if (kept > kMaxHitsPerFile) return false;
        output.emplace_back(relative, number, searchPreview(value, matcher));
        return output.size() < kMaxHits;
    });
}

std::optional<std::wstring> relativePath(const std::wstring& path, const std::wstring& directory) {
    std::wstring root = normalizedPath(directory);
    std::wstring full = normalizedPath(path);
    std::wstring prefix = root;
    if (!prefix.empty() && prefix.back() != L'\\') prefix += L'\\';
    if (full.size() <= prefix.size() || lowercased(full.substr(0, prefix.size())) != lowercased(prefix)) {
        return std::nullopt;
    }
    return replaceAll(full.substr(prefix.size()), L"\\", L"/");
}

// ── Native backend ─────────────────────────────────────────────────────────

void nativeWalk(const std::wstring& directory, const std::wstring& relativeDir, const SearchMatcher& matcher,
                const CancelToken& cancellation, std::vector<RawHit>& out, bool& finished) {
    WIN32_FIND_DATAW data;
    HANDLE find = FindFirstFileExW(pathJoin(directory, L"*").c_str(), FindExInfoBasic, &data,
                                   FindExSearchNameMatch, nullptr, FIND_FIRST_EX_LARGE_FETCH);
    if (find == INVALID_HANDLE_VALUE) return;
    std::vector<std::pair<std::wstring, bool>> entries;
    do {
        std::wstring name = data.cFileName;
        if (name == L"." || name == L"..") continue;
        // Hidden files are skipped, as the enumerator's .skipsHiddenFiles did.
        if (name[0] == L'.' || (data.dwFileAttributes & FILE_ATTRIBUTE_HIDDEN)) continue;
        if (data.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) continue;
        bool isDirectory = (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
        if (!isDirectory) {
            uint64_t size = ((uint64_t)data.nFileSizeHigh << 32) | data.nFileSizeLow;
            if (size >= kMaxNativeFileBytes) continue;
        }
        entries.emplace_back(name, isDirectory);
    } while (FindNextFileW(find, &data));
    FindClose(find);
    std::sort(entries.begin(), entries.end(), [](const auto& a, const auto& b) {
        return lowercased(a.first) < lowercased(b.first);
    });
    for (auto& [name, isDirectory] : entries) {
        // Once per file: the unit of work small enough to abandon promptly.
        if (finished) return;
        if (cancellation.isCancelled()) {
            finished = true;
            return;
        }
        std::wstring full = pathJoin(directory, name);
        std::wstring relative = relativeDir.empty() ? name : relativeDir + L"/" + name;
        if (isDirectory) {
            if (skipDirs().count(name)) continue;
            nativeWalk(full, relative, matcher, cancellation, out, finished);
            continue;
        }
        if (SearchPanel::isGeneratedArtifact(name)) continue;
        auto contents = readFile(full, kMaxNativeFileBytes);
        if (!contents) continue;
        if (std::string_view(*contents).substr(0, 1024).find('\0') != std::string_view::npos) continue;
        int kept = 0;
        forEachLine(*contents, [&](std::string_view raw, int number) {
            if (characterCount(raw) > kMaxSearchableLineLength) return true;
            // The same per-file cap the ripgrep backend applies.
            if (kept >= kMaxHitsPerFile) return false;
            std::wstring value = W(std::string(raw));
            if (matcher.firstRange(value)) {
                ++kept;
                out.emplace_back(relative, number, searchPreview(value, matcher));
                if (out.size() >= kMaxHits) {
                    finished = true;
                    return false;
                }
            }
            return true;
        });
    }
}

std::vector<RawHit> nativeSearch(const std::wstring& directory, const SearchMatcher& matcher,
                                 const CancelToken& cancellation) {
    std::vector<RawHit> out;
    bool finished = false;
    nativeWalk(directory, L"", matcher, cancellation, out, finished);
    return out;
}

// ── ripgrep backend ────────────────────────────────────────────────────────

const std::wstring& ripgrepPath() {
    static const std::wstring path = [] {
        std::wstring found = findOnPath(L"rg");
        if (found.empty()) {
            for (const wchar_t* candidate : {L"C:\\Program Files\\ripgrep\\rg.exe",
                                             L"C:\\ProgramData\\chocolatey\\bin\\rg.exe"}) {
                if (fileExists(candidate)) return std::wstring(candidate);
            }
        }
        return found;
    }();
    return path;
}

std::vector<std::wstring> ripgrepArguments(const std::wstring& query, const SearchOptions& options) {
    // No `--max-count`: ripgrep would spend that budget on the very lines this
    // end throws away. The per-file cap is applied below instead.
    std::vector<std::wstring> args = {L"--json", L"--max-columns", L"1000", L"--max-columns-preview",
                                      L"--max-filesize", std::to_wstring(kMaxNativeFileBytes),
                                      L"--path-separator", L"/"};
    for (auto& suffix : generatedSuffixes()) {
        args.push_back(L"--glob");
        args.push_back(L"!*" + suffix);
    }
    if (!options.regex) args.push_back(L"--fixed-strings");
    args.push_back(options.caseSensitive ? L"--case-sensitive" : L"--ignore-case");
    if (options.wholeWord) args.push_back(L"--word-regexp");
    args.push_back(L"--");
    args.push_back(query);
    args.push_back(L".");
    return args;
}

std::string base64Decode(const std::string& in) {
    auto value = [](char c) -> int {
        if (c >= 'A' && c <= 'Z') return c - 'A';
        if (c >= 'a' && c <= 'z') return c - 'a' + 26;
        if (c >= '0' && c <= '9') return c - '0' + 52;
        if (c == '+') return 62;
        if (c == '/') return 63;
        return -1;
    };
    std::string out;
    int bits = 0, buffer = 0;
    for (char c : in) {
        int v = value(c);
        if (v < 0) continue;
        buffer = (buffer << 6) | v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out += (char)((buffer >> bits) & 0xff);
        }
    }
    return out;
}

std::optional<std::string> jsonText(const JsonValue* value) {
    if (!value || !value->isObject()) return std::nullopt;
    if (auto text = value->get("text"); text && text->isString()) return text->string;
    if (auto bytes = value->get("bytes"); bytes && bytes->isString()) return base64Decode(bytes->string);
    return std::nullopt;
}

std::optional<std::vector<RawHit>> ripgrep(const std::wstring& rg, const std::wstring& query,
                                           const std::wstring& directory, const SearchOptions& options,
                                           const SearchMatcher& matcher, const CancelToken& cancellation) {
    SECURITY_ATTRIBUTES sa{sizeof(sa), nullptr, TRUE};
    HANDLE readEnd = nullptr, writeEnd = nullptr;
    if (!CreatePipe(&readEnd, &writeEnd, &sa, 1 << 16)) return std::nullopt;
    SetHandleInformation(readEnd, HANDLE_FLAG_INHERIT, 0);
    // Search errors are represented by no results; an unread stderr pipe can
    // deadlock on a tree with many permission errors.
    HANDLE nul = CreateFileW(L"NUL", GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, &sa, OPEN_EXISTING, 0, nullptr);
    std::wstring commandLine = quoteArgument(rg);
    for (auto& arg : ripgrepArguments(query, options)) commandLine += L" " + quoteArgument(arg);
    STARTUPINFOW si{};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = nul;
    si.hStdOutput = writeEnd;
    si.hStdError = nul;
    PROCESS_INFORMATION pi{};
    BOOL started = CreateProcessW(rg.c_str(), commandLine.data(), nullptr, nullptr, TRUE, CREATE_NO_WINDOW,
                                  nullptr, directory.c_str(), &si, &pi);
    CloseHandle(writeEnd);
    if (nul != INVALID_HANDLE_VALUE) CloseHandle(nul);
    if (!started) {
        CloseHandle(readEnd);
        return std::nullopt;
    }
    CloseHandle(pi.hThread);

    // Read incrementally and stop once there is enough: a common word in a
    // big repository could be tens of MB of matches thrown away.
    std::vector<RawHit> out;
    std::map<std::wstring, int> perFile;
    std::string buffer;
    bool done = false;
    bool skippingOversizedRecord = false;
    char chunk[65536];
    while (!done) {
        // Cancelling abandons the results; the child goes with them.
        if (cancellation.isCancelled()) break;
        DWORD available = 0;
        if (!PeekNamedPipe(readEnd, nullptr, 0, nullptr, &available, nullptr)) break;  // closed: rg exited
        if (available == 0) {
            if (WaitForSingleObject(pi.hProcess, 10) == WAIT_OBJECT_0) {
                // Drain whatever arrived between the peek and the exit.
                if (!PeekNamedPipe(readEnd, nullptr, 0, nullptr, &available, nullptr) || available == 0) break;
            } else {
                continue;
            }
        }
        DWORD read = 0;
        if (!ReadFile(readEnd, chunk, std::min<DWORD>(available, sizeof(chunk)), &read, nullptr) || read == 0) break;
        buffer.append(chunk, read);
        if (skippingOversizedRecord) {
            size_t nl = buffer.find('\n');
            if (nl == std::string::npos) {
                buffer.clear();
                continue;
            }
            buffer.erase(0, nl + 1);
            skippingOversizedRecord = false;
        }
        size_t start = 0;
        while (true) {
            size_t nl = buffer.find('\n', start);
            if (nl == std::string::npos) break;
            std::string line = buffer.substr(start, nl - start);
            start = nl + 1;
            if (line.find("\"type\":\"match\"") == std::string::npos) continue;
            auto object = parseJson(line);
            if (!object || !object->isObject()) continue;
            auto type = object->get("type");
            if (!type || !type->isString() || type->string != "match") continue;
            auto payload = object->get("data");
            if (!payload) continue;
            auto rel = jsonText(payload->get("path"));
            auto textValue = jsonText(payload->get("lines"));
            auto number = payload->get("line_number");
            if (!rel || !textValue || !number || !number->isNumber()) continue;
            std::string relative = *rel;
            if (startsWith(relative, "./")) relative.erase(0, 2);
            std::string text = trimTrailingNewlines(*textValue);
            if (!text.empty() && text.back() == '\r') text.pop_back();
            // rg's JSON printer emits the whole matching line whatever
            // `--max-columns` says, so the minified-line rule is applied here.
            if (characterCount(text) > kMaxSearchableLineLength) continue;
            std::wstring wideRelative = W(relative);
            int& kept = perFile[wideRelative];
            if (kept >= kMaxHitsPerFile) continue;
            ++kept;
            out.emplace_back(wideRelative, (int)number->number, searchPreview(W(text), matcher));
            if (out.size() >= kMaxHits) {
                done = true;
                break;
            }
        }
        buffer.erase(0, start);
        // One record this large is a hit on a line no preview would show.
        if (buffer.size() > kMaxSearchRecordBytes) {
            skippingOversizedRecord = true;
            buffer.clear();
        }
    }
    if (WaitForSingleObject(pi.hProcess, 0) != WAIT_OBJECT_0) TerminateProcess(pi.hProcess, 1);
    WaitForSingleObject(pi.hProcess, 2000);
    CloseHandle(pi.hProcess);
    CloseHandle(readEnd);
    return out;
}

Dispatch::Queue& searchQueue() {
    // Serial: one search at a time. Two full scans of the same tree cost twice
    // the peak memory and only the newer one's results are ever shown.
    static Dispatch::Queue* queue = new Dispatch::Queue("app.puzzle.search");
    return *queue;
}

}  // namespace

// ── SearchMatcher ──────────────────────────────────────────────────────────

std::optional<SearchMatcher> SearchMatcher::make(const std::wstring& query, const SearchOptions& options) {
    if (query.empty()) return std::nullopt;
    SearchMatcher matcher;
    matcher.options_ = options;
    if (options.regex) {
        try {
            auto flags = std::regex_constants::ECMAScript | std::regex_constants::optimize;
            if (!options.caseSensitive) flags |= std::regex_constants::icase;
            matcher.regex_ = std::make_shared<std::wregex>(query, flags);
        } catch (const std::regex_error&) {
            return std::nullopt;
        }
    } else {
        matcher.needle_ = options.caseSensitive ? query : lowerString(query);
    }
    return matcher;
}

std::optional<std::pair<size_t, size_t>> SearchMatcher::firstRange(const std::wstring& text) const {
    // Whole word: no letter, digit or underscore on either side of the match.
    auto bounded = [&](size_t start, size_t length) {
        if (!options_.wholeWord) return true;
        if (start > 0 && isWordChar(text[start - 1])) return false;
        if (start + length < text.size() && isWordChar(text[start + length])) return false;
        return true;
    };
    if (regex_) {
        try {
            for (auto it = std::wsregex_iterator(text.begin(), text.end(), *regex_); it != std::wsregex_iterator();
                 ++it) {
                size_t start = (size_t)it->position(0), length = (size_t)it->length(0);
                if (length == 0 && !options_.wholeWord) return std::make_pair(start, length);
                if (length > 0 && bounded(start, length)) return std::make_pair(start, length);
            }
        } catch (const std::regex_error&) {
        }
        return std::nullopt;
    }
    std::wstring haystack = options_.caseSensitive ? text : lowerString(text);
    size_t from = 0;
    while (true) {
        size_t found = haystack.find(needle_, from);
        if (found == std::wstring::npos) return std::nullopt;
        if (bounded(found, needle_.size())) return std::make_pair(found, needle_.size());
        from = found + 1;
    }
}

// ── The search ─────────────────────────────────────────────────────────────

bool SearchPanel::isGeneratedArtifact(const std::wstring& name) {
    std::wstring lowered = lowercased(name);
    for (auto& suffix : generatedSuffixes()) {
        if (endsWith(lowered, suffix)) return true;
    }
    return false;
}

std::wstring SearchPanel::FileGroup::folder() const {
    size_t slash = relative.find_last_of(L"\\/");
    return slash == std::wstring::npos ? L"" : relative.substr(0, slash);
}

std::wstring SearchPanel::FileGroup::name() const { return lastPathComponent(relative); }

std::vector<SearchPanel::FileGroup> SearchPanel::search(
    const std::wstring& query, const std::wstring& directory, const SearchOptions& options,
    const std::vector<std::pair<std::wstring, std::string>>& inMemoryFiles,
    const std::shared_ptr<CancelToken>& cancellation) {
    auto matcher = SearchMatcher::make(query, options);
    if (!matcher) return {};
    std::vector<RawHit> diskHits;
    const std::wstring& rg = ripgrepPath();
    std::optional<std::vector<RawHit>> fromRipgrep;
    if (!rg.empty()) fromRipgrep = ripgrep(rg, query, directory, options, *matcher, *cancellation);
    diskHits = fromRipgrep ? std::move(*fromRipgrep) : nativeSearch(directory, *matcher, *cancellation);
    if (cancellation->isCancelled()) return {};

    std::vector<std::pair<std::wstring, const std::string*>> snapshots;
    for (auto& [path, text] : inMemoryFiles) {
        if (auto rel = relativePath(path, directory)) snapshots.emplace_back(*rel, &text);
    }
    std::sort(snapshots.begin(), snapshots.end(), [](const auto& a, const auto& b) { return a.first < b.first; });
    std::set<std::wstring> overridden;
    for (auto& snapshot : snapshots) overridden.insert(lowercased(snapshot.first));

    std::vector<RawHit> raw;
    // Modified files take priority so a saturated disk result set cannot hide
    // a current in-memory match. Their old disk hits are removed even when the
    // edit deleted every occurrence.
    for (auto& snapshot : snapshots) {
        appendMatches(*snapshot.second, snapshot.first, *matcher, raw);
        if (raw.size() >= kMaxHits) break;
    }
    for (auto& hit : diskHits) {
        if (raw.size() >= kMaxHits) break;
        if (overridden.count(lowercased(std::get<0>(hit)))) continue;
        raw.push_back(std::move(hit));
    }
    // Preserve file order, group hits.
    std::vector<FileGroup> groups;
    std::map<std::wstring, size_t> byFile;
    for (auto& [rel, line, text] : raw) {
        Hit hit{line, text, matcher->firstRange(text)};
        auto found = byFile.find(rel);
        if (found != byFile.end()) {
            groups[found->second].hits.push_back(std::move(hit));
        } else {
            byFile[rel] = groups.size();
            FileGroup group;
            group.path = pathJoinGit(directory, U(rel));
            group.relative = replaceAll(rel, L"/", L"\\");
            group.hits.push_back(std::move(hit));
            groups.push_back(std::move(group));
        }
    }
    return groups;
}

// ── The panel ──────────────────────────────────────────────────────────────

SearchPanel::SearchPanel() {
    backgroundColor = Theme::panelBackground;
    field_.setPlaceholder(L"Search project\u2026");
    field_.onChange = [this](const std::wstring&, const SearchOptions&) { searchChanged(); };
    field_.onSubmit = [this](const std::wstring&, const SearchOptions&) { searchChanged(); };

    summary_.font = Theme::uiFont(10.5f);
    summary_.color = Theme::dimText;
    summary_.align = Align::Center;

    placeholder_.font = Theme::uiFont(11);
    placeholder_.color = Theme::dimText;
    placeholder_.align = Align::Center;
    placeholder_.wraps = true;

    list_.backgroundColor = Theme::panelBackground;
    list_.rowHeight = Theme::treeRowHeight();
    list_.numberOfRows = [this] { return (int)rows_.size(); };
    list_.drawRow = [this](Graphics& g, int row, const Rect& rect) { drawRow(g, row, rect); };
    // Flat selection matching the file tree's active row.
    list_.rowBackground = [this](int row) {
        return row == list_.selectedRow() ? Theme::activeRow : Theme::panelBackground;
    };
    list_.onClick = [this](int row) { rowClicked(row); };
    list_.tooltipForRow = [this](int row, Point) -> std::wstring {
        if (row < 0 || row >= (int)rows_.size()) return L"";
        const FileGroup& group = groups_[rows_[row].group];
        if (rows_[row].hit < 0) return group.relative;
        return L"";
    };

    addSubview(&field_);
    addSubview(&summary_);
    addSubview(&placeholder_);
    addSubview(&list_);
    updatePlaceholder(L"", std::nullopt);
}

SearchPanel::~SearchPanel() {
    if (searchWork_) searchWork_->cancel();
    if (searchToken_) searchToken_->cancel();
}

void SearchPanel::layout() {
    Rect b = bounds();
    field_.setFrame(Rect(8, 8, std::max(0.0f, b.w - 16), SearchInputView::height));
    float summaryHeight = std::ceil(summary_.font.lineHeight());
    summary_.setFrame(Rect(8, field_.frame().maxY() + 6, std::max(0.0f, b.w - 16), summaryHeight));
    float placeholderWidth = std::max(0.0f, b.w - 48);
    placeholder_.setFrame(Rect(24, summary_.frame().maxY() + 40, placeholderWidth,
                               placeholder_.fittingHeight(placeholderWidth)));
    float listTop = summary_.frame().maxY() + 6;
    list_.setFrame(Rect(0, listTop, b.w, std::max(0.0f, b.h - listTop)));
}

void SearchPanel::setDirectory(const std::optional<std::wstring>& directory) {
    if (directory_ == directory) return;
    directory_ = directory;
    ++searchGeneration_;
    if (searchWork_) searchWork_->cancel();
    searchWork_.reset();
    if (searchToken_) searchToken_->cancel();
    searchToken_.reset();
    groups_.clear();
    rebuildRows();
    summary_.text.clear();
    summary_.setNeedsDisplay();
    updatePlaceholder(L"", std::nullopt);
}

/// The results area explains itself when it has nothing to show: what the
/// panel does before a query, and what came back after one.
void SearchPanel::updatePlaceholder(const std::wstring& query, std::optional<int> matches) {
    if (!groups_.empty()) {
        placeholder_.setHidden(true);
        return;
    }
    if (query.empty()) {
        placeholder_.text = L"Search every file in this project.\n\n"
                            L"Aa  match case      wd  whole word      .*  regular expression";
    } else if (matches && *matches == 0) {
        placeholder_.text = L"No matches for \u201c" + query + L"\u201d.";
    } else if (query.size() < 2) {
        placeholder_.text = L"Keep typing \u2014 searching starts at two characters.";
    } else {
        placeholder_.text.clear();
    }
    placeholder_.setHidden(placeholder_.text.empty());
    placeholder_.setNeedsDisplay();
    setNeedsLayout();
}

void SearchPanel::refreshFonts() {
    backgroundColor = Theme::panelBackground;
    list_.backgroundColor = Theme::panelBackground;
    field_.refreshFonts();
    summary_.font = Theme::uiFont(10.5f);
    placeholder_.font = Theme::uiFont(11);
    list_.rowHeight = Theme::treeRowHeight();
    list_.reloadData();
    setNeedsLayout();
    setNeedsDisplay();
}

void SearchPanel::releaseTransientMemory() {
    ++searchGeneration_;
    if (searchWork_) searchWork_->cancel();
    searchWork_.reset();
    groups_.clear();
    groups_.shrink_to_fit();
    rebuildRows();
}

void SearchPanel::performSearch(const std::wstring& query) {
    field_.setText(query);
    searchChanged();
}

void SearchPanel::searchChanged() {
    std::wstring query = field_.text();
    SearchOptions options = field_.options();
    int generation = ++searchGeneration_;
    if (searchWork_) searchWork_->cancel();
    searchWork_.reset();
    // Cancel the query that is already running, not just the one still waiting
    // out the debounce.
    if (searchToken_) searchToken_->cancel();
    searchToken_.reset();
    if (query.size() < 2 || !directory_) {
        groups_.clear();
        rebuildRows();
        summary_.text = query.empty() ? L"" : L"Type at least 2 characters";
        summary_.setNeedsDisplay();
        updatePlaceholder(query, std::nullopt);
        return;
    }
    // Release the previous result tree before the replacement is built.
    groups_.clear();
    rebuildRows();
    summary_.text = L"Searching\u2026";
    summary_.setNeedsDisplay();
    updatePlaceholder(query, std::nullopt);
    // Disk search cannot see edits that have not been saved yet: snapshot the
    // modified buffers here, on the main thread.
    auto snapshots = std::make_shared<std::vector<std::pair<std::wstring, std::string>>>(
        DocumentStore::shared().modifiedTextSnapshots(*directory_));
    auto token = std::make_shared<CancelToken>();
    searchToken_ = token;
    std::wstring directory = *directory_;
    auto weak = life_.weak();
    searchWork_ = Dispatch::after(0.15, [this, weak, token, query, options, directory, snapshots, generation] {
        if (weak.expired() || token->isCancelled()) return;
        searchQueue().async([this, weak, token, query, options, directory, snapshots, generation] {
            if (token->isCancelled()) return;
            auto found = std::make_shared<std::vector<FileGroup>>(
                search(query, directory, options, *snapshots, token));
            if (token->isCancelled()) return;
            Dispatch::main([this, weak, found, query, generation] {
                if (weak.expired() || searchGeneration_ != generation) return;
                searchWork_.reset();
                groups_ = std::move(*found);
                rebuildRows();
                int matches = 0;
                for (auto& g : groups_) matches += (int)g.hits.size();
                int files = (int)groups_.size();
                summary_.text = matches == 0
                                    ? std::wstring(L"No results")
                                    : std::to_wstring(matches) + (matches == 1 ? L" result in " : L" results in ")
                                          + std::to_wstring(files) + (files == 1 ? L" file" : L" files");
                summary_.setNeedsDisplay();
                updatePlaceholder(query, matches);
            });
        });
    });
}

void SearchPanel::rebuildRows() {
    rows_.clear();
    for (int g = 0; g < (int)groups_.size(); ++g) {
        rows_.push_back({g, -1});
        if (!groups_[g].expanded) continue;
        for (int h = 0; h < (int)groups_[g].hits.size(); ++h) rows_.push_back({g, h});
    }
    if (list_.selectedRow() >= (int)rows_.size()) list_.setSelectedRow(-1, false);
    list_.reloadData();
}

void SearchPanel::rowClicked(int row) {
    if (row < 0 || row >= (int)rows_.size()) return;
    Row r = rows_[row];
    FileGroup& group = groups_[r.group];
    list_.setSelectedRow(row, false);
    if (r.hit < 0) {
        if (list_.pressX < 16) {
            group.expanded = !group.expanded;
            rebuildRows();
            return;
        }
        if (onOpenFile) onOpenFile(group.path);
    } else {
        if (onOpenResult) onOpenResult(group.path, group.hits[r.hit].line);
    }
}

namespace {
constexpr float kDisclosureX = 4;
constexpr float kDisclosure = 10;
constexpr float kIndentPerLevel = 12;
constexpr float kOutlineCell = 16;  // where a level-0 cell starts, past the disclosure
}  // namespace

void SearchPanel::drawRow(Graphics& g, int index, const Rect& rect) {
    const Row& row = rows_[index];
    const FileGroup& group = groups_[row.group];
    if (row.hit < 0) {
        // The disclosure triangle a file row carries in the outline.
        Rect chevron(rect.x + kDisclosureX, rect.y + (rect.h - kDisclosure) / 2, kDisclosure, kDisclosure);
        drawSymbol(g, group.expanded ? Symbol::ChevronDown : Symbol::ChevronRight, chevron, Theme::dimText, 0.9f);
        Rect cell(rect.x + kOutlineCell, rect.y, std::max(0.0f, rect.w - kOutlineCell), rect.h);
        Rect icon(cell.x + 2, cell.y + std::floor((cell.h - 13) / 2), 13, 13);
        CellDrawing::fileIcon(g, U(group.name()), icon);
        CellDrawing::primaryAndSecondary(g, group.name(), Theme::uiFont(11.5f), Theme::foreground, group.folder(),
                                         Theme::uiFont(10), Theme::dimText,
                                         Rect(cell.x + 20, cell.y, std::max(0.0f, cell.w - 24), cell.h));
        return;
    }
    const Hit& hit = group.hits[row.hit];
    Rect cell(rect.x + kOutlineCell + kIndentPerLevel, rect.y, std::max(0.0f, rect.w - kOutlineCell - kIndentPerLevel - 4),
              rect.h);
    Font font = Theme::uiFont(11);
    // The first tab right-aligns the line number at 32; the code column starts
    // at 38. One baseline for both.
    float baseline = Text::centeredBaseline(font, cell);
    std::wstring number = std::to_wstring(hit.line);
    float numberWidth = Text::width(number, font);
    g.text(number, font, Theme::dimText, baseline, Rect(cell.x + 32 - numberWidth, cell.y, numberWidth + 1, cell.h),
           LineBreak::Clipping);
    float codeX = cell.x + 38;
    Rect codeRect(codeX, cell.y, std::max(0.0f, cell.maxX() - codeX), cell.h);
    g.text(hit.preview, font, Theme::foreground, baseline, codeRect, LineBreak::TruncatingTail);
    // A rule under the match, the same one the editor draws: nothing is
    // painted over the preview, so the row keeps its own contrast.
    if (hit.matchRange && hit.matchRange->first + hit.matchRange->second <= hit.preview.size()) {
        float start = Text::width(hit.preview.substr(0, hit.matchRange->first), font);
        float width = Text::width(hit.preview.substr(hit.matchRange->first, hit.matchRange->second), font);
        float left = codeX + start;
        float right = std::min(left + width, codeRect.maxX());
        if (right > left) {
            g.fillRect(Rect(left, baseline - font.descender() + 1 - Theme::matchUnderlineWidth, right - left,
                            Theme::matchUnderlineWidth),
                       Theme::matchUnderline);
        }
    }
}

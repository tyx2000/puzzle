#include "palette.h"

#include "theme.h"

#include <dwmapi.h>

// ── QuickOpen ──────────────────────────────────────────────────────────────

namespace QuickOpen {

const std::set<std::wstring>& skipDirectories() {
    static const std::set<std::wstring> dirs = {L".git", L"node_modules", L".build", L"build",
                                                L"DerivedData", L".svn", L"Pods", L".obj"};
    return dirs;
}

namespace {
void walk(const std::wstring& directory, const std::wstring& relative, std::vector<std::wstring>& out) {
    WIN32_FIND_DATAW data;
    HANDLE find = FindFirstFileExW(pathJoin(directory, L"*").c_str(), FindExInfoBasic, &data,
                                   FindExSearchNameMatch, nullptr, FIND_FIRST_EX_LARGE_FETCH);
    if (find == INVALID_HANDLE_VALUE) return;
    std::vector<std::wstring> subdirectories;
    do {
        std::wstring name = data.cFileName;
        if (name == L"." || name == L"..") continue;
        // Hidden files are skipped, as the enumerator's .skipsHiddenFiles did.
        if (name[0] == L'.' || (data.dwFileAttributes & FILE_ATTRIBUTE_HIDDEN)) continue;
        std::wstring path = relative.empty() ? name : relative + L"/" + name;
        if (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
            if (data.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) continue;
            if (skipDirectories().count(name)) continue;
            subdirectories.push_back(name);
            continue;
        }
        out.push_back(path);
        if (out.size() >= maxFiles) break;
    } while (FindNextFileW(find, &data));
    FindClose(find);
    for (auto& name : subdirectories) {
        if (out.size() >= maxFiles) return;
        walk(pathJoin(directory, name), relative.empty() ? name : relative + L"/" + name, out);
    }
}
}  // namespace

std::vector<std::wstring> index(const std::wstring& directory) {
    std::vector<std::wstring> paths;
    walk(directory, L"", paths);
    if (paths.size() > maxFiles) paths.resize(maxFiles);
    return paths;
}

std::optional<int> score(const std::wstring& path, const std::wstring& query) {
    if (query.empty()) return 0;
    std::wstring haystack = lowercased(path);
    std::wstring needle;
    for (wchar_t c : lowercased(query)) {
        if (!iswspace(c)) needle += c;
    }
    if (needle.empty() || needle.size() > haystack.size()) return std::nullopt;
    size_t slash = path.rfind(L'/');
    size_t nameStart = slash == std::wstring::npos ? 0 : slash + 1;
    int total = 0;
    size_t index = 0;
    long previousMatch = -2;
    for (wchar_t character : needle) {
        size_t found = haystack.find(character, index);
        if (found == std::wstring::npos) return std::nullopt;
        total += 10;
        if ((long)found == previousMatch + 1) total += 12;  // consecutive
        if (found == 0 || haystack[found - 1] == L'/') total += 8;
        if (found == nameStart) total += 10;
        if (found >= nameStart) total += 6;  // in the file name
        previousMatch = (long)found;
        index = found + 1;
    }
    // Shorter paths win ties, so `App.cpp` beats `deep/nested/App.cpp`.
    return total - (int)(path.size() / 8);
}

std::vector<std::wstring> matches(const std::vector<std::wstring>& paths, const std::wstring& query,
                                  size_t limit) {
    if (trim(query).empty()) {
        return std::vector<std::wstring>(paths.begin(), paths.begin() + std::min(limit, paths.size()));
    }
    std::vector<std::pair<std::wstring, int>> scored;
    for (auto& path : paths) {
        if (auto value = score(path, query)) scored.emplace_back(path, *value);
    }
    std::sort(scored.begin(), scored.end(), [](const auto& l, const auto& r) {
        if (l.second != r.second) return l.second > r.second;
        return naturalCompare(U(l.first), U(r.first)) < 0;
    });
    std::vector<std::wstring> out;
    for (size_t i = 0; i < scored.size() && i < limit; ++i) out.push_back(scored[i].first);
    return out;
}

std::optional<std::pair<int, std::optional<int>>> lineTarget(const std::wstring& query) {
    std::wstring trimmed = trim(query);
    if (trimmed.empty()) return std::nullopt;
    // Empty fields are kept: ":12" is not line 12.
    size_t colon = trimmed.find(L':');
    std::wstring first = trimmed.substr(0, colon);
    auto number = [](const std::wstring& s) -> std::optional<int> {
        if (s.empty() || s.size() > 9) return std::nullopt;
        for (wchar_t c : s) if (c < L'0' || c > L'9') return std::nullopt;
        return std::stoi(s);
    };
    auto line = number(first);
    if (!line || *line <= 0) return std::nullopt;
    if (colon == std::wstring::npos) return std::make_pair(*line, std::optional<int>());
    auto column = number(trimmed.substr(colon + 1));
    if (!column || *column <= 0) return std::make_pair(*line, std::optional<int>());
    return std::make_pair(*line, column);
}

}  // namespace QuickOpen

// ── PalettePanel ───────────────────────────────────────────────────────────

PalettePanel::PalettePanel(float width) : width_(width) {
    RECT frame{0, 0, 10, 10};
    createWindow(L"", WS_POPUP, WS_EX_TOOLWINDOW, nullptr, frame);
    resizeBorder = 0;
    DWORD corner = 2;  // DWMWCP_ROUND
    DwmSetWindowAttribute(hwnd(), 33 /* DWMWA_WINDOW_CORNER_PREFERENCE */, &corner, sizeof corner);

    content_.panel = this;
    content_.backgroundColor = Theme::panelBackground;
    field_.font = Theme::uiFont(14);
    field_.textColor = Theme::foreground;
    field_.fillColor = Theme::inputBackground;
    field_.placeholderColor = Theme::dimText;
    field_.horizontalInset = 6;
    field_.onChange = [this] {
        if (onQueryChanged) onQueryChanged(field_.text());
    };
    field_.onSubmit = [this] { accept(); };
    field_.onEscape = [this] { dismiss(); };
    field_.onKey = [this](UINT key) {
        if (key == VK_DOWN) {
            move(1);
            return true;
        }
        if (key == VK_UP) {
            move(-1);
            return true;
        }
        return false;
    };
    hint_.font = Theme::uiFont(10.5f);
    hint_.color = Theme::dimText;
    list_.backgroundColor = Theme::panelBackground;
    list_.rowHeight = rowHeight;
    list_.numberOfRows = [this] { return (int)items_.size(); };
    list_.rowBackground = [this](int row) { return row == selection_ ? Theme::activeRow : Theme::panelBackground; };
    list_.drawRow = [this](Graphics& g, int row, const Rect& rect) { drawRow(g, row, rect); };
    list_.onClick = [this](int row) {
        if (row < 0) return;
        selection_ = row;
        accept();
    };
    content_.addSubview(&field_);
    content_.addSubview(&hint_);
    content_.addSubview(&list_);
    setRootView(&content_);
}

PalettePanel::~PalettePanel() {
    setRootView(nullptr);
    if (hwnd()) DestroyWindow(hwnd());
}

void PalettePanel::Content::layout() {
    Rect b = bounds();
    panel->field_.setFrame(Rect(12, 10, std::max(0.0f, b.w - 24), 26));
    panel->hint_.setFrame(Rect(12, 42, std::max(0.0f, b.w - 24), 16));
    float top = 10 + 26 + 8;
    panel->list_.setFrame(Rect(0, top, b.w, std::max(0.0f, b.h - top)));
}

void PalettePanel::Content::draw(Graphics& g) {
    g.strokeRect(bounds(), Theme::border, 1);
}

void PalettePanel::configure(const std::wstring& placeholder, const std::wstring& hint) {
    field_.placeholder = placeholder;
    hint_.text = hint;
    hint_.setHidden(hint.empty());
    field_.setNeedsDisplay();
}

void PalettePanel::setQuery(const std::wstring& text) {
    field_.setText(text);  // onChange tells onQueryChanged
}

void PalettePanel::setItems(std::vector<Item> items) {
    items_ = std::move(items);
    selection_ = items_.empty() ? -1 : 0;
    list_.reloadData();
    list_.setContentOffset(Point(0, 0));
    resize();
}

/// Grow with the results instead of leaving an empty well under the field.
void PalettePanel::resize() {
    int rows = std::min((int)items_.size(), maxVisibleRows);
    float listHeight = rows * rowHeight;
    bool hintVisible = items_.empty() && !hint_.text.empty();
    hint_.setHidden(!hintVisible);
    float hintHeight = hintVisible ? 22.0f : 0.0f;
    float height = 10 + 26 + 8 + listHeight + hintHeight + (listHeight > 0 ? 8 : 4);
    float s = scale();
    SetWindowPos(hwnd(), nullptr, 0, 0, (int)std::lround(width_ * s), (int)std::lround(height * s),
                 SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
    setNeedsLayout();
    invalidateAll();
}

void PalettePanel::present(HWND parent) {
    parent_ = parent;
    SetWindowLongPtrW(hwnd(), GWLP_HWNDPARENT, (LONG_PTR)parent);
    UINT dpi = GetDpiForWindow(parent);
    float s = dpi / 96.0f;
    RECT pr;
    GetWindowRect(parent, &pr);
    int width = (int)std::lround(width_ * s);
    RECT r;
    GetWindowRect(hwnd(), &r);
    int x = (pr.left + pr.right) / 2 - width / 2;
    int y = pr.top + (int)std::lround(120 * s);
    SetWindowPos(hwnd(), HWND_TOP, x, y, width, std::max<int>(r.bottom - r.top, 10), SWP_SHOWWINDOW);
    presented_ = true;
    resize();
    SetForegroundWindow(hwnd());
    SetActiveWindow(hwnd());
    field_.focus();
    field_.selectAll();
}

void PalettePanel::dismiss() {
    if (!presented_) return;
    presented_ = false;
    ShowWindow(hwnd(), SW_HIDE);
    if (parent_ && IsWindow(parent_)) SetActiveWindow(parent_);
}

LRESULT PalettePanel::handleMessage(UINT message, WPARAM wParam, LPARAM lParam) {
    if (message == WM_CLOSE) {
        dismiss();
        return 0;
    }
    if (message == WM_KEYDOWN && wParam == VK_ESCAPE) {
        dismiss();
        return 0;
    }
    return WindowHost::handleMessage(message, wParam, lParam);
}

void PalettePanel::windowDidActivate(bool active) {
    // Losing the keyboard dismisses it, as the panel did on resigning key.
    if (!active && presented_) {
        presented_ = false;
        ShowWindow(hwnd(), SW_HIDE);
    } else if (active) {
        field_.focus();
    }
}

void PalettePanel::accept() {
    const Item* item = selection_ >= 0 && selection_ < (int)items_.size() ? &items_[selection_] : nullptr;
    if (!onAccept) return;
    if (item) {
        Item copy = *item;  // the handler may replace the items
        onAccept(&copy);
    } else {
        onAccept(nullptr);
    }
}

void PalettePanel::move(int delta) {
    if (items_.empty()) return;
    selection_ = std::clamp(selection_ + delta, 0, (int)items_.size() - 1);
    list_.scrollRowToVisible(selection_);
    list_.setNeedsDisplay();
}

void PalettePanel::drawRow(Graphics& g, int row, const Rect& rect) {
    const Item& item = items_[row];
    Font font = Theme::uiFont(12);
    Font detailFont = Theme::uiFont(10);
    float baseline = Text::centeredBaseline(font, Rect(rect.x, rect.y, rect.w, rect.h / 2 + 6));
    Rect textRect(rect.x + 12, rect.y, std::max(0.0f, rect.w - 24), rect.h);
    g.text(item.title, font, Theme::foreground, baseline, textRect);
    if (item.detail.empty()) return;
    g.text(item.detail, detailFont, Theme::dimText, baseline + 13, textRect, LineBreak::TruncatingHead);
}

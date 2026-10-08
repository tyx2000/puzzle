// The floating input used for Ctrl+P and Ctrl+L, and the fuzzy file lookup
// behind Ctrl+P (PalettePanel.swift, QuickOpen.swift).
#pragma once

#include "widgets.h"

namespace QuickOpen {

/// Directories never worth listing — the same set project search skips.
const std::set<std::wstring>& skipDirectories();
constexpr size_t maxFiles = 20000;
constexpr size_t maxResults = 50;

/// Project-relative paths with forward slashes, bounded so a huge checkout
/// cannot make Ctrl+P allocate without limit.
std::vector<std::wstring> index(const std::wstring& directory);
/// Subsequence match with a score: consecutive hits, matches right after a
/// separator, and matches in the file name all count for more.
std::optional<int> score(const std::wstring& path, const std::wstring& query);
std::vector<std::wstring> matches(const std::vector<std::wstring>& paths, const std::wstring& query,
                                  size_t limit = maxResults);
/// "12" jumps to a line, "12:8" to a column too. Nullopt when it is not one.
std::optional<std::pair<int, std::optional<int>>> lineTarget(const std::wstring& query);

}  // namespace QuickOpen

/// A query field with an optional result list underneath, keyboard-driven
/// and dismissed by Escape or by losing the keyboard.
class PalettePanel : public WindowHost {
public:
    /// One row: what to show, and what to hand back when it is chosen.
    struct Item {
        std::wstring title;
        std::wstring detail;
        std::optional<std::wstring> value;
    };
    static constexpr float rowHeight = 34;
    static constexpr int maxVisibleRows = 8;

    explicit PalettePanel(float width = 560);
    ~PalettePanel() override;

    std::function<void(const Item*)> onAccept;
    std::function<void(const std::wstring&)> onQueryChanged;

    void configure(const std::wstring& placeholder, const std::wstring& hint);
    std::wstring query() const { return field_.text(); }
    void setQuery(const std::wstring& text);
    void setItems(std::vector<Item> items);
    /// Centred near the top of the owning window, where a palette belongs.
    void present(HWND parent);
    void dismiss();
    bool isPresented() const { return presented_; }

protected:
    LRESULT handleMessage(UINT message, WPARAM wParam, LPARAM lParam) override;
    void windowDidActivate(bool active) override;

private:
    class Content : public View {
    public:
        PalettePanel* panel = nullptr;
        void layout() override;
        void draw(Graphics& g) override;
    };
    void resize();
    void accept();
    void move(int delta);
    void drawRow(Graphics& g, int row, const Rect& rect);

    float width_;
    Content content_;
    TextField field_;
    Label hint_;
    ListView list_;
    std::vector<Item> items_;
    int selection_ = 0;
    bool presented_ = false;
    HWND parent_ = nullptr;
};

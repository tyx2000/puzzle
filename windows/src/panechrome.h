// What frames the editor: the tab strip, the strip above a diff, the
// side-by-side diff, and the start page (EditorTabBar.swift,
// DiffHeaderView.swift, SideBySideDiffView.swift, WelcomeView.swift).
#pragma once

#include "diffrows.h"
#include "widgets.h"

enum class DiffMode { Unified, SideBySide };

/// The side-by-side diff: old on the left, new on the right, one list so both
/// columns scroll as one.
class SideBySideDiffView : public View {
public:
    static constexpr float gutterWidth = 44;
    SideBySideDiffView();
    void configure(const std::string& diff);
    int changeCount() const { return (int)changeStarts_.size(); }
    void step(bool forward);
    void layout() override;
    void refreshAppearance();
private:
    void drawRow(Graphics& g, int row, const Rect& rect);
    void drawSide(Graphics& g, const Rect& rect, std::optional<int> number,
                  const std::optional<std::wstring>& text, const Color* background, const Color& ink);
    ListView list_;
    std::vector<DiffRows::Row> rows_;
    std::vector<int> changeStarts_;
    int currentBlock_ = -1;
    std::optional<int> currentRow_;
};

/// The strip above a diff: which file, how many changes, ↑ ↓ and the layout.
class DiffHeaderView : public View {
public:
    static constexpr float height = 28;
    DiffHeaderView();
    std::function<void()> onPrevious;
    std::function<void()> onNext;
    std::function<void()> onToggleMode;
    void configure(const std::string& path, int changes);
    const std::string& path() const { return path_; }
    void setMode(DiffMode mode);
    void layout() override;
    void draw(Graphics& g) override;
private:
    SymbolButton previous_;
    SymbolButton next_;
    SymbolButton mode_;
    std::string path_;
    std::wstring folder_;
    std::wstring name_;
    std::wstring summary_;
};

/// One flat tab: the full-height ground when active, no border.
class TabPillView : public View {
public:
    TabPillView();
    std::function<void()> onSelect;
    std::function<void()> onClose;
    std::function<void()> onCloseOthers;
    std::function<void()> onCloseRight;
    bool canCloseOthers = false;
    bool canCloseRight = false;
    void configure(const std::wstring& title, bool modified, bool active, const std::wstring& path);
    float preferredWidth() const;
    void layout() override;
    void draw(Graphics& g) override;
    bool mouseDown(const MouseEvent& e) override;
    bool rightMouseDown(const MouseEvent& e) override;
private:
    SymbolButton close_;
    std::wstring title_;
    bool active_ = false;
};

/// File tabs, wrapping onto rows of the title band's height. The first row
/// keeps the window's corner clear: the settings gear and the caption buttons.
class EditorTabBar : public View {
public:
    static constexpr float defaultRowHeight = 32;
    /// Room on the right of the first row for the editor's own actions.
    static constexpr float actionAreaWidth = 34;
    std::function<void(int)> onSelect;
    std::function<void(int)> onClose;
    std::function<void(int)> onCloseOthers;
    std::function<void(int)> onCloseRight;
    struct TabInfo {
        std::wstring title;
        bool modified = false;
        std::wstring path;
    };
    float rowHeight = defaultRowHeight;
    /// The caption buttons' width, kept clear at the right of the first row.
    float captionReserve = 0;
    bool paneActive = true;
    void reload(const std::vector<TabInfo>& tabs, int active);
    float currentHeight();
    void layout() override;
    bool isWindowDragArea(Point) override { return true; }
private:
    float layoutPills(bool apply);
    std::vector<std::unique_ptr<TabPillView>> pills_;
};

/// Shown centred in the editor area when no project is open: the app name,
/// Open, and the recently opened projects.
class WelcomeView : public View {
public:
    WelcomeView();
    ~WelcomeView() override;
    std::function<void()> onOpenFolder;
    std::function<void(const std::wstring&)> onOpenRecent;
    std::function<void(const std::vector<std::wstring>&)> onOpenChecked;
    void layout() override;
    bool isWindowDragArea(Point p) override { return p.y < 32; }
    void reloadRecents();
    void refreshFonts();
private:
    class RecentRow;
    void setChecked(const std::wstring& path, bool checked);
    Label title_;
    PushButton openButton_;
    PushButton openCheckedButton_;
    std::vector<std::unique_ptr<RecentRow>> rows_;
    std::set<std::wstring> checked_;
    int observer_ = 0;
};

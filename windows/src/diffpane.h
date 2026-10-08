// The right side of the window: one tab per diff opened, the strip naming
// the file, and the read-only diff — or, with no project, the start page
// (DiffPaneViewController, DiffTabBar, DiffHeaderView, DiffView, WelcomeView).
#pragma once

#include "diffrows.h"
#include "gitservice.h"
#include "widgets.h"

enum class DiffMode { Unified, SideBySide };

/// A read-only diff in one table, so a long diff costs only the rows on screen.
class DiffView : public View {
public:
    static constexpr float gutterWidth = 44;
    static constexpr size_t noteLimit = 400;
    DiffView();
    /// `keepingPosition` is for the same diff read again.
    void configure(const std::string& diff, bool keepingPosition = false);
    void setMode(DiffMode mode);
    int changeCount() const { return (int)changeStarts_.size(); }
    long long omittedLines() const { return omittedLines_; }
    void step(bool forward);
    void layout() override;
    static std::wstring note(const std::string& diff);
private:
    void rebuild();
    void drawRow(Graphics& g, int row, const Rect& rect);
    void drawSide(Graphics& g, const Rect& rect, std::optional<int> number,
                  const std::optional<std::wstring>& text, const Color* background, const Color& ink);
    ListView list_;
    Label note_;
    std::string diff_;
    DiffMode mode_ = DiffMode::Unified;
    std::vector<DiffRows::Row> rows_;
    long long omittedLines_ = 0;
    std::vector<int> changeStarts_;
    int currentBlock_ = -1;
    std::optional<int> currentRow_;
};

/// The strip above a diff: which file, how many changes, and ↑ ↓ and the
/// layout toggle.
class DiffHeaderView : public View {
public:
    static constexpr float height = 28;
    DiffHeaderView();
    std::function<void()> onPrevious;
    std::function<void()> onNext;
    std::function<void()> onToggleMode;
    void configure(const std::string& path, int changes, long long omittedLines = 0);
    void setMode(DiffMode mode);
    void layout() override;
    void draw(Graphics& g) override;
private:
    SymbolButton previous_;
    SymbolButton next_;
    SymbolButton mode_;
    std::wstring folder_;
    std::wstring name_;
    std::wstring summary_;
};

/// One flat tab.
class TabPillView : public View {
public:
    TabPillView();
    std::function<void()> onSelect;
    std::function<void()> onClose;
    std::function<void()> onCloseOthers;
    std::function<void()> onCloseRight;
    bool canCloseOthers = false;
    bool canCloseRight = false;
    void configure(const std::wstring& title, bool active, const std::wstring& path);
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

/// Flat tabs, wrapping onto rows of the title band's height. The first row
/// leaves room for the caption buttons at the window's corner.
class DiffTabBar : public View {
public:
    static constexpr float defaultRowHeight = 32;
    std::function<void(int)> onSelect;
    std::function<void(int)> onClose;
    std::function<void(int)> onCloseOthers;
    std::function<void(int)> onCloseRight;
    struct TabInfo {
        std::wstring title;
        std::wstring path;
    };
    float rowHeight = defaultRowHeight;
    /// Width kept clear at the right end of the first row.
    float trailingReserve = 0;
    void reload(const std::vector<TabInfo>& tabs, int active);
    /// The height the rows need at the current width.
    float currentHeight();
    void layout() override;
    bool isWindowDragArea(Point) override { return true; }
private:
    float layoutPills(bool apply);
    std::vector<std::unique_ptr<TabPillView>> pills_;
};

/// The start page: the app name, Open, and the recent projects.
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

class DiffPane : public View {
public:
    struct Tab {
        enum class Source { WorkingTree, Commit };
        std::wstring directory;
        std::string path;
        Source source = Source::WorkingTree;
        std::string hash;
        std::string diff;
        bool needsReread = false;
        std::wstring id() const;
        std::wstring title() const;
        bool sameSource(const Tab& o) const {
            return samePath(directory, o.directory) && path == o.path && source == o.source
                && hash == o.hash;
        }
    };

    DiffPane();
    /// Read this diff again — reopened, or shown after its body was released.
    std::function<void(const std::wstring&, const std::string&, Tab::Source, const std::string&)>
        onReadAgain;
    std::function<void()> onOpenFolder;
    std::function<void(const std::wstring&)> onOpenRecent;
    std::function<void(const std::vector<std::wstring>&)> onOpenChecked;

    void setHasProject(bool hasProject);
    void setTabRowHeight(float height);
    void setCaptionReserve(float width);
    void open(const Tab& tab);
    void update(const std::wstring& id, const std::string& diff);
    void select(int index);
    void markWorkingTreeTabsStale(const std::wstring& directory, const std::optional<std::wstring>& except);
    void releaseInactiveBodies();
    void close(int index);
    bool closeActive();
    void closeOthers(int index);
    void closeRight(int index);
    void closeAll();
    void closeTabs(const std::wstring& directory);
    void step(int offset);
    bool reopenLastClosed();
    const Tab* activeTab() const;
    bool copyActiveDiff(HWND owner);

    void layout() override;
    bool isWindowDragArea(Point p) override { return p.y < tabBar_.rowHeight; }

    static size_t bodyByteBudget;

private:
    struct ClosedTab {
        std::wstring directory;
        std::string path;
        Tab::Source source;
        std::string hash;
    };
    void remember(const Tab& tab);
    void reload();
    void showActive(bool keepingPosition);
    void noteShown(const std::wstring& id);
    void enforceBodyBudget();
    void readAgainIfNeeded();
    void toggleMode();
    void updatePlaceholder();
    void updateWelcome();
    std::wstring tooltip(const Tab& tab) const;

    DiffTabBar tabBar_;
    DiffHeaderView header_;
    DiffView diffView_;
    Label hint_;
    std::unique_ptr<WelcomeView> welcome_;
    bool welcomePending_ = false;
    bool hasProject_ = false;
    std::vector<Tab> tabs_;
    std::optional<int> activeIndex_;
    std::vector<ClosedTab> closed_;
    std::vector<std::wstring> shownOrder_;
    static DiffMode mode_;
    Lifetime life_;
};

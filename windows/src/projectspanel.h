// The Projects panel: the window's projects listed down the side, the one
// being shown expanded to its file tree beside its changes over its history
// (ProjectsPanel.swift).
#pragma once

#include "changes.h"
#include "filetree.h"
#include "history.h"
#include "widgets.h"

struct ProjectRowInfo {
    std::wstring name;
    std::wstring branch;
    std::wstring user;
    int changes = 0;
    std::wstring path;
};

/// One project: its name, its branch, who commits there, how many files it
/// has changed, and the ✕ that takes it out of the window.
class ProjectRowView : public View {
public:
    static constexpr float height = 32;
    static constexpr float closeWidth = 18;
    static constexpr float closeInset = 8;
    static constexpr float markerWidth = 5;
    static constexpr float iconSize = 14;
    static constexpr float iconGap = 5;
    static constexpr double sweepPeriod = 1.0;

    ProjectRowView();
    std::function<void()> onSelect;
    std::function<void()> onClose;
    /// The branch name is its own target: it selects the project and shows
    /// that project's Git panel.
    std::function<void()> onSelectBranch;
    /// The Git mark pulls the project.
    std::function<void()> onPull;
    std::function<bool()> onDragBegan;
    /// How far the row has travelled down the list from where it was picked up.
    std::function<void(float)> onDragMoved;
    std::function<void()> onDragEnded;

    void configure(const ProjectRowInfo& info, bool isActive);
    void setSyncing(bool syncing);
    void setShowsDivider(bool on);
    /// Where the row divides its two headings, as a share of its width: the
    /// same number the columns below are split at.
    void setDividerFraction(float fraction);
    const std::wstring& projectPath() const { return info_.path; }

    void draw(Graphics& g) override;
    void mouseMoved(const MouseEvent& e) override;
    void mouseExited() override;
    bool mouseDown(const MouseEvent& e) override;
    void mouseDragged(const MouseEvent& e) override;
    void mouseUp(const MouseEvent& e) override;
    Cursor cursorAt(Point p) override;
    std::wstring tooltipAt(Point p) override;
    void viewDidMoveToWindow() override { syncingChanged(); }

private:
    float columnDivider() const;
    Rect closeRect() const;
    Rect nameIconRect() const;
    Rect branchIconRect() const;
    Rect pullRect() const;
    Rect nameRect() const;
    Rect branchColumnRect() const;
    Rect branchRect() const;
    std::wstring pullHint() const;
    void syncingChanged();
    std::optional<float> sweepPhase() const;
    void drawGitMark(Graphics& g, const Rect& rect);

    ProjectRowInfo info_;
    bool isActive_ = false;
    bool showsDivider_ = false;
    bool closeHovered_ = false;
    bool branchHovered_ = false;
    bool pullHovered_ = false;
    float dividerFraction_ = 0.5f;
    bool isSyncing_ = false;
    std::optional<double> sweepStarted_;
    Dispatch::RepeatingTimer sweepTimer_;
    // Press tracking.
    Point pressStart_;
    Point pressStartInWindow_;
    bool dragging_ = false;
    bool pressedClose_ = false;
};

/// Two panes split by a line the reader can drag: the file tree beside the Git
/// column, and inside that the changes over the history.
class ProjectColumnsView : public View {
public:
    enum class Axis { Horizontal, Vertical };
    static constexpr float borderWidth = 1;
    static constexpr float minimumColumn = 90;
    static constexpr float minimumRow = 44;
    static Color regionBorder(const Color& hue) { return hue.withAlpha(0.4f); }
    static float divider(float fraction, float length, float minimum);

    Axis axis = Axis::Horizontal;
    View* first = nullptr;
    View* second = nullptr;
    bool showsSecond = true;
    float fraction = 0.5f;
    std::function<void(float)> onFractionChanged;
    Color firstBorder;
    Color secondBorder;
    float minimumPane = minimumColumn;

    float dividerPosition() const;
    Rect firstPaneRect() const;
    Rect secondPaneRect() const;
    void moveDivider(float along);

    void layout() override;
    void draw(Graphics& g) override;
    View* hitTest(Point p) override;
    bool mouseDown(const MouseEvent& e) override;
    void mouseDragged(const MouseEvent& e) override;
    Cursor cursorAt(Point p) override;
    bool scrollWheel(float dx, float dy, const MouseEvent& e) override;

private:
    float span() const;
    float position(Point p) const;
    bool isOnGrabBand(Point p) const;
    Rect dividerRect(float radius) const;
    static Rect content(const Rect& pane, bool bordered);
    bool tracking_ = false;
};

class ProjectsPanel : public View {
public:
    ProjectsPanel();
    ~ProjectsPanel() override;
    FileTreeView fileTree;
    /// The right-hand column, itself split: what the expanded project has
    /// changed, over the commits behind it.
    ProjectChangesView changes;
    ProjectHistoryView history;
    std::function<void(int)> onSelect;
    std::function<void(int)> onClose;
    /// The branch name on a row was clicked: show that project's Git panel.
    std::function<void(int)> onSelectBranch;
    std::function<void(int)> onPull;
    std::function<void(int, int)> onReorder;

    void setSyncing(const std::set<std::wstring>& paths);
    void configure(const std::vector<ProjectRowInfo>& projects, std::optional<int> active);
    void layout() override;

    static constexpr double switchDuration = 0.3;

private:
    void showRegions(std::optional<bool> isRepository);
    void applyDividerFraction(float fraction);
    void layOut(std::optional<int> active);
    bool canReorder() const;
    bool beginRowDrag(ProjectRowView* row);
    void rowDragMoved(ProjectRowView* row, float travel);
    void endRowDrag();
    std::vector<Rect> targetFrames() const;

    ProjectColumnsView columns_;
    ProjectColumnsView gitColumn_;
    float dividerFraction_ = 0.5f;
    std::vector<std::unique_ptr<ProjectRowView>> rows_;
    std::vector<View*> arranged_;
    std::vector<std::wstring> shown_;
    std::optional<int> activeIndex_;
    std::set<std::wstring> syncingPaths_;
    ProjectRowView* draggingRow_ = nullptr;
    int dragStartIndex_ = 0;
    struct Pending {
        std::vector<ProjectRowInfo> projects;
        std::optional<int> active;
    };
    std::optional<Pending> pendingConfiguration_;
    // The slide when a project opens.
    std::map<View*, Rect> animationFrom_;
    double animationStart_ = 0;
    Dispatch::RepeatingTimer animationTimer_;
};

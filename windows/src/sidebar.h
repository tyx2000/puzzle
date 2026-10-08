// The left panel: the project/branch band at the top of the window and,
// under it, the window's projects (SidebarViewController, ProjectTitleView).
#pragma once

#include "projectspanel.h"

/// The project name and its branch, in the title band. The name is a label;
/// the branch opens the branch menu.
class ProjectTitleView : public View {
public:
    static constexpr float horizontalPadding = 8;
    static constexpr float branchGap = 8;
    /// The branch was clicked; the rect is the branch text, in this view.
    std::function<void(const Rect&)> onBranchClick;
    void configure(const std::wstring& project, const std::wstring& branch);
    float intrinsicWidth() const;
    void draw(Graphics& g) override;
    bool mouseDown(const MouseEvent& e) override;
    void mouseUp(const MouseEvent& e) override;
    Cursor cursorAt(Point p) override;
    std::wstring tooltipAt(Point p) override;
    bool isWindowDragArea(Point p) override;
private:
    enum class Zone { None, Project, Branch };
    std::pair<Rect, Rect> zones() const;
    Zone zoneAt(Point p) const;
    std::wstring project_;
    std::wstring branch_;
    Zone pressed_ = Zone::None;
};

/// The empty part of the title band, which moves the window.
class TitleBandView : public View {
public:
    bool isWindowDragArea(Point) override { return true; }
};

class SidebarView : public View {
public:
    SidebarView();
    ProjectTitleView projectTitle;
    ProjectsPanel projectsPanel;
    SymbolButton menuButton;
    SymbolButton addProjectButton;
    SymbolButton terminalButton;

    std::function<void(int)> onSelectProjectRow;
    std::function<void(int)> onCloseProjectRow;
    std::function<void(int, int)> onReorderProjectRows;
    std::function<void(int)> onPullProjectRow;
    std::function<void()> onAddProject;
    std::function<void()> onOpenTerminal;
    std::function<void()> onShowMenu;
    std::function<void(const Git::StatusEntry&, const std::wstring&)> onGitDiff;
    std::function<void(const Git::Commit&, const Git::CommitFile&, const std::wstring&)> onGitCommitDiff;
    std::function<void(const std::wstring&)> onProjectGitChanged;

    void setTabRowHeight(float height);
    void setTitlebarLeadingInset(float inset);
    void setProjectTitle(const std::wstring& project, const std::wstring& branch);
    void setProjects(const std::vector<ProjectRowInfo>& projects, std::optional<int> active,
                     std::optional<bool> isRepository = std::nullopt);
    void setSyncingProjects(const std::set<std::wstring>& paths);
    void setChanges(const std::vector<Git::StatusEntry>& entries,
                    const std::optional<std::wstring>& directory,
                    const ProjectHistoryView::State& state);
    void clearChanges(const std::optional<std::wstring>& directory);

    void layout() override;
    void draw(Graphics& g) override;
    bool isWindowDragArea(Point p) override { return p.y < tabRowHeight_; }

private:
    float tabRowHeight_ = 32;
    float leadingInset_ = 44;
};

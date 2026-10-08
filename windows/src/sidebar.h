// The left panel: the project/branch band at the top of the window, the
// Projects, Search or Git panel under it, and Zed's 40pt action bar pinned at
// the bottom (SidebarViewController, ProjectTitleView, ActivityBarView).
#pragma once

#include "gitpanel.h"
#include "projectspanel.h"
#include "search.h"

/// The project name and its branch, in the title band. The name shows the
/// Projects panel; the branch opens the branch menu.
class ProjectTitleView : public View {
public:
    static constexpr float horizontalPadding = 8;
    static constexpr float branchGap = 8;
    std::function<void()> onProjectClick;
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

/// Zed's bottom-left action bar: one evenly spaced text button per panel; the
/// one for the visible panel gets a full-height ground.
class ActivityBarView : public View {
public:
    static constexpr float height = 40;
    enum class Action { Project, Search, Git };
    /// The host decides whether to show that panel or collapse the sidebar.
    std::function<void(Action)> onAction;
    void setSelected(std::optional<Action> action);
    void draw(Graphics& g) override;
    bool mouseDown(const MouseEvent& e) override;
private:
    int slotAt(Point p) const;
    std::optional<Action> selected_;
};

class SidebarView : public View {
public:
    SidebarView();
    ~SidebarView() override;
    ProjectTitleView projectTitle;
    ProjectsPanel projectsPanel;
    ActivityBarView activityBar;
    SymbolButton menuButton;
    SymbolButton addProjectButton;
    SymbolButton terminalButton;
    FileTreeView& fileTree() { return projectsPanel.fileTree; }

    std::function<void(int)> onSelectProjectRow;
    std::function<void(int)> onCloseProjectRow;
    /// The branch on a project row was clicked, which goes to its Git panel.
    std::function<void(int)> onSelectProjectBranchRow;
    std::function<void(int, int)> onReorderProjectRows;
    std::function<void(int)> onPullProjectRow;
    std::function<void()> onAddProject;
    std::function<void()> onOpenTerminal;
    std::function<void()> onShowMenu;
    std::function<void(const std::wstring&, int)> onSearchResult;
    std::function<void(const std::wstring&)> onSearchFile;
    std::function<void(const std::wstring&)> onGitFile;
    std::function<void(const Git::StatusEntry&, const std::wstring&)> onGitDiff;
    std::function<void(const Git::Commit&, const Git::CommitFile&, const std::wstring&)> onGitCommitDiff;
    std::function<void()> onGitChanged;
    /// The commit line over a project's changes committed or pushed in this
    /// repository.
    std::function<void(const std::wstring&)> onProjectGitChanged;

    using Panel = ActivityBarView::Action;
    Panel visiblePanel() const { return visiblePanel_; }

    void setTabRowHeight(float height);
    void setTitlebarLeadingInset(float inset);
    void setProjectTitle(const std::wstring& project, const std::wstring& branch);
    /// `nullopt` when the window has no project left.
    void setDirectory(const std::optional<std::wstring>& directory);
    void setProjects(const std::vector<ProjectRowInfo>& projects, std::optional<int> active);
    void setSyncingProjects(const std::set<std::wstring>& paths);
    void setChanges(const std::vector<Git::StatusEntry>& entries, const std::optional<std::wstring>& directory,
                    const ProjectHistoryView::State& state);
    void clearChanges(const std::optional<std::wstring>& directory);

    void showFiles();
    void showSearch();
    void showGit();
    /// Reveal the Git panel already switched to its Branch tab.
    void showGitBranches();
    void refreshFonts();
    /// External Git tools can update an already-visible panel; a hidden one
    /// is not built just for this.
    void refreshGitPanelIfLoaded();
    /// Drop heavy hidden panels; reopening one rebuilds it.
    void releaseHiddenPanels();
    void performSearch(const std::wstring& query);
    void showHistory();
    void expandCommit(int index);
    void openCommitFile(int commitIndex, int fileIndex);
    GitPanel* gitPanel() const { return git_.get(); }

    void layout() override;
    void draw(Graphics& g) override;
    bool isWindowDragArea(Point p) override { return p.y < tabRowHeight_; }

private:
    SearchPanel& ensureSearch();
    GitPanel& ensureGit();
    void reveal(View* panel);

    View container_;
    std::unique_ptr<SearchPanel> search_;
    std::unique_ptr<GitPanel> git_;
    std::optional<std::wstring> directory_;
    Panel visiblePanel_ = Panel::Project;
    float tabRowHeight_ = 32;
    float leadingInset_ = 44;
};

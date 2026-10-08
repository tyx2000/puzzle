// One window: its projects down the side, and the diffs opened from them
// (WorkspaceWindowController and RootViewController).
#pragma once

#include "diffpane.h"
#include "services.h"
#include "sidebar.h"

class Menu;

/// The invisible target over the panel/diff divider, painting the 1pt line.
class DividerHandle : public View {
public:
    static constexpr float hitWidth = 13;
    std::function<void()> onDragBegan;
    std::function<void(float)> onDrag;
    void draw(Graphics& g) override;
    Cursor cursorAt(Point) override { return Cursor::ResizeLeftRight; }
    bool mouseDown(const MouseEvent& e) override;
    void mouseDragged(const MouseEvent& e) override;
private:
    float startX_ = 0;
};

/// Window content: the projects panel beside the diffs.
class RootView : public View {
public:
    static constexpr float minimumSidebarWidth = 300;
    static constexpr float defaultSidebarFraction = 0.4f;
    RootView(SidebarView* sidebar, DiffPane* diffs);
    CaptionButtonsView caption;
    void layout() override;
    /// After the window is on screen, the width it opened at is the width it keeps.
    void settleOpeningWidth();
    static float openingSidebarWidth(float windowWidth);
private:
    void resizeSidebar(float proposed);
    SidebarView* sidebar_;
    DiffPane* diffs_;
    DividerHandle divider_;
    float sidebarWidth_ = 500;
    float dragStartWidth_ = 500;
    bool settled_ = false;
};

class WorkspaceWindow : public WindowHost {
public:
    WorkspaceWindow();
    ~WorkspaceWindow() override;

    /// Called once the window has closed, so the app can let go of it.
    std::function<void(WorkspaceWindow*)> onClose;
    /// The app routes folders to an existing project first.
    std::function<void(const std::vector<std::wstring>&)> onOpenRequested;
    /// The app menu (File, Edit, View, Window, Help) for this window.
    std::function<std::shared_ptr<Menu>(WorkspaceWindow*)> makeAppMenu;

    void showWindow();
    const std::vector<std::wstring>& projects() const { return projects_; }
    const std::optional<std::wstring>& projectURL() const { return projectURL_; }
    bool hasProject() const { return projectURL_.has_value(); }

    void openProject(const std::wstring& path);
    void activateProject(const std::wstring& path);
    void deactivateProject();
    void closeProject(const std::wstring& path);
    void moveProject(int from, int to);
    void openSelection(const std::vector<std::wstring>& paths);

    void refreshExternalGitState();
    void refreshGit(bool requireFollowUp = false);
    void refreshProjectSummaries(bool all = false);
    void applicationDidBecomeActive();

    void showDiff(const Git::StatusEntry& entry, const std::wstring& directory);
    void showDiffForPath(const std::string& path, const std::wstring& directory);
    void showCommitDiff(const std::string& hash, const std::string& path, const std::wstring& directory);

    // Menu actions.
    void openFolder();
    void closeTab();
    void selectNextTab() { diffs_.step(1); }
    void selectPreviousTab() { diffs_.step(-1); }
    void reopenClosedTab();
    void releaseTransientMemory();
    void copy();
    void refreshRepository();
    void showAppMenu();

protected:
    LRESULT handleMessage(UINT message, WPARAM wParam, LPARAM lParam) override;
    bool handleShortcut(const KeyEvent& e) override;
    void windowDidActivate(bool active) override;
    void windowWillClose() override;
    void windowDidMinimize() override;

private:
    struct ProjectSummary {
        std::wstring branch;
        std::wstring user;
        int changes = 0;
        bool operator==(const ProjectSummary& o) const {
            return branch == o.branch && user == o.user && changes == o.changes;
        }
        bool operator!=(const ProjectSummary& o) const { return !(*this == o); }
    };

    void wire();
    void refreshWindowTitle();
    void loadProject(const std::wstring& path);
    void clearProject();
    void apply(const Git::Status& status, const std::wstring& project);
    void refreshOpenDiffs(const std::set<std::string>& changed, const std::wstring& directory);
    void refreshProjectTabs();
    void applySummaries(const std::vector<std::pair<std::wstring, ProjectSummary>>& found);
    bool noteSummary(const ProjectSummary& summary, const std::wstring& path);
    int indexOfProject(const std::wstring& path) const;

    // Syncing with the remote.
    void beginSync(const std::wstring& path);
    void endSync(const std::wstring& path, double startedAt);
    void publishSyncing();
    void pullProject(const std::wstring& path);
    void startPull(const std::wstring& path);
    void presentPullError(const std::string& message, const std::wstring& path);
    void remoteRefsMoved();

    // Branches.
    void showBranchMenu(const Rect& rect);
    std::shared_ptr<Menu> branchMenu(const std::vector<Git::Branch>& branches, const std::wstring& directory);
    void switchBranch(const Git::Branch& branch, const std::wstring& directory);
    void createBranch(const std::vector<Git::Branch>& branches, const std::wstring& directory);
    void deleteBranch(const Git::Branch& branch, const std::wstring& directory);
    void runBranchOperation(const std::wstring& failureTitle, const std::wstring& directory,
                            std::function<Git::RemoteResult()> work);
    void presentBranchAlert(const std::wstring& title, const std::string& message);

    SidebarView sidebar_;
    DiffPane diffs_;
    RootView root_;
    std::vector<std::wstring> projects_;
    std::optional<std::wstring> projectURL_;
    std::unique_ptr<GitRepositoryMonitor> gitRepositoryMonitor_;
    std::unique_ptr<WorkspaceFileMonitor> workspaceFileMonitor_;
    int gitRefreshGeneration_ = 0;
    bool gitSummaryRefreshInFlight_ = false;
    bool gitSummaryRefreshAgain_ = false;
    std::optional<std::wstring> gitSummaryDirectory_;
    int gitSummaryGeneration_ = 0;
    std::optional<std::string> currentBranchName_;
    std::optional<bool> isRepository_;
    std::map<std::wstring, ProjectSummary> projectSummaries_;

    bool diffRefreshInFlight_ = false;
    bool diffRefreshAgain_ = false;
    std::shared_ptr<CancelToken> openDiffReadToken_;
    std::set<std::string> lastChangedPaths_;

    std::map<std::wstring, int> syncing_;
    std::set<std::wstring> fetching_;
    std::set<std::wstring> pulling_;
    std::set<std::wstring> pullAfterFetch_;
    static constexpr double minimumSyncAnimation = 0.6;
    bool shown_ = false;
    Lifetime life_;
};

/// The key a project path is compared by.
std::wstring projectKey(const std::wstring& path);

// One editor window: its projects, sidebar, tabs and editor pane
// (WorkspaceWindowController and RootViewController). Several can exist at
// once (Ctrl+N).
#pragma once

#include "editor.h"
#include "palette.h"
#include "services.h"
#include "sidebar.h"

class Menu;

/// The invisible target over the panel/editor divider, painting the 1pt line.
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

/// Window content: sidebar | editor. There is no status bar — the panel
/// buttons live in the sidebar's bottom action bar (Zed layout).
class RootView : public View {
public:
    /// The floor is what the Git panel's rows need before names truncate.
    static constexpr float minimumSidebarWidth = 300;
    /// What a window opens at: half its own width.
    static constexpr float defaultSidebarFraction = 0.5f;
    RootView(SidebarView* sidebar, EditorArea* editor);
    CaptionButtonsView caption;
    void layout() override;
    /// On screen: the width it opened at is the width it keeps.
    void settleOpeningWidth();
    static float openingSidebarWidth(float windowWidth);
    void showSidebar();
    void preserveSidebarWidth() { setNeedsLayout(); }
private:
    void resizeSidebar(float proposed);
    SidebarView* sidebar_;
    EditorArea* editor_;
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
    /// The app routes both files and folders to an existing project first.
    std::function<void(const std::vector<std::wstring>&)> onOpenRequested;
    /// The app menu (File, Edit, View, Window, Help) for this window.
    std::function<std::shared_ptr<Menu>(WorkspaceWindow*)> makeAppMenu;

    SidebarView& sidebar() { return sidebar_; }
    EditorArea& editor() { return editor_; }

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
    /// Re-apply fonts/metrics after settings.json changes.
    void refreshDisplay();
    void releaseTransientMemory();

    void showDiff(const Git::StatusEntry& entry, const std::wstring& directory);
    void showCommitDiff(const Git::Commit& commit, const Git::CommitFile& file, const std::wstring& directory);
    void openSettings();

    /// Teach the store how to rebuild a diff buffer from its URL, so those
    /// buffers can be evicted like any other. Registered once, at launch.
    static void registerDiffContentProvider();
    static DocumentStore::VirtualContent commitDiffContent(const std::string& commit, const std::string& path,
                                                           const std::wstring& directory);

    // Menu actions.
    void openFolder();
    void quickOpen();
    void goToLine();
    void save() { editor_.save(); }
    void findInFile() { editor_.showFindBar(); }
    void findAndReplace() { editor_.showFindBar(std::nullopt, true); }
    void closeTab();
    void selectNextTab() { editor_.stepTab(1); }
    void selectPreviousTab() { editor_.stepTab(-1); }
    void reopenClosedTab();
    void showFiles();
    void findInFolder();
    void showGit();
    void showSidebar() { root_.showSidebar(); }
    void showAppMenu();
    /// The editor commands of the Edit menu, sent to whatever has the keyboard.
    void editCommand(const std::string& command);

protected:
    LRESULT handleMessage(UINT message, WPARAM wParam, LPARAM lParam) override;
    bool handleShortcut(const KeyEvent& e) override;
    void windowDidActivate(bool active) override;
    bool windowShouldClose() override;
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
    void refreshWindowTitle(const std::optional<std::wstring>& activeFile);
    void loadProject(const std::wstring& path);
    void clearProject();
    void refreshProjectTabs();
    void applySummaries(const std::vector<std::pair<std::wstring, ProjectSummary>>& found);
    void noteSummary(const ProjectSummary& summary, const std::wstring& path);
    int indexOfProject(const std::wstring& path) const;
    void showFileHistory(const std::wstring& file);
    std::wstring diffPreviewURL(const std::wstring& directory, const std::string& path,
                                const std::string& commit = "") const;
    void scheduleGitRefreshAfterSave();
    void gitChanged();
    void handleActivity(ActivityBarView::Action action);
    void openProjectInTerminal();

    // Syncing with the remote.
    void beginSync(const std::wstring& path);
    void endSync(const std::wstring& path, double startedAt);
    void publishSyncing();
    void pullProject(const std::wstring& path);
    void startPull(const std::wstring& path);
    void presentPullError(const std::string& message, const std::wstring& path);
    void remoteRefsMoved();

    // Quick open.
    PalettePanel& ensurePalette();
    std::vector<PalettePanel::Item> quickOpenItems(const std::wstring& query) const;
    void refreshQuickOpenIndex(const std::wstring& directory);

    // Branches.
    void showBranchMenu(const Rect& rect);
    void switchBranch(const Git::Branch& branch, const std::wstring& directory);
    void presentBranchAlert(const std::wstring& title, const std::string& message);

    SidebarView sidebar_;
    EditorArea editor_;
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
    /// Branch currently checked out, as last reported by the Git refresh.
    std::optional<std::string> currentBranchName_;
    std::map<std::wstring, ProjectSummary> projectSummaries_;
    std::shared_ptr<Dispatch::Pending> gitRefreshAfterSave_;

    std::unique_ptr<PalettePanel> palette_;
    std::vector<std::wstring> quickOpenIndex_;
    bool quickOpenIndexInFlight_ = false;
    /// One replaceable Git preview buffer per window.
    std::wstring diffPreviewID_;

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

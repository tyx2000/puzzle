// The Git panel: flat Changes / Branch / History tabs, an automatically staged
// change list, branch information, a commit message editor and commit controls
// (GitPanelViewController.swift).
#pragma once

#include "gitlist.h"

class GitPanel : public View {
public:
    GitPanel();
    ~GitPanel() override;

    std::function<void(const std::wstring&)> onOpenFile;
    /// Clicking a changed file asks the window to show its coloured diff.
    std::function<void(const Git::StatusEntry&, const std::wstring&)> onOpenDiff;
    /// Clicking a file inside an expanded commit shows that commit's diff for it.
    std::function<void(const Git::Commit&, const Git::CommitFile&, const std::wstring&)> onOpenCommitDiff;
    std::function<void()> onChanged;

    /// History is read in pages.
    static int historyPageSize;
    /// What Commit says about itself. The commit line over a project's
    /// changes asks here too, so the two never describe one state differently.
    static std::wstring commitHint(bool possible, bool hasChanges);
    /// What Push says about itself, with how many commits it would send.
    static std::wstring pushHint(int ahead);

    void setDirectory(const std::optional<std::wstring>& directory);
    void releaseTransientMemory();
    void refreshFonts();
    void refresh();
    /// External repository events and completed Git mutations must not be lost
    /// if they arrive while a snapshot is already being collected.
    void refreshExternal();
    void showBranchTab();
    void showHistory();
    void expandCommit(int index);
    void openCommitFile(int commitIndex, int fileIndex);

    void layout() override;

private:
    enum class Tab { Changes, Branches, History };
    struct HistoryRow {
        bool isFile = false;
        size_t commit = 0;  // index into history_
        Git::CommitFile file;
    };
    struct HistoryRead {
        std::vector<Git::Commit> log;
        std::set<std::string> unpushed;
        std::unordered_map<std::string, HistoryGraph::Row> graphRows;
        int laneCount = 0;
    };
    static HistoryRead readHistory(const std::wstring& directory, int depth);

    void requestRefresh(bool requireFollowUp);
    void applyStatus(const Git::Status& status, const std::wstring& directory);
    void applyHistory(const HistoryRead& read, int depth);
    void historyScrolled();
    void reloadRows(bool force = false);
    bool rowsNeedReload() const;
    void rebuildHistoryRows();
    void clearHistoryGraph();
    void tabChanged();
    void updateTabLayout();
    void updateHistoryColumnWidth();
    bool isUnpushed(const std::string& shortHash) const;
    bool pushIsPossible() const { return aheadCount_ > 0 || !hasUpstream_; }
    bool commitIsPossible() const;
    std::wstring trimmedCommitMessage() const;
    void refreshCommitButton();
    void refreshPushButton();
    void pushAction();
    void runRemote(const std::wstring& verb, std::function<Git::RemoteResult()> work);
    void performCommit(bool push);
    void continuePushAfterCommit(int operation, const std::wstring& directory);
    std::optional<int> beginOperation(const std::wstring& label, bool lockCommitMessage);
    void transitionOperation(int id, const std::wstring& label);
    void finishOperation(int id);
    void presentOperationError(const std::wstring& title, const std::string& message);
    void presentGitError(const std::wstring& title, const std::wstring& message);
    void activate(int row);
    void newBranchAction();
    void remoteAction();
    void contextMenu(int row, POINT screen);
    void switchBranch(const Git::Branch& branch, const std::wstring& directory);
    void deleteBranch(const Git::Branch& branch, const std::wstring& directory);
    void discardAllChanges(const std::wstring& directory);
    void discardChanges(const Git::StatusEntry& entry, const std::wstring& directory);
    void toggleCommit(const Git::Commit& commit, const std::wstring& directory);
    void drawRow(Graphics& g, int row, const Rect& rect);
    Color rowBackground(int row);
    std::vector<RowAction> actionsForRow(int row);
    void performRowAction(int row, RowAction action);
    HWND ownerWindow() const;

    FlatPanelTabBar segmented_{{L"Changes", L"Branch", L"History"}};
    FlatView branchToolbar_;
    PushButton newBranchButton_;
    PushButton remoteButton_;
    GitList table_;
    Label branchLabel_;
    FlatView commitBox_;
    TextField commitField_;
    ProgressShimmer progressShimmer_;
    PushButton commitButton_;
    PushButton discardAllButton_;
    BadgeButton pushControl_;

    std::optional<std::wstring> directory_;
    std::vector<Git::StatusEntry> entries_;
    std::vector<Git::Branch> branches_;
    std::vector<Git::Remote> remotes_;
    std::vector<Git::Commit> history_;
    std::vector<HistoryRow> historyRows_;
    std::set<std::string> expandedCommits_;
    std::map<std::string, std::vector<Git::CommitFile>> commitFiles_;
    std::optional<std::string> activeChangesPath_;
    std::optional<std::pair<std::string, std::string>> activeCommitFile_;
    std::unordered_map<std::string, HistoryGraph::Row> historyGraphRows_;
    float historyGraphWidth_ = 0;
    float historyMinimumWidth_ = 0;
    std::set<std::string> unpushed_;
    Tab tab_ = Tab::Changes;
    std::string currentBranch_;
    bool hasUpstream_ = true;
    bool hasChanges_ = false;
    int aheadCount_ = 0;
    std::vector<Git::StatusEntry> renderedEntries_;
    std::optional<std::string> renderedActiveChangesPath_;
    std::optional<std::string> renderedActiveCommitFile_;
    bool reloadDeferred_ = false;
    bool refreshInFlight_ = false;
    bool refreshAgain_ = false;
    std::optional<std::wstring> refreshDirectory_;
    std::optional<int> activeOperation_;
    int nextOperation_ = 1;
    bool operationLocksMessage_ = false;
    int historyLimit_ = 200;
    bool historyHasMore_ = true;
    bool historyPageLoading_ = false;
    Lifetime life_;
};

// The current branch's commits, under the changes of the same project
// (ProjectHistoryView.swift).
//
// One line per commit, its files underneath when it is opened — the rows the
// Git panel's History tab draws. That tab is the whole repository; this is
// only the branch checked out: HEAD and what is behind it. Where the branch it
// was started from can be told (Git::branchBase), a rule naming it sits above
// the first of its commits, and its commits are drawn a step back.
#pragma once

#include "gitlist.h"

class ProjectHistoryView : public View {
public:
    struct State {
        std::string head;
        int ahead = 0;
        bool hasUpstream = false;
        /// The branch checked out: a new branch at the same commit has a
        /// different base.
        std::string branch;
        bool operator==(const State& o) const {
            return head == o.head && ahead == o.ahead && hasUpstream == o.hasUpstream && branch == o.branch;
        }
        bool operator!=(const State& o) const { return !(*this == o); }
    };
    static int pageSize;

    ProjectHistoryView();
    /// A file inside a commit was clicked: show that commit's diff for it.
    std::function<void(const Git::Commit&, const Git::CommitFile&, const std::wstring&)> onOpenCommitDiff;
    /// Open the current working-tree file from the row's trailing button.
    std::function<void(const std::wstring&)> onOpenFile;

    /// Called with every Git refresh; the log is re-read only when what the
    /// rows show has moved.
    void setSource(const std::optional<std::wstring>& directory, const State& state);
    /// Empty the list for a project whose state is not known yet.
    void prepare(const std::optional<std::wstring>& directory);
    /// A fetch moved a remote-tracking branch.
    void remoteRefsMoved(const std::wstring& directory);
    void refreshFonts();
    void layout() override;

private:
    enum class Kind { Commit, File, Base };
    struct Row {
        Kind kind = Kind::Commit;
        size_t commit = 0;  // index into commits_
        Git::CommitFile file;
    };
    void load(const std::wstring& directory);
    void scrolled();
    void rebuildRows();
    bool isUnpushed(const std::string& shortHash) const;
    void act(int row);
    void toggle(const Git::Commit& commit, const std::wstring& directory);
    void toggleBaseFold();
    std::optional<std::string> foldKey() const;
    bool isBaseFolded() const;
    void drawRow(Graphics& g, int row, const Rect& rect);

    GitList list_;
    std::optional<std::wstring> directory_;
    std::optional<State> state_;
    std::vector<Git::Commit> commits_;
    std::set<std::string> unpushed_;
    std::set<std::string> expanded_;
    std::map<std::string, std::vector<Git::CommitFile>> files_;
    /// The branch this one was started from, when it can be told.
    std::optional<std::string> baseName_;
    /// Full IDs of the listed commits that came with that branch.
    std::set<std::string> inherited_;
    std::vector<Row> rows_;
    bool loading_ = false;
    bool loadAgain_ = false;
    int limit_ = 200;
    bool hasMore_ = true;
    Lifetime life_;
};

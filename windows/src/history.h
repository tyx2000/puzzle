// The commits behind a project, one line each — graph, refs, commit ID,
// message, author, time — with a commit's files under it once it is opened
// (ProjectHistoryViewController and its cells).
#pragma once

#include "historygraph.h"
#include "widgets.h"

class ProjectHistoryView : public View {
public:
    struct State {
        std::string head;
        int ahead = 0;
        bool hasUpstream = false;
        bool operator==(const State& o) const {
            return head == o.head && ahead == o.ahead && hasUpstream == o.hasUpstream;
        }
        bool operator!=(const State& o) const { return !(*this == o); }
    };

    /// Shared column widths, so each column starts at the same place.
    struct Columns {
        float commitID = 0;
        float author = 0;
        float date = 0;
    };
    static constexpr float columnGap = 10;
    static constexpr float minimumSubjectWidth = 60;
    static constexpr float minimumSqueezedWidth = 30;
    static int pageSize;

    ProjectHistoryView();
    /// A file inside a commit was clicked.
    std::function<void(const Git::Commit&, const Git::CommitFile&, const std::wstring&)>
        onOpenCommitDiff;

    /// Called with every Git refresh; the log is re-read only when what the
    /// rows show has moved.
    void setSource(const std::optional<std::wstring>& directory, const State& state);
    /// Empty the list for a project whose state is not known yet.
    void prepare(const std::optional<std::wstring>& directory);
    /// A fetch moved a remote-tracking branch.
    void remoteRefsMoved(const std::wstring& directory);
    void layout() override;

private:
    struct Row {
        bool isFile = false;
        size_t commit = 0;  // index into commits_
        Git::CommitFile file;
    };
    void load(const std::wstring& directory);
    void scrolled();
    void rebuildRows();
    bool isUnpushed(const std::string& shortHash) const;
    void act(int row);
    void toggle(const Git::Commit& commit, const std::wstring& directory);
    void showContextMenu(int row, POINT screen);
    void drawRow(Graphics& g, int row, const Rect& rect);
    void drawCommit(Graphics& g, const Git::Commit& commit, const Rect& rect);
    void drawFile(Graphics& g, const Row& row, const Rect& rect);
    static float metaWidth(const std::wstring& text);
    static std::wstring authorText(const Git::Commit& commit, bool pending);

    ListView list_;
    std::optional<std::wstring> directory_;
    std::optional<State> state_;
    std::vector<Git::Commit> commits_;
    std::vector<std::vector<Git::RefLabel>> refs_;
    std::set<std::string> unpushed_;
    Columns columns_;
    std::unordered_map<std::string, HistoryGraph::Row> graphRows_;
    float graphWidth_ = 0;
    std::set<std::string> expanded_;
    std::map<std::string, std::vector<Git::CommitFile>> files_;
    std::vector<Row> rows_;
    bool loading_ = false;
    bool loadAgain_ = false;
    int limit_ = 200;
    bool hasMore_ = true;
    Lifetime life_;
};

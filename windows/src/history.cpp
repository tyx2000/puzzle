#include "history.h"

#include "theme.h"

int ProjectHistoryView::pageSize = 200;

namespace {
/// Branches whose base's commits are folded away under the rule, by project
/// and branch: kept while Puzzle runs, in every window.
std::set<std::string>& foldedBranches() {
    static std::set<std::string> folded;
    return folded;
}

bool isSourceFile(const std::wstring& path) { return fileExists(path) && !directoryExists(path); }
}  // namespace

ProjectHistoryView::ProjectHistoryView() {
    backgroundColor = Theme::panelBackground;
    limit_ = pageSize;
    addSubview(&list_);
    list_.backgroundColor = Theme::panelBackground;
    list_.rowHeight = Theme::treeRowHeight();
    list_.numberOfRows = [this] { return (int)rows_.size(); };
    list_.rowBackground = [this](int row) {
        if (row == list_.hoveredRow()) return Theme::hover;
        // The rule is not read across as a row.
        if (row >= 0 && row < (int)rows_.size() && rows_[row].kind == Kind::Base) return Theme::panelBackground;
        return row % 2 == 1 ? Theme::stripedRow : Theme::panelBackground;
    };
    list_.drawRow = [this](Graphics& g, int row, const Rect& rect) { drawRow(g, row, rect); };
    list_.tooltipForRow = [this](int row, Point) -> std::wstring {
        if (row < 0 || row >= (int)rows_.size() || rows_[row].kind != Kind::File) return L"";
        return W(rows_[row].file.path);
    };
    list_.onClick = [this](int row) { act(row); };
    list_.actionsForRow = [this](int row) -> std::vector<RowAction> {
        if (!directory_ || row < 0 || row >= (int)rows_.size() || rows_[row].kind != Kind::File) return {};
        // History describes an old commit; opening the source means its
        // current working-tree file.
        if (isSourceFile(pathJoinGit(*directory_, rows_[row].file.path))) return {RowAction::Open};
        return {};
    };
    list_.onAction = [this](int row, RowAction) {
        if (!directory_ || row < 0 || row >= (int)rows_.size() || rows_[row].kind != Kind::File) return;
        std::wstring path = pathJoinGit(*directory_, rows_[row].file.path);
        if (isSourceFile(path) && onOpenFile) onOpenFile(path);
    };
    list_.onScroll = [this] { scrolled(); };
}

void ProjectHistoryView::layout() { list_.setFrame(bounds()); }

void ProjectHistoryView::refreshFonts() {
    list_.rowHeight = Theme::treeRowHeight();
    list_.reloadData();
}

std::optional<std::string> ProjectHistoryView::foldKey() const {
    if (!directory_ || !state_ || state_->branch.empty()) return std::nullopt;
    return U(lowercased(*directory_)) + "\n" + state_->branch;
}

bool ProjectHistoryView::isBaseFolded() const {
    auto key = foldKey();
    return key && foldedBranches().count(*key);
}

void ProjectHistoryView::setSource(const std::optional<std::wstring>& directory, const State& state) {
    if (directory == directory_ && state_ && *state_ == state) return;
    prepare(directory);
    state_ = state;
    // No commit to read from: not a repository.
    if (!directory || state.head.empty()) return;
    load(*directory);
}

void ProjectHistoryView::prepare(const std::optional<std::wstring>& directory) {
    if (directory == directory_) return;
    directory_ = directory;
    state_.reset();
    // Another project's commits must not sit here while its own load is still
    // running, and its depth is not this one's.
    limit_ = pageSize;
    hasMore_ = true;
    commits_.clear();
    unpushed_.clear();
    expanded_.clear();
    files_.clear();
    baseName_.reset();
    inherited_.clear();
    list_.setContentOffset(Point(0, 0));
    rebuildRows();
}

void ProjectHistoryView::remoteRefsMoved(const std::wstring& directory) {
    if (!directory_ || *directory_ != directory || !state_ || state_->head.empty()) return;
    load(directory);
}

void ProjectHistoryView::load(const std::wstring& directory) {
    if (loading_) {
        loadAgain_ = true;
        return;
    }
    loading_ = true;
    int wanted = limit_;
    auto alive = life_.weak();
    Git::workQueue().async([this, alive, directory, wanted] {
        auto log = Git::log(directory, wanted, false);
        auto pending = Git::unpushedHashes(directory);
        auto base = Git::branchBase(directory);
        // Only what is listed is kept, not every commit the branch has.
        std::set<std::string> inherited;
        if (base) {
            for (auto& commit : log) {
                if (!base->ownCommits.count(commit.graphID())) inherited.insert(commit.graphID());
            }
        }
        std::optional<std::string> baseName;
        if (base) baseName = base->name;
        Dispatch::main([this, alive, directory, wanted, log, pending, baseName, inherited] {
            if (alive.expired()) return;
            loading_ = false;
            if (directory_ && *directory_ == directory) {
                commits_ = log;
                hasMore_ = (int)log.size() >= wanted;
                unpushed_ = pending;
                baseName_ = baseName;
                inherited_ = inherited;
                // A commit that is no longer listed cannot stay open.
                std::set<std::string> listed;
                for (auto& commit : commits_) listed.insert(commit.shortHash);
                for (auto it = expanded_.begin(); it != expanded_.end();) {
                    it = listed.count(*it) ? std::next(it) : expanded_.erase(it);
                }
                for (auto it = files_.begin(); it != files_.end();) {
                    it = listed.count(it->first) ? std::next(it) : files_.erase(it);
                }
                rebuildRows();
            }
            if (loadAgain_ && directory_) {
                loadAgain_ = false;
                load(*directory_);
            }
        });
    });
}

/// Another page once the end of this one is in view, re-read from the top.
void ProjectHistoryView::scrolled() {
    // Folded, the list ends at the rule: a deeper page would only be folded
    // away too.
    if (!hasMore_ || loading_ || !directory_ || (isBaseFolded() && !inherited_.empty())) return;
    Rect visible = list_.visibleContentRect();
    float remaining = list_.contentSize().h - visible.maxY();
    if (remaining >= visible.h) return;
    limit_ += pageSize;
    load(*directory_);
}

void ProjectHistoryView::rebuildRows() {
    std::vector<Row> built;
    bool ruled = false;
    bool folded = isBaseFolded();
    for (size_t i = 0; i < commits_.size(); ++i) {
        const Git::Commit& commit = commits_[i];
        // Topological order puts the branch's own commits first, but a merge
        // from the base can bring its commits up among them: the rule goes
        // above the first, and each one is drawn back on its own.
        bool isInherited = baseName_ && inherited_.count(commit.graphID());
        if (isInherited && !ruled) {
            built.push_back({Kind::Base, i, {}});
            ruled = true;
        }
        if (isInherited && folded) continue;
        built.push_back({Kind::Commit, i, {}});
        if (!expanded_.count(commit.shortHash)) continue;
        auto files = files_.find(commit.shortHash);
        if (files == files_.end()) continue;
        for (auto& file : files->second) built.push_back({Kind::File, i, file});
    }
    rows_ = std::move(built);
    list_.reloadData();
}

bool ProjectHistoryView::isUnpushed(const std::string& shortHash) const {
    // `git log` and `rev-list` can abbreviate to different lengths.
    for (auto& hash : unpushed_) {
        if (startsWith(hash, shortHash) || startsWith(shortHash, hash)) return true;
    }
    return false;
}

void ProjectHistoryView::act(int index) {
    if (!directory_ || index < 0 || index >= (int)rows_.size()) return;
    Row row = rows_[index];
    switch (row.kind) {
    case Kind::Commit: toggle(commits_[row.commit], *directory_); break;
    case Kind::File:
        if (onOpenCommitDiff) onOpenCommitDiff(commits_[row.commit], row.file, *directory_);
        break;
    case Kind::Base: toggleBaseFold(); break;
    }
}

/// The rule folds the base's commits away, and brings them back.
void ProjectHistoryView::toggleBaseFold() {
    auto key = foldKey();
    if (!key) return;
    if (!foldedBranches().erase(*key)) foldedBranches().insert(*key);
    rebuildRows();
    // Unfolded at the end of what is read, the next page may be due.
    if (!isBaseFolded()) scrolled();
}

void ProjectHistoryView::toggle(const Git::Commit& commit, const std::wstring& directory) {
    std::string hash = commit.shortHash;
    if (expanded_.count(hash)) {
        expanded_.erase(hash);
        rebuildRows();
        return;
    }
    expanded_.insert(hash);
    if (files_.count(hash)) {
        rebuildRows();
        return;
    }
    // `git show` on a large commit is not instant.
    auto alive = life_.weak();
    Git::workQueue().async([this, alive, hash, directory] {
        auto found = Git::filesInCommit(hash, directory);
        Dispatch::main([this, alive, hash, directory, found] {
            if (alive.expired() || !directory_ || *directory_ != directory || !expanded_.count(hash)) return;
            files_[hash] = found;
            rebuildRows();
        });
    });
}

void ProjectHistoryView::drawRow(Graphics& g, int index, const Rect& rect) {
    const Row& row = rows_[index];
    switch (row.kind) {
    case Kind::Commit: {
        const Git::Commit& commit = commits_[row.commit];
        GitCells::CommitStyle style;
        // One line a row: message, name and time fit the column without the id.
        style.showsID = false;
        style.pending = isUnpushed(commit.shortHash);
        style.inherited = inherited_.count(commit.graphID()) > 0;
        if (state_) style.currentBranch = state_->branch;
        GitCells::drawCommit(g, commit, rect, style);
        break;
    }
    case Kind::Base:
        GitCells::drawBranchBase(g, baseName_.value_or(""), isBaseFolded(), rect);
        break;
    case Kind::File:
        GitCells::drawHistoryFile(g, row.file, rect, {}, 0, list_.actionsWidth(index));
        list_.drawActions(g, index, rect);
        break;
    }
}

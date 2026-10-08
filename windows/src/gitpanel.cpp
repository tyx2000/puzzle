#include "gitpanel.h"

#include "dialog.h"
#include "menu.h"
#include "services.h"
#include "theme.h"

int GitPanel::historyPageSize = 200;

namespace {
constexpr float kTabsHeight = 36;
constexpr float kBranchToolbarHeight = 52;
constexpr float kCommitBoxHeight = 200;
constexpr float kButtonHeight = 22;

bool isSourceFile(const std::wstring& path) { return fileExists(path) && !directoryExists(path); }
}  // namespace

GitPanel::GitPanel() {
    backgroundColor = Theme::panelBackground;
    historyLimit_ = historyPageSize;

    segmented_.onChange = [this] { tabChanged(); };

    branchToolbar_.fillColor = Theme::panelBackground;
    branchToolbar_.setHidden(true);
    newBranchButton_.title = L"New Branch";
    newBranchButton_.font = Theme::uiFont(10.5f);
    newBranchButton_.onClick = [this] { newBranchAction(); };
    remoteButton_.title = L"Remote";
    remoteButton_.font = Theme::uiFont(10.5f);
    remoteButton_.onClick = [this] { remoteAction(); };
    branchToolbar_.addSubview(&newBranchButton_);
    branchToolbar_.addSubview(&remoteButton_);

    table_.backgroundColor = Theme::panelBackground;
    table_.rowHeight = Theme::treeRowHeight();
    table_.numberOfRows = [this] {
        switch (tab_) {
        case Tab::Branches: return (int)branches_.size();
        case Tab::History: return (int)historyRows_.size();
        case Tab::Changes: return (int)entries_.size();
        }
        return 0;
    };
    table_.drawRow = [this](Graphics& g, int row, const Rect& rect) { drawRow(g, row, rect); };
    table_.rowBackground = [this](int row) { return rowBackground(row); };
    table_.onClick = [this](int row) { activate(row); };
    table_.onContextMenu = [this](int row, POINT screen) { contextMenu(row, screen); };
    table_.actionsForRow = [this](int row) { return actionsForRow(row); };
    table_.onAction = [this](int row, RowAction action) { performRowAction(row, action); };
    table_.tooltipForRow = [this](int row, Point) -> std::wstring {
        if (tab_ == Tab::Changes && row >= 0 && row < (int)entries_.size()) return W(entries_[row].path);
        if (tab_ == Tab::History && row >= 0 && row < (int)historyRows_.size() && historyRows_[row].isFile) {
            return W(historyRows_[row].file.path);
        }
        return L"";
    };
    // Reaching the end of History asks for the next page.
    table_.onScroll = [this] { historyScrolled(); };

    branchLabel_.font = Theme::uiFont(10.5f);
    branchLabel_.color = Theme::dimText;
    branchLabel_.ignoresMouse = false;

    commitBox_.fillColor = Theme::activeTab;
    commitBox_.topBorder = true;
    commitBox_.bottomBorder = true;
    commitField_.multiline = true;
    commitField_.font = Theme::uiFont(11);
    commitField_.textColor = Theme::foreground;
    commitField_.fillColor = Theme::activeTab;
    commitField_.placeholder = L"Commit message";
    commitField_.placeholderColor = Theme::dimText;
    commitField_.horizontalInset = 9;
    commitField_.verticalInset = 5;
    commitField_.onCommitShortcut = [this] {
        // Ctrl+Enter obeys the same rule the button does.
        if (!commitIsPossible() || activeOperation_) {
            MessageBeep(MB_OK);
            return;
        }
        performCommit(false);
    };
    commitField_.onPushShortcut = [this] {
        // One Git operation at a time, and something to push.
        if (!pushIsPossible() || activeOperation_) {
            MessageBeep(MB_OK);
            return;
        }
        pushAction();
    };
    commitField_.onChange = [this] { refreshCommitButton(); };
    commitBox_.addSubview(&commitField_);

    discardAllButton_.title = L"Discard";
    discardAllButton_.font = Theme::uiFont(10.5f);
    discardAllButton_.tooltip = L"Discard all changes";
    discardAllButton_.onClick = [this] {
        if (directory_) discardAllChanges(*directory_);
    };
    commitButton_.title = L"Commit";
    commitButton_.font = Theme::uiFont(10.5f);
    commitButton_.onClick = [this] { performCommit(false); };

    // Push is the common case, so it is one click on its own button.
    pushControl_.title = L"Push";
    pushControl_.onClick = [this] { pushAction(); };
    refreshPushButton();
    refreshCommitButton();

    for (View* v : std::initializer_list<View*>{&segmented_, &branchToolbar_, &table_, &branchLabel_, &commitBox_,
                                                &progressShimmer_, &commitButton_, &pushControl_,
                                                &discardAllButton_}) {
        addSubview(v);
    }
}

GitPanel::~GitPanel() = default;

HWND GitPanel::ownerWindow() const {
    WindowHost* host = window();
    return host ? host->hwnd() : nullptr;
}

void GitPanel::layout() {
    Rect b = bounds();
    segmented_.setFrame(Rect(0, 0, b.w, kTabsHeight));
    bool branchTab = tab_ == Tab::Branches;
    bool listOnly = tab_ != Tab::Changes;
    float top = kTabsHeight;
    if (branchTab) {
        branchToolbar_.setFrame(Rect(0, kTabsHeight, b.w, kBranchToolbarHeight));
        float buttonWidth = std::max(0.0f, (b.w - 16 - 20) / 2);
        newBranchButton_.setFrame(Rect(8, (kBranchToolbarHeight - 32) / 2, buttonWidth, 32));
        remoteButton_.setFrame(Rect(8 + buttonWidth + 20, (kBranchToolbarHeight - 32) / 2, buttonWidth, 32));
        top += kBranchToolbarHeight;
    }
    float buttonsY = b.h - 8 - kButtonHeight;
    float pushWidth = pushControl_.intrinsicWidth();
    pushControl_.setFrame(Rect(8, buttonsY, pushWidth, BadgeButton::height));
    float commitWidth = std::max(64.0f, std::ceil(Text::width(commitButton_.title, Theme::uiFont(10.5f))) + 24);
    commitButton_.setFrame(Rect(b.w - 8 - commitWidth, buttonsY, commitWidth, kButtonHeight));
    float discardWidth = std::max(64.0f, std::ceil(Text::width(discardAllButton_.title, Theme::uiFont(10.5f))) + 24);
    float discardX = std::max(8 + pushWidth + 6, commitButton_.frame().x - 6 - discardWidth);
    discardAllButton_.setFrame(Rect(discardX, buttonsY, std::max(0.0f, commitButton_.frame().x - 6 - discardX), kButtonHeight));
    float boxY = buttonsY - 6 - kCommitBoxHeight;
    commitBox_.setFrame(Rect(0, boxY, b.w, kCommitBoxHeight));
    commitField_.setFrame(Rect(0, 1, b.w, kCommitBoxHeight - 2));
    progressShimmer_.setFrame(Rect(0, boxY, b.w, 3));
    float labelHeight = std::ceil(branchLabel_.font.lineHeight());
    branchLabel_.setFrame(Rect(8, boxY - 6 - labelHeight, std::max(0.0f, b.w - 16), labelHeight));
    float bottom = listOnly ? b.h : branchLabel_.frame().y - 6;
    table_.setFrame(Rect(0, top, b.w, std::max(0.0f, bottom - top)));
    updateHistoryColumnWidth();
}

// ── Data ───────────────────────────────────────────────────────────────────

void GitPanel::setDirectory(const std::optional<std::wstring>& directory) {
    directory_ = directory;
    currentBranch_.clear();
    entries_.clear();
    // Another repository's depth is not this one's.
    historyLimit_ = historyPageSize;
    historyHasMore_ = true;
    history_.clear();
    historyRows_.clear();
    clearHistoryGraph();
    unpushed_.clear();
    branches_.clear();
    remotes_.clear();
    aheadCount_ = 0;
    hasChanges_ = false;
    branchLabel_.text = L"Loading Git status…";
    branchLabel_.setNeedsDisplay();
    segmented_.setLabel(L"Changes", L"", 0);
    refreshPushButton();
    refreshCommitButton();
    table_.reloadData();
    refresh();
}

void GitPanel::releaseTransientMemory() {
    historyRows_.clear();
    expandedCommits_.clear();
    commitFiles_.clear();
    entries_.clear();
    history_.clear();
    clearHistoryGraph();
    historyLimit_ = historyPageSize;
    historyHasMore_ = true;
    unpushed_.clear();
    branches_.clear();
    remotes_.clear();
    table_.reloadData();
}

void GitPanel::clearHistoryGraph() {
    historyGraphRows_.clear();
    historyGraphWidth_ = 0;
    historyMinimumWidth_ = 0;
    updateHistoryColumnWidth();
}

void GitPanel::refreshFonts() {
    backgroundColor = Theme::panelBackground;
    table_.rowHeight = Theme::treeRowHeight();
    branchLabel_.font = Theme::uiFont(10.5f);
    commitField_.font = Theme::uiFont(11);
    commitField_.dpiChanged();
    for (PushButton* b : {&commitButton_, &discardAllButton_, &newBranchButton_, &remoteButton_}) {
        b->font = Theme::uiFont(10.5f);
    }
    historyMinimumWidth_ = GitCells::minimumWidth(history_, historyGraphWidth_);
    updateHistoryColumnWidth();
    table_.reloadData();
    setNeedsLayout();
    setNeedsDisplay();
}

void GitPanel::refresh() { requestRefresh(false); }

void GitPanel::refreshExternal() { requestRefresh(true); }

void GitPanel::requestRefresh(bool requireFollowUp) {
    if (!directory_) return;
    if (refreshInFlight_) {
        if (refreshDirectory_ != directory_ || requireFollowUp) refreshAgain_ = true;
        return;
    }
    refreshInFlight_ = true;
    refreshDirectory_ = directory_;
    Tab priority = tab_;
    int historyDepth = historyLimit_;
    std::wstring directory = *directory_;
    auto weak = life_.weak();
    // Panel-owned Git commands run on the operation queue so refresh staging
    // cannot race a commit, checkout, pull or other mutation.
    Git::operationQueue().async([this, weak, directory, priority, historyDepth] {
        Git::Status status = Git::status(directory);
        bool needsStaging = false;
        if (status.isRepo) {
            for (auto& e : status.entries) {
                if (e.isUntracked() || e.worktreeStatus() != ' ' || e.indexStatus() == 'A') {
                    needsStaging = true;
                    break;
                }
            }
        }
        if (needsStaging) {
            Git::stageAll(directory);
            status = Git::status(directory);
        }
        Dispatch::main([this, weak, directory, status] {
            if (weak.expired() || directory_ != directory) return;
            applyStatus(status, directory);
            if (tab_ == Tab::Changes) reloadRows();
        });

        auto loadRemotes = [this, weak, directory] {
            auto remotes = Git::remotes(directory);
            Dispatch::main([this, weak, directory, remotes] {
                if (weak.expired() || directory_ != directory) return;
                remotes_ = remotes;
                refreshPushButton();
            });
        };
        auto loadBranches = [this, weak, directory] {
            auto branches = Git::branches(directory);
            Dispatch::main([this, weak, directory, branches] {
                if (weak.expired() || directory_ != directory) return;
                branches_ = branches;
                if (tab_ == Tab::Branches) table_.reloadData();
            });
        };
        auto loadHistory = [this, weak, directory, historyDepth] {
            auto read = std::make_shared<HistoryRead>(readHistory(directory, historyDepth));
            Dispatch::main([this, weak, directory, read, historyDepth] {
                if (weak.expired() || directory_ != directory) return;
                applyHistory(*read, historyDepth);
            });
        };
        switch (priority) {
        case Tab::Changes: loadRemotes(); loadBranches(); loadHistory(); break;
        case Tab::Branches: loadBranches(); loadRemotes(); loadHistory(); break;
        case Tab::History: loadHistory(); loadRemotes(); loadBranches(); break;
        }

        Dispatch::main([this, weak, directory] {
            if (weak.expired()) return;
            refreshInFlight_ = false;
            refreshDirectory_.reset();
            if (directory_ != directory) {
                refreshAgain_ = false;
                refresh();
                return;
            }
            if (refreshAgain_) {
                refreshAgain_ = false;
                requestRefresh(false);
            }
        });
    });
}

GitPanel::HistoryRead GitPanel::readHistory(const std::wstring& directory, int depth) {
    HistoryRead read;
    read.log = Git::log(directory, depth);
    read.unpushed = Git::unpushedHashes(directory);
    HistoryGraph graph(read.log, Git::historyGraphTrunk(directory));
    for (size_t i = 0; i < read.log.size() && i < graph.rows.size(); ++i) {
        read.graphRows[read.log[i].graphID()] = graph.rows[i];
    }
    read.laneCount = graph.laneCount;
    return read;
}

void GitPanel::applyHistory(const HistoryRead& read, int depth) {
    // Reads land in the order they were asked for — one serial queue — and
    // each takes the depth of the moment it was asked.
    history_ = read.log;
    historyHasMore_ = (int)read.log.size() >= depth;
    unpushed_ = read.unpushed;
    historyGraphRows_ = read.graphRows;
    historyGraphWidth_ = HistoryGraphDrawing::columnWidth(read.laneCount);
    historyMinimumWidth_ = GitCells::minimumWidth(history_, historyGraphWidth_);
    updateHistoryColumnWidth();
    rebuildHistoryRows();
    if (tab_ == Tab::History) table_.reloadData();
}

/// The end of History came into view: read one page deeper. Only the log is
/// read again.
void GitPanel::historyScrolled() {
    if (tab_ != Tab::History || !historyHasMore_ || historyPageLoading_ || !directory_) return;
    float visible = table_.bounds().h;
    float remaining = table_.contentSize().h - (table_.contentOffset().y + visible);
    if (remaining >= visible) return;
    historyLimit_ += historyPageSize;
    historyPageLoading_ = true;
    int depth = historyLimit_;
    std::wstring directory = *directory_;
    auto weak = life_.weak();
    Git::operationQueue().async([this, weak, directory, depth] {
        auto read = std::make_shared<HistoryRead>(readHistory(directory, depth));
        Dispatch::main([this, weak, directory, depth, read] {
            if (weak.expired()) return;
            historyPageLoading_ = false;
            if (directory_ != directory) return;
            applyHistory(*read, depth);
        });
    });
}

/// Rebuild the rows only when they would come out different, and never while
/// the mouse is down inside the panel.
void GitPanel::reloadRows(bool force) {
    if (!force && !rowsNeedReload()) return;
    if (GetAsyncKeyState(VK_LBUTTON) < 0 || GetAsyncKeyState(VK_RBUTTON) < 0) {
        if (reloadDeferred_) return;
        reloadDeferred_ = true;
        auto weak = life_.weak();
        Dispatch::after(0.15, [this, weak] {
            if (weak.expired()) return;
            reloadDeferred_ = false;
            reloadRows(true);
        });
        return;
    }
    renderedEntries_ = entries_;
    renderedActiveChangesPath_ = activeChangesPath_;
    renderedActiveCommitFile_.reset();
    if (activeCommitFile_) renderedActiveCommitFile_ = activeCommitFile_->first + ":" + activeCommitFile_->second;
    table_.reloadData();
}

bool GitPanel::rowsNeedReload() const {
    if (tab_ != Tab::Changes) return true;
    if (renderedEntries_ != entries_) return true;
    if (renderedActiveChangesPath_ != activeChangesPath_) return true;
    std::optional<std::string> key;
    if (activeCommitFile_) key = activeCommitFile_->first + ":" + activeCommitFile_->second;
    return renderedActiveCommitFile_ != key;
}

/// The cheap status snapshot, applied apart from the slower history and
/// remote refresh.
void GitPanel::applyStatus(const Git::Status& status, const std::wstring& directory) {
    entries_ = status.entries;
    currentBranch_ = status.isRepo ? status.branch : "";
    std::wstring label = lastPathComponent(directory) + L" / " + W(status.branch);
    // Who the next commit will be authored by, straight from git config.
    if (!status.userName.empty()) label += L" / " + W(status.userName);
    // What is waiting to be pushed belongs on the Push button, not here.
    if (status.isRepo && !status.hasUpstream) label += L"  (no upstream)";
    branchLabel_.text = status.isRepo ? label : L"not a git repository";
    branchLabel_.tooltip = status.ahead > 0 ? std::to_wstring(status.ahead)
                                                  + (status.ahead == 1 ? L" commit not pushed yet"
                                                                       : L" commits not pushed yet")
                                            : L"";
    branchLabel_.setNeedsDisplay();
    segmented_.setLabel(L"Changes", status.entries.empty() ? L"" : std::to_wstring(status.entries.size()), 0);
    discardAllButton_.setEnabled(!status.entries.empty());
    hasChanges_ = !status.entries.empty();
    aheadCount_ = status.ahead;
    hasUpstream_ = status.hasUpstream;
    refreshCommitButton();
    refreshPushButton();
}

bool GitPanel::isUnpushed(const std::string& shortHash) const {
    // `git log --abbrev` and `rev-list --abbrev-commit` can hand back different
    // lengths: match on prefix.
    for (auto& hash : unpushed_) {
        if (startsWith(hash, shortHash) || startsWith(shortHash, hash)) return true;
    }
    return false;
}

/// Flatten commits (and the files of expanded ones) into display rows.
void GitPanel::rebuildHistoryRows() {
    std::vector<HistoryRow> built;
    for (size_t i = 0; i < history_.size(); ++i) {
        const Git::Commit& commit = history_[i];
        built.push_back({false, i, {}});
        if (!expandedCommits_.count(commit.shortHash)) continue;
        auto files = commitFiles_.find(commit.shortHash);
        if (files == commitFiles_.end()) continue;
        for (auto& f : files->second) built.push_back({true, i, f});
    }
    historyRows_ = std::move(built);
}

void GitPanel::tabChanged() {
    switch (segmented_.selectedSegment()) {
    case 1: tab_ = Tab::Branches; break;
    case 2: tab_ = Tab::History; break;
    default: tab_ = Tab::Changes; break;
    }
    updateTabLayout();
    table_.setSelectedRow(-1, false);
    table_.reloadData();
}

void GitPanel::updateTabLayout() {
    // Committing belongs to Changes. Branch and History are lists to read, so
    // they give the whole panel to their list.
    bool listOnly = tab_ != Tab::Changes;
    branchToolbar_.setHidden(tab_ != Tab::Branches);
    branchLabel_.setHidden(listOnly);
    commitBox_.setHidden(listOnly);
    progressShimmer_.setHidden(listOnly || !activeOperation_);
    commitButton_.setHidden(listOnly);
    discardAllButton_.setHidden(listOnly);
    pushControl_.setHidden(listOnly);
    // Only History can scroll sideways for a wide graph.
    table_.hasHorizontalScroller = tab_ == Tab::History;
    updateHistoryColumnWidth();
    if (tab_ != Tab::History) table_.setContentOffset(Point(0, table_.contentOffset().y));
    setNeedsLayout();
    setNeedsDisplay();
}

void GitPanel::updateHistoryColumnWidth() {
    float minimum = tab_ == Tab::History ? historyMinimumWidth_ : 0;
    if (table_.minimumContentWidth != minimum) {
        table_.minimumContentWidth = minimum;
        table_.reloadData();
    }
}

// ── Commit and push ────────────────────────────────────────────────────────

std::wstring GitPanel::trimmedCommitMessage() const { return trim(commitField_.text()); }

bool GitPanel::commitIsPossible() const { return hasChanges_ && !trimmedCommitMessage().empty(); }

std::wstring GitPanel::commitHint(bool possible, bool hasChanges) {
    return possible ? L"Commit  (Ctrl+Enter)"
                    : (hasChanges ? L"Describe the change to commit it" : L"Nothing to commit");
}

std::wstring GitPanel::pushHint(int ahead) {
    return ahead > 0 ? L"Push " + std::to_wstring(ahead) + (ahead == 1 ? L" commit" : L" commits")
                           + L"  (Ctrl+Shift+Enter)"
                     : L"Push the current branch  (Ctrl+Shift+Enter)";
}

void GitPanel::refreshCommitButton() {
    // Never enable anything while an operation owns the panel.
    commitButton_.setEnabled(!activeOperation_ && commitIsPossible());
    commitButton_.tooltip = commitHint(commitIsPossible(), hasChanges_);
}

void GitPanel::refreshPushButton() {
    pushControl_.setBadge(aheadCount_ > 0 ? std::to_wstring(aheadCount_) : L"");
    // Nothing to push, nothing to do — except a branch with no upstream, where
    // pushing is what sets one up.
    pushControl_.setEnabled(pushIsPossible());
    pushControl_.tooltip = pushHint(aheadCount_);
    setNeedsLayout();
}

void GitPanel::pushAction() {
    if (!directory_) return;
    std::wstring directory = *directory_;
    runRemote(L"Push", [directory] { return Git::push(directory); });
}

/// Run a remote operation on the Git queue and report the outcome.
void GitPanel::runRemote(const std::wstring& verb, std::function<Git::RemoteResult()> work) {
    if (!directory_) return;
    std::wstring operationDirectory = *directory_;
    auto operation = beginOperation(verb, false);
    if (!operation) return;
    int id = *operation;
    auto weak = life_.weak();
    Git::operationQueue().async([this, weak, work, id, verb, operationDirectory] {
        Git::RemoteResult result = work();
        Dispatch::main([this, weak, result, id, verb, operationDirectory] {
            if (weak.expired() || activeOperation_ != id) return;
            finishOperation(id);
            if (directory_ != operationDirectory) return;
            refreshExternal();
            if (onChanged) onChanged();
            if (!result.ok) presentOperationError(verb + L" failed", result.message);
        });
    });
}

/// Commit, optionally pushing afterwards — both off the main thread.
void GitPanel::performCommit(bool push) {
    if (!directory_) return;
    std::wstring message = trimmedCommitMessage();
    if (message.empty()) {
        Alert::inform(ownerWindow(), L"Commit message required", L"");
        return;
    }
    auto operation = beginOperation(L"Committing", true);
    if (!operation) return;
    int id = *operation;
    std::wstring directory = *directory_;
    std::string text = U(message);
    auto weak = life_.weak();
    Git::operationQueue().async([this, weak, id, directory, text, push] {
        Git::RunResult commit = Git::commit(text, directory);
        std::optional<Git::Status> postCommitStatus;
        if (commit.code == 0) postCommitStatus = Git::status(directory);
        Dispatch::main([this, weak, id, directory, commit, postCommitStatus, push] {
            if (weak.expired() || activeOperation_ != id) return;
            if (directory_ != directory) {
                finishOperation(id);
                return;
            }
            if (commit.code != 0) {
                finishOperation(id);
                refreshExternal();
                if (onChanged) onChanged();
                presentOperationError(L"Commit failed", commit.err.empty() ? commit.out : commit.err);
                return;
            }
            // Reflect the local repository state before any network push, so
            // Changes clears immediately.
            commitField_.setText(L"");
            refreshCommitButton();
            if (postCommitStatus) {
                applyStatus(*postCommitStatus, directory);
                table_.reloadData();
            }
            if (onChanged) onChanged();
            if (push) {
                continuePushAfterCommit(id, directory);
            } else {
                finishOperation(id);
                refreshExternal();
            }
        });
    });
}

void GitPanel::continuePushAfterCommit(int id, const std::wstring& directory) {
    transitionOperation(id, L"Pushing");
    auto weak = life_.weak();
    Git::operationQueue().async([this, weak, id, directory] {
        Git::RemoteResult result = Git::push(directory);
        Dispatch::main([this, weak, id, directory, result] {
            if (weak.expired() || activeOperation_ != id) return;
            finishOperation(id);
            if (directory_ != directory) return;
            refreshExternal();
            if (onChanged) onChanged();
            if (!result.ok) presentOperationError(L"Committed, but push failed", result.message);
        });
    });
}

std::optional<int> GitPanel::beginOperation(const std::wstring&, bool lockCommitMessage) {
    if (activeOperation_) {
        MessageBeep(MB_OK);
        return std::nullopt;
    }
    int id = nextOperation_++;
    activeOperation_ = id;
    operationLocksMessage_ = lockCommitMessage;
    commitButton_.setEnabled(false);
    pushControl_.setEnabled(false);
    newBranchButton_.setEnabled(false);
    remoteButton_.setEnabled(false);
    if (lockCommitMessage) commitField_.setEditable(false);
    progressShimmer_.start();
    progressShimmer_.setHidden(tab_ != Tab::Changes);
    return id;
}

void GitPanel::transitionOperation(int id, const std::wstring&) {
    if (activeOperation_ != id) return;
    progressShimmer_.start();
    progressShimmer_.setHidden(tab_ != Tab::Changes);
}

void GitPanel::finishOperation(int id) {
    if (activeOperation_ != id) return;
    activeOperation_.reset();
    refreshCommitButton();
    pushControl_.setEnabled(pushIsPossible());
    newBranchButton_.setEnabled(true);
    remoteButton_.setEnabled(true);
    if (operationLocksMessage_) commitField_.setEditable(true);
    operationLocksMessage_ = false;
    progressShimmer_.stop();
}

void GitPanel::presentOperationError(const std::wstring& title, const std::string& message) {
    Alert::inform(ownerWindow(), title, trim(W(message)));
}

void GitPanel::presentGitError(const std::wstring& title, const std::wstring& message) {
    Alert::inform(ownerWindow(), title, trim(message));
}

// ── Rows ───────────────────────────────────────────────────────────────────

/// A click on a row, or Return on the row the keys lit.
void GitPanel::activate(int row) {
    if (row < 0 || !directory_ || activeOperation_) return;
    std::wstring directory = *directory_;
    // The branch rows are informational: switching lives in their menu.
    if (tab_ == Tab::Branches) return;
    if (tab_ == Tab::History) {
        if (row >= (int)historyRows_.size()) return;
        HistoryRow r = historyRows_[row];
        const Git::Commit commit = history_[r.commit];
        if (!r.isFile) {
            toggleCommit(commit, directory);
        } else {
            activeCommitFile_ = std::make_pair(commit.shortHash, r.file.path);
            activeChangesPath_.reset();
            table_.reloadData();
            if (onOpenCommitDiff) onOpenCommitDiff(commit, r.file, directory);
        }
        return;
    }
    if (row >= (int)entries_.size()) return;
    Git::StatusEntry entry = entries_[row];
    activeChangesPath_ = entry.path;
    activeCommitFile_.reset();
    table_.reloadData();
    // Clicking a changed file shows its diff, not the plain file.
    if (onOpenDiff) onOpenDiff(entry, directory);
}

void GitPanel::showBranchTab() {
    segmented_.setSelectedSegment(1);
    tabChanged();
}

void GitPanel::showHistory() {
    segmented_.setSelectedSegment(2);
    tabChanged();
}

void GitPanel::expandCommit(int index) {
    if (!directory_ || index < 0 || index >= (int)history_.size()) return;
    toggleCommit(history_[index], *directory_);
}

void GitPanel::openCommitFile(int commitIndex, int fileIndex) {
    if (!directory_ || commitIndex < 0 || commitIndex >= (int)history_.size()) return;
    const Git::Commit& commit = history_[commitIndex];
    auto files = commitFiles_.find(commit.shortHash);
    if (files == commitFiles_.end() || fileIndex < 0 || fileIndex >= (int)files->second.size()) return;
    if (onOpenCommitDiff) onOpenCommitDiff(commit, files->second[fileIndex], *directory_);
}

/// Expand or collapse a commit, loading its file list on first expand.
void GitPanel::toggleCommit(const Git::Commit& commit, const std::wstring& directory) {
    std::string hash = commit.shortHash;
    if (expandedCommits_.count(hash)) {
        expandedCommits_.erase(hash);
        rebuildHistoryRows();
        table_.reloadData();
        return;
    }
    expandedCommits_.insert(hash);
    if (commitFiles_.count(hash)) {
        rebuildHistoryRows();
        table_.reloadData();
        return;
    }
    // Off the main thread; `git show` on a big commit isn't instant.
    auto weak = life_.weak();
    Dispatch::background([this, weak, hash, directory] {
        auto files = Git::filesInCommit(hash, directory);
        Dispatch::main([this, weak, hash, directory, files] {
            if (weak.expired() || directory_ != directory || !expandedCommits_.count(hash)) return;
            commitFiles_[hash] = files;
            rebuildHistoryRows();
            table_.reloadData();
        });
    });
}

Color GitPanel::rowBackground(int row) {
    bool active = false;
    if (tab_ == Tab::History && row >= 0 && row < (int)historyRows_.size()) {
        const HistoryRow& r = historyRows_[row];
        active = r.isFile && activeCommitFile_ && activeCommitFile_->first == history_[r.commit].shortHash
            && activeCommitFile_->second == r.file.path;
    } else if (tab_ == Tab::Changes && row >= 0 && row < (int)entries_.size()) {
        active = activeChangesPath_ && *activeChangesPath_ == entries_[row].path;
    }
    if (active) return Theme::activeRow;
    if (row == table_.hoveredRow() || row == table_.selectedRow()) return Theme::hover;
    // Branches and commits are read across a wide row; alternate rows keep
    // the line. Changes is a short list of names and stays plain.
    if (tab_ != Tab::Changes && row % 2 == 1) return Theme::stripedRow;
    return Theme::panelBackground;
}

std::vector<RowAction> GitPanel::actionsForRow(int row) {
    if (!directory_) return {};
    if (tab_ == Tab::Changes && row >= 0 && row < (int)entries_.size()) {
        return {RowAction::Discard, RowAction::Open};
    }
    if (tab_ == Tab::History && row >= 0 && row < (int)historyRows_.size() && historyRows_[row].isFile) {
        // History describes an old commit; opening the source means its
        // current working-tree file, when there is one.
        if (isSourceFile(pathJoinGit(*directory_, historyRows_[row].file.path))) return {RowAction::Open};
    }
    return {};
}

void GitPanel::performRowAction(int row, RowAction action) {
    if (!directory_ || activeOperation_) return;
    std::wstring directory = *directory_;
    if (tab_ == Tab::Changes && row >= 0 && row < (int)entries_.size()) {
        Git::StatusEntry entry = entries_[row];
        if (action == RowAction::Discard) discardChanges(entry, directory);
        else if (onOpenFile) onOpenFile(pathJoinGit(directory, entry.path));
        return;
    }
    if (tab_ == Tab::History && row >= 0 && row < (int)historyRows_.size() && historyRows_[row].isFile) {
        std::wstring path = pathJoinGit(directory, historyRows_[row].file.path);
        // The file may have disappeared since the row was drawn.
        if (isSourceFile(path) && onOpenFile) onOpenFile(path);
    }
}

void GitPanel::drawRow(Graphics& g, int row, const Rect& rect) {
    switch (tab_) {
    case Tab::Branches:
        if (row < (int)branches_.size()) GitCells::drawBranch(g, branches_[row], rect);
        return;
    case Tab::History: {
        if (row >= (int)historyRows_.size()) return;
        const HistoryRow& r = historyRows_[row];
        const Git::Commit& commit = history_[r.commit];
        auto graph = historyGraphRows_.find(commit.graphID());
        if (!r.isFile) {
            GitCells::CommitStyle style;
            style.pending = isUnpushed(commit.shortHash);
            style.graphRow = graph == historyGraphRows_.end() ? nullptr : &graph->second;
            style.graphWidth = historyGraphWidth_;
            style.currentBranch = currentBranch_;
            GitCells::drawCommit(g, commit, rect, style);
        } else {
            static const std::vector<HistoryGraph::Lane> none;
            GitCells::drawHistoryFile(g, r.file, rect, graph == historyGraphRows_.end() ? none : graph->second.bottomLanes,
                                      historyGraphWidth_, table_.actionsWidth(row));
            table_.drawActions(g, row, rect);
        }
        return;
    }
    case Tab::Changes:
        if (row >= (int)entries_.size()) return;
        GitCells::drawChange(g, entries_[row], rect, table_.actionsWidth(row));
        table_.drawActions(g, row, rect);
        return;
    }
}

// ── Menus and dialogs ──────────────────────────────────────────────────────

/// Right-click menu for a row — branches and history only. A changed file
/// carries its own two actions at the end of its row.
void GitPanel::contextMenu(int row, POINT screen) {
    if (!directory_) return;
    std::wstring directory = *directory_;
    HWND owner = ownerWindow();
    Menu menu;
    if (tab_ == Tab::Branches) {
        if (row < 0 || row >= (int)branches_.size()) return;
        Git::Branch branch = branches_[row];
        menu.add(L"Switch to “" + W(branch.name) + L"”",
                 [this, branch, directory] { switchBranch(branch, directory); }, !branch.isCurrent);
        menu.addSeparator();
        menu.add(branch.isRemote ? L"Delete Remote Branch…" : L"Delete Branch…",
                 [this, branch, directory] { deleteBranch(branch, directory); }, !branch.isCurrent);
    } else if (tab_ == Tab::History) {
        if (row < 0 || row >= (int)historyRows_.size()) return;
        HistoryRow r = historyRows_[row];
        Git::Commit commit = history_[r.commit];
        if (!r.isFile) {
            menu.add(L"Copy Commit Hash", [owner, commit] { copyToClipboard(owner, W(commit.shortHash)); });
            menu.add(L"Copy Commit Message", [owner, commit] { copyToClipboard(owner, W(commit.subject)); });
        } else {
            Git::CommitFile file = r.file;
            menu.add(L"Show Changes in This Commit", [this, commit, file, directory] {
                if (onOpenCommitDiff) onOpenCommitDiff(commit, file, directory);
            });
            menu.add(L"Copy Path", [owner, file] { copyToClipboard(owner, W(file.path)); });
        }
    } else {
        return;
    }
    menu.popup(owner, screen);
}

void GitPanel::switchBranch(const Git::Branch& branch, const std::wstring& directory) {
    if (branch.isCurrent) return;
    Alert alert;
    alert.style = Alert::Style::Warning;
    alert.messageText = L"Switch to “" + W(branch.name) + L"”?";
    std::wstring effect = branch.isRemote
        ? L"A local tracking branch will be created, checked out, and the files in this working tree will be "
          L"replaced with that branch's versions."
        : L"The files in this working tree will be replaced with the versions from this branch. Git will refuse "
          L"the switch if local changes cannot be preserved.";
    alert.informativeText = L"Project:\n" + directory + L"\n\n" + effect;
    alert.buttons = {L"Switch", L"Cancel"};
    if (alert.runModal(ownerWindow()) != 0) return;
    runRemote(L"Switch branch", [branch, directory] { return Git::switchBranch(branch, directory); });
}

void GitPanel::deleteBranch(const Git::Branch& branch, const std::wstring& directory) {
    if (branch.isCurrent) {
        presentGitError(L"Cannot delete branch", L"The current branch cannot be deleted.");
        return;
    }
    Alert alert;
    alert.style = Alert::Style::Warning;
    alert.messageText = L"Delete branch “" + W(branch.name) + L"”?";
    alert.informativeText = branch.isRemote
        ? L"Remote: " + W(branch.upstreamRemote.value_or("unknown")) + L"\nProject: " + directory
              + L"\n\nThis deletes the branch from the remote repository for everyone. Commits reachable only "
                L"from this branch may become difficult to recover."
        : L"Project:\n" + directory
              + L"\n\nThis removes the local branch reference. Git permits this action only when the branch is "
                L"fully merged; unmerged commits will not be deleted.";
    alert.buttons = {L"Delete", L"Cancel"};
    if (alert.runModal(ownerWindow()) != 0) return;
    runRemote(L"Delete branch", [branch, directory] { return Git::deleteBranch(branch, directory); });
}

namespace {
void styleDialogLabel(Label& label, const std::wstring& text) {
    label.text = text;
    label.font = Theme::uiFont(10.5f);
    label.color = Theme::dimText;
}
void styleDialogField(TextField& field, const std::wstring& value, const std::wstring& placeholder) {
    field.setText(value);
    field.placeholder = placeholder;
    field.font = Theme::uiFont(10.5f);
    field.fillColor = Theme::panelBackground;
    field.borderColor = Theme::border.blended(0.5f, Theme::dimText);
    field.horizontalInset = 8;
}
}  // namespace

void GitPanel::newBranchAction() {
    if (!directory_) return;
    std::wstring directory = *directory_;
    std::vector<std::wstring> names;
    int selected = 0;
    for (size_t i = 0; i < branches_.size(); ++i) {
        if (branches_[i].isCurrent) selected = (int)i;
        names.push_back(W(branches_[i].name));
    }
    if (names.empty()) {
        presentGitError(L"Cannot create branch", L"No base branches are available.");
        return;
    }
    constexpr float width = 340;
    View grid;
    Label nameLabel, baseLabel;
    TextField nameField;
    PopupButton base;
    styleDialogLabel(nameLabel, L"Name");
    styleDialogLabel(baseLabel, L"Base");
    styleDialogField(nameField, L"", L"Branch name");
    base.items = names;
    base.selected = selected;
    nameLabel.setFrame(Rect(0, 0, 48, 26));
    nameField.setFrame(Rect(56, 0, width - 56, 26));
    baseLabel.setFrame(Rect(0, 36, 48, 26));
    base.setFrame(Rect(56, 36, width - 56, 26));
    for (View* v : std::initializer_list<View*>{&nameLabel, &nameField, &baseLabel, &base}) grid.addSubview(v);

    Alert alert;
    alert.messageText = L"Create branch";
    alert.informativeText = L"The new branch will be created and checked out immediately.";
    alert.accessory = &grid;
    alert.accessorySize = Size(width, 62);
    alert.initialFocus = &nameField;
    alert.buttons = {L"Create", L"Cancel"};
    nameField.onSubmit = [] { PostMessageW(GetActiveWindow(), WM_KEYDOWN, VK_RETURN, 0); };
    int answer = alert.runModal(ownerWindow());
    std::wstring name = trim(nameField.text());
    std::wstring from = base.selectedTitle();
    grid.removeFromSuperview();
    if (answer != 0) return;
    if (name.empty()) {
        presentGitError(L"Invalid branch name", L"Enter a branch name.");
        return;
    }
    if (from.empty()) from = names[0];
    std::string branchName = U(name), baseName = U(from);
    runRemote(L"Create branch",
              [branchName, baseName, directory] { return Git::createBranch(branchName, baseName, directory); });
}

void GitPanel::remoteAction() {
    if (!directory_) return;
    std::wstring directory = *directory_;
    auto current = Git::remotes(directory);
    constexpr float width = 420;
    View grid;
    Label nameLabel, fetchLabel, pushLabel;
    TextField nameField, fetchField, pushField;
    styleDialogLabel(nameLabel, L"Name");
    styleDialogLabel(fetchLabel, L"Fetch");
    styleDialogLabel(pushLabel, L"Push");
    styleDialogField(nameField, current.empty() ? L"origin" : W(current[0].name), L"Remote name");
    styleDialogField(fetchField, current.empty() ? L"" : W(current[0].fetchURL), L"https://… or git@…");
    styleDialogField(pushField, current.empty() ? L"" : W(current[0].pushURL), L"Optional push URL");
    float y = 0;
    const std::pair<Label*, TextField*> rows[] = {{&nameLabel, &nameField}, {&fetchLabel, &fetchField},
                                                  {&pushLabel, &pushField}};
    for (auto [label, field] : rows) {
        label->setFrame(Rect(0, y, 48, 26));
        field->setFrame(Rect(56, y, width - 56, 26));
        grid.addSubview(label);
        grid.addSubview(field);
        y += 36;
    }
    Alert alert;
    alert.messageText = L"Remote repositories";
    alert.accessory = &grid;
    alert.accessorySize = Size(width, y - 10);
    alert.initialFocus = &fetchField;
    alert.buttons = {L"Save Remote", L"Close"};
    int answer = alert.runModal(ownerWindow());
    std::wstring name = trim(nameField.text());
    std::wstring fetchURL = trim(fetchField.text());
    std::wstring pushURL = trim(pushField.text());
    grid.removeFromSuperview();
    if (answer != 0) return;
    if (name.empty() || fetchURL.empty()) {
        presentGitError(L"Invalid remote", L"Remote name and Fetch URL are required.");
        return;
    }
    std::string n = U(name), f = U(fetchURL), p = U(pushURL);
    runRemote(L"Save remote", [n, f, p, directory] { return Git::saveRemote(n, f, p, directory); });
}

/// Throw away every change in the project. Confirmed first, and the alert
/// spells out what cannot be recovered.
void GitPanel::discardAllChanges(const std::wstring& directory) {
    auto entries = entries_;
    if (entries.empty()) return;
    std::vector<Git::StatusEntry> newFiles;
    for (auto& e : entries) {
        if (Git::discardRemovesFile(e, directory)) newFiles.push_back(e);
    }
    Alert alert;
    alert.style = Alert::Style::Warning;
    alert.messageText = entries.size() == 1
        ? std::wstring(L"Discard the 1 change in this project?")
        : L"Discard all " + std::to_wstring(entries.size()) + L" changes in this project?";
    std::wstring detail = L"Project:\n" + directory + L"\n\n";
    detail += L"Every uncommitted change, staged included, will be replaced with the version in HEAD. Git cannot "
              L"restore the discarded edits.";
    if (!newFiles.empty()) {
        detail += L"\n\n" + std::to_wstring(newFiles.size()) + (newFiles.size() == 1 ? L" file" : L" files")
            + L" never committed will be removed from Git and moved to the Recycle Bin; recovery is possible only "
              L"while the item remains in the Recycle Bin:\n";
        std::vector<std::wstring> lines;
        for (size_t i = 0; i < newFiles.size() && i < 10; ++i) lines.push_back(L"• " + W(newFiles[i].path));
        detail += join(lines, L"\n");
        if (newFiles.size() > 10) detail += L"\n• …and " + std::to_wstring(newFiles.size() - 10) + L" more";
    }
    alert.informativeText = detail;
    alert.buttons = {L"Discard All Changes", L"Cancel"};
    if (alert.runModal(ownerWindow()) != 0) return;
    auto operation = beginOperation(L"Discarding all changes", false);
    if (!operation) return;
    int id = *operation;
    auto weak = life_.weak();
    Git::operationQueue().async([this, weak, id, entries, directory] {
        auto result = Git::discardAll(entries, directory);
        Git::Status status = Git::status(directory);
        Dispatch::main([this, weak, id, entries, directory, result, status] {
            if (weak.expired() || activeOperation_ != id) return;
            finishOperation(id);
            if (directory_ != directory) return;
            applyStatus(status, directory);
            activeChangesPath_.reset();
            table_.reloadData();
            if (onChanged) onChanged();
            refreshExternal();
            if (result.second) {
                presentOperationError(L"Discard all changes failed",
                                      std::to_string(result.first) + " of " + std::to_string(entries.size())
                                          + " discarded.\n" + *result.second);
            }
        });
    });
}

void GitPanel::discardChanges(const Git::StatusEntry& entry, const std::wstring& directory) {
    bool removesFile = Git::discardRemovesFile(entry, directory);
    Alert alert;
    alert.style = Alert::Style::Warning;
    alert.messageText = L"Discard changes to “" + W(entry.path) + L"”?";
    std::wstring affected = L"File:\n" + pathJoinGit(directory, entry.path);
    if (entry.code.find('R') != std::string::npos && entry.originalPath) {
        affected += L"\nOriginal path:\n" + pathJoinGit(directory, *entry.originalPath);
    }
    alert.informativeText = affected + L"\n\n" + W(Git::discardConsequence(removesFile));
    alert.buttons = {L"Discard Changes", L"Cancel"};
    if (alert.runModal(ownerWindow()) != 0) return;
    auto operation = beginOperation(L"Discarding changes", false);
    if (!operation) return;
    int id = *operation;
    auto weak = life_.weak();
    Git::operationQueue().async([this, weak, id, entry, directory] {
        Git::RemoteResult result = Git::discard(entry, directory);
        std::optional<Git::Status> status;
        if (result.ok) status = Git::status(directory);
        Dispatch::main([this, weak, id, entry, directory, result, status] {
            if (weak.expired() || activeOperation_ != id) return;
            finishOperation(id);
            if (directory_ != directory) return;
            if (status) {
                applyStatus(*status, directory);
                bool stillThere = std::any_of(status->entries.begin(), status->entries.end(),
                                              [&](const Git::StatusEntry& e) { return e.path == entry.path; });
                if (!stillThere) activeChangesPath_.reset();
                table_.reloadData();
                if (onChanged) onChanged();
                refreshExternal();
            } else {
                presentOperationError(L"Discard changes failed", result.message);
            }
        });
    });
}

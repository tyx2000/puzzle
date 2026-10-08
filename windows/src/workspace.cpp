#include "workspace.h"

#include "app.h"
#include "dialog.h"
#include "menu.h"
#include "theme.h"

#include <shobjidl.h>

std::wstring projectKey(const std::wstring& path) { return lowercased(path); }

// ── DividerHandle ──────────────────────────────────────────────────────────

void DividerHandle::draw(Graphics& g) {
    // Straddles the divider and paints its middle column: the same 1pt
    // border line the title band draws.
    g.fillRect(Rect(std::floor(bounds().midX()), 0, 1, bounds().h), Theme::border);
}

bool DividerHandle::mouseDown(const MouseEvent& e) {
    startX_ = e.windowLocation.x;
    if (onDragBegan) onDragBegan();
    return true;
}

void DividerHandle::mouseDragged(const MouseEvent& e) {
    if (onDrag) onDrag(e.windowLocation.x - startX_);
}

// ── RootView ───────────────────────────────────────────────────────────────

RootView::RootView(SidebarView* sidebar, DiffPane* diffs) : sidebar_(sidebar), diffs_(diffs) {
    backgroundColor = Theme::diffBackground;
    addSubview(sidebar_);
    addSubview(diffs_);
    addSubview(&divider_);
    addSubview(&caption);
    divider_.onDragBegan = [this] { dragStartWidth_ = sidebarWidth_; };
    divider_.onDrag = [this](float dx) { resizeSidebar(dragStartWidth_ + dx); };
}

float RootView::openingSidebarWidth(float width) {
    float share = std::round(width * defaultSidebarFraction);
    float limit = std::max(minimumSidebarWidth, std::round(width * 0.8f));
    return std::min(std::max(share, minimumSidebarWidth), limit);
}

void RootView::settleOpeningWidth() {
    if (!settled_ && bounds().w > 0) sidebarWidth_ = openingSidebarWidth(bounds().w);
    settled_ = true;
    setNeedsLayout();
}

void RootView::resizeSidebar(float proposed) {
    // A width chosen by hand is not replaced by the opening default.
    settled_ = true;
    float limit = std::max(minimumSidebarWidth, std::round(bounds().w * 0.8f));
    sidebarWidth_ = std::min(std::max(proposed, minimumSidebarWidth), limit);
    setNeedsLayout();
    if (WindowHost* host = window()) host->displayIfNeeded();
}

void RootView::layout() {
    Rect b = bounds();
    if (!settled_ && b.w > 0) sidebarWidth_ = openingSidebarWidth(b.w);
    float width = std::min(sidebarWidth_, std::max(0.0f, b.w - 1));
    sidebar_->setFrame(Rect(0, 0, width, b.h));
    diffs_->setFrame(Rect(width + 1, 0, std::max(0.0f, b.w - width - 1), b.h));
    divider_.setFrame(Rect(width + 0.5f - DividerHandle::hitWidth / 2, 0, DividerHandle::hitWidth, b.h));
    float captionWidth = caption.preferredWidth();
    caption.setFrame(Rect(b.w - captionWidth, 0, captionWidth, CaptionButtonsView::buttonHeight));
}

// ── WorkspaceWindow ────────────────────────────────────────────────────────

namespace {

Dispatch::Queue& summaryQueue() {
    static Dispatch::Queue* queue = new Dispatch::Queue("app.gift.git-summaries");
    return *queue;
}

/// One status read at a time per window; the windows share the thread.
Dispatch::Queue& windowStatusQueue() {
    static Dispatch::Queue* queue = new Dispatch::Queue("app.gift.workspace-git-summary");
    return *queue;
}

RECT defaultWindowFrame() {
    POINT cursor{};
    GetCursorPos(&cursor);
    HMONITOR monitor = MonitorFromPoint(cursor, MONITOR_DEFAULTTOPRIMARY);
    MONITORINFO info{sizeof info};
    GetMonitorInfoW(monitor, &info);
    RECT work = info.rcWork;
    // The full usable height, two thirds of the usable width, centred.
    LONG width = (work.right - work.left) * 2 / 3;
    LONG x = work.left + ((work.right - work.left) - width) / 2;
    return RECT{x, work.top, x + width, work.bottom};
}

}  // namespace

WorkspaceWindow::WorkspaceWindow() : root_(&sidebar_, &diffs_) {
    RECT frame = defaultWindowFrame();
    createWindow(APP_NAME, WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN, 0, nullptr, frame);
    captionButtons = &root_.caption;
    minimumSize = Size(640, 400);
    setRootView(&root_);
    sidebar_.setTabRowHeight(DiffTabBar::defaultRowHeight);
    sidebar_.setTitlebarLeadingInset(44);
    diffs_.setTabRowHeight(DiffTabBar::defaultRowHeight);
    diffs_.setCaptionReserve(root_.caption.preferredWidth());
    wire();
}

WorkspaceWindow::~WorkspaceWindow() {
    if (gitRepositoryMonitor_) gitRepositoryMonitor_->stop();
    if (workspaceFileMonitor_) workspaceFileMonitor_->stop();
    setRootView(nullptr);
}

void WorkspaceWindow::showWindow() {
    show(SW_SHOWNORMAL);
    bringToFront();
    if (!shown_) {
        shown_ = true;
        Dispatch::main([this, alive = life_.weak()] {
            if (!alive.expired()) root_.settleOpeningWidth();
        });
    }
}

void WorkspaceWindow::wire() {
    sidebar_.onAddProject = [this] { openFolder(); };
    sidebar_.onOpenTerminal = [this] {
        if (projectURL_) TerminalLauncher::open(*projectURL_);
    };
    sidebar_.onShowMenu = [this] { showAppMenu(); };
    sidebar_.onSelectProjectRow = [this](int index) {
        if (index < 0 || index >= (int)projects_.size()) return;
        std::wstring wanted = projects_[index];
        // Clicking the project already showing collapses it, and the start
        // page comes back.
        if (projectURL_ && *projectURL_ == wanted) deactivateProject();
        else activateProject(wanted);
    };
    sidebar_.onPullProjectRow = [this](int index) {
        if (index >= 0 && index < (int)projects_.size()) pullProject(projects_[index]);
    };
    sidebar_.onReorderProjectRows = [this](int from, int to) { moveProject(from, to); };
    sidebar_.onCloseProjectRow = [this](int index) {
        if (index >= 0 && index < (int)projects_.size()) closeProject(projects_[index]);
    };
    sidebar_.onGitDiff = [this](const Git::StatusEntry& entry, const std::wstring& dir) {
        showDiff(entry, dir);
    };
    sidebar_.onGitCommitDiff = [this](const Git::Commit& commit, const Git::CommitFile& file,
                                      const std::wstring& dir) {
        showCommitDiff(commit.shortHash, file.path, dir);
    };
    sidebar_.onProjectGitChanged = [this](const std::wstring& dir) {
        refreshGit(true);
        // Finished after the user moved to another project: that row still
        // counts the changes it committed.
        if (!projectURL_ || *projectURL_ != dir) refreshProjectSummaries(true);
    };
    sidebar_.projectTitle.onBranchClick = [this](const Rect& rect) { showBranchMenu(rect); };
    diffs_.onReadAgain = [this](const std::wstring& dir, const std::string& path,
                                DiffPane::Tab::Source source, const std::string& hash) {
        if (source == DiffPane::Tab::Source::WorkingTree) showDiffForPath(path, dir);
        else showCommitDiff(hash, path, dir);
    };
    diffs_.onOpenFolder = [this] { openFolder(); };
    diffs_.onOpenRecent = [this](const std::wstring& path) { openSelection({path}); };
    diffs_.onOpenChecked = [this](const std::vector<std::wstring>& paths) { openSelection(paths); };
}

void WorkspaceWindow::refreshWindowTitle() {
    // The project first, because that tells two windows apart in the
    // taskbar; then the app.
    if (!projectURL_) setTitle(APP_NAME);
    else setTitle(lastPathComponent(*projectURL_) + L" - " + APP_NAME);
}

void WorkspaceWindow::windowWillClose() {
    if (gitRepositoryMonitor_) gitRepositoryMonitor_->stop();
    gitRepositoryMonitor_.reset();
    if (workspaceFileMonitor_) workspaceFileMonitor_->stop();
    workspaceFileMonitor_.reset();
    if (onClose) onClose(this);
}

void WorkspaceWindow::windowDidActivate(bool active) {
    if (!active) return;
    // Coming back from somewhere else — a terminal, most likely. Anything
    // resolved once for this project could have been changed out there.
    Git::forgetRepositoryInfo();
    refreshGit(true);
}

void WorkspaceWindow::windowDidMinimize() { FileIcons::releaseTransientMemory(); }

void WorkspaceWindow::applicationDidBecomeActive() { refreshProjectSummaries(true); }

int WorkspaceWindow::indexOfProject(const std::wstring& path) const {
    for (size_t i = 0; i < projects_.size(); ++i) {
        if (samePath(projects_[i], path)) return (int)i;
    }
    return -1;
}

// ── Projects ───────────────────────────────────────────────────────────────

void WorkspaceWindow::openProject(const std::wstring& path) {
    std::wstring resolved = normalizedPath(path);
    if (indexOfProject(resolved) < 0) projects_.push_back(resolved);
    activateProject(resolved);
}

void WorkspaceWindow::activateProject(const std::wstring& path) {
    int index = indexOfProject(normalizedPath(path));
    if (index < 0) return;
    std::wstring resolved = projects_[index];
    if (!projectURL_ || *projectURL_ != resolved) diffs_.closeAll();
    loadProject(resolved);
}

void WorkspaceWindow::loadProject(const std::wstring& url) {
    Git::forgetRepositoryInfo();
    // A batch of diff reads for the project being left stops where it is.
    if (openDiffReadToken_) openDiffReadToken_->cancel();
    lastChangedPaths_.clear();
    if (gitRepositoryMonitor_) gitRepositoryMonitor_->stop();
    gitRepositoryMonitor_.reset();
    if (workspaceFileMonitor_) workspaceFileMonitor_->stop();
    workspaceFileMonitor_.reset();
    projectURL_ = url;
    isRepository_.reset();
    diffs_.setHasProject(true);
    RecentProjects::shared().add(url);
    // Empty until this project's own refresh lands.
    sidebar_.clearChanges(url);
    sidebar_.setProjectTitle(lastPathComponent(url), L"");
    refreshWindowTitle();
    refreshGit();
    // Opened or switched to: find out what its remote has now — not again if
    // it was fetched a moment ago, nor while a pull is running.
    if (!pulling_.count(url)) {
        auto fetchStarted = std::make_shared<double>(monotonicNow());
        auto alive = life_.weak();
        BackgroundFetch::fetchIfDue(
            url,
            [this, alive, url, fetchStarted] {
                if (alive.expired()) return;
                *fetchStarted = monotonicNow();
                fetching_.insert(url);
                beginSync(url);
            },
            [this, alive, url, fetchStarted](bool moved) {
                if (alive.expired()) return;
                fetching_.erase(url);
                // A pull asked for meanwhile goes now, before this fetch lets
                // go of the mark.
                if (pullAfterFetch_.erase(url)) startPull(url);
                endSync(url, *fetchStarted);
                if (moved && projectURL_ && *projectURL_ == url) remoteRefsMoved();
            });
    }
    // Inside .git: commits, checkouts, fetches from anywhere.
    gitRepositoryMonitor_ = std::make_unique<GitRepositoryMonitor>(url, [this, url] {
        if (projectURL_ && *projectURL_ == url) refreshExternalGitState();
    });
    // The working tree: an edit in any editor is a change to list.
    workspaceFileMonitor_ = std::make_unique<WorkspaceFileMonitor>(url, [this, url] {
        if (projectURL_ && *projectURL_ == url) refreshGit(true);
    });
    refreshProjectTabs();
}

void WorkspaceWindow::refreshExternalGitState() {
    if (!projectURL_) return;
    Git::forgetRepositoryInfo();
    refreshGit(true);
}

void WorkspaceWindow::openSelection(const std::vector<std::wstring>& paths) {
    if (onOpenRequested) {
        onOpenRequested(paths);
        return;
    }
    for (auto& path : paths) {
        if (directoryExists(path)) openProject(path);
    }
}

void WorkspaceWindow::moveProject(int from, int to) {
    if (from < 0 || from >= (int)projects_.size() || from == to) return;
    int destination = std::clamp(to, 0, (int)projects_.size() - 1);
    std::wstring moved = projects_[from];
    projects_.erase(projects_.begin() + from);
    projects_.insert(projects_.begin() + destination, moved);
    refreshProjectTabs();
}

void WorkspaceWindow::closeProject(const std::wstring& path) {
    int index = indexOfProject(normalizedPath(path));
    if (index < 0) return;
    std::wstring resolved = projects_[index];
    bool wasShowing = projectURL_ && *projectURL_ == resolved;
    projects_.erase(projects_.begin() + index);
    diffs_.closeTabs(resolved);
    if (!wasShowing) {
        refreshProjectTabs();
        return;
    }
    if (projects_.empty()) {
        clearProject();
        refreshProjectTabs();
        return;
    }
    std::wstring next = index < (int)projects_.size() ? projects_[index] : projects_.back();
    activateProject(next);
}

void WorkspaceWindow::deactivateProject() {
    if (!projectURL_) return;
    clearProject();
    refreshProjectTabs();
}

void WorkspaceWindow::clearProject() {
    diffs_.closeAll();
    if (gitRepositoryMonitor_) gitRepositoryMonitor_->stop();
    gitRepositoryMonitor_.reset();
    if (workspaceFileMonitor_) workspaceFileMonitor_->stop();
    workspaceFileMonitor_.reset();
    Git::forgetRepositoryInfo();
    if (openDiffReadToken_) openDiffReadToken_->cancel();
    lastChangedPaths_.clear();
    projectURL_.reset();
    isRepository_.reset();
    diffs_.setHasProject(false);
    sidebar_.clearChanges(std::nullopt);
    sidebar_.setProjectTitle(L"", L"");
    // A refresh already in flight would speak for a project no longer shown.
    ++gitRefreshGeneration_;
    currentBranchName_.reset();
    refreshWindowTitle();
}

// ── Diffs ──────────────────────────────────────────────────────────────────

void WorkspaceWindow::showDiff(const Git::StatusEntry& entry, const std::wstring& directory) {
    auto alive = life_.weak();
    Git::workQueue().async([this, alive, entry, directory] {
        std::string text = Git::diffForEntry(entry, directory);
        Dispatch::main([this, alive, entry, directory, text] {
            if (alive.expired() || !projectURL_ || *projectURL_ != directory) return;
            DiffPane::Tab tab;
            tab.directory = directory;
            tab.path = entry.path;
            tab.source = DiffPane::Tab::Source::WorkingTree;
            tab.diff = text;
            diffs_.open(tab);
        });
    });
}

void WorkspaceWindow::showDiffForPath(const std::string& path, const std::wstring& directory) {
    auto alive = life_.weak();
    Git::workQueue().async([this, alive, path, directory] {
        std::string text = Git::diffForPath(path, directory).value_or("");
        Dispatch::main([this, alive, path, directory, text] {
            if (alive.expired() || !projectURL_ || *projectURL_ != directory) return;
            DiffPane::Tab tab;
            tab.directory = directory;
            tab.path = path;
            tab.source = DiffPane::Tab::Source::WorkingTree;
            tab.diff = text;
            diffs_.open(tab);
        });
    });
}

void WorkspaceWindow::showCommitDiff(const std::string& hash, const std::string& path,
                                     const std::wstring& directory) {
    auto alive = life_.weak();
    Git::workQueue().async([this, alive, hash, path, directory] {
        std::string text = Git::diffInCommit(hash, path, directory);
        Dispatch::main([this, alive, hash, path, directory, text] {
            if (alive.expired() || !projectURL_ || *projectURL_ != directory) return;
            DiffPane::Tab tab;
            tab.directory = directory;
            tab.path = path;
            tab.source = DiffPane::Tab::Source::Commit;
            tab.hash = hash;
            tab.diff = text;
            diffs_.open(tab);
        });
    });
}

void WorkspaceWindow::refreshOpenDiffs(const std::set<std::string>& changed,
                                       const std::wstring& directory) {
    lastChangedPaths_ = changed;
    // Only the tab on screen is read now; the others give up their bodies
    // and are read when next shown.
    const DiffPane::Tab* active = diffs_.activeTab();
    std::optional<std::wstring> activeID;
    if (active) activeID = active->id();
    diffs_.markWorkingTreeTabsStale(directory, activeID);
    active = diffs_.activeTab();
    if (!active || !samePath(active->directory, directory)
        || active->source != DiffPane::Tab::Source::WorkingTree) {
        return;
    }
    std::wstring id = active->id();
    std::string path = active->path;
    if (diffRefreshInFlight_) {
        diffRefreshAgain_ = true;
        return;
    }
    diffRefreshInFlight_ = true;
    auto token = std::make_shared<CancelToken>();
    openDiffReadToken_ = token;
    int generation = gitRefreshGeneration_;
    auto alive = life_.weak();
    Git::workQueue().async([this, alive, token, generation, id, path, changed, directory] {
        if (!token->isCancelled()) {
            // Not listed as changed: nothing left to show, nothing to ask Git.
            std::string text = changed.count(path) ? Git::diffForPath(path, directory).value_or("") : "";
            Dispatch::main([this, alive, generation, id, text, directory] {
                if (alive.expired() || !projectURL_ || *projectURL_ != directory
                    || gitRefreshGeneration_ != generation) {
                    return;
                }
                diffs_.update(id, text);
            });
        }
        Dispatch::main([this, alive, token] {
            if (alive.expired()) return;
            diffRefreshInFlight_ = false;
            if (!diffRefreshAgain_) return;
            diffRefreshAgain_ = false;
            if (!projectURL_ || token->isCancelled()) return;
            refreshOpenDiffs(lastChangedPaths_, *projectURL_);
        });
    });
}

// ── Git refresh ────────────────────────────────────────────────────────────

void WorkspaceWindow::refreshGit(bool requireFollowUp) {
    if (!projectURL_) return;
    std::wstring project = *projectURL_;
    if (gitSummaryRefreshInFlight_) {
        // Coalesced into the one in flight — unless that one no longer counts.
        if (!gitSummaryDirectory_ || *gitSummaryDirectory_ != project || requireFollowUp
            || gitSummaryGeneration_ != gitRefreshGeneration_) {
            gitSummaryRefreshAgain_ = true;
        }
        return;
    }
    gitSummaryRefreshInFlight_ = true;
    gitSummaryDirectory_ = project;
    int generation = ++gitRefreshGeneration_;
    gitSummaryGeneration_ = generation;
    auto alive = life_.weak();
    windowStatusQueue().async([this, alive, project, generation] {
        Git::Status status = Git::status(project);
        Dispatch::main([this, alive, project, generation, status] {
            if (alive.expired()) return;
            gitSummaryRefreshInFlight_ = false;
            gitSummaryDirectory_.reset();
            if (projectURL_ && *projectURL_ == project && gitRefreshGeneration_ == generation) {
                apply(status, project);
            }
            if (gitSummaryRefreshAgain_) {
                gitSummaryRefreshAgain_ = false;
                refreshGit();
            }
        });
    });
}

void WorkspaceWindow::apply(const Git::Status& status, const std::wstring& project) {
    if (status.isRepo) currentBranchName_ = status.branch;
    else currentBranchName_.reset();
    std::optional<bool> wasRepository = isRepository_;
    isRepository_ = status.isRepo;
    ProjectHistoryView::State state;
    if (status.isRepo) {
        state.head = status.head;
        state.ahead = status.ahead;
        state.hasUpstream = status.hasUpstream;
    }
    sidebar_.setChanges(status.isRepo ? status.entries : std::vector<Git::StatusEntry>{}, project, state);
    sidebar_.setProjectTitle(lastPathComponent(project), status.isRepo ? W(status.branch) : L"");
    std::set<std::string> changed;
    if (status.isRepo) {
        for (auto& entry : status.entries) changed.insert(entry.path);
    }
    refreshOpenDiffs(changed, project);
    // The row says the same thing the title strip does, at the same moment.
    ProjectSummary summary{status.isRepo ? W(status.branch) : L"",
                           status.isRepo ? W(status.userName) : L"",
                           status.isRepo ? (int)status.entries.size() : 0};
    bool redrawn = noteSummary(summary, project);
    if (!redrawn && wasRepository != isRepository_) refreshProjectTabs();
}

void WorkspaceWindow::refreshProjectTabs() {
    std::vector<ProjectRowInfo> rows;
    for (auto& path : projects_) {
        ProjectRowInfo info;
        info.name = lastPathComponent(path);
        info.path = path;
        auto summary = projectSummaries_.find(projectKey(path));
        if (summary != projectSummaries_.end()) {
            info.branch = summary->second.branch;
            info.user = summary->second.user;
            info.changes = summary->second.changes;
        }
        rows.push_back(info);
    }
    std::optional<int> active;
    if (projectURL_) {
        int index = indexOfProject(*projectURL_);
        if (index >= 0) active = index;
    }
    sidebar_.setProjects(rows, active, isRepository_);
    refreshProjectSummaries();
}

void WorkspaceWindow::refreshProjectSummaries(bool all) {
    // `all` re-reads every project but the one on screen, whose own refresh
    // knows more; otherwise only the ones never read.
    std::vector<std::wstring> wanted;
    for (auto& path : projects_) {
        bool showing = projectURL_ && samePath(path, *projectURL_);
        if (all ? !showing : !projectSummaries_.count(projectKey(path))) wanted.push_back(path);
    }
    if (wanted.empty()) return;
    auto alive = life_.weak();
    summaryQueue().async([this, alive, wanted] {
        // One status walk each, giving both the branch and the count.
        std::vector<std::pair<std::wstring, ProjectSummary>> found;
        for (auto& url : wanted) {
            Git::Status status = Git::status(url);
            found.push_back({url, ProjectSummary{status.isRepo ? W(status.branch) : L"",
                                                 status.isRepo ? W(status.userName) : L"",
                                                 status.isRepo ? (int)status.entries.size() : 0}});
        }
        Dispatch::main([this, alive, found] {
            if (!alive.expired()) applySummaries(found);
        });
    });
}

void WorkspaceWindow::applySummaries(const std::vector<std::pair<std::wstring, ProjectSummary>>& found) {
    bool changed = false;
    for (auto& [url, summary] : found) {
        // The project on screen may have been opened while the sweep read
        // it; its own refresh is newer than this snapshot.
        if (projectURL_ && samePath(url, *projectURL_)) continue;
        auto it = projectSummaries_.find(projectKey(url));
        if (it != projectSummaries_.end() && it->second == summary) continue;
        projectSummaries_[projectKey(url)] = summary;
        changed = true;
    }
    if (changed) refreshProjectTabs();
}

bool WorkspaceWindow::noteSummary(const ProjectSummary& summary, const std::wstring& path) {
    std::wstring key = projectKey(path);
    auto it = projectSummaries_.find(key);
    if (it != projectSummaries_.end() && it->second == summary) return false;
    projectSummaries_[key] = summary;
    refreshProjectTabs();
    return true;
}

// ── Syncing with the remote ────────────────────────────────────────────────

void WorkspaceWindow::beginSync(const std::wstring& path) {
    syncing_[path] += 1;
    publishSyncing();
}

void WorkspaceWindow::endSync(const std::wstring& path, double startedAt) {
    // A sync quicker than this would only flicker on the Git mark.
    double wait = std::max(0.0, minimumSyncAnimation - (monotonicNow() - startedAt));
    Dispatch::after(wait, [this, alive = life_.weak(), path] {
        if (alive.expired()) return;
        auto it = syncing_.find(path);
        int left = (it == syncing_.end() ? 1 : it->second) - 1;
        if (left > 0) syncing_[path] = left;
        else syncing_.erase(path);
        publishSyncing();
    });
}

void WorkspaceWindow::publishSyncing() {
    std::set<std::wstring> paths;
    for (auto& [path, count] : syncing_) paths.insert(path);
    sidebar_.setSyncingProjects(paths);
}

void WorkspaceWindow::pullProject(const std::wstring& path) {
    // Already on its way: once is enough.
    if (pulling_.count(path) || pullAfterFetch_.count(path)) {
        MessageBeep(MB_OK);
        return;
    }
    if (fetching_.count(path)) {
        pullAfterFetch_.insert(path);
        return;
    }
    startPull(path);
}

void WorkspaceWindow::startPull(const std::wstring& path) {
    double started = monotonicNow();
    pulling_.insert(path);
    beginSync(path);
    auto alive = life_.weak();
    Git::operationQueue().async([this, alive, path, started] {
        Git::RemoteResult result = Git::pull(path);
        Dispatch::main([this, alive, path, started, result] {
            if (alive.expired()) return;
            pulling_.erase(path);
            endSync(path, started);
            if (projectURL_ && *projectURL_ == path) {
                // HEAD has moved, and the remote branches with it.
                refreshExternalGitState();
                sidebar_.projectsPanel.history.remoteRefsMoved(path);
            } else {
                refreshProjectSummaries(true);
            }
            if (!result.ok) presentPullError(result.message, path);
        });
    });
}

void WorkspaceWindow::presentPullError(const std::string& message, const std::wstring& path) {
    Alert alert;
    alert.style = Alert::Style::Warning;
    alert.messageText = L"Couldn't pull “" + lastPathComponent(path) + L"”";
    alert.informativeText = trim(W(message));
    alert.buttons = {L"OK"};
    alert.runModal(hwnd());
}

void WorkspaceWindow::remoteRefsMoved() {
    if (!projectURL_) return;
    sidebar_.projectsPanel.history.remoteRefsMoved(*projectURL_);
    refreshGit(true);
}

// ── Branches ───────────────────────────────────────────────────────────────

void WorkspaceWindow::showBranchMenu(const Rect& rect) {
    if (!projectURL_ || isRepository_ == false) return;
    std::wstring directory = *projectURL_;
    // Just under the branch text, so the menu reads as its dropdown.
    Point anchor = sidebar_.projectTitle.convertToWindow(Point(rect.x, rect.maxY()));
    auto alive = life_.weak();
    windowStatusQueue().async([this, alive, directory, anchor] {
        auto branches = Git::branches(directory);
        Dispatch::main([this, alive, directory, anchor, branches] {
            if (alive.expired() || !projectURL_ || *projectURL_ != directory) return;
            auto menu = branchMenu(branches, directory);
            menu->popup(hwnd(), screenPoint(anchor));
        });
    });
}

namespace {

std::wstring branchDetail(const Git::Branch& branch) {
    if (branch.heldByWorktree) return L"in use by " + lastPathComponent(W(*branch.heldByWorktree));
    return branch.author.empty() ? W(branch.createdAt)
                                 : W(branch.author) + L" · " + W(branch.createdAt);
}

}  // namespace

std::shared_ptr<Menu> WorkspaceWindow::branchMenu(const std::vector<Git::Branch>& branches,
                                                  const std::wstring& directory) {
    auto menu = std::make_shared<Menu>();
    menu->titleSize = 11;
    // The current branch first so switching away from it is obvious, then
    // the rest in the order Git lists them.
    std::vector<Git::Branch> local, remote;
    for (auto& b : branches) {
        if (!b.isRemote && b.isCurrent) local.push_back(b);
    }
    for (auto& b : branches) {
        if (!b.isRemote && !b.isCurrent) local.push_back(b);
    }
    for (auto& b : branches) {
        if (b.isRemote) remote.push_back(b);
    }
    auto addBranch = [this, directory](Menu& target, const Git::Branch& branch) {
        auto& item = target.add(W(branch.name), [this, branch, directory] { switchBranch(branch, directory); },
                                !branch.heldByWorktree.has_value());
        item.detail = branchDetail(branch);
        item.checked = branch.isCurrent;
        item.titleSize = 11.5f;
        item.dimTitle = branch.heldByWorktree.has_value();
    };
    if (local.empty()) menu->add(L"No branches", nullptr, false);
    for (auto& branch : local) addBranch(*menu, branch);
    if (!remote.empty()) {
        auto submenu = std::make_shared<Menu>();
        submenu->titleSize = 11;
        for (auto& branch : remote) addBranch(*submenu, branch);
        menu->addSubmenu(L"Remote Branches", submenu);
    }
    menu->addSeparator();
    menu->add(L"New Branch…", [this, branches, directory] { createBranch(branches, directory); });
    // Neither the branch this tree is on nor one another tree holds can be
    // deleted; Git refuses both.
    auto deleteMenu = std::make_shared<Menu>();
    deleteMenu->titleSize = 11;
    for (auto& branch : local) {
        if (branch.isCurrent || branch.heldByWorktree) continue;
        deleteMenu->add(W(branch.name), [this, branch, directory] { deleteBranch(branch, directory); });
    }
    menu->addSubmenu(L"Delete Branch", deleteMenu, !deleteMenu->empty());
    return menu;
}

void WorkspaceWindow::switchBranch(const Git::Branch& branch, const std::wstring& directory) {
    if (branch.isCurrent) return;
    std::wstring name = W(branch.name);
    if (branch.heldByWorktree) {
        // Git allows a branch in one working tree at a time: said plainly,
        // with the place to look.
        presentBranchAlert(L"Cannot switch to “" + name + L"”",
                           "\xE2\x80\x9C" + branch.name + "\xE2\x80\x9D is checked out in another working tree:\n"
                               + *branch.heldByWorktree + "\n\nGit keeps a branch in one working tree at a time. "
                               "Switch that tree to something else, or remove it with `git worktree remove`, and "
                               "\xE2\x80\x9C" + branch.name + "\xE2\x80\x9D is free again.");
        return;
    }
    if (branch.isRemote && !branch.upstreamBranch) {
        presentBranchAlert(L"Cannot switch to “" + name + L"”",
                           "This remote-tracking ref has no branch name to check out locally.");
        return;
    }
    if (currentBranchName_ && *currentBranchName_ == branch.name) return;
    std::wstring from = currentBranchName_ ? W(*currentBranchName_) : L"the current branch";
    Alert alert;
    alert.style = Alert::Style::Warning;
    alert.messageText = L"Switch from “" + from + L"” to “" + name + L"”?";
    std::wstring effect = branch.isRemote
        ? L"A local tracking branch will be created, checked out, and the files in this working tree "
          L"will be replaced with that branch's versions."
        : L"The files in this working tree will be replaced with the versions from “" + name
            + L"”. Git will refuse the switch if local changes cannot be preserved.";
    alert.informativeText = L"Project:\n" + directory + L"\n\n" + effect;
    alert.buttons = {L"Switch", L"Cancel"};
    if (alert.runModal(hwnd()) != 0) return;
    runBranchOperation(L"Could not switch to “" + name + L"”", directory,
                       [branch, directory] { return Git::switchBranch(branch, directory); });
}

void WorkspaceWindow::createBranch(const std::vector<Git::Branch>& branches, const std::wstring& directory) {
    std::vector<std::wstring> names;
    int selected = 0;
    for (auto& branch : branches) {
        if (branch.isRemote) continue;
        if (branch.isCurrent) selected = (int)names.size();
        names.push_back(W(branch.name));
    }
    if (names.empty()) {
        presentBranchAlert(L"Cannot create branch", "No base branches are available.");
        return;
    }
    View grid;
    Label nameLabel, baseLabel;
    TextField nameField;
    PopupButton base;
    for (Label* label : {&nameLabel, &baseLabel}) {
        label->font = Theme::uiFont(11.5f);
        label->color = Theme::foreground;
    }
    nameLabel.text = L"Name";
    baseLabel.text = L"Base";
    nameField.placeholder = L"Branch name";
    nameField.font = Theme::uiFont(11.5f);
    nameField.fillColor = Theme::panelBackground;
    nameField.borderColor = Theme::border.blended(0.5f, Theme::dimText);
    nameField.horizontalInset = 8;
    base.items = names;
    base.selected = selected;
    nameLabel.setFrame(Rect(0, 0, 56, 26));
    nameField.setFrame(Rect(60, 0, 240, 26));
    baseLabel.setFrame(Rect(0, 34, 56, 26));
    base.setFrame(Rect(60, 34, 240, 26));
    grid.addSubview(&nameLabel);
    grid.addSubview(&nameField);
    grid.addSubview(&baseLabel);
    grid.addSubview(&base);

    Alert alert;
    alert.messageText = L"Create branch";
    alert.informativeText = L"The new branch will be created and checked out immediately.";
    alert.accessory = &grid;
    alert.accessorySize = Size(300, 60);
    alert.initialFocus = &nameField;
    alert.buttons = {L"Create", L"Cancel"};
    nameField.onSubmit = [] { PostMessageW(GetActiveWindow(), WM_KEYDOWN, VK_RETURN, 0); };
    int answer = alert.runModal(hwnd());
    std::wstring name = trim(nameField.text());
    std::wstring from = base.selectedTitle();
    grid.removeFromSuperview();
    if (answer != 0) return;
    if (name.empty()) {
        presentBranchAlert(L"Invalid branch name", "Enter a branch name.");
        return;
    }
    if (from.empty()) from = names[0];
    std::string branchName = U(name), baseName = U(from);
    runBranchOperation(L"Could not create “" + name + L"”", directory,
                       [branchName, baseName, directory] {
                           return Git::createBranch(branchName, baseName, directory);
                       });
}

void WorkspaceWindow::deleteBranch(const Git::Branch& branch, const std::wstring& directory) {
    if (branch.isCurrent) return;
    std::wstring name = W(branch.name);
    Alert alert;
    alert.style = Alert::Style::Warning;
    alert.messageText = L"Delete branch “" + name + L"”?";
    alert.informativeText = L"Project:\n" + directory + L"\n\n"
        L"This removes the local branch reference. Git permits this only when the branch is fully "
        L"merged; unmerged commits will not be deleted.";
    alert.buttons = {L"Delete", L"Cancel"};
    if (alert.runModal(hwnd()) != 0) return;
    runBranchOperation(L"Could not delete “" + name + L"”", directory,
                       [branch, directory] { return Git::deleteBranch(branch, directory); });
}

void WorkspaceWindow::runBranchOperation(const std::wstring& failureTitle, const std::wstring& directory,
                                         std::function<Git::RemoteResult()> work) {
    auto alive = life_.weak();
    Git::operationQueue().async([this, alive, failureTitle, directory, work] {
        Git::RemoteResult result = work();
        Dispatch::main([this, alive, failureTitle, directory, result] {
            if (alive.expired()) return;
            if (result.ok) {
                if (projectURL_ && *projectURL_ == directory) refreshExternalGitState();
                refreshProjectSummaries(true);
            } else {
                // Git refused it; hand its own words to the user.
                presentBranchAlert(failureTitle, result.message);
            }
        });
    });
}

void WorkspaceWindow::presentBranchAlert(const std::wstring& title, const std::string& message) {
    Alert::inform(hwnd(), title, trim(W(message)));
}

// ── Menu actions ───────────────────────────────────────────────────────────

void WorkspaceWindow::openFolder() {
    Com<IFileOpenDialog> dialog;
    if (FAILED(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER,
                                IID_IFileOpenDialog, reinterpret_cast<void**>(dialog.put())))) {
        return;
    }
    DWORD options = 0;
    dialog->GetOptions(&options);
    dialog->SetOptions(options | FOS_PICKFOLDERS | FOS_ALLOWMULTISELECT | FOS_FORCEFILESYSTEM
                       | FOS_PATHMUSTEXIST);
    dialog->SetTitle(L"Choose one or more repositories");
    dialog->SetOkButtonLabel(L"Open");
    if (FAILED(dialog->Show(hwnd()))) return;
    Com<IShellItemArray> items;
    if (FAILED(dialog->GetResults(items.put()))) return;
    DWORD count = 0;
    items->GetCount(&count);
    std::vector<std::wstring> paths;
    for (DWORD i = 0; i < count; ++i) {
        Com<IShellItem> item;
        if (FAILED(items->GetItemAt(i, item.put()))) continue;
        wchar_t* path = nullptr;
        if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &path)) && path) {
            paths.push_back(path);
            CoTaskMemFree(path);
        }
    }
    if (!paths.empty()) openSelection(paths);
}

void WorkspaceWindow::closeTab() {
    // With no diff open the window itself closes, so the shortcut never
    // feels dead.
    if (!diffs_.closeActive()) performClose();
}

void WorkspaceWindow::reopenClosedTab() {
    if (!diffs_.reopenLastClosed()) MessageBeep(MB_OK);
}

void WorkspaceWindow::releaseTransientMemory() { diffs_.releaseInactiveBodies(); }

void WorkspaceWindow::copy() {
    // Typing in the commit message keeps its own copy.
    if (isTextInputFocused()) {
        SendMessageW(GetFocus(), WM_COPY, 0, 0);
        return;
    }
    if (!diffs_.copyActiveDiff(hwnd())) MessageBeep(MB_OK);
}

void WorkspaceWindow::refreshRepository() {
    refreshExternalGitState();
    refreshProjectSummaries(true);
}

void WorkspaceWindow::showAppMenu() {
    if (!makeAppMenu) return;
    auto menu = makeAppMenu(this);
    Rect button = sidebar_.menuButton.convertToWindow(sidebar_.menuButton.bounds());
    menu->popup(hwnd(), screenPoint(Point(button.x, button.maxY())));
}

LRESULT WorkspaceWindow::handleMessage(UINT message, WPARAM wParam, LPARAM lParam) {
    if (message == WM_ACTIVATEAPP) App::shared().applicationActivated(wParam != FALSE);
    return WindowHost::handleMessage(message, wParam, lParam);
}

bool WorkspaceWindow::handleShortcut(const KeyEvent& e) {
    if (e.alt) return false;
    if (e.control && !e.shift) {
        switch (e.key) {
        case 'N': App::shared().newWindow(); return true;
        case 'O': openFolder(); return true;
        case 'W': closeTab(); return true;
        case 'R': refreshRepository(); return true;
        case 'C': copy(); return true;
        case 'Q': App::shared().quit(); return true;
        case 'M': ShowWindow(hwnd(), SW_MINIMIZE); return true;
        case VK_TAB:
        case VK_NEXT: selectNextTab(); return true;
        case VK_PRIOR: selectPreviousTab(); return true;
        default: return false;
        }
    }
    if (e.control && e.shift) {
        switch (e.key) {
        case 'W': performClose(); return true;
        case 'T': reopenClosedTab(); return true;
        case VK_OEM_6: selectNextTab(); return true;      // ]
        case VK_OEM_4: selectPreviousTab(); return true;  // [
        case VK_TAB: selectPreviousTab(); return true;
        default: return false;
        }
    }
    if (!e.control && !e.shift) {
        if (e.key == VK_F5) {
            refreshRepository();
            return true;
        }
        // The start page's Open is the default button.
        if (e.key == VK_RETURN && !hasProject() && !isTextInputFocused()) {
            openFolder();
            return true;
        }
    }
    return false;
}

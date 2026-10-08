#include "workspace.h"

#include "app.h"
#include "dialog.h"
#include "documentstore.h"
#include "menu.h"
#include "settings.h"
#include "theme.h"

#include <objbase.h>
#include <shobjidl.h>

std::wstring projectKey(const std::wstring& path) { return lowercased(path); }

// ── DividerHandle ──────────────────────────────────────────────────────────

void DividerHandle::draw(Graphics& g) {
    // Straddles the divider and paints its middle column: the same 1pt border
    // line the title band draws.
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

RootView::RootView(SidebarView* sidebar, EditorArea* editor) : sidebar_(sidebar), editor_(editor) {
    backgroundColor = Theme::editorBackground;
    addSubview(sidebar_);
    addSubview(editor_);
    addSubview(&divider_);
    addSubview(&caption);
    divider_.onDragBegan = [this] { dragStartWidth_ = sidebarWidth_; };
    divider_.onDrag = [this](float dx) { resizeSidebar(dragStartWidth_ + dx); };
}

float RootView::openingSidebarWidth(float width) {
    float half = std::round(width * defaultSidebarFraction);
    float limit = std::max(minimumSidebarWidth, std::round(width * 0.8f));
    return std::min(std::max(half, minimumSidebarWidth), limit);
}

void RootView::settleOpeningWidth() {
    if (!settled_ && bounds().w > 0) sidebarWidth_ = openingSidebarWidth(bounds().w);
    settled_ = true;
    setNeedsLayout();
}

void RootView::resizeSidebar(float proposed) {
    // A width chosen by hand is not replaced by the opening default.
    settled_ = true;
    // Never more than 80% of the window.
    float limit = std::max(minimumSidebarWidth, std::round(bounds().w * 0.8f));
    sidebarWidth_ = std::min(std::max(proposed, minimumSidebarWidth), limit);
    setNeedsLayout();
    if (WindowHost* host = window()) host->displayIfNeeded();
}

void RootView::showSidebar() {
    sidebarWidth_ = std::max(sidebarWidth_, minimumSidebarWidth);
    setNeedsLayout();
}

void RootView::layout() {
    Rect b = bounds();
    if (!settled_ && b.w > 0) sidebarWidth_ = openingSidebarWidth(b.w);
    float width = std::min(sidebarWidth_, std::max(0.0f, b.w - 1));
    sidebar_->setFrame(Rect(0, 0, width, b.h));
    editor_->setFrame(Rect(width + 1, 0, std::max(0.0f, b.w - width - 1), b.h));
    divider_.setFrame(Rect(width + 0.5f - DividerHandle::hitWidth / 2, 0, DividerHandle::hitWidth, b.h));
    float captionWidth = caption.preferredWidth();
    caption.setFrame(Rect(b.w - captionWidth, 0, captionWidth, CaptionButtonsView::buttonHeight));
}

// ── WorkspaceWindow ────────────────────────────────────────────────────────

namespace {

/// Summaries of the projects behind the one on screen, off the queue that
/// project's own history is read on.
Dispatch::Queue& summaryQueue() {
    static Dispatch::Queue* queue = new Dispatch::Queue("app.puzzle.git-summaries");
    return *queue;
}

/// One status read at a time per window; the windows share the thread.
Dispatch::Queue& windowStatusQueue() {
    static Dispatch::Queue* queue = new Dispatch::Queue("app.puzzle.workspace-git-summary");
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

std::string extensionOf(const std::string& path) {
    std::string name = lastPathComponent(path);
    size_t dot = name.rfind('.');
    return dot == std::string::npos ? "" : lowercased(name.substr(dot + 1));
}

/// A picture we can preview: `git diff` on a binary just says "Binary files
/// differ", so the image itself is far more useful.
bool isImage(const std::string& path) { return Document::imageExtensions().count(extensionOf(path)) > 0; }
/// Media is the same case.
bool isPlayable(const std::string& path) { return Document::mediaExtensions().count(extensionOf(path)) > 0; }

std::optional<SVGDiffSides> toSides(const std::optional<Git::PictureSides>& sides) {
    if (!sides) return std::nullopt;
    return SVGDiffSides{sides->before, sides->after};
}

std::wstring newIdentifier() {
    GUID guid;
    if (FAILED(CoCreateGuid(&guid))) return std::to_wstring(GetTickCount64());
    wchar_t text[64];
    StringFromGUID2(guid, text, 64);
    std::wstring id = text;
    id.erase(std::remove(id.begin(), id.end(), L'{'), id.end());
    id.erase(std::remove(id.begin(), id.end(), L'}'), id.end());
    return id;
}

/// The repository path below the per-commit temp folder, so `assets/icon.png`
/// and `docs/icon.png` never share a cached image.
std::wstring commitBlobPath(const std::wstring& repository, const std::string& commit, const std::string& path) {
    std::string key;
    {
        static const char* alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
        std::string bytes = U(lowercased(normalizedPath(repository)));
        int bits = 0, buffer = 0;
        for (unsigned char c : bytes) {
            buffer = (buffer << 8) | c;
            bits += 8;
            while (bits >= 6) {
                bits -= 6;
                key += alphabet[(buffer >> bits) & 63];
            }
        }
        if (bits > 0) key += alphabet[(buffer << (6 - bits)) & 63];
        if (key.size() > 120) key = key.substr(key.size() - 120);
    }
    wchar_t temp[MAX_PATH + 1];
    DWORD n = GetTempPathW(MAX_PATH + 1, temp);
    std::wstring base = n ? std::wstring(temp, n) : appDataDirectory();
    std::wstring folder = pathJoin(pathJoin(pathJoin(base, L"puzzle-blobs"), W(key)), W(commit));
    return pathJoinGit(folder, path);
}

}  // namespace

WorkspaceWindow::WorkspaceWindow() : root_(&sidebar_, &editor_) {
    diffPreviewID_ = newIdentifier();
    RECT frame = defaultWindowFrame();
    createWindow(APP_NAME, WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN, 0, nullptr, frame);
    captionButtons = &root_.caption;
    minimumSize = Size(640, 400);
    setRootView(&root_);
    // The title band: the project/branch strip starts after the menu button
    // that stands where the traffic lights are on a Mac.
    sidebar_.setTabRowHeight(EditorTabBar::defaultRowHeight);
    sidebar_.setTitlebarLeadingInset(44);
    editor_.setTabRowHeight(EditorTabBar::defaultRowHeight);
    editor_.setCaptionReserve(root_.caption.preferredWidth());
    // Files and folders dropped on the window open as they do from Explorer.
    DragAcceptFiles(hwnd(), TRUE);
    wire();
}

WorkspaceWindow::~WorkspaceWindow() {
    if (gitRepositoryMonitor_) gitRepositoryMonitor_->stop();
    if (workspaceFileMonitor_) workspaceFileMonitor_->stop();
    if (palette_) palette_->dismiss();
    palette_.reset();
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
    sidebar_.onShowMenu = [this] { showAppMenu(); };
    sidebar_.onSelectProjectRow = [this](int index) {
        if (index < 0 || index >= (int)projects_.size()) return;
        std::wstring wanted = projects_[index];
        // Clicking the project already showing collapses it: the tree folds
        // away and the start page comes back.
        if (projectURL_ && *projectURL_ == wanted) deactivateProject();
        else activateProject(wanted);
    };
    // The branch is a shortcut into that project's Git panel: it brings the
    // project forward, and never collapses the one showing.
    sidebar_.onSelectProjectBranchRow = [this](int index) {
        if (index < 0 || index >= (int)projects_.size()) return;
        std::wstring wanted = projects_[index];
        if (!projectURL_ || *projectURL_ != wanted) activateProject(wanted);
        sidebar_.showGit();
    };
    sidebar_.onPullProjectRow = [this](int index) {
        if (index >= 0 && index < (int)projects_.size()) pullProject(projects_[index]);
    };
    sidebar_.onReorderProjectRows = [this](int from, int to) { moveProject(from, to); };
    sidebar_.onCloseProjectRow = [this](int index) {
        if (index >= 0 && index < (int)projects_.size()) closeProject(projects_[index]);
    };
    FileTreeView& tree = sidebar_.fileTree();
    tree.onOpenFile = [this](const std::wstring& path) { editor_.open(path); };
    tree.onGitHistory = [this](const std::wstring& path) { showFileHistory(path); };
    tree.onOpenInTerminal = [](const std::wstring& path) {
        TerminalLauncher::open(directoryExists(path) ? path : deletingLastPathComponent(path));
    };
    tree.onFileSystemChanged = [this] {
        sidebar_.refreshGitPanelIfLoaded();
        refreshGit(true);
    };
    tree.canMutatePath = [this](const std::wstring& path) { return editor_.canMutatePath(path); };
    tree.onPathRenamed = [this](const std::wstring& from, const std::wstring& to) { editor_.pathRenamed(from, to); };
    tree.onPathDeleted = [this](const std::wstring& path) { editor_.pathDeleted(path); };
    sidebar_.onSearchResult = [this](const std::wstring& path, int line) {
        editor_.open(path);
        editor_.jumpToLine(line);
    };
    sidebar_.onSearchFile = [this](const std::wstring& path) { editor_.open(path); };
    sidebar_.onGitFile = [this](const std::wstring& path) { editor_.open(path); };
    sidebar_.onGitDiff = [this](const Git::StatusEntry& entry, const std::wstring& dir) { showDiff(entry, dir); };
    sidebar_.onGitCommitDiff = [this](const Git::Commit& commit, const Git::CommitFile& file,
                                      const std::wstring& dir) { showCommitDiff(commit, file, dir); };
    sidebar_.onGitChanged = [this] { gitChanged(); };
    sidebar_.onProjectGitChanged = [this](const std::wstring& dir) {
        gitChanged();
        // The Git panel did not run this one, so it has not read it yet.
        sidebar_.refreshGitPanelIfLoaded();
        // Finished after the user moved to another project: that row still
        // counts the changes it committed.
        if (!projectURL_ || *projectURL_ != dir) refreshProjectSummaries(true);
    };
    sidebar_.activityBar.onAction = [this](ActivityBarView::Action action) { handleActivity(action); };
    // The name goes back to the list it was chosen from; the terminal has its
    // own button at the end of the band.
    sidebar_.projectTitle.onProjectClick = [this] { sidebar_.showFiles(); };
    sidebar_.onOpenTerminal = [this] { openProjectInTerminal(); };
    sidebar_.projectTitle.onBranchClick = [this](const Rect& rect) { showBranchMenu(rect); };
    editor_.onOpenFolder = [this] { openFolder(); };
    editor_.onOpenSettings = [this] { openSettings(); };
    editor_.onOpenRecent = [this](const std::wstring& path) { openSelection({path}); };
    // Every ticked project joins this window; the last one read is shown.
    editor_.onOpenChecked = [this](const std::vector<std::wstring>& paths) { openSelection(paths); };
    editor_.onDocumentSaved = [this](const std::wstring& path) {
        // The file changed on disk, so its cached blame is stale.
        editor_.invalidateBlame(path);
        // Saving settings.json applies the new display config immediately.
        if (samePath(path, Settings::filePath())) Settings::shared().reload();
        scheduleGitRefreshAfterSave();
    };
    // Keep the file tree's active-file highlight in sync with the active tab.
    editor_.onActiveDocumentChanged = [this](const std::optional<std::wstring>& path) {
        if (!path) return;
        sidebar_.fileTree().selectFile(*path);
        refreshWindowTitle(path);
    };
}

/// A window is a project, so it keeps the project's name as tabs come and go;
/// a window opened on a single file is named after that file.
void WorkspaceWindow::refreshWindowTitle(const std::optional<std::wstring>& activeFile) {
    std::wstring name;
    if (projectURL_) name = lastPathComponent(*projectURL_);
    else if (activeFile && !DiffURL::is(*activeFile)) name = lastPathComponent(*activeFile);
    setTitle(name.empty() ? std::wstring(APP_NAME) : name + L" - " + APP_NAME);
}

bool WorkspaceWindow::windowShouldClose() { return editor_.confirmClose(); }

void WorkspaceWindow::windowWillClose() {
    if (gitRepositoryMonitor_) gitRepositoryMonitor_->stop();
    gitRepositoryMonitor_.reset();
    if (workspaceFileMonitor_) workspaceFileMonitor_->stop();
    workspaceFileMonitor_.reset();
    if (palette_) palette_->dismiss();
    // Release this window's buffers.
    editor_.detachAllPanes();
    if (onClose) onClose(this);
}

void WorkspaceWindow::windowDidMinimize() {
    quickOpenIndex_.clear();
    quickOpenIndex_.shrink_to_fit();
    sidebar_.releaseHiddenPanels();
    editor_.releaseTransientMemory();
    DocumentStore::shared().releaseTransientMemory();
    // Nothing is drawing file rows while the window is minimised.
    FileIcons::releaseTransientMemory();
}

void WorkspaceWindow::windowDidActivate(bool active) {
    if (!active) {
        // Clicking another window, or switching apps, is a focus change: the
        // buffers are written before attention moves on.
        editor_.autosaveAll();
        return;
    }
    // Coming back from somewhere else — a terminal, most likely. Anything
    // resolved once for this project could have been changed out there.
    Git::forgetRepositoryInfo();
    sidebar_.refreshGitPanelIfLoaded();
    refreshGit(true);
}

/// The app came back from somewhere else: the rows behind the one on screen
/// are most likely to be wrong now.
void WorkspaceWindow::applicationDidBecomeActive() { refreshProjectSummaries(true); }

void WorkspaceWindow::releaseTransientMemory() {
    // Rebuilt in well under a second the next time Ctrl+P is used.
    quickOpenIndex_.clear();
    quickOpenIndex_.shrink_to_fit();
    if (palette_) palette_->dismiss();
    sidebar_.releaseHiddenPanels();
    editor_.releaseTransientMemory();
}

void WorkspaceWindow::refreshDisplay() {
    editor_.refreshDisplay();
    sidebar_.refreshFonts();
    root_.setNeedsDisplay();
    invalidateAll();
}

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

/// Switch to a project this window already holds. The editor is emptied
/// first: nothing of the previous project is carried across.
void WorkspaceWindow::activateProject(const std::wstring& path) {
    int index = indexOfProject(normalizedPath(path));
    if (index < 0) return;
    std::wstring resolved = projects_[index];
    if (!projectURL_ || *projectURL_ != resolved) editor_.closeAllTabs();
    loadProject(resolved);
}

void WorkspaceWindow::loadProject(const std::wstring& url) {
    // Where the repository root is and who commits from it are resolved once
    // per project and then reused; a new project resolves its own.
    Git::forgetRepositoryInfo();
    if (gitRepositoryMonitor_) gitRepositoryMonitor_->stop();
    gitRepositoryMonitor_.reset();
    if (workspaceFileMonitor_) workspaceFileMonitor_->stop();
    workspaceFileMonitor_.reset();
    projectURL_ = url;
    quickOpenIndex_.clear();
    if (palette_) palette_->dismiss();
    editor_.setHasProject(true);
    editor_.setRepositoryRoot(url);
    RecentProjects::shared().add(url);
    sidebar_.fileTree().setRoot(url);
    // Empty until this project's own refresh lands.
    sidebar_.clearChanges(url);
    sidebar_.setDirectory(url);
    // The name straight away; the branch follows the Git refresh.
    sidebar_.setProjectTitle(lastPathComponent(url), L"");
    refreshWindowTitle(std::nullopt);
    refreshGit();
    // Opened or switched to: find out what its remote has now — this project
    // only, not again if it was fetched a moment ago, nor while a pull runs.
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
                // go of the mark, so the band runs on without a break.
                if (pullAfterFetch_.erase(url)) startPull(url);
                endSync(url, *fetchStarted);
                if (moved && projectURL_ && *projectURL_ == url) remoteRefsMoved();
            });
    }
    gitRepositoryMonitor_ = std::make_unique<GitRepositoryMonitor>(url, [this, url] {
        if (projectURL_ && *projectURL_ == url) refreshExternalGitState();
    });
    workspaceFileMonitor_ = std::make_unique<WorkspaceFileMonitor>(
        url, [this, url](const std::vector<std::wstring>& paths, int64_t observedAt) {
            if (!projectURL_ || *projectURL_ != url) return;
            auto reloaded = DocumentStore::shared().reloadExternalChanges(paths, observedAt);
            // New and deleted files are not open documents, but the tree still
            // needs them at once.
            sidebar_.fileTree().refresh(paths);
            sidebar_.refreshGitPanelIfLoaded();
            refreshGit(true);
            for (auto& path : reloaded) editor_.invalidateBlame(path);
        });
    refreshProjectTabs();
}

/// Every Git-derived surface, after another process changed the repository.
void WorkspaceWindow::refreshExternalGitState() {
    if (!projectURL_) return;
    // Something changed inside .git — possibly the repository's own user.name.
    Git::forgetRepositoryInfo();
    auto reloaded = DocumentStore::shared().reloadExternalChanges({*projectURL_});
    sidebar_.fileTree().refresh(std::vector<std::wstring>{*projectURL_});
    sidebar_.refreshGitPanelIfLoaded();
    refreshGit(true);
    if (reloaded.empty()) {
        editor_.invalidateBlame();
    } else {
        for (auto& path : reloaded) editor_.invalidateBlame(path);
    }
    editor_.refreshGitLineChanges();
}

void WorkspaceWindow::openSelection(const std::vector<std::wstring>& paths) {
    if (onOpenRequested) {
        onOpenRequested(paths);
        return;
    }
    for (auto& path : paths) {
        if (directoryExists(path)) {
            openProject(path);
        } else if (fileExists(path)) {
            if (!hasProject()) openProject(deletingLastPathComponent(path));
            editor_.open(path);
        }
    }
}

/// Reorder the strip. Which project is showing does not change.
void WorkspaceWindow::moveProject(int from, int to) {
    if (from < 0 || from >= (int)projects_.size() || from == to) return;
    int destination = std::clamp(to, 0, (int)projects_.size() - 1);
    std::wstring moved = projects_[from];
    projects_.erase(projects_.begin() + from);
    projects_.insert(projects_.begin() + destination, moved);
    refreshProjectTabs();
}

/// Take a project out of this window. Closing the one being shown moves to a
/// neighbour; closing the last empties the window back to the start page.
void WorkspaceWindow::closeProject(const std::wstring& path) {
    int index = indexOfProject(normalizedPath(path));
    if (index < 0) return;
    std::wstring resolved = projects_[index];
    bool wasShowing = projectURL_ && *projectURL_ == resolved;
    projects_.erase(projects_.begin() + index);
    // A summary outliving its project would come back wrong with it.
    projectSummaries_.erase(projectKey(resolved));
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

/// Show no project, while keeping the window's list of them.
void WorkspaceWindow::deactivateProject() {
    if (!projectURL_) return;
    clearProject();
    refreshProjectTabs();
}

/// Back to having nothing open: no tabs, no monitors, no tree, no Git.
void WorkspaceWindow::clearProject() {
    editor_.closeAllTabs();
    if (gitRepositoryMonitor_) gitRepositoryMonitor_->stop();
    gitRepositoryMonitor_.reset();
    if (workspaceFileMonitor_) workspaceFileMonitor_->stop();
    workspaceFileMonitor_.reset();
    Git::forgetRepositoryInfo();
    projectURL_.reset();
    quickOpenIndex_.clear();
    if (palette_) palette_->dismiss();
    editor_.setHasProject(false);
    editor_.setRepositoryRoot(std::nullopt);
    sidebar_.fileTree().clearRoot();
    sidebar_.clearChanges(std::nullopt);
    sidebar_.setDirectory(std::nullopt);
    sidebar_.setProjectTitle(L"", L"");
    // A refresh already in flight would speak for a project no longer shown.
    ++gitRefreshGeneration_;
    currentBranchName_.reset();
    refreshWindowTitle(std::nullopt);
}

// ── Diffs ──────────────────────────────────────────────────────────────────

std::wstring WorkspaceWindow::diffPreviewURL(const std::wstring& directory, const std::string& path,
                                             const std::string& commit) const {
    return DiffURL::make(diffPreviewID_, directory, path, commit);
}

void WorkspaceWindow::showDiff(const Git::StatusEntry& entry, const std::wstring& directory) {
    // Images and media preview instead of diffing — the view the tree gives.
    if (isImage(entry.path) || isPlayable(entry.path)) {
        std::wstring file = pathJoinGit(directory, entry.path);
        if (fileExists(file)) {
            editor_.open(file);
            return;
        }
        // Deleted: nothing on disk to show, so the diff it is.
    }
    auto alive = life_.weak();
    Dispatch::background([this, alive, entry, directory] {
        std::string text = Git::diffForEntry(entry, directory);
        // A picture that is also source: the diff tab shows both versions.
        auto sides = toSides(Git::svgDiffSides(entry.path, directory));
        Dispatch::main([this, alive, entry, directory, text, sides] {
            if (alive.expired() || !projectURL_ || *projectURL_ != directory) return;
            std::wstring url = diffPreviewURL(directory, entry.path);
            // Replace any previous diff for this file so re-clicking refreshes.
            Document& document = DocumentStore::shared().setVirtualDocument(
                url, text, W(lastPathComponent(entry.path)) + L" (diff)");
            document.svgDiffSides = sides;
            editor_.open(url, true);
        });
    });
}

DocumentStore::VirtualContent WorkspaceWindow::commitDiffContent(const std::string& commit, const std::string& path,
                                                                 const std::wstring& directory) {
    std::wstring name = W(lastPathComponent(path));
    auto sides = toSides(Git::svgDiffSides(commit, path, directory));
    DocumentStore::VirtualContent content;
    content.displayName = name + L" @ " + W(commit);
    content.svgSides = sides;
    // An SVG the commit added reads better as the file itself, with its
    // picture above it.
    if (sides && !sides->before && sides->after && isValidUTF8(*sides->after)) {
        content.text = *sides->after;
        return content;
    }
    content.text = Git::diffInCommit(commit, path, directory);
    return content;
}

void WorkspaceWindow::registerDiffContentProvider() {
    DocumentStore::shared().virtualContentProvider =
        [](const std::wstring& url) -> std::optional<DocumentStore::VirtualContent> {
        auto parts = DiffURL::parse(url);
        if (!parts || parts->path.empty()) return std::nullopt;
        if (!parts->commit.empty()) {
            if (parts->commit == "file-history-table") return std::nullopt;
            return commitDiffContent(parts->commit, parts->path, parts->directory);
        }
        auto text = Git::diffForPath(parts->path, parts->directory);
        if (!text) return std::nullopt;
        DocumentStore::VirtualContent content;
        content.text = *text;
        content.displayName = W(lastPathComponent(parts->path)) + L" (diff)";
        content.svgSides = toSides(Git::svgDiffSides(parts->path, parts->directory));
        return content;
    };
}

/// How one file changed in a specific commit.
void WorkspaceWindow::showCommitDiff(const Git::Commit& commit, const Git::CommitFile& file,
                                     const std::wstring& directory) {
    std::string hash = commit.shortHash;
    auto alive = life_.weak();
    // For an image, show the picture as it looked in that commit: the blob is
    // written to a temp file so the normal preview can decode it.
    if (isImage(file.path) && file.status != "D") {
        Dispatch::background([this, alive, hash, file, directory] {
            Git::BlobResult blob = Git::blob(hash, file.path, directory);
            if (blob.kind != Git::BlobResult::Kind::Data || blob.data.empty()) {
                Dispatch::main([this, alive, blob, directory] {
                    if (alive.expired() || !projectURL_ || *projectURL_ != directory) return;
                    std::wstring detail;
                    if (blob.kind == Git::BlobResult::Kind::TooLarge) {
                        detail = L"The image is " + formatByteCount(blob.size) + L", which exceeds Puzzle's preview limit.";
                    } else if (blob.kind == Git::BlobResult::Kind::Unavailable) {
                        detail = trim(W(blob.message));
                    } else {
                        detail = L"The image blob is empty.";
                    }
                    Alert::inform(hwnd(), L"Unable to open history image", detail);
                });
                return;
            }
            std::wstring temp = commitBlobPath(directory, hash, file.path);
            createDirectories(deletingLastPathComponent(temp));
            if (!atomicWriteFile(temp, blob.data)) return;
            Dispatch::main([this, alive, directory, temp] {
                if (alive.expired() || !projectURL_ || *projectURL_ != directory) return;
                editor_.open(temp);
            });
        });
        return;
    }
    Dispatch::background([this, alive, hash, file, directory] {
        // Built the way the rebuild-from-URL path builds it, so a History tab
        // evicted and reopened comes back identical.
        auto content = std::make_shared<DocumentStore::VirtualContent>(commitDiffContent(hash, file.path, directory));
        Dispatch::main([this, alive, hash, file, directory, content] {
            if (alive.expired() || !projectURL_ || *projectURL_ != directory) return;
            std::wstring url = diffPreviewURL(directory, file.path, hash);
            Document& document =
                DocumentStore::shared().setVirtualDocument(url, content->text, content->displayName);
            document.svgDiffSides = content->svgSides;
            editor_.open(url, true);
        });
    });
}

void WorkspaceWindow::showFileHistory(const std::wstring& file) {
    if (!projectURL_) return;
    std::wstring directory = *projectURL_;
    auto relative = Git::projectRelative(file, directory);
    if (!relative) return;
    std::string path = *relative;
    auto alive = life_.weak();
    Dispatch::background([this, alive, file, directory, path] {
        auto commits = Git::logFile(file, directory);
        Dispatch::main([this, alive, file, directory, path, commits] {
            if (alive.expired() || !projectURL_ || *projectURL_ != directory) return;
            FileHistoryModel model;
            model.tabURL = diffPreviewURL(directory, path, "file-history-table");
            model.repository = directory;
            model.relativePath = path;
            model.displayName = lastPathComponent(file) + L" History";
            model.commits = commits;
            editor_.showFileHistory(model);
        });
    });
}

/// Saves arrive in bursts now that leaving a buffer writes it; a burst is
/// collapsed into one Git refresh.
void WorkspaceWindow::scheduleGitRefreshAfterSave() {
    if (gitRefreshAfterSave_) gitRefreshAfterSave_->cancel();
    gitRefreshAfterSave_ = Dispatch::after(0.4, [this, alive = life_.weak()] {
        if (alive.expired()) return;
        gitRefreshAfterSave_.reset();
        sidebar_.refreshGitPanelIfLoaded();
        refreshGit(true);
    });
}

/// Something committed, pushed or otherwise moved the repository.
void WorkspaceWindow::gitChanged() {
    refreshGit(true);
    // Committing rewrites authorship, and clears the gutter marks.
    editor_.invalidateBlame();
    editor_.refreshGitLineChanges();
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
        auto status = std::make_shared<Git::Status>(Git::status(project));
        auto split = Git::trackedAndUntracked(*status);
        std::set<std::string> ignored;
        if (status->isRepo) ignored = Git::ignoredPaths(project);
        Dispatch::main([this, alive, project, generation, status, split, ignored] {
            if (alive.expired()) return;
            gitSummaryRefreshInFlight_ = false;
            gitSummaryDirectory_.reset();
            if (projectURL_ && *projectURL_ == project && gitRefreshGeneration_ == generation) {
                bool repo = status->isRepo;
                sidebar_.fileTree().setStatus(split.first, split.second, ignored);
                if (repo) currentBranchName_ = status->branch;
                else currentBranchName_.reset();
                ProjectHistoryView::State state;
                if (repo) {
                    state.head = status->head;
                    state.ahead = status->ahead;
                    state.hasUpstream = status->hasUpstream;
                    state.branch = status->branch;
                }
                sidebar_.setChanges(repo ? status->entries : std::vector<Git::StatusEntry>{}, project, state);
                sidebar_.setProjectTitle(lastPathComponent(project), repo ? W(status->branch) : L"");
                // The row says the same thing the title strip does.
                noteSummary(ProjectSummary{repo ? W(status->branch) : L"", repo ? W(status->userName) : L"",
                                           repo ? (int)status->entries.size() : 0},
                            project);
            }
            if (gitSummaryRefreshAgain_) {
                gitSummaryRefreshAgain_ = false;
                refreshGit();
            }
        });
    });
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
    sidebar_.setProjects(rows, active);
    refreshProjectSummaries();
}

/// `all` re-reads every project but the one on screen, whose own refresh
/// knows more; otherwise only the ones never read.
void WorkspaceWindow::refreshProjectSummaries(bool all) {
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
        // The project on screen has a newer read of its own; one closed while
        // the sweep was out has no row to describe.
        if (projectURL_ && samePath(url, *projectURL_)) continue;
        if (indexOfProject(url) < 0) continue;
        auto it = projectSummaries_.find(projectKey(url));
        if (it != projectSummaries_.end() && it->second == summary) continue;
        projectSummaries_[projectKey(url)] = summary;
        changed = true;
    }
    if (changed) refreshProjectTabs();
}

void WorkspaceWindow::noteSummary(const ProjectSummary& summary, const std::wstring& path) {
    std::wstring key = projectKey(path);
    auto it = projectSummaries_.find(key);
    if (it != projectSummaries_.end() && it->second == summary) return;
    projectSummaries_[key] = summary;
    refreshProjectTabs();
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

/// The Git mark on a project's row: bring the remote's commits into the
/// branch when that is a fast-forward; anything else is Git's to explain.
void WorkspaceWindow::pullProject(const std::wstring& path) {
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
                // Files may have changed under open tabs, HEAD has moved, and
                // the remote branches with it.
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

/// A fetch moved a remote-tracking branch: what draws remote branches reads
/// again, and so does the ahead count.
void WorkspaceWindow::remoteRefsMoved() {
    if (!projectURL_) return;
    sidebar_.refreshGitPanelIfLoaded();
    sidebar_.projectsPanel.history.remoteRefsMoved(*projectURL_);
    refreshGit(true);
}

void WorkspaceWindow::openProjectInTerminal() {
    if (projectURL_) TerminalLauncher::open(*projectURL_);
}

// ── Quick Open / Go to Line ────────────────────────────────────────────────

PalettePanel& WorkspaceWindow::ensurePalette() {
    if (!palette_) palette_ = std::make_unique<PalettePanel>();
    return *palette_;
}

std::vector<PalettePanel::Item> WorkspaceWindow::quickOpenItems(const std::wstring& query) const {
    std::vector<PalettePanel::Item> items;
    if (!projectURL_) return items;
    for (auto& path : QuickOpen::matches(quickOpenIndex_, query)) {
        size_t slash = path.rfind(L'/');
        PalettePanel::Item item;
        item.title = slash == std::wstring::npos ? path : path.substr(slash + 1);
        item.detail = slash == std::wstring::npos ? L"" : replaceAll(path.substr(0, slash), L"/", L"\\");
        item.value = pathJoinGit(*projectURL_, U(path));
        items.push_back(item);
    }
    return items;
}

/// Ctrl+P. The file index is built off the main thread on first use and
/// reused until the project changes.
void WorkspaceWindow::quickOpen() {
    if (!projectURL_) return;
    std::wstring directory = *projectURL_;
    PalettePanel& panel = ensurePalette();
    panel.configure(L"Search files by name",
                    L"Type to filter · ↑↓ to choose · ↵ to open · esc to dismiss");
    panel.onQueryChanged = [this](const std::wstring& query) {
        if (palette_) palette_->setItems(quickOpenItems(query));
    };
    panel.onAccept = [this](const PalettePanel::Item* item) {
        if (palette_) palette_->dismiss();
        if (item && item->value) editor_.open(*item->value);
    };
    panel.setQuery(L"");
    panel.setItems(quickOpenItems(L""));
    panel.present(hwnd());
    refreshQuickOpenIndex(directory);
}

/// Ctrl+L. Same panel, no list: a line (or `line:column`) to jump to.
void WorkspaceWindow::goToLine() {
    if (!editor_.hasOpenDocument()) return;
    PalettePanel& panel = ensurePalette();
    panel.configure(L"Line number", L"Type a line, or line:column · ↵ to jump · esc to dismiss");
    panel.onQueryChanged = [this](const std::wstring&) {
        if (palette_) palette_->setItems({});
    };
    panel.onAccept = [this](const PalettePanel::Item*) {
        if (!palette_) return;
        auto target = QuickOpen::lineTarget(palette_->query());
        if (!target) return;
        palette_->dismiss();
        editor_.jumpToLine(target->first, target->second);
    };
    panel.setQuery(L"");
    panel.setItems({});
    panel.present(hwnd());
}

void WorkspaceWindow::refreshQuickOpenIndex(const std::wstring& directory) {
    if (quickOpenIndexInFlight_) return;
    quickOpenIndexInFlight_ = true;
    auto alive = life_.weak();
    Dispatch::background([this, alive, directory] {
        auto paths = std::make_shared<std::vector<std::wstring>>(QuickOpen::index(directory));
        Dispatch::main([this, alive, directory, paths] {
            if (alive.expired()) return;
            quickOpenIndexInFlight_ = false;
            if (!projectURL_ || *projectURL_ != directory) return;
            quickOpenIndex_ = std::move(*paths);
            if (palette_ && palette_->isPresented()) palette_->setItems(quickOpenItems(palette_->query()));
        });
    });
}

// ── Branch menu ────────────────────────────────────────────────────────────

namespace {
/// How many branches the title-strip menu lists; beyond this the Git panel's
/// Branch tab is the place to look.
constexpr size_t kBranchMenuLimit = 10;
}  // namespace

void WorkspaceWindow::showBranchMenu(const Rect& rect) {
    if (!projectURL_) return;
    std::wstring directory = *projectURL_;
    // Just under the branch text, so the menu reads as its dropdown.
    Point anchor = sidebar_.projectTitle.convertToWindow(Point(rect.x, rect.maxY()));
    auto alive = life_.weak();
    windowStatusQueue().async([this, alive, directory, anchor] {
        auto branches = Git::branches(directory);
        Dispatch::main([this, alive, directory, anchor, branches] {
            if (alive.expired() || !projectURL_ || *projectURL_ != directory) return;
            Menu menu;
            menu.titleSize = 11;
            // The current branch first so switching away from it is obvious,
            // then the rest, capped.
            std::vector<Git::Branch> entries;
            for (auto& b : branches) if (b.isCurrent) entries.push_back(b);
            for (auto& b : branches) if (!b.isCurrent) entries.push_back(b);
            if (entries.size() > kBranchMenuLimit) entries.resize(kBranchMenuLimit);
            if (entries.empty()) menu.add(L"No branches", nullptr, false);
            for (auto& branch : entries) {
                auto& item = menu.add(W(branch.name), [this, branch, directory] { switchBranch(branch, directory); });
                // Two lines: the branch, then who last touched it and when.
                item.detail = branch.author.empty() ? W(branch.createdAt)
                                                    : W(branch.author) + L" · " + W(branch.createdAt);
                item.checked = branch.isCurrent;
                item.titleSize = 11.5f;
            }
            if (branches.size() > entries.size()) {
                menu.addSeparator();
                menu.add(std::to_wstring(branches.size() - entries.size()) + L" more in the Git panel…",
                         [this] { sidebar_.showGitBranches(); });
            }
            menu.popup(hwnd(), screenPoint(anchor));
        });
    });
}

/// Switch to `branch`, explaining first: a switch that cannot happen says why;
/// one that can names both ends before it runs.
void WorkspaceWindow::switchBranch(const Git::Branch& branch, const std::wstring& directory) {
    std::wstring name = W(branch.name);
    if (branch.isCurrent || (currentBranchName_ && *currentBranchName_ == branch.name)) {
        presentBranchAlert(L"Already on “" + name + L"”",
                           "This is the branch the working tree is already checked out to.");
        return;
    }
    if (branch.isRemote && !branch.upstreamBranch) {
        presentBranchAlert(L"Cannot switch to “" + name + L"”",
                           "This remote-tracking ref has no branch name to check out locally. Create a local "
                           "branch from it in the Git panel's Branch tab.");
        return;
    }
    std::wstring from = currentBranchName_ ? W(*currentBranchName_) : L"the current branch";
    Alert alert;
    alert.style = Alert::Style::Warning;
    alert.messageText = L"Switch from “" + from + L"” to “" + name + L"”?";
    std::wstring effect = branch.isRemote
        ? L"A local tracking branch will be created, checked out, and the files in this working tree will be "
          L"replaced with that branch's versions."
        : L"The files in this working tree will be replaced with the versions from “" + name
              + L"”. Git will refuse the switch if local changes cannot be preserved.";
    alert.informativeText = L"Project:\n" + directory + L"\n\n" + effect;
    alert.buttons = {L"Switch", L"Cancel"};
    if (alert.runModal(hwnd()) != 0) return;
    auto alive = life_.weak();
    windowStatusQueue().async([this, alive, branch, directory, name] {
        Git::RemoteResult result = Git::switchBranch(branch, directory);
        Dispatch::main([this, alive, directory, result, name] {
            if (alive.expired() || !projectURL_ || *projectURL_ != directory) return;
            if (result.ok) {
                refreshExternalGitState();
            } else {
                // Git refused it; hand its own words to the user.
                presentBranchAlert(L"Could not switch to “" + name + L"”", result.message);
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
    if (FAILED(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_IFileOpenDialog,
                                reinterpret_cast<void**>(dialog.put())))) {
        return;
    }
    DWORD options = 0;
    dialog->GetOptions(&options);
    dialog->SetOptions(options | FOS_PICKFOLDERS | FOS_ALLOWMULTISELECT | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST);
    dialog->SetTitle(L"Choose a project folder");
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

/// Ctrl+W. With nothing open the window itself closes, so the shortcut never
/// feels dead.
void WorkspaceWindow::closeTab() {
    if (!editor_.closeActiveTab()) performClose();
}

void WorkspaceWindow::reopenClosedTab() {
    if (!editor_.reopenLastClosedTab()) MessageBeep(MB_OK);
}

void WorkspaceWindow::showFiles() {
    root_.showSidebar();
    sidebar_.showFiles();
    root_.preserveSidebarWidth();
}

void WorkspaceWindow::findInFolder() {
    root_.showSidebar();
    sidebar_.showSearch();
    root_.preserveSidebarWidth();
}

void WorkspaceWindow::showGit() {
    root_.showSidebar();
    sidebar_.showGit();
    root_.preserveSidebarWidth();
}

/// settings.json in this window's editor, created if needed.
void WorkspaceWindow::openSettings() { editor_.open(Settings::shared().ensureFileExists()); }

/// The activity bar selects the requested panel; the sidebar stays visible.
void WorkspaceWindow::handleActivity(ActivityBarView::Action action) {
    root_.showSidebar();
    switch (action) {
    case ActivityBarView::Action::Project: sidebar_.showFiles(); break;
    case ActivityBarView::Action::Search: sidebar_.showSearch(); break;
    case ActivityBarView::Action::Git: sidebar_.showGit(); break;
    }
    root_.preserveSidebarWidth();
}

void WorkspaceWindow::showAppMenu() {
    if (!makeAppMenu) return;
    auto menu = makeAppMenu(this);
    Rect button = sidebar_.menuButton.convertToWindow(sidebar_.menuButton.bounds());
    menu->popup(hwnd(), screenPoint(Point(button.x, button.maxY())));
}

void WorkspaceWindow::editCommand(const std::string& command) {
    HWND focus = GetFocus();
    EditorView& view = editor_.pane().editor();
    if (focus && focus == view.handle()) {
        if (command == "undo") view.undo();
        else if (command == "redo") view.redo();
        else if (command == "cut") view.cut();
        else if (command == "copy") view.copy();
        else if (command == "paste") view.paste();
        else if (command == "selectAll") view.selectAll();
        else if (command == "toggleComment") view.toggleComment();
        return;
    }
    if (!focus || !isTextInputFocused()) {
        MessageBeep(MB_OK);
        return;
    }
    if (command == "undo" || command == "redo") SendMessageW(focus, WM_UNDO, 0, 0);
    else if (command == "cut") SendMessageW(focus, WM_CUT, 0, 0);
    else if (command == "copy") SendMessageW(focus, WM_COPY, 0, 0);
    else if (command == "paste") SendMessageW(focus, WM_PASTE, 0, 0);
    else if (command == "selectAll") SendMessageW(focus, EM_SETSEL, 0, -1);
    else MessageBeep(MB_OK);
}

LRESULT WorkspaceWindow::handleMessage(UINT message, WPARAM wParam, LPARAM lParam) {
    if (message == WM_ACTIVATEAPP) App::shared().applicationActivated(wParam != FALSE);
    if (message == WM_DROPFILES) {
        HDROP drop = reinterpret_cast<HDROP>(wParam);
        UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
        std::vector<std::wstring> paths;
        for (UINT i = 0; i < count; ++i) {
            UINT length = DragQueryFileW(drop, i, nullptr, 0);
            std::wstring path(length + 1, L'\0');
            DragQueryFileW(drop, i, path.data(), length + 1);
            path.resize(length);
            paths.push_back(path);
        }
        DragFinish(drop);
        if (!paths.empty()) App::shared().openURLs(paths, this);
        return 0;
    }
    return WindowHost::handleMessage(message, wParam, lParam);
}

bool WorkspaceWindow::handleShortcut(const KeyEvent& e) {
    if (e.alt && !e.control) return false;
    if (e.control && e.alt && !e.shift && e.key == 'F') {
        findAndReplace();
        return true;
    }
    if (e.alt) return false;
    if (e.control && !e.shift) {
        switch (e.key) {
        case 'N': App::shared().newWindow(); return true;
        case 'O': openFolder(); return true;
        case 'P': quickOpen(); return true;
        case 'S': save(); return true;
        case 'W': closeTab(); return true;
        case 'F': findInFile(); return true;
        case 'H': findAndReplace(); return true;
        case 'L':
        case 'G': goToLine(); return true;
        case 'B': showSidebar(); return true;
        case '1': showFiles(); return true;
        case '2': findInFolder(); return true;
        case '3': showGit(); return true;
        case 'Q': App::shared().quit(); return true;
        case 'M': ShowWindow(hwnd(), SW_MINIMIZE); return true;
        case VK_OEM_COMMA: openSettings(); return true;
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
        case 'F': findInFolder(); return true;
        case 'E': showFiles(); return true;
        case 'G': showGit(); return true;
        case VK_OEM_6: selectNextTab(); return true;      // ]
        case VK_OEM_4: selectPreviousTab(); return true;  // [
        case VK_TAB: selectPreviousTab(); return true;
        default: return false;
        }
    }
    if (!e.control && !e.shift && e.key == VK_F1) {
        showAppMenu();
        return true;
    }
    return false;
}

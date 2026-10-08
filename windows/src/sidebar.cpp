#include "sidebar.h"

#include "theme.h"

// ── ProjectTitleView ───────────────────────────────────────────────────────

namespace {
Font projectFont() { return Theme::uiFont(11.5f); }
Font branchFont() { return Theme::uiFont(11); }
}  // namespace

void ProjectTitleView::configure(const std::wstring& project, const std::wstring& branch) {
    if (project == project_ && branch == branch_) return;
    project_ = project;
    branch_ = branch;
    setNeedsDisplay();
    if (superview()) superview()->setNeedsLayout();
}

float ProjectTitleView::intrinsicWidth() const {
    if (project_.empty()) return 0;
    float width = std::ceil(Text::width(project_, projectFont()));
    if (!branch_.empty()) width += branchGap + std::ceil(Text::width(branch_, branchFont()));
    return width + horizontalPadding * 2;
}

std::pair<Rect, Rect> ProjectTitleView::zones() const {
    Rect content = bounds().inset(horizontalPadding, 0);
    if (content.w <= 0 || project_.empty()) return {Rect(), Rect()};
    float projectWidth = std::min(std::ceil(Text::width(project_, projectFont())), content.w);
    Rect projectRect(content.x, content.y, projectWidth, content.h);
    if (branch_.empty()) return {projectRect, Rect()};
    float branchX = projectRect.maxX() + branchGap;
    if (branchX >= content.maxX()) return {projectRect, Rect()};
    float branchWidth = std::min(std::ceil(Text::width(branch_, branchFont())), content.maxX() - branchX);
    return {projectRect, Rect(branchX, content.y, branchWidth, content.h)};
}

ProjectTitleView::Zone ProjectTitleView::zoneAt(Point p) const {
    auto [projectRect, branchRect] = zones();
    if (!branch_.empty() && branchRect.contains(p)) return Zone::Branch;
    if (projectRect.contains(p)) return Zone::Project;
    return Zone::None;
}

void ProjectTitleView::draw(Graphics& g) {
    if (project_.empty()) return;
    auto [projectRect, branchRect] = zones();
    if (projectRect.w <= 0) return;
    // One shared baseline so the smaller branch sits on the name's line.
    float baseline = Text::centeredBaseline(projectFont(), projectRect);
    g.text(project_, projectFont(), Theme::foreground, baseline, projectRect);
    if (branchRect.w <= 0) return;
    g.text(branch_, branchFont(), Theme::dimText, baseline, branchRect, LineBreak::TruncatingHead);
}

bool ProjectTitleView::mouseDown(const MouseEvent& e) {
    if (project_.empty()) return false;
    pressed_ = zoneAt(e.location);
    return pressed_ != Zone::None;
}

void ProjectTitleView::mouseUp(const MouseEvent& e) {
    Zone pressed = pressed_;
    pressed_ = Zone::None;
    if (pressed == Zone::None || zoneAt(e.location) != pressed) return;
    // The name shows the Projects panel — the list it was chosen from; the
    // branch opens its menu.
    if (pressed == Zone::Project) {
        if (onProjectClick) onProjectClick();
    } else if (onBranchClick) {
        onBranchClick(zones().second);
    }
}

Cursor ProjectTitleView::cursorAt(Point p) {
    return zoneAt(p) != Zone::None ? Cursor::Hand : Cursor::Arrow;
}

std::wstring ProjectTitleView::tooltipAt(Point) {
    return project_.empty() ? L"" : L"Click the name for the projects, the branch to switch";
}

bool ProjectTitleView::isWindowDragArea(Point p) { return zoneAt(p) == Zone::None; }

// ── ActivityBarView ────────────────────────────────────────────────────────

namespace {
const wchar_t* const kActivityTitles[] = {L"Projects", L"Search", L"Git"};
}

void ActivityBarView::setSelected(std::optional<Action> action) {
    if (action == selected_) return;
    selected_ = action;
    setNeedsDisplay();
}

int ActivityBarView::slotAt(Point p) const {
    Rect b = bounds();
    if (!b.contains(p)) return -1;
    float slot = b.w / 3;
    return std::clamp((int)(p.x / slot), 0, 2);
}

void ActivityBarView::draw(Graphics& g) {
    Rect b = bounds();
    g.fillRect(b, Theme::activityBar);
    // The one-point top divider.
    g.fillRect(Rect(0, 0, b.w, 1), Theme::border);
    float slot = b.w / 3;
    Font font = Theme::uiFont(10.5f);
    for (int i = 0; i < 3; ++i) {
        Rect r(std::round(slot * i), 1, std::round(slot), b.h - 1);
        bool isSelected = selected_ && (int)*selected_ == i;
        if (isSelected) g.fillRect(r, Theme::selectedControl);
        // Truncates rather than overflowing into the neighbouring slot.
        g.text(kActivityTitles[i], font, isSelected ? Theme::selectedControlText : Theme::dimText, r.inset(4, 0),
               LineBreak::TruncatingTail, Align::Center);
    }
}

bool ActivityBarView::mouseDown(const MouseEvent& e) {
    int slot = slotAt(e.location);
    if (slot < 0) return false;
    if (onAction) onAction((Action)slot);
    return true;
}

// ── SidebarView ────────────────────────────────────────────────────────────

SidebarView::SidebarView() {
    backgroundColor = Theme::panelBackground;
    addSubview(&container_);
    container_.addSubview(&projectsPanel);
    addSubview(&activityBar);
    addSubview(&projectTitle);
    menuButton.symbol = Symbol::MenuLines;
    menuButton.tint = Theme::dimText;
    menuButton.symbolSize = 14;
    menuButton.hoverBackground = true;
    menuButton.tooltip = L"Menu";
    menuButton.onClick = [this] { if (onShowMenu) onShowMenu(); };
    addSubview(&menuButton);
    addProjectButton.symbol = Symbol::Plus;
    addProjectButton.tint = Theme::dimText;
    addProjectButton.symbolSize = 12;
    addProjectButton.tooltip = L"Open another project";
    addProjectButton.onClick = [this] { if (onAddProject) onAddProject(); };
    addSubview(&addProjectButton);
    terminalButton.symbol = Symbol::Prompt;
    terminalButton.tint = Theme::dimText;
    terminalButton.symbolSize = 14;
    terminalButton.tooltip = L"Open this project in a terminal";
    terminalButton.onClick = [this] { if (onOpenTerminal) onOpenTerminal(); };
    addSubview(&terminalButton);

    projectsPanel.onSelect = [this](int i) { if (onSelectProjectRow) onSelectProjectRow(i); };
    projectsPanel.onClose = [this](int i) { if (onCloseProjectRow) onCloseProjectRow(i); };
    projectsPanel.onSelectBranch = [this](int i) { if (onSelectProjectBranchRow) onSelectProjectBranchRow(i); };
    projectsPanel.onPull = [this](int i) { if (onPullProjectRow) onPullProjectRow(i); };
    projectsPanel.onReorder = [this](int from, int to) {
        if (onReorderProjectRows) onReorderProjectRows(from, to);
    };
    // The changes column opens a diff the same way the Git panel's list does.
    projectsPanel.changes.onOpenDiff = [this](const Git::StatusEntry& entry, const std::wstring& dir) {
        if (onGitDiff) onGitDiff(entry, dir);
    };
    // A commit or push from the line over the changes moves everything that
    // reads the repository, the Git panel included.
    projectsPanel.changes.onChanged = [this](const std::wstring& dir) {
        if (onProjectGitChanged) onProjectGitChanged(dir);
    };
    projectsPanel.changes.onOpenFile = [this](const std::wstring& path) { if (onGitFile) onGitFile(path); };
    projectsPanel.history.onOpenFile = [this](const std::wstring& path) { if (onGitFile) onGitFile(path); };
    projectsPanel.history.onOpenCommitDiff = [this](const Git::Commit& commit, const Git::CommitFile& file,
                                                    const std::wstring& dir) {
        if (onGitCommitDiff) onGitCommitDiff(commit, file, dir);
    };
    showFiles();
}

SidebarView::~SidebarView() = default;

void SidebarView::setTabRowHeight(float height) {
    if (height == tabRowHeight_) return;
    tabRowHeight_ = height;
    setNeedsLayout();
}

void SidebarView::setTitlebarLeadingInset(float inset) {
    if (inset == leadingInset_) return;
    leadingInset_ = inset;
    setNeedsLayout();
}

void SidebarView::layout() {
    Rect b = bounds();
    float band = tabRowHeight_;
    menuButton.setFrame(Rect(6, std::round((band - 26) / 2), 32, 26));
    float buttonY = std::round((band - 20) / 2);
    terminalButton.setFrame(Rect(b.w - 8 - 22, buttonY, 22, 20));
    addProjectButton.setFrame(Rect(terminalButton.frame().x - 2 - 22, buttonY, 22, 20));
    // The name truncates rather than pushing the buttons off the end.
    float titleMax = std::max(0.0f, addProjectButton.frame().x - 6 - leadingInset_);
    projectTitle.setFrame(Rect(leadingInset_, 0, std::min(projectTitle.intrinsicWidth(), titleMax), band));
    float barY = std::max(band, b.h - ActivityBarView::height);
    activityBar.setFrame(Rect(0, barY, b.w, b.h - barY));
    container_.setFrame(Rect(0, band, b.w, std::max(0.0f, barY - band)));
    Rect inner = container_.bounds();
    projectsPanel.setFrame(inner);
    if (search_) search_->setFrame(inner);
    if (git_) git_->setFrame(inner);
}

void SidebarView::draw(Graphics& g) {
    // The 1pt line under the title band.
    g.fillRect(Rect(0, tabRowHeight_ - 1, bounds().w, 1), Theme::border);
}

void SidebarView::setProjectTitle(const std::wstring& project, const std::wstring& branch) {
    projectTitle.configure(project, branch);
    setNeedsLayout();
}

void SidebarView::setDirectory(const std::optional<std::wstring>& directory) {
    directory_ = directory;
    if (search_) search_->setDirectory(directory);
    if (git_) git_->setDirectory(directory);
}

void SidebarView::setProjects(const std::vector<ProjectRowInfo>& projects, std::optional<int> active) {
    projectsPanel.configure(projects, active);
}

void SidebarView::setSyncingProjects(const std::set<std::wstring>& paths) {
    projectsPanel.setSyncing(paths);
}

/// What the project on screen has changed, for the column beside its tree, and
/// where it stands — the history is re-read only when something it shows moved.
void SidebarView::setChanges(const std::vector<Git::StatusEntry>& entries,
                             const std::optional<std::wstring>& directory,
                             const ProjectHistoryView::State& state) {
    projectsPanel.changes.setEntries(entries, directory, state.ahead, state.hasUpstream);
    projectsPanel.history.setSource(directory, state);
}

void SidebarView::clearChanges(const std::optional<std::wstring>& directory) {
    projectsPanel.changes.setEntries({}, directory);
    projectsPanel.history.prepare(directory);
}

void SidebarView::reveal(View* panel) {
    projectsPanel.setHidden(panel != &projectsPanel);
    if (search_) search_->setHidden(panel != search_.get());
    if (git_) git_->setHidden(panel != git_.get());
    setNeedsLayout();
}

void SidebarView::showFiles() {
    visiblePanel_ = Panel::Project;
    reveal(&projectsPanel);
    activityBar.setSelected(Panel::Project);
}

void SidebarView::showSearch() {
    SearchPanel& search = ensureSearch();
    visiblePanel_ = Panel::Search;
    reveal(&search);
    activityBar.setSelected(Panel::Search);
    layoutSubtreeIfNeeded();
    search.focusSearchField();
}

void SidebarView::showGit() {
    GitPanel& git = ensureGit();
    visiblePanel_ = Panel::Git;
    reveal(&git);
    activityBar.setSelected(Panel::Git);
}

void SidebarView::showGitBranches() {
    showGit();
    if (git_) git_->showBranchTab();
}

void SidebarView::refreshFonts() {
    backgroundColor = Theme::panelBackground;
    activityBar.setNeedsDisplay();
    projectTitle.setNeedsDisplay();
    projectsPanel.fileTree.refreshAppearance();
    if (search_) search_->refreshFonts();
    if (git_) git_->refreshFonts();
    projectsPanel.changes.refreshFonts();
    projectsPanel.history.refreshFonts();
    setNeedsLayout();
    setNeedsDisplay();
}

void SidebarView::refreshGitPanelIfLoaded() {
    if (git_) git_->refreshExternal();
}

void SidebarView::releaseHiddenPanels() {
    if (visiblePanel_ != Panel::Search && search_) {
        search_->releaseTransientMemory();
        retireView(std::move(search_));
    }
    if (visiblePanel_ != Panel::Git && git_) {
        git_->releaseTransientMemory();
        retireView(std::move(git_));
    }
}

SearchPanel& SidebarView::ensureSearch() {
    if (search_) return *search_;
    search_ = std::make_unique<SearchPanel>();
    search_->onOpenResult = [this](const std::wstring& path, int line) {
        if (onSearchResult) onSearchResult(path, line);
    };
    search_->onOpenFile = [this](const std::wstring& path) { if (onSearchFile) onSearchFile(path); };
    if (directory_) search_->setDirectory(directory_);
    search_->setHidden(true);
    container_.addSubview(search_.get());
    setNeedsLayout();
    return *search_;
}

GitPanel& SidebarView::ensureGit() {
    if (git_) return *git_;
    git_ = std::make_unique<GitPanel>();
    git_->onOpenFile = [this](const std::wstring& path) { if (onGitFile) onGitFile(path); };
    git_->onOpenDiff = [this](const Git::StatusEntry& entry, const std::wstring& dir) {
        if (onGitDiff) onGitDiff(entry, dir);
    };
    git_->onOpenCommitDiff = [this](const Git::Commit& commit, const Git::CommitFile& file, const std::wstring& dir) {
        if (onGitCommitDiff) onGitCommitDiff(commit, file, dir);
    };
    git_->onChanged = [this] { if (onGitChanged) onGitChanged(); };
    if (directory_) git_->setDirectory(directory_);
    git_->setHidden(true);
    container_.addSubview(git_.get());
    setNeedsLayout();
    return *git_;
}

void SidebarView::performSearch(const std::wstring& query) { ensureSearch().performSearch(query); }
void SidebarView::showHistory() { ensureGit().showHistory(); }
void SidebarView::expandCommit(int index) { ensureGit().expandCommit(index); }
void SidebarView::openCommitFile(int commitIndex, int fileIndex) {
    ensureGit().openCommitFile(commitIndex, fileIndex);
}

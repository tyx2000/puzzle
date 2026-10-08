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
    if (pressed != Zone::Branch || zoneAt(e.location) != Zone::Branch) return;
    if (onBranchClick) onBranchClick(zones().second);
}

Cursor ProjectTitleView::cursorAt(Point p) {
    return zoneAt(p) == Zone::Branch ? Cursor::Hand : Cursor::Arrow;
}

std::wstring ProjectTitleView::tooltipAt(Point) {
    return branch_.empty() ? L"" : L"Click the branch to switch, create or delete one";
}

bool ProjectTitleView::isWindowDragArea(Point p) { return zoneAt(p) != Zone::Branch; }

// ── SidebarView ────────────────────────────────────────────────────────────

SidebarView::SidebarView() {
    backgroundColor = Theme::panelBackground;
    addSubview(&projectsPanel);
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
    projectsPanel.onPull = [this](int i) { if (onPullProjectRow) onPullProjectRow(i); };
    projectsPanel.onReorder = [this](int from, int to) {
        if (onReorderProjectRows) onReorderProjectRows(from, to);
    };
    projectsPanel.changes.onOpenDiff = [this](const Git::StatusEntry& entry, const std::wstring& dir) {
        if (onGitDiff) onGitDiff(entry, dir);
    };
    projectsPanel.changes.onChanged = [this](const std::wstring& dir) {
        if (onProjectGitChanged) onProjectGitChanged(dir);
    };
    projectsPanel.history.onOpenCommitDiff = [this](const Git::Commit& commit,
                                                    const Git::CommitFile& file,
                                                    const std::wstring& dir) {
        if (onGitCommitDiff) onGitCommitDiff(commit, file, dir);
    };
}

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
    projectsPanel.setFrame(Rect(0, band, b.w, std::max(0.0f, b.h - band)));
}

void SidebarView::draw(Graphics& g) {
    // The 1pt line under the title band.
    g.fillRect(Rect(0, tabRowHeight_ - 1, bounds().w, 1), Theme::border);
}

void SidebarView::setProjectTitle(const std::wstring& project, const std::wstring& branch) {
    projectTitle.configure(project, branch);
    setNeedsLayout();
}

void SidebarView::setProjects(const std::vector<ProjectRowInfo>& projects, std::optional<int> active,
                              std::optional<bool> isRepository) {
    projectsPanel.configure(projects, active, isRepository);
}

void SidebarView::setSyncingProjects(const std::set<std::wstring>& paths) {
    projectsPanel.setSyncing(paths);
}

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

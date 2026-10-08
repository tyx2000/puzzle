#include "projectspanel.h"

#include "celldrawing.h"
#include "prefs.h"
#include "theme.h"

namespace {
Font nameFont() { return Theme::uiFont(12); }

bool reducesMotion() {
    BOOL animations = TRUE;
    SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0, &animations, 0);
    return !animations;
}

constexpr wchar_t kGitDividerKey[] = L"projects_panel_git_divider";
}  // namespace

// ── ProjectRowView ─────────────────────────────────────────────────────────

ProjectRowView::ProjectRowView() { clipsToBounds = true; }

void ProjectRowView::configure(const ProjectRowInfo& info, bool isActive) {
    info_ = info;
    isActive_ = isActive;
    setNeedsDisplay();
}

void ProjectRowView::setShowsDivider(bool on) {
    if (on == showsDivider_) return;
    showsDivider_ = on;
    setNeedsDisplay();
}

float ProjectRowView::columnDivider() const {
    float start = markerWidth + 6 + iconSize + iconGap;
    float natural = std::ceil(Text::width(info_.name, nameFont()));
    return std::min(start + natural + 14, std::round(bounds().w / 2));
}

Rect ProjectRowView::closeRect() const {
    Rect b = bounds();
    return Rect(b.w - closeWidth - closeInset, (b.h - closeWidth) / 2, closeWidth, closeWidth);
}

Rect ProjectRowView::nameIconRect() const {
    return Rect(markerWidth + 6, (bounds().h - iconSize) / 2, iconSize, iconSize);
}

Rect ProjectRowView::branchIconRect() const {
    return Rect(columnDivider() + 8, (bounds().h - iconSize) / 2, iconSize, iconSize);
}

Rect ProjectRowView::pullRect() const {
    if (info_.branch.empty() || !onPull) return {};
    return branchIconRect().inset(-3, -5);
}

Rect ProjectRowView::nameRect() const {
    float x = nameIconRect().maxX() + iconGap;
    return Rect(x, 0, std::max(0.0f, columnDivider() - x - 6), bounds().h);
}

Rect ProjectRowView::branchColumnRect() const {
    float x = branchIconRect().maxX() + iconGap;
    return Rect(x, 0, std::max(0.0f, bounds().w - closeWidth - closeInset - 4 - x), bounds().h);
}

std::wstring ProjectRowView::pullHint() const {
    return isSyncing_ ? L"Syncing with the remote…" : L"Pull from the remote (fast-forward only)";
}

void ProjectRowView::draw(Graphics& g) {
    Rect b = bounds();
    // The project being shown carries a band; the row under the pointer does
    // not.
    if (isActive_) g.fillRect(b, Theme::selectedControl);
    if (showsDivider_) g.fillRect(Rect(0, 0, b.w, 1), Theme::border);
    if (isActive_) g.fillRect(Rect(0, 0, markerWidth, b.h), Theme::accent);
    Color ink = isActive_ ? Theme::selectedControlText : Theme::foreground;
    Font font = nameFont();
    FileIcons::draw(g, "folder-base", nameIconRect());
    Rect name = nameRect();
    float baseline = Text::centeredBaseline(font, b);
    g.text(info_.name, font, ink, baseline, name);

    if (!info_.branch.empty()) {
        drawGitMark(g, branchIconRect());
        // The branch, then who commits there (dimmed), then the count of
        // changed files as the sidebar's round badge — one line that gives
        // way at its end.
        Rect column = branchColumnRect();
        float x = column.x;
        float right = column.maxX();
        float gapWidth = Text::width(L"  ", font);
        float branchWidth = Text::width(info_.branch, font);
        if (x + branchWidth > right) {
            g.text(info_.branch, font, ink, baseline, Rect(x, 0, right - x, b.h));
        } else {
            g.text(info_.branch, font, ink, baseline, Rect(x, 0, branchWidth + 2, b.h),
                   LineBreak::Clipping);
            x += branchWidth;
            bool fits = true;
            if (!info_.user.empty()) {
                x += gapWidth;
                float userWidth = Text::width(info_.user, font);
                if (x + userWidth > right) {
                    g.text(info_.user, font, Theme::dimText, baseline,
                           Rect(x, 0, std::max(0.0f, right - x), b.h));
                    fits = false;
                } else {
                    g.text(info_.user, font, Theme::dimText, baseline, Rect(x, 0, userWidth + 2, b.h),
                           LineBreak::Clipping);
                    x += userWidth;
                }
            }
            if (fits && info_.changes > 0) {
                std::wstring count = std::to_wstring(info_.changes);
                float d = Badge::diameter(count, font);
                x += gapWidth;
                if (x + d <= right) {
                    // On the row being shown the band is already the badge's
                    // usual colour.
                    Color ground = isActive_ ? Theme::panelBackground : Theme::activeRow;
                    Badge::draw(g, count, Point(x + d / 2, baseline - font.capHeight() / 2), font,
                                ground, Theme::foreground);
                }
            }
        }
    }

    // Always there, so the name's room never changes as the pointer moves.
    Color closeInk = closeHovered_ ? Theme::foreground : Theme::dimText.withAlpha(0.7f);
    drawSymbol(g, Symbol::XMark, closeRect().inset(4, 4), closeInk, 0.85f);
}

void ProjectRowView::drawGitMark(Graphics& g, const Rect& rect) {
    Rect fitted = g.snapped(rect);
    ID2D1Bitmap* icon = FileIcons::bitmap("git", fitted, g.scale());
    if (!icon) return;
    g.drawBitmap(icon, fitted);
    if (!isSyncing_) return;
    // Dimmed while its project syncs, with a band of light running down it.
    g.fillMask(icon, fitted, Color(0, 0, 0, 0.3f));
    auto phase = sweepPhase();
    if (!phase) return;
    float band = fitted.h * 0.8f;
    Color light = Theme::accent.blended(0.55f, Color(1, 1, 1));
    Rect bandRect(fitted.x, fitted.y - band + (fitted.h + band) * *phase, fitted.w, band);
    g.fillMaskGradient(icon, fitted, bandRect,
                       {{0, light.withAlpha(0)}, {0.5f, light.withAlpha(0.9f)}, {1, light.withAlpha(0)}},
                       true);
}

void ProjectRowView::mouseMoved(const MouseEvent& e) {
    bool onClose = closeRect().inset(-4, -4).contains(e.location);
    bool onPullMark = !onClose && pullRect().contains(e.location);
    if (onClose == closeHovered_ && onPullMark == pullHovered_) return;
    closeHovered_ = onClose;
    pullHovered_ = onPullMark;
    setNeedsDisplay();
}

void ProjectRowView::mouseExited() {
    if (!closeHovered_ && !pullHovered_) return;
    closeHovered_ = false;
    pullHovered_ = false;
    setNeedsDisplay();
}

Cursor ProjectRowView::cursorAt(Point p) {
    return pullRect().contains(p) ? Cursor::Hand : Cursor::Arrow;
}

std::wstring ProjectRowView::tooltipAt(Point p) {
    if (closeRect().inset(-4, -4).contains(p)) return L"Close this project";
    if (pullRect().contains(p)) return pullHint();
    return info_.path;
}

bool ProjectRowView::mouseDown(const MouseEvent& e) {
    dragging_ = false;
    pressedClose_ = false;
    // The ✕ takes the click, so closing never also selects.
    if (closeRect().inset(-4, -4).contains(e.location)) {
        pressedClose_ = true;
        if (onClose) onClose();
        return true;
    }
    // Selection waits for the release: a press that turns into a drag is
    // carrying the row to another place in the list.
    pressStart_ = e.location;
    pressStartInWindow_ = e.windowLocation;
    return true;
}

void ProjectRowView::mouseDragged(const MouseEvent& e) {
    if (pressedClose_) return;
    float travelled = e.windowLocation.y - pressStartInWindow_.y;
    if (!dragging_) {
        if (std::abs(travelled) <= 4 || !onDragBegan || !onDragBegan()) return;
        dragging_ = true;
    }
    if (onDragMoved) onDragMoved(travelled);
}

void ProjectRowView::mouseUp(const MouseEvent& e) {
    if (pressedClose_) {
        pressedClose_ = false;
        return;
    }
    if (dragging_) {
        dragging_ = false;
        if (onDragEnded) onDragEnded();
        return;
    }
    // A press let go somewhere else was abandoned.
    if (!bounds().contains(e.location)) return;
    if (pullRect().contains(pressStart_) && onPull) onPull();
    else if (onSelect) onSelect();
}

void ProjectRowView::setSyncing(bool syncing) {
    if (syncing == isSyncing_) return;
    isSyncing_ = syncing;
    syncingChanged();
}

void ProjectRowView::syncingChanged() {
    if (isSyncing_ && window() && !reducesMotion()) {
        if (!sweepTimer_.running()) {
            sweepStarted_ = monotonicNow();
            sweepTimer_.start(1.0 / 60.0, [this] { setNeedsDisplay(branchIconRect()); });
        }
    } else {
        sweepTimer_.stop();
        sweepStarted_.reset();
    }
    setNeedsDisplay(branchIconRect());
}

std::optional<float> ProjectRowView::sweepPhase() const {
    if (!sweepStarted_) return std::nullopt;
    double elapsed = monotonicNow() - *sweepStarted_;
    return (float)(std::fmod(elapsed, sweepPeriod) / sweepPeriod);
}

// ── ProjectColumnsView ─────────────────────────────────────────────────────

float ProjectColumnsView::divider(float fraction, float length, float minimum) {
    if (length <= minimum * 2 + 1) return std::round(length / 2);
    return std::min(std::max(std::round(fraction * length), minimum), length - minimum - 1);
}

float ProjectColumnsView::span() const {
    return axis == Axis::Horizontal ? bounds().w : bounds().h;
}

float ProjectColumnsView::dividerPosition() const {
    return showsSecond ? divider(fraction, span(), minimumPane) : span();
}

float ProjectColumnsView::position(Point p) const { return axis == Axis::Horizontal ? p.x : p.y; }

bool ProjectColumnsView::isOnGrabBand(Point p) const {
    return showsSecond && bounds().contains(p) && std::abs(position(p) - dividerPosition()) <= 3;
}

Rect ProjectColumnsView::dividerRect(float radius) const {
    float d = dividerPosition();
    float thickness = radius * 2 + 1;
    Rect b = bounds();
    if (axis == Axis::Horizontal) return Rect(d - radius, 0, thickness, b.h);
    return Rect(0, d - radius, b.w, thickness);
}

Rect ProjectColumnsView::firstPaneRect() const {
    Rect b = bounds();
    float d = dividerPosition();
    if (axis == Axis::Horizontal) return Rect(0, 0, d, b.h);
    return Rect(0, 0, b.w, d);
}

Rect ProjectColumnsView::secondPaneRect() const {
    Rect b = bounds();
    float d = dividerPosition();
    if (axis == Axis::Horizontal) return Rect(d + 1, 0, std::max(0.0f, b.w - d - 1), b.h);
    return Rect(0, d + 1, b.w, std::max(0.0f, b.h - d - 1));
}

Rect ProjectColumnsView::content(const Rect& pane, bool bordered) {
    if (!bordered) return pane;
    return Rect(pane.x + borderWidth, pane.y + borderWidth, std::max(0.0f, pane.w - borderWidth * 2),
                std::max(0.0f, pane.h - borderWidth * 2));
}

void ProjectColumnsView::layout() {
    if (second) second->setHidden(!showsSecond);
    if (first) first->setFrame(content(firstPaneRect(), !firstBorder.isClear()));
    if (showsSecond && second) second->setFrame(content(secondPaneRect(), !secondBorder.isClear()));
}

void ProjectColumnsView::draw(Graphics& g) {
    // Two coloured borders meeting already separate the panes; a grey line
    // between them would be a third edge saying the same thing.
    if (showsSecond && firstBorder.isClear() && secondBorder.isClear()) {
        g.fillRect(dividerRect(0), Theme::border);
    }
    Rect firstPane = firstPaneRect();
    if (!firstBorder.isClear() && !firstPane.isEmpty()) g.strokeRect(firstPane, firstBorder, borderWidth);
    Rect secondPane = secondPaneRect();
    if (showsSecond && !secondBorder.isClear() && !secondPane.isEmpty()) {
        g.strokeRect(secondPane, secondBorder, borderWidth);
    }
}

View* ProjectColumnsView::hitTest(Point p) {
    if (isHidden()) return nullptr;
    // The grab band lies over the two lists, so the press that moves the line
    // is claimed before a list swallows it.
    if (isOnGrabBand(p)) return this;
    return View::hitTest(p);
}

bool ProjectColumnsView::mouseDown(const MouseEvent& e) {
    tracking_ = isOnGrabBand(e.location);
    return tracking_;
}

void ProjectColumnsView::mouseDragged(const MouseEvent& e) {
    if (tracking_) moveDivider(position(e.location));
}

Cursor ProjectColumnsView::cursorAt(Point p) {
    if (!isOnGrabBand(p) && !tracking_) return Cursor::Arrow;
    return axis == Axis::Horizontal ? Cursor::ResizeLeftRight : Cursor::ResizeUpDown;
}

bool ProjectColumnsView::scrollWheel(float dx, float dy, const MouseEvent& e) {
    // A scroll landing on the band belongs to the list under it.
    if (!isOnGrabBand(e.location)) return false;
    View* pane = position(e.location) <= dividerPosition() ? first : second;
    if (!pane) return false;
    Point local(e.location.x - pane->frame().x, e.location.y - pane->frame().y);
    View* target = pane->hitTest(local);
    MouseEvent forwarded = e;
    for (View* v = target; v; v = v->superview()) {
        forwarded.location = v->convertFromWindow(e.windowLocation);
        if (v->scrollWheel(dx, dy, forwarded)) return true;
        if (v == pane) break;
    }
    return true;
}

void ProjectColumnsView::moveDivider(float along) {
    float length = span();
    if (length <= 0) return;
    float next = divider(along / length, length, minimumPane) / length;
    if (next == fraction) return;
    fraction = next;
    setNeedsLayout();
    setNeedsDisplay();
    if (onFractionChanged) onFractionChanged(next);
}

// ── ProjectsPanel ──────────────────────────────────────────────────────────

ProjectsPanel::ProjectsPanel() {
    backgroundColor = Theme::panelBackground;
    detail_.fillColor = Theme::panelBackground;
    gitColumn_.axis = ProjectColumnsView::Axis::Vertical;
    gitColumn_.minimumPane = ProjectColumnsView::minimumRow;
    gitColumn_.first = &changes;
    gitColumn_.second = &history;
    gitColumn_.addSubview(&changes);
    gitColumn_.addSubview(&history);
    // One hue per region, drawn inside it: what has changed, and what has
    // been committed.
    gitColumn_.firstBorder = ProjectColumnsView::regionBorder(Theme::orange);
    gitColumn_.secondBorder = ProjectColumnsView::regionBorder(Theme::purple);
    auto stored = Prefs::number(kGitDividerKey);
    gitColumn_.fraction = (stored && *stored > 0.05 && *stored < 0.95) ? (float)*stored : 0.5f;
    gitColumn_.onFractionChanged = [](float fraction) { Prefs::setNumber(kGitDividerKey, fraction); };
    notRepository_.text = L"Not a Git repository";
    notRepository_.font = Theme::uiFont(12);
    notRepository_.color = Theme::dimText;
    notRepository_.align = Align::Center;
    detail_.addSubview(&gitColumn_);
    detail_.addSubview(&notRepository_);
    addSubview(&detail_);
    arranged_ = {&detail_};
    showRegions(std::nullopt);
}

ProjectsPanel::~ProjectsPanel() { animationTimer_.stop(); }

void ProjectsPanel::setSyncing(const std::set<std::wstring>& paths) {
    syncingPaths_ = paths;
    for (auto& row : rows_) row->setSyncing(paths.count(row->projectPath()) > 0);
}

void ProjectsPanel::showRegions(std::optional<bool> isRepository) {
    gitColumn_.setHidden(isRepository != true);
    notRepository_.setHidden(isRepository != false);
}

void ProjectsPanel::configure(const std::vector<ProjectRowInfo>& projects, std::optional<int> active,
                              std::optional<bool> isRepository) {
    // A refresh landing in the middle of a row drag waits until the row is
    // put down.
    if (draggingRow_) {
        pendingConfiguration_ = Pending{projects, active, isRepository};
        return;
    }
    std::vector<std::wstring> identity;
    for (auto& project : projects) identity.push_back(project.path + L"|" + project.branch);
    if (identity != shown_) {
        shown_ = identity;
        for (auto& row : rows_) {
            arranged_.erase(std::remove(arranged_.begin(), arranged_.end(), row.get()), arranged_.end());
            retireView(std::move(row));
        }
        rows_.clear();
        for (size_t index = 0; index < projects.size(); ++index) {
            auto row = std::make_unique<ProjectRowView>();
            int i = (int)index;
            row->onSelect = [this, i] { if (onSelect) onSelect(i); };
            row->onClose = [this, i] { if (onClose) onClose(i); };
            row->onPull = [this, i] { if (onPull) onPull(i); };
            ProjectRowView* raw = row.get();
            row->onDragBegan = [this, raw] { return beginRowDrag(raw); };
            row->onDragMoved = [this, raw](float travel) { rowDragMoved(raw, travel); };
            row->onDragEnded = [this] { endRowDrag(); };
            rows_.push_back(std::move(row));
        }
    }
    for (size_t index = 0; index < projects.size() && index < rows_.size(); ++index) {
        rows_[index]->configure(projects[index], active && *active == (int)index);
        // Between rows only: not under the project whose lists follow it.
        rows_[index]->setShowsDivider(index > 0);
        rows_[index]->setSyncing(syncingPaths_.count(projects[index].path) > 0);
    }
    activeIndex_ = active;
    showRegions(active ? isRepository : std::nullopt);
    layOut(active);
}

std::vector<Rect> ProjectsPanel::targetFrames() const {
    std::vector<Rect> frames;
    Rect b = bounds();
    float rowsHeight = rows_.size() * ProjectRowView::height;
    float y = 0;
    for (View* view : arranged_) {
        float h = view == &detail_ ? std::max(0.0f, b.h - rowsHeight) : ProjectRowView::height;
        frames.push_back(Rect(0, y, b.w, h));
        y += h;
    }
    return frames;
}

void ProjectsPanel::layOut(std::optional<int> active) {
    std::vector<View*> desired;
    for (size_t index = 0; index < rows_.size(); ++index) {
        desired.push_back(rows_[index].get());
        if (active && *active == (int)index) desired.push_back(&detail_);
    }
    // No project: the space under the rows is still taken, empty.
    if (!active || rows_.empty()) desired.push_back(&detail_);
    if (desired == arranged_) {
        setNeedsLayout();
        return;
    }
    bool hadRows = false;
    for (View* view : arranged_) hadRows = hadRows || view != &detail_;
    std::map<View*, Rect> from;
    for (View* view : desired) {
        if (std::find(arranged_.begin(), arranged_.end(), view) != arranged_.end()
            && view->superview() == this) {
            from[view] = view->frame();
        }
    }
    arranged_ = desired;
    for (View* view : arranged_) {
        if (view->superview() != this) addSubview(view);
    }
    // The rows below the chosen project travel the height of a whole list;
    // sliding reads as the one project opening. A window filling for the
    // first time finds its project already there.
    if (hadRows) {
        animationFrom_ = from;
        animationStart_ = monotonicNow();
        animationTimer_.start(1.0 / 60.0, [this] {
            setNeedsLayout();
            if (monotonicNow() - animationStart_ >= switchDuration) {
                animationTimer_.stop();
                animationFrom_.clear();
                setNeedsLayout();
            }
        });
    } else {
        animationTimer_.stop();
        animationFrom_.clear();
    }
    setNeedsLayout();
}

void ProjectsPanel::layout() {
    auto frames = targetFrames();
    double t = animationFrom_.empty() ? 1.0 : (monotonicNow() - animationStart_) / switchDuration;
    t = std::clamp(t, 0.0, 1.0);
    float eased = (float)(t * t * (3 - 2 * t));
    for (size_t i = 0; i < arranged_.size() && i < frames.size(); ++i) {
        View* view = arranged_[i];
        Rect target = frames[i];
        auto from = animationFrom_.find(view);
        if (from != animationFrom_.end() && t < 1.0) {
            const Rect& a = from->second;
            target = Rect(a.x + (target.x - a.x) * eased, std::round(a.y + (target.y - a.y) * eased),
                          a.w + (target.w - a.w) * eased, std::round(a.h + (target.h - a.h) * eased));
        }
        view->setFrame(target);
    }
    Rect detail = detail_.bounds();
    gitColumn_.setFrame(detail);
    float labelWidth = std::min(detail.w, notRepository_.fittingWidth() + 4);
    notRepository_.setFrame(Rect(std::round((detail.w - labelWidth) / 2), 24, labelWidth, 20));
}

bool ProjectsPanel::canReorder() const { return !activeIndex_ && rows_.size() > 1; }

bool ProjectsPanel::beginRowDrag(ProjectRowView* row) {
    if (!canReorder()) return false;
    auto it = std::find(arranged_.begin(), arranged_.end(), row);
    if (it == arranged_.end()) return false;
    draggingRow_ = row;
    dragStartIndex_ = (int)(it - arranged_.begin());
    animationTimer_.stop();
    animationFrom_.clear();
    return true;
}

void ProjectsPanel::rowDragMoved(ProjectRowView* row, float travel) {
    if (draggingRow_ != row) return;
    // Counted in whole rows travelled: reordering is only offered with every
    // project collapsed, so the rows are a contiguous run of one height.
    int moved = (int)std::lround(travel / ProjectRowView::height);
    int slot = std::clamp(dragStartIndex_ + moved, 0, (int)rows_.size() - 1);
    auto it = std::find(arranged_.begin(), arranged_.end(), row);
    if (it == arranged_.end() || (int)(it - arranged_.begin()) == slot) return;
    arranged_.erase(it);
    arranged_.insert(arranged_.begin() + slot, row);
    setNeedsLayout();
    if (WindowHost* host = window()) host->displayIfNeeded();
}

void ProjectsPanel::endRowDrag() {
    ProjectRowView* row = draggingRow_;
    draggingRow_ = nullptr;
    auto pending = pendingConfiguration_;
    pendingConfiguration_.reset();
    if (row) {
        auto it = std::find(arranged_.begin(), arranged_.end(), row);
        int landed = (int)(it - arranged_.begin());
        if (it != arranged_.end() && landed != dragStartIndex_) {
            // The reorder redraws the list from the model, which already holds
            // anything the deferred refresh would have said.
            if (onReorder) onReorder(dragStartIndex_, landed);
            return;
        }
    }
    if (pending) configure(pending->projects, pending->active, pending->isRepository);
}

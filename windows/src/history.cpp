#include "history.h"

#include "celldrawing.h"
#include "menu.h"
#include "services.h"
#include "theme.h"

int ProjectHistoryView::pageSize = 200;

namespace {
Font subjectFont() { return Theme::uiFont(11); }
Font metaFont() { return Theme::uiFont(9.5f); }

Color statusColor(const std::string& status) {
    if (status == "A") return Theme::green;
    if (status == "D") return Theme::red;
    if (status == "R") return Theme::blue;
    return Theme::yellow;  // M and friends
}

struct Boxes {
    Rect commitID, subject, author, date;
};

Boxes layoutColumns(const ProjectHistoryView::Columns& columns, const Rect& content) {
    using V = ProjectHistoryView;
    float fixedSum = 0;
    int fixedCount = 0;
    for (float w : {columns.commitID, columns.author, columns.date}) {
        if (w > 0) {
            fixedSum += w;
            ++fixedCount;
        }
    }
    float gaps = fixedCount * V::columnGap;
    // Too narrow for every column: the author gives way before the message
    // goes below its minimum.
    float shortfall = fixedSum + gaps + V::minimumSubjectWidth - content.w;
    float author = columns.author
        - std::min(std::max(0.0f, shortfall), std::max(0.0f, columns.author - V::minimumSqueezedWidth));
    auto box = [&](float x, float w) { return Rect(x, content.y, std::max(0.0f, w), content.h); };
    float x = content.x;
    Rect idBox = box(x, columns.commitID);
    if (columns.commitID > 0) x += columns.commitID + V::columnGap;
    float right = content.maxX();
    Rect dateBox = box(right - columns.date, columns.date);
    if (columns.date > 0) right -= columns.date + V::columnGap;
    Rect authorBox = box(right - author, author);
    if (author > 0) right -= author + V::columnGap;
    return Boxes{idBox, box(x, right - x), authorBox, dateBox};
}
}  // namespace

ProjectHistoryView::ProjectHistoryView() {
    backgroundColor = Theme::panelBackground;
    limit_ = pageSize;
    addSubview(&list_);
    list_.rowHeight = Theme::treeRowHeight();
    // Deeply branched histories keep distinct lanes; past the width beside
    // the text, the list scrolls sideways rather than folding tracks.
    list_.hasHorizontalScroller = true;
    list_.numberOfRows = [this] { return (int)rows_.size(); };
    list_.rowBackground = [this](int row) {
        if (row == list_.hoveredRow()) return Theme::hover;
        return row % 2 == 1 ? Theme::stripedRow : Theme::panelBackground;
    };
    list_.drawRow = [this](Graphics& g, int row, const Rect& rect) { drawRow(g, row, rect); };
    list_.tooltipForRow = [this](int row, Point) -> std::wstring {
        if (row < 0 || row >= (int)rows_.size() || !rows_[row].isFile) return L"";
        return W(rows_[row].file.path);
    };
    list_.onClick = [this](int row) { act(row); };
    list_.onContextMenu = [this](int row, POINT screen) { showContextMenu(row, screen); };
    list_.onScroll = [this] { scrolled(); };
}

void ProjectHistoryView::layout() { list_.setFrame(bounds()); }

float ProjectHistoryView::metaWidth(const std::wstring& text) {
    if (text.empty()) return 0;
    // A point of slack over the measured advance, which rounds a hair under
    // what is drawn.
    return std::ceil(Text::width(text, metaFont())) + 2;
}

std::wstring ProjectHistoryView::authorText(const Git::Commit& commit, bool pending) {
    return pending ? L"↑ " + W(commit.author) : W(commit.author);
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
    limit_ = pageSize;
    hasMore_ = true;
    commits_.clear();
    refs_.clear();
    unpushed_.clear();
    columns_ = Columns();
    graphRows_.clear();
    graphWidth_ = 0;
    expanded_.clear();
    files_.clear();
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
        auto log = Git::log(directory, wanted);
        auto pending = Git::unpushedHashes(directory);
        auto trunk = Git::historyGraphTrunk(directory);
        auto graph = std::make_shared<HistoryGraph>(log, trunk);
        Dispatch::main([this, alive, directory, wanted, log, pending, graph] {
            if (alive.expired()) return;
            loading_ = false;
            if (directory_ && *directory_ == directory) {
                commits_ = log;
                hasMore_ = (int)log.size() >= wanted;
                unpushed_ = pending;
                refs_.clear();
                for (auto& commit : commits_) refs_.push_back(commit.refDecorations());
                graphRows_.clear();
                for (size_t i = 0; i < commits_.size() && i < graph->rows.size(); ++i) {
                    graphRows_[commits_[i].graphID()] = graph->rows[i];
                }
                graphWidth_ = HistoryGraphDrawing::columnWidth(graph->laneCount);
                Columns measured;
                for (auto& commit : commits_) {
                    measured.commitID = std::max(measured.commitID, metaWidth(W(commit.shortHash)));
                    measured.author = std::max(
                        measured.author, metaWidth(authorText(commit, isUnpushed(commit.shortHash))));
                    measured.date = std::max(measured.date, metaWidth(W(commit.absoluteDate)));
                }
                columns_ = measured;
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

void ProjectHistoryView::scrolled() {
    if (!hasMore_ || loading_ || !directory_) return;
    // Another page once the end of this one is in view, read from the top.
    Rect visible = list_.visibleContentRect();
    float remaining = list_.contentSize().h - visible.maxY();
    if (remaining >= visible.h) return;
    limit_ += pageSize;
    load(*directory_);
}

void ProjectHistoryView::rebuildRows() {
    std::vector<Row> built;
    for (size_t i = 0; i < commits_.size(); ++i) {
        Row row;
        row.commit = i;
        built.push_back(row);
        const std::string& hash = commits_[i].shortHash;
        if (!expanded_.count(hash)) continue;
        auto files = files_.find(hash);
        if (files == files_.end()) continue;
        for (auto& file : files->second) {
            Row fileRow;
            fileRow.isFile = true;
            fileRow.commit = i;
            fileRow.file = file;
            built.push_back(fileRow);
        }
    }
    rows_ = std::move(built);
    float refsWidth = 0;
    for (auto& refs : refs_) refsWidth = std::max(refsWidth, RefLabelsDrawing::width(refs));
    float fixed = 0;
    int fixedCount = 0;
    for (float w : {columns_.commitID, std::min(columns_.author, minimumSqueezedWidth), columns_.date}) {
        if (w > 0) {
            fixed += w;
            ++fixedCount;
        }
    }
    list_.minimumContentWidth = 16 + graphWidth_ + refsWidth + (refsWidth > 0 ? columnGap : 0) + fixed
        + fixedCount * columnGap + minimumSubjectWidth;
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
    const Row& row = rows_[index];
    const Git::Commit& commit = commits_[row.commit];
    if (row.isFile) {
        if (onOpenCommitDiff) onOpenCommitDiff(commit, row.file, *directory_);
    } else {
        toggle(commit, *directory_);
    }
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
            if (alive.expired() || !directory_ || *directory_ != directory || !expanded_.count(hash)) {
                return;
            }
            files_[hash] = found;
            rebuildRows();
        });
    });
}

void ProjectHistoryView::showContextMenu(int index, POINT screen) {
    if (!directory_ || index < 0 || index >= (int)rows_.size()) return;
    WindowHost* host = window();
    if (!host) return;
    HWND owner = host->hwnd();
    Row row = rows_[index];
    Git::Commit commit = commits_[row.commit];
    std::wstring directory = *directory_;
    Menu menu;
    if (!row.isFile) {
        menu.add(L"Copy Commit ID", [owner, commit] { copyToClipboard(owner, W(commit.shortHash)); });
        menu.add(L"Copy Commit Message", [owner, commit] { copyToClipboard(owner, W(commit.subject)); });
    } else {
        menu.add(L"Show Changes in This Commit", [this, commit, row, directory] {
            if (onOpenCommitDiff) onOpenCommitDiff(commit, row.file, directory);
        });
        menu.add(L"Copy Path", [owner, row] { copyToClipboard(owner, W(row.file.path)); });
    }
    menu.popup(owner, screen);
}

void ProjectHistoryView::drawRow(Graphics& g, int index, const Rect& rect) {
    const Row& row = rows_[index];
    if (row.isFile) drawFile(g, row, rect);
    else drawCommit(g, commits_[row.commit], rect);
}

void ProjectHistoryView::drawCommit(Graphics& g, const Git::Commit& commit, const Rect& rect) {
    g.pushClip(rect);
    auto graph = graphRows_.find(commit.graphID());
    if (graph != graphRows_.end() && graphWidth_ > 0) {
        HistoryGraphDrawing::draw(
            g, graph->second,
            Rect(rect.x + 8, rect.y, graphWidth_ - HistoryGraphDrawing::trailingGap, rect.h));
    }
    Rect content(rect.x + 8 + graphWidth_, rect.y, std::max(0.0f, rect.w - 16 - graphWidth_), rect.h);
    size_t commitIndex = &commit - commits_.data();
    const std::vector<Git::RefLabel>& refs = refs_[commitIndex];
    if (!refs.empty() && content.w > 0) {
        float natural = RefLabelsDrawing::width(refs);
        float available = std::min(natural, std::floor(content.w * 0.42f));
        auto drawn = RefLabelsDrawing::draw(g, refs, Rect(content.x, content.y, available, content.h),
                                            Theme::accent);
        if (!drawn.empty()) {
            float taken = drawn.back().maxX() - content.x + columnGap;
            content = Rect(content.x + taken, content.y, std::max(0.0f, content.w - taken), content.h);
        }
    }
    bool pending = isUnpushed(commit.shortHash);
    Color meta = pending ? Theme::accent : Theme::dimText;
    Boxes boxes = layoutColumns(columns_, content);
    float baseline = Text::centeredBaseline(subjectFont(), content);
    g.text(W(commit.shortHash), metaFont(), Theme::dimText, baseline, boxes.commitID, LineBreak::Clipping);
    g.text(W(commit.subject), subjectFont(), Theme::foreground, baseline, boxes.subject);
    g.text(authorText(commit, pending), metaFont(), meta, baseline, boxes.author);
    g.text(W(commit.absoluteDate), metaFont(), meta, baseline, boxes.date, LineBreak::Clipping);
    g.popClip();
}

void ProjectHistoryView::drawFile(Graphics& g, const Row& row, const Rect& rect) {
    g.pushClip(rect);
    if (graphWidth_ > 0) {
        auto graph = graphRows_.find(commits_[row.commit].graphID());
        if (graph != graphRows_.end()) {
            HistoryGraphDrawing::drawContinuation(
                g, graph->second.bottomLanes,
                Rect(rect.x + 8, rect.y, graphWidth_ - HistoryGraphDrawing::trailingGap, rect.h));
        }
    }
    // Files stay indented under the commit text, clear of every graph lane.
    g.text(W(row.file.status), Theme::uiFont(10), statusColor(row.file.status),
           Rect(rect.x + 18 + graphWidth_, rect.y, 14, rect.h), LineBreak::Clipping, Align::Center);
    float textX = 38 + graphWidth_;
    std::wstring path = W(row.file.path);
    CellDrawing::primaryAndSecondary(g, lastPathComponent(path), Theme::uiFont(11), Theme::foreground,
                                     W(deletingLastPathComponent(row.file.path)), Theme::uiFont(9.5f),
                                     Theme::dimText,
                                     Rect(rect.x + textX, rect.y, std::max(0.0f, rect.w - textX - 6), rect.h));
    g.popClip();
}

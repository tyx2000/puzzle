#include "filehistory.h"

#include "highlight.h"
#include "theme.h"

namespace {
const wchar_t* kTitles[4] = {L"Commit", L"Time", L"Author", L"Commit ID"};
constexpr float kResizeBand = 8;
}  // namespace

FileHistoryView::FileHistoryView() {
    backgroundColor = Theme::editorBackground;
    table_.rowHeight = std::max(28.0f, Theme::treeRowHeight());
    table_.numberOfRows = [this] { return model_ ? (int)model_->commits.size() : 0; };
    table_.rowBackground = [this](int row) {
        return expandedRow_ && *expandedRow_ == row ? Theme::activeRow : Theme::editorBackground;
    };
    table_.drawRow = [this](Graphics& g, int row, const Rect& rect) {
        if (!model_ || row >= (int)model_->commits.size()) return;
        const Git::Commit& commit = model_->commits[row];
        // The header owns the boundary above row zero.
        if (row > 0) g.fillRect(Rect(rect.x, rect.y, rect.w, 1), Theme::border.withAlpha(0.35f));
        auto widths = columnWidths();
        std::wstring values[4] = {W(commit.subject), W(commit.absoluteDate), W(commit.author), W(commit.shortHash)};
        float x = rect.x;
        for (int c = 0; c < 4; ++c) {
            Font font = c == 3 ? Theme::editorFont() : Theme::uiFont(12);
            g.text(values[c], font, Theme::foreground, Rect(x + 8, rect.y, std::max(0.0f, widths[c] - 15), rect.h));
            x += widths[c];
        }
    };
    table_.onClick = [this](int row) { toggleDetail(row); };
    table_.tooltipForRow = [this](int row, Point inRow) -> std::wstring {
        if (!model_ || row >= (int)model_->commits.size()) return L"";
        auto widths = columnWidths();
        const Git::Commit& commit = model_->commits[row];
        std::wstring values[4] = {W(commit.subject), W(commit.absoluteDate), W(commit.author), W(commit.shortHash)};
        float x = 0;
        for (int c = 0; c < 4; ++c) {
            if (inRow.x >= x && inRow.x < x + widths[c]) return values[c];
            x += widths[c];
        }
        return L"";
    };
    addSubview(&table_);
    empty_.text = L"No commits found for this file.";
    empty_.font = Theme::uiFont(12);
    empty_.color = Theme::dimText;
    empty_.align = Align::Center;
    empty_.setHidden(true);
    addSubview(&empty_);
    detailTitle_.font = Theme::uiFont(12);
    detailTitle_.color = Theme::foreground;
    detailTitle_.lineBreak = LineBreak::TruncatingMiddle;
    detailTitle_.setHidden(true);
    addSubview(&detailTitle_);
    detail_.setHidden(true);
    detail_.setShowsCurrentLineBand(false);
    addSubview(&detail_);
}

FileHistoryView::~FileHistoryView() {
    detail_.detach();
    if (detailDocument_) HighlightService::documentWillClose(*detailDocument_);
}

std::vector<float> FileHistoryView::columnWidths() const {
    float total = bounds().w;
    float time = 160, author = 140, id = 100;
    float message = std::max(220.0f, total - time - author - id);
    return {message, time, author, id};
}

Rect FileHistoryView::detailRect() const {
    Rect b = bounds();
    return Rect(0, b.h - detailHeight_, b.w, detailHeight_);
}

float FileHistoryView::applyDetailHeight(float requested) {
    float maximum = std::max(0.0f, std::floor(bounds().h * 0.6f));
    float minimum = std::min(120.0f, maximum);
    detailHeight_ = std::min(maximum, std::max(minimum, requested));
    setNeedsLayout();
    return detailHeight_;
}

void FileHistoryView::layout() {
    Rect b = bounds();
    bool showsDetail = expandedRow_.has_value();
    if (showsDetail) applyDetailHeight(preferredDetailHeight_ ? *preferredDetailHeight_
                                                              : std::max(180.0f, std::floor(b.h * 0.38f)));
    else detailHeight_ = 0;
    float tableBottom = b.h - detailHeight_;
    table_.setFrame(Rect(0, headerHeight, b.w, std::max(0.0f, tableBottom - headerHeight)));
    empty_.setFrame(Rect(0, headerHeight + 40, b.w, 24));
    detailTitle_.setHidden(!showsDetail);
    detail_.setHidden(!showsDetail);
    if (showsDetail) {
        Rect d = detailRect();
        detailTitle_.setFrame(Rect(12, d.y + kResizeBand + 3, std::max(0.0f, d.w - 24), 18));
        float top = d.y + kResizeBand + 3 + 18 + 6;
        detail_.setFrame(Rect(0, top, d.w, std::max(0.0f, d.maxY() - top)));
    }
}

void FileHistoryView::draw(Graphics& g) {
    Rect b = bounds();
    // The column headers.
    auto widths = columnWidths();
    g.fillRect(Rect(0, 0, b.w, headerHeight), Theme::barBackground);
    float x = 0;
    for (int c = 0; c < 4; ++c) {
        g.text(kTitles[c], Theme::uiFont(11), Theme::dimText, Rect(x + 8, 0, std::max(0.0f, widths[c] - 12), headerHeight));
        if (c < 3) g.fillRect(Rect(x + widths[c] - 1, 4, 1, headerHeight - 8), Theme::border);
        x += widths[c];
    }
    g.fillRect(Rect(0, headerHeight - 1, b.w, 1), Theme::border);
    if (expandedRow_) {
        Rect d = detailRect();
        g.fillRect(Rect(0, std::floor(d.y + kResizeBand / 2), b.w, 1), Theme::border);
    }
}

bool FileHistoryView::mouseDown(const MouseEvent& e) {
    if (expandedRow_) {
        Rect d = detailRect();
        if (e.location.y >= d.y && e.location.y < d.y + kResizeBand) {
            resizing_ = true;
            return true;
        }
    }
    return false;
}

void FileHistoryView::mouseDragged(const MouseEvent& e) {
    if (!resizing_) return;
    preferredDetailHeight_ = applyDetailHeight(bounds().h - e.location.y);
    if (WindowHost* host = window()) host->displayIfNeeded();
}

void FileHistoryView::mouseUp(const MouseEvent&) { resizing_ = false; }

Cursor FileHistoryView::cursorAt(Point p) {
    if (expandedRow_) {
        Rect d = detailRect();
        if (p.y >= d.y && p.y < d.y + kResizeBand) return Cursor::ResizeUpDown;
    }
    return Cursor::Arrow;
}

void FileHistoryView::configure(const FileHistoryModel& model) {
    model_ = model;
    ++detailGeneration_;
    expandedRow_.reset();
    preferredDetailHeight_.reset();
    detailTitle_.text.clear();
    setDetailText("", false);
    empty_.setHidden(!model.commits.empty());
    table_.reloadData();
    table_.setContentOffset(Point(0, 0));
    setNeedsLayout();
    setNeedsDisplay();
}

void FileHistoryView::collapseDetail() {
    if (!expandedRow_) return;
    ++detailGeneration_;
    expandedRow_.reset();
    setDetailText("", false);
    setNeedsLayout();
    setNeedsDisplay();
    table_.setNeedsDisplay();
}

void FileHistoryView::toggleDetail(int row) {
    if (!model_ || row < 0 || row >= (int)model_->commits.size()) return;
    if (expandedRow_ && *expandedRow_ == row) {
        collapseDetail();
        return;
    }
    expandedRow_ = row;
    int generation = ++detailGeneration_;
    Git::Commit commit = model_->commits[row];
    detailTitle_.text = L"Changes in " + W(commit.shortHash) + L" — " + W(model_->relativePath);
    detailTitle_.setNeedsDisplay();
    setDetailText("Loading…", false);
    setNeedsLayout();
    setNeedsDisplay();
    table_.setNeedsDisplay();
    std::wstring repository = model_->repository, tab = model_->tabURL;
    std::string path = model_->relativePath, hash = commit.shortHash;
    Dispatch::background([this, alive = life_.weak(), generation, row, repository, path, hash, tab] {
        std::string diff = Git::diffInCommit(hash, path, repository);
        Dispatch::main([this, alive, generation, row, diff, tab] {
            if (alive.expired() || detailGeneration_ != generation || expandedRow_ != row) return;
            if (!model_ || model_->tabURL != tab) return;
            setDetailText(diff, true);
            detail_.setSelection(TextRange(0, 0));
            detail_.scrollRangeToVisible(TextRange(0, 0));
        });
    });
}

void FileHistoryView::setDetailText(const std::string& text, bool highlightingDiff) {
    if (!detailDocument_) {
        detailDocument_ = std::make_unique<Document>(L"puzzle-history-detail:" + std::to_wstring((uintptr_t)this),
                                                     "", L"detail");
    }
    detailDocument_->replaceVirtualContent(text, std::wstring(L"detail"));
    if (highlightingDiff) {
        DiffHighlighter::apply(*detailDocument_);
        detailDocument_->diffLineNumbers = DiffHighlighter::lineNumbers(detailDocument_->view());
    } else {
        detailDocument_->diffLineNumbers.clear();
        std::vector<unsigned char> plain(detailDocument_->length(), 0);
        SciDoc::setStyles(detailDocument_->handle(), 0, plain.data(), plain.size());
    }
    detail_.attach(detailDocument_.get());
    detail_.setEditable(false);
    detail_.setWraps(false);
    detail_.setDiffLineNumbers(detailDocument_->diffLineNumbers);
}

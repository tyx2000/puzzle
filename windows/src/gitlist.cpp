#include "gitlist.h"

#include "celldrawing.h"
#include "theme.h"

namespace GitCells {

namespace {
float metaWidth(const std::wstring& text, const Font& font) {
    if (text.empty()) return 0;
    return std::ceil(Text::width(text, font)) + 2;
}
}  // namespace

Color statusColor(const std::string& status) {
    if (status == "A") return Theme::green;
    if (status == "D") return Theme::red;
    if (status == "R") return Theme::blue;
    return Theme::yellow;  // M and friends
}

float minimumWidth(const std::vector<Git::Commit>& commits, float graphWidth) {
    Font font = Theme::uiFont(9.5f);
    float textWidth = 60;
    for (auto& commit : commits) {
        float idWidth = metaWidth(W(commit.shortHash), font);
        float refsWidth = RefLabelsDrawing::width(commit.refDecorations());
        float metadata = metaWidth(W(commit.absoluteDate), font) + columnGap
            + std::min(30.0f, metaWidth(W(commit.author), font));
        float body = std::max(std::ceil(metadata / 0.6f), metadata + columnGap + 60);
        float refsGap = refsWidth > 0 ? columnGap : 0;
        textWidth = std::max(textWidth, std::max(idWidth * 4, refsWidth + refsGap + idWidth + columnGap + body));
    }
    return 16 + graphWidth + textWidth;
}

void drawCommit(Graphics& g, const Git::Commit& commit, const Rect& rect, const CommitStyle& style) {
    g.pushClip(rect);
    if (style.graphRow && style.graphWidth > 0) {
        HistoryGraphDrawing::draw(g, *style.graphRow,
                                  Rect(rect.x + 8, rect.y, style.graphWidth - HistoryGraphDrawing::trailingGap, rect.h));
    }
    Rect content(rect.x + 8 + style.graphWidth, rect.y, std::max(0.0f, rect.w - 16 - style.graphWidth), rect.h);
    auto refs = commit.refDecorations();
    if (!refs.empty() && content.w > 0) {
        float natural = RefLabelsDrawing::width(refs, style.currentBranch);
        // Refs identify the commit, but on a narrow column they must not
        // erase the subject.
        float available = std::min(natural, std::floor(content.w * 0.42f));
        auto drawn = RefLabelsDrawing::draw(g, refs, Rect(content.x, content.y, available, content.h), Theme::cursor,
                                            style.currentBranch);
        if (!drawn.empty()) {
            float taken = drawn.back().maxX() - content.x + columnGap;
            content = Rect(content.x + taken, content.y, std::max(0.0f, content.w - taken), content.h);
        }
    }
    if (style.showsID && !commit.shortHash.empty()) {
        Font idFont = Theme::uiFont(9.5f);
        std::wstring id = W(commit.shortHash);
        // A quarter at most: the message is what the row is read for.
        float idWidth = std::min(std::ceil(Text::width(id, idFont)) + 2, std::floor(content.w * 0.25f));
        Rect box(content.x, content.y, idWidth, content.h);
        g.text(id, idFont, Theme::dimText, Text::centeredBaseline(Theme::uiFont(11), content), box,
               LineBreak::Clipping);
        float taken = idWidth + columnGap;
        content = Rect(content.x + taken, content.y, std::max(0.0f, content.w - taken), content.h);
    }
    // The name gives way before the timestamp does.
    std::wstring author = style.pending ? L"↑  " + W(commit.author) : W(commit.author);
    Color metaColor = style.pending ? Theme::cursor : (style.inherited ? Theme::gutter : Theme::dimText);
    Color subjectColor = style.inherited ? Theme::dimText : Theme::foreground;
    CellDrawing::leadingAndTrailing(g, W(commit.subject), Theme::uiFont(11), subjectColor, author,
                                    Theme::uiFont(9.5f), metaColor, W(commit.absoluteDate), content, columnGap);
    g.popClip();
}

void drawBranchBase(Graphics& g, const std::string& name, bool folded, const Rect& rect) {
    std::wstring label = L"Branched from " + W(name);
    Font font = Theme::uiFont(9.5f);
    constexpr float chevronSize = 10;
    drawSymbol(g, folded ? Symbol::ChevronRight : Symbol::ChevronDown,
               Rect(rect.x + 8, rect.y + std::floor((rect.h - chevronSize) / 2), chevronSize, chevronSize),
               Theme::dimText, 0.8f);
    float leading = 8 + chevronSize + 6;
    Rect content(rect.x + leading, rect.y, std::max(0.0f, rect.w - leading - 8), rect.h);
    // The name gives way before the rule disappears entirely.
    float textWidth = std::min(std::ceil(Text::width(label, font)) + 2, std::floor(content.w * 0.7f));
    Rect box(content.x, rect.y, textWidth, rect.h);
    g.text(label, font, Theme::dimText, Text::centeredBaseline(Theme::uiFont(11), content), box);
    float ruleX = box.maxX() + 8;
    if (ruleX >= content.maxX()) return;
    g.fillRect(Rect(ruleX, rect.y + std::floor(rect.h / 2), content.maxX() - ruleX, 1), Theme::lineHighlight);
}

void drawHistoryFile(Graphics& g, const Git::CommitFile& file, const Rect& rect,
                     const std::vector<HistoryGraph::Lane>& lanes, float graphWidth, float actionsWidth) {
    g.pushClip(rect);
    if (graphWidth > 0) {
        HistoryGraphDrawing::drawContinuation(
            g, lanes, Rect(rect.x + 8, rect.y, graphWidth - HistoryGraphDrawing::trailingGap, rect.h));
    }
    // Indent beneath the commit text, leaving the graph lanes connected.
    g.text(W(file.status), Theme::uiFont(10), statusColor(file.status), Rect(rect.x + 18 + graphWidth, rect.y, 14, rect.h),
           LineBreak::Clipping, Align::Center);
    float textX = rect.x + 38 + graphWidth;
    Rect nameBox(textX, rect.y, std::max(0.0f, rect.maxX() - textX - 6 - actionsWidth), rect.h);
    CellDrawing::primaryAndSecondary(g, W(lastPathComponent(file.path)), Theme::uiFont(11), Theme::foreground,
                                     W(deletingLastPathComponent(file.path)), Theme::uiFont(9.5f), Theme::dimText,
                                     nameBox);
    g.popClip();
}

void drawChange(Graphics& g, const Git::StatusEntry& entry, const Rect& rect, float actionsWidth) {
    Color color = entry.isUntracked() ? Theme::green : Theme::yellow;
    g.text(W(entry.displayCode()), Theme::uiFont(10), color, Rect(rect.x + 6, rect.y, 18, rect.h), LineBreak::Clipping,
           Align::Center);
    CellDrawing::fileIcon(g, lastPathComponent(entry.path),
                          Rect(rect.x + 26, rect.y + std::floor((rect.h - 13) / 2), 13, 13));
    // Leave room for the actions only while the pointer is on the row.
    Rect nameBox(rect.x + 44, rect.y, std::max(0.0f, rect.w - 52 - actionsWidth), rect.h);
    CellDrawing::primaryAndSecondary(g, W(lastPathComponent(entry.path)), Theme::uiFont(11), Theme::foreground,
                                     W(deletingLastPathComponent(entry.path)), Theme::uiFont(9.5f), Theme::dimText,
                                     nameBox, 5, LineBreak::TruncatingMiddle);
}

void drawBranch(Graphics& g, const Git::Branch& branch, const Rect& rect) {
    std::wstring name = branch.isCurrent ? W(branch.name) + L"  · current" : W(branch.name);
    // Switch and delete live in the row's context menu, so the name has the
    // full width up to its metadata.
    CellDrawing::leadingAndTrailing(g, name, Theme::uiFont(11), branch.isCurrent ? Theme::cursor : Theme::foreground,
                                    W(branch.author), Theme::uiFont(9.5f), Theme::dimText, W(branch.createdAt),
                                    Rect(rect.x + 8, rect.y, std::max(0.0f, rect.w - 16), rect.h), 8, 0.6f,
                                    LineBreak::TruncatingMiddle);
}

}  // namespace GitCells

// ── GitList ────────────────────────────────────────────────────────────────

GitList::GitList() {
    keyboardNavigation = true;
}

std::vector<RowAction> GitList::shownActions(int row) const {
    if (row < 0 || row != hoveredRow() || !actionsForRow) return {};
    return actionsForRow(row);
}

float GitList::actionsWidth(int row) const {
    float count = (float)shownActions(row).size();
    if (count <= 0) return 0;
    return count * actionSize + (count - 1) * actionGap + actionInset;
}

Rect GitList::actionRect(int row, RowAction action) const {
    auto shown = shownActions(row);
    auto place = std::find(shown.begin(), shown.end(), action);
    if (place == shown.end()) return Rect();
    float fromEnd = (float)(shown.size() - 1 - (place - shown.begin()));
    Rect r = rectOfRow(row);
    float x = r.maxX() - actionInset - actionSize - fromEnd * (actionSize + actionGap);
    return Rect(x, r.y + std::round((r.h - actionSize) / 2), actionSize, actionSize);
}

std::optional<RowAction> GitList::actionAt(Point p) const {
    int row = rowAt(p);
    for (RowAction action : shownActions(row)) {
        if (actionRect(row, action).contains(p)) return action;
    }
    return std::nullopt;
}

void GitList::drawActions(Graphics& g, int row, const Rect&) {
    for (RowAction action : shownActions(row)) {
        Rect box = actionRect(row, action);
        bool lit = hoveredAction_ && *hoveredAction_ == action;
        if (lit) g.fillRoundedRect(box, 4, Theme::activeRow);
        Rect glyph(box.midX() - actionGlyph / 2, box.midY() - actionGlyph / 2, actionGlyph, actionGlyph);
        drawSymbol(g, action == RowAction::Discard ? Symbol::UturnBackward : Symbol::Document, glyph,
                   lit ? Theme::foreground : Theme::dimText);
    }
}

bool GitList::contentMouseDown(const MouseEvent& e, Point p) {
    if (auto action = actionAt(p)) {
        int row = rowAt(p);
        if (onAction) onAction(row, *action);
        return true;
    }
    return ListView::contentMouseDown(e, p);
}

void GitList::contentMouseMoved(Point p) {
    keysLitRow_ = false;
    ListView::contentMouseMoved(p);
    auto next = actionAt(p);
    if (next != hoveredAction_) {
        hoveredAction_ = next;
        setNeedsDisplay();
    }
}

void GitList::contentMouseExited() {
    if (hoveredAction_) {
        hoveredAction_.reset();
        setNeedsDisplay();
    }
    if (keysLitRow_) return;
    ListView::contentMouseExited();
}

Cursor GitList::cursorAt(Point local) {
    return actionAt(toContent(local)) ? Cursor::Hand : Cursor::Arrow;
}

bool GitList::keyDown(const KeyEvent& e) {
    if (e.control || e.alt || e.shift) return false;
    int count = rowCount();
    if (e.key == VK_DOWN || e.key == VK_UP) {
        if (count == 0) return true;
        int step = e.key == VK_DOWN ? 1 : -1;
        int from = hoveredRow() >= 0 ? hoveredRow() : selectedRow();
        int next = from < 0 ? (step > 0 ? 0 : count - 1) : std::clamp(from + step, 0, count - 1);
        keysLitRow_ = true;
        setHoveredRow(next);
        scrollRowToVisible(next);
        return true;
    }
    if (e.key == VK_RETURN) {
        int row = hoveredRow() >= 0 ? hoveredRow() : selectedRow();
        if (row >= 0 && row < count) {
            if (onActivate) onActivate(row);
            else if (onClick) onClick(row);
        }
        return true;
    }
    return false;
}

// ── FlatPanelTabBar ────────────────────────────────────────────────────────

FlatPanelTabBar::FlatPanelTabBar(std::vector<std::wstring> labels)
    : labels_(std::move(labels)), badges_(labels_.size()) {}

void FlatPanelTabBar::setSelectedSegment(int index) {
    if (index == selected_) return;
    selected_ = index;
    setNeedsDisplay();
}

void FlatPanelTabBar::setLabel(const std::wstring& label, const std::wstring& badge, int index) {
    if (index < 0 || index >= (int)labels_.size()) return;
    if (labels_[index] == label && badges_[index] == badge) return;
    labels_[index] = label;
    badges_[index] = badge;
    setNeedsDisplay();
}

int FlatPanelTabBar::segmentAt(Point p) const {
    if (labels_.empty() || !bounds().contains(p)) return -1;
    float width = bounds().w / labels_.size();
    return std::clamp((int)(p.x / width), 0, (int)labels_.size() - 1);
}

void FlatPanelTabBar::draw(Graphics& g) {
    Rect b = bounds();
    g.fillRect(b, Theme::barBackground);
    if (labels_.empty()) return;
    float width = b.w / labels_.size();
    Font font = Theme::uiFont(11);
    for (size_t i = 0; i < labels_.size(); ++i) {
        float minX = std::round(i * width), maxX = std::round((i + 1) * width);
        Rect slot(minX, 0, maxX - minX, b.h);
        bool selected = (int)i == selected_;
        if (selected) g.fillRect(slot, Theme::selectedControl);
        CellDrawing::labelWithBadge(g, labels_[i], badges_[i], font,
                                    selected ? Theme::selectedControlText : Theme::dimText, Theme::activeRow,
                                    Theme::foreground, slot.inset(4, 0), Align::Center);
    }
}

bool FlatPanelTabBar::mouseDown(const MouseEvent& e) {
    int index = segmentAt(e.location);
    if (index < 0 || index == selected_) return true;
    selected_ = index;
    setNeedsDisplay();
    if (onChange) onChange();
    return true;
}

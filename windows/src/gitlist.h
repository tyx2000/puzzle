// The rows the Git panel and a project's history draw, and the list they sit
// in (GitPanelViews.swift): a commit on one line, the "Branched from" rule, a
// commit's file, a changed file with its trailing actions, a branch, and the
// flat two- or three-way tab strip.
#pragma once

#include "historygraph.h"
#include "widgets.h"

namespace GitCells {

/// Between every column in a commit row.
constexpr float columnGap = 15;

/// Colour for a commit file's status letter (A added, M modified, D deleted).
Color statusColor(const std::string& status);

/// Preserve the hash and a readable message beside the graph.
float minimumWidth(const std::vector<Git::Commit>& commits, float graphWidth);

struct CommitStyle {
    /// Not on the upstream yet: an ↑ rides with the author.
    bool pending = false;
    /// The commit's id ahead of the message (the Git panel has the width).
    bool showsID = true;
    const HistoryGraph::Row* graphRow = nullptr;
    float graphWidth = 0;
    /// A commit the branch was started on rather than one of its own.
    bool inherited = false;
    std::string currentBranch;
};
void drawCommit(Graphics& g, const Git::Commit& commit, const Rect& rect, const CommitStyle& style);

/// "Branched from <name>" and a rule; the chevron says whether it is folded.
void drawBranchBase(Graphics& g, const std::string& name, bool folded, const Rect& rect);

void drawHistoryFile(Graphics& g, const Git::CommitFile& file, const Rect& rect,
                     const std::vector<HistoryGraph::Lane>& lanes, float graphWidth, float actionsWidth);

void drawChange(Graphics& g, const Git::StatusEntry& entry, const Rect& rect, float actionsWidth);

void drawBranch(Graphics& g, const Git::Branch& branch, const Rect& rect);

}  // namespace GitCells

/// What a changed file's row offers at its trailing edge.
enum class RowAction { Discard, Open };

/// GitTableView: the row under the pointer lights up and shows the actions it
/// offers; ↑↓ move the lit row and Return acts on it, as in a menu.
class GitList : public ListView {
public:
    GitList();
    /// The actions a row offers, in order from leading to trailing. Shown
    /// only while the pointer is on the row.
    std::function<std::vector<RowAction>(int row)> actionsForRow;
    /// A row's own click comes through `onClick`; Return on the lit row
    /// through `onActivate`, or `onClick` when that is unset.
    std::function<void(int row, RowAction)> onAction;

    static constexpr float actionSize = 20;
    static constexpr float actionGlyph = 13;
    static constexpr float actionGap = 2;
    static constexpr float actionInset = 6;

    /// The room the actions take at the trailing edge of `row`; nothing
    /// unless the row is lit.
    float actionsWidth(int row) const;
    /// Paint the lit row's actions; call at the end of the row's drawing.
    void drawActions(Graphics& g, int row, const Rect& rowRect);

    bool keyDown(const KeyEvent& e) override;
    Cursor cursorAt(Point p) override;

protected:
    bool contentMouseDown(const MouseEvent& e, Point p) override;
    void contentMouseMoved(Point p) override;
    void contentMouseExited() override;

private:
    std::vector<RowAction> shownActions(int row) const;
    Rect actionRect(int row, RowAction action) const;
    std::optional<RowAction> actionAt(Point contentPoint) const;
    std::optional<RowAction> hoveredAction_;
    bool keysLitRow_ = false;
};

/// The Git panel's tab strip: equal slots, the selected one filled
/// edge to edge, a count badge after a label.
class FlatPanelTabBar : public View {
public:
    explicit FlatPanelTabBar(std::vector<std::wstring> labels);
    std::function<void()> onChange;
    int selectedSegment() const { return selected_; }
    void setSelectedSegment(int index);
    void setLabel(const std::wstring& label, const std::wstring& badge, int index);
    void draw(Graphics& g) override;
    bool mouseDown(const MouseEvent& e) override;

private:
    int segmentAt(Point p) const;
    std::vector<std::wstring> labels_;
    std::vector<std::wstring> badges_;
    int selected_ = 0;
};

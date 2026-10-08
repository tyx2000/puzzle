#include "changes.h"

#include "celldrawing.h"
#include "dialog.h"
#include "gitpanel.h"
#include "theme.h"

// ── CommitBar ──────────────────────────────────────────────────────────────

CommitBar::CommitBar() {
    field.placeholder = placeholder;
    field.font = Theme::uiFont(11);
    field.fillColor = Theme::activeTab;
    field.textColor = Theme::foreground;
    field.horizontalInset = 7;
    commitButton.title = L"Commit";
    pushButton.title = L"Push";
    commitButton.style = BadgeButton::Style::Plain;
    pushButton.style = BadgeButton::Style::Plain;
    addSubview(&field);
    addSubview(&commitButton);
    addSubview(&pushButton);
    addSubview(&progress);
}

void CommitBar::draw(Graphics& g) { g.fillRect(bounds(), Theme::activeTab); }

void CommitBar::layout() {
    Rect b = bounds();
    float h = BadgeButton::height;
    float top = std::round((b.h - h) / 2);
    // Right to left: Push at the edge, Commit before it, the message in
    // whatever is left — from the region's left edge, top to bottom.
    float x = b.w - inset;
    for (BadgeButton* button : {&pushButton, &commitButton}) {
        float w = button->intrinsicWidth();
        x -= w;
        button->setFrame(Rect(x, top, w, h));
        x -= gap;
    }
    field.setFrame(Rect(0, 0, std::max(0.0f, x), b.h));
    progress.setFrame(Rect(0, b.h - 2, b.w, 2));
}

// ── ProjectChangesView ─────────────────────────────────────────────────────

ProjectChangesView::ProjectChangesView() {
    backgroundColor = Theme::panelBackground;
    addSubview(&bar_);
    addSubview(&list_);
    list_.rowHeight = Theme::treeRowHeight();
    list_.numberOfRows = [this] { return (int)entries_.size(); };
    list_.rowBackground = [this](int row) {
        return row == list_.hoveredRow() ? Theme::hover : Theme::panelBackground;
    };
    list_.drawRow = [this](Graphics& g, int row, const Rect& rect) { drawRow(g, row, rect); };
    list_.tooltipForRow = [this](int row, Point) {
        return row >= 0 && row < (int)entries_.size() ? W(entries_[row].path) : L"";
    };
    list_.onClick = [this](int row) { activate(row); };
    // The same two errands the Git panel's list offers, on the same terms: at
    // the end of the row, and only under the pointer.
    list_.actionsForRow = [this](int row) -> std::vector<RowAction> {
        if (!directory_ || row < 0 || row >= (int)entries_.size()) return {};
        return {RowAction::Discard, RowAction::Open};
    };
    list_.onAction = [this](int row, RowAction action) {
        if (!directory_ || row < 0 || row >= (int)entries_.size()) return;
        Git::StatusEntry entry = entries_[row];
        std::wstring directory = *directory_;
        if (action == RowAction::Discard) discard(entry, directory);
        else if (onOpenFile) onOpenFile(pathJoinGit(directory, entry.path));
    };

    bar_.field.onChange = [this] { refreshButtons(); };
    bar_.field.onCommitShortcut = [this] { commitAction(); };
    bar_.field.onPushShortcut = [this] { pushAction(); };
    bar_.commitButton.onClick = [this] { commitAction(); };
    bar_.pushButton.onClick = [this] { pushAction(); };
    refreshButtons();
}

void ProjectChangesView::layout() {
    Rect b = bounds();
    bar_.setFrame(Rect(0, 0, b.w, CommitBar::height));
    list_.setFrame(Rect(0, CommitBar::height, b.w, std::max(0.0f, b.h - CommitBar::height)));
}

void ProjectChangesView::drawRow(Graphics& g, int row, const Rect& rect) {
    GitCells::drawChange(g, entries_[row], rect, list_.actionsWidth(row));
    list_.drawActions(g, row, rect);
}

/// A click on a row, or Return on the row the keys lit.
void ProjectChangesView::activate(int row) {
    if (!directory_ || row < 0 || row >= (int)entries_.size()) return;
    if (onOpenDiff) onOpenDiff(entries_[row], *directory_);
}

void ProjectChangesView::refreshFonts() {
    list_.rowHeight = Theme::treeRowHeight();
    bar_.field.font = Theme::uiFont(11);
    bar_.field.dpiChanged();
    list_.reloadData();
    bar_.setNeedsLayout();
    setNeedsDisplay();
}

std::wstring ProjectChangesView::message() const { return trim(bar_.field.text()); }

bool ProjectChangesView::commitIsPossible() const {
    return !entries_.empty() && !message().empty();
}

bool ProjectChangesView::pushIsPossible() const {
    if (!remote_) return false;
    return remote_->first > 0 || !remote_->second;
}

void ProjectChangesView::setEntries(const std::vector<Git::StatusEntry>& entries,
                                    const std::optional<std::wstring>& directory,
                                    std::optional<int> ahead, bool hasUpstream) {
    std::optional<std::pair<int, bool>> remote;
    if (ahead) remote = std::make_pair(*ahead, hasUpstream);
    bool remoteChanged = remote_ != remote;
    remote_ = remote;
    if (entries_ == entries && directory_ == directory) {
        if (remoteChanged) refreshButtons();
        return;
    }
    if (directory_ != directory) switchDraft(directory_, directory);
    entries_ = entries;
    directory_ = directory;
    list_.reloadData();
    refreshButtons();
}

void ProjectChangesView::switchDraft(const std::optional<std::wstring>& from,
                                     const std::optional<std::wstring>& to) {
    if (from) {
        std::wstring text = bar_.field.text();
        if (text.empty()) drafts_.erase(*from);
        else drafts_[*from] = text;
    }
    std::wstring next;
    if (to) {
        auto it = drafts_.find(*to);
        if (it != drafts_.end()) next = it->second;
    }
    bar_.field.setText(next);
}

void ProjectChangesView::refreshButtons() {
    bool idle = !operation_.has_value();
    bool possible = commitIsPossible();
    bar_.commitButton.setEnabled(idle && possible);
    bar_.commitButton.tooltip = GitPanel::commitHint(possible, !entries_.empty());
    bar_.pushButton.setEnabled(idle && pushIsPossible());
    int ahead = remote_ ? remote_->first : 0;
    bar_.pushButton.setBadge(ahead > 0 ? std::to_wstring(ahead) : L"");
    bar_.pushButton.tooltip = GitPanel::pushHint(ahead);
    bar_.setNeedsLayout();
}

HWND ProjectChangesView::ownerWindow() const {
    WindowHost* host = window();
    return host ? host->hwnd() : nullptr;
}

void ProjectChangesView::presentError(const std::wstring& title, const std::string& message) {
    Alert::inform(ownerWindow(), title, trim(W(message)));
}

int ProjectChangesView::begin(const std::wstring&, const std::wstring& directory, bool locksMessage) {
    int id = nextOperation_++;
    operation_ = Operation{id, directory, locksMessage};
    // A commit takes the message as it stands; a push leaves it alone.
    if (locksMessage) bar_.field.setEditable(false);
    bar_.progress.start();
    refreshButtons();
    return id;
}

void ProjectChangesView::finish(int id) {
    if (!operation_ || operation_->id != id) return;
    bool locked = operation_->locksMessage;
    operation_.reset();
    if (locked) bar_.field.setEditable(true);
    bar_.progress.stop();
    refreshButtons();
}

void ProjectChangesView::commitAction() {
    if (!directory_ || operation_ || !commitIsPossible()) {
        MessageBeep(MB_OK);
        return;
    }
    std::wstring directory = *directory_;
    std::string text = U(message());
    int id = begin(L"Committing", directory, true);
    auto alive = life_.weak();
    Git::operationQueue().async([this, alive, directory, text, id] {
        Git::RunResult result = Git::commit(text, directory);
        Dispatch::main([this, alive, directory, result, id] {
            if (alive.expired() || !operation_ || operation_->id != id) return;
            if (result.code == 0) {
                // The message has been used; it is nobody's draft now.
                drafts_.erase(directory);
                if (directory_ == directory) bar_.field.setText(L"");
            }
            finish(id);
            if (onChanged) onChanged(directory);
            if (result.code != 0) {
                presentError(L"Commit failed", result.err.empty() ? result.out : result.err);
            }
        });
    });
}

void ProjectChangesView::pushAction() {
    if (!directory_ || operation_ || !pushIsPossible()) {
        MessageBeep(MB_OK);
        return;
    }
    std::wstring directory = *directory_;
    int id = begin(L"Pushing", directory, false);
    auto alive = life_.weak();
    Git::operationQueue().async([this, alive, directory, id] {
        Git::RemoteResult result = Git::push(directory);
        Dispatch::main([this, alive, directory, result, id] {
            if (alive.expired() || !operation_ || operation_->id != id) return;
            finish(id);
            if (onChanged) onChanged(directory);
            if (!result.ok) presentError(L"Push failed", result.message);
        });
    });
}

// ── Discard ────────────────────────────────────────────────────────────────

void ProjectChangesView::discard(const Git::StatusEntry& entry, const std::wstring& directory) {
    if (operation_) {
        MessageBeep(MB_OK);
        return;
    }
    bool removesFile = Git::discardRemovesFile(entry, directory);
    Alert alert;
    alert.style = Alert::Style::Warning;
    alert.messageText = L"Discard changes to \u201c" + W(entry.path) + L"\u201d?";
    std::wstring affected = L"File:\n" + pathJoinGit(directory, entry.path);
    if (entry.code.find('R') != std::string::npos && entry.originalPath) {
        affected += L"\nOriginal path:\n" + pathJoinGit(directory, *entry.originalPath);
    }
    alert.informativeText = affected + L"\n\n" + W(Git::discardConsequence(removesFile));
    alert.buttons = {L"Discard Changes", L"Cancel"};
    if (alert.runModal(ownerWindow()) != 0 || operation_) return;
    int id = begin(L"Discarding changes", directory, false);
    auto alive = life_.weak();
    Git::operationQueue().async([this, alive, entry, directory, id] {
        Git::RemoteResult result = Git::discard(entry, directory);
        Dispatch::main([this, alive, directory, result, id] {
            if (alive.expired() || !operation_ || operation_->id != id) return;
            finish(id);
            if (onChanged) onChanged(directory);
            if (!result.ok) presentError(L"Discard changes failed", result.message);
        });
    });
}

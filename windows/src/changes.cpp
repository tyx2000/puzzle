#include "changes.h"

#include "celldrawing.h"
#include "dialog.h"
#include "menu.h"
#include "services.h"
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
    list_.onClick = [this](int row) {
        if (!directory_ || row < 0 || row >= (int)entries_.size()) return;
        if (onOpenDiff) onOpenDiff(entries_[row], *directory_);
    };
    list_.onContextMenu = [this](int row, POINT screen) { showContextMenu(row, screen); };

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
    const Git::StatusEntry& entry = entries_[row];
    std::wstring status = W(entry.displayCode());
    Color statusColor = entry.isUntracked() ? Theme::green : Theme::yellow;
    g.text(status, Theme::uiFont(10), statusColor, Rect(rect.x + 6, rect.y, 18, rect.h),
           LineBreak::Clipping, Align::Center);
    CellDrawing::fileIcon(g, lastPathComponent(entry.path),
                          Rect(rect.x + 26, rect.y + std::floor((rect.h - 13) / 2), 13, 13));
    std::wstring path = W(entry.path);
    CellDrawing::primaryAndSecondary(
        g, lastPathComponent(path), Theme::uiFont(11), Theme::foreground,
        W(deletingLastPathComponent(entry.path)), Theme::uiFont(9.5f), Theme::dimText,
        Rect(rect.x + 44, rect.y, std::max(0.0f, rect.w - 52), rect.h), 5,
        LineBreak::TruncatingMiddle);
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
    bar_.commitButton.tooltip = possible ? L"Commit  (Ctrl+Enter)"
        : (!entries_.empty() ? L"Describe the change to commit it" : L"Nothing to commit");
    bar_.pushButton.setEnabled(idle && pushIsPossible());
    int ahead = remote_ ? remote_->first : 0;
    bar_.pushButton.setBadge(ahead > 0 ? std::to_wstring(ahead) : L"");
    bar_.pushButton.tooltip = ahead > 0
        ? L"Push " + std::to_wstring(ahead) + L" commit" + (ahead == 1 ? L"" : L"s")
            + L"  (Ctrl+Shift+Enter)"
        : L"Push the current branch  (Ctrl+Shift+Enter)";
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

// ── Context menu ───────────────────────────────────────────────────────────

void ProjectChangesView::showContextMenu(int row, POINT screen) {
    if (!directory_ || row < 0 || row >= (int)entries_.size()) return;
    Git::StatusEntry entry = entries_[row];
    std::wstring directory = *directory_;
    std::wstring file = pathJoinGit(directory, entry.path);
    Menu menu;
    menu.add(L"Show Changes", [this, entry, directory] {
        if (onOpenDiff) onOpenDiff(entry, directory);
    });
    menu.addSeparator();
    menu.add(L"Copy Path", [this, entry] { copyToClipboard(ownerWindow(), W(entry.path)); });
    menu.add(L"Show in Explorer", [file] { revealInExplorer(file); }, fileExists(file));
    menu.addSeparator();
    bool idle = !operation_.has_value();
    menu.add(L"Discard Changes…", [this, entry, directory] { discardChanges(entry, directory); },
             idle);
    std::wstring all = entries_.size() == 1
        ? L"Discard All Changes…"
        : L"Discard All " + std::to_wstring(entries_.size()) + L" Changes…";
    menu.add(all, [this, directory] { discardAllChanges(directory); }, idle);
    menu.popup(ownerWindow(), screen);
}

void ProjectChangesView::prepareDiscard(const std::vector<Git::StatusEntry>& entries,
                                        const std::wstring& directory,
                                        std::function<void(std::vector<Git::StatusEntry>)> ask) {
    if (operation_) {
        MessageBeep(MB_OK);
        return;
    }
    // Which files Git has never committed: a subprocess each, asked off the
    // main thread so a few hundred of them do not freeze the window.
    int id = begin(L"Checking what can be restored", directory, false);
    auto alive = life_.weak();
    Git::operationQueue().async([this, alive, entries, directory, ask, id] {
        std::vector<Git::StatusEntry> newFiles;
        for (auto& entry : entries) {
            if (Git::discardRemovesFile(entry, directory)) newFiles.push_back(entry);
        }
        Dispatch::main([this, alive, newFiles, directory, ask, id] {
            if (alive.expired() || !operation_ || operation_->id != id) return;
            finish(id);
            if (directory_ != directory) return;  // the reader moved on
            ask(newFiles);
        });
    });
}

void ProjectChangesView::discardChanges(const Git::StatusEntry& entry, const std::wstring& directory) {
    prepareDiscard({entry}, directory, [this, entry, directory](std::vector<Git::StatusEntry> newFiles) {
        confirmDiscardOf(entry, !newFiles.empty(), directory);
    });
}

void ProjectChangesView::confirmDiscardOf(const Git::StatusEntry& entry, bool removesFile,
                                          const std::wstring& directory) {
    Alert alert;
    alert.style = Alert::Style::Warning;
    alert.messageText = L"Discard changes to “" + W(entry.path) + L"”?";
    std::wstring affected = L"File:\n" + pathJoinGit(directory, entry.path);
    if (entry.code.find('R') != std::string::npos && entry.originalPath) {
        affected += L"\nOriginal path:\n" + pathJoinGit(directory, *entry.originalPath);
    }
    std::wstring consequence = removesFile
        ? L"This file has no committed version. It will be removed from Git and moved to the "
          L"Recycle Bin. Gift cannot undo the action; recovery is possible only while the item "
          L"remains in the Recycle Bin."
        : L"All uncommitted changes to this file, including staged changes, will be replaced with "
          L"the version in HEAD. Git cannot restore the discarded edits.";
    alert.informativeText = affected + L"\n\n" + consequence;
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

void ProjectChangesView::discardAllChanges(const std::wstring& directory) {
    std::vector<Git::StatusEntry> entries = entries_;
    if (entries.empty()) return;
    prepareDiscard(entries, directory, [this, entries, directory](std::vector<Git::StatusEntry> newFiles) {
        confirmDiscardOfAll(entries, newFiles, directory);
    });
}

void ProjectChangesView::confirmDiscardOfAll(const std::vector<Git::StatusEntry>& entries,
                                             const std::vector<Git::StatusEntry>& newFiles,
                                             const std::wstring& directory) {
    Alert alert;
    alert.style = Alert::Style::Warning;
    alert.messageText = entries.size() == 1
        ? L"Discard the 1 change in this project?"
        : L"Discard all " + std::to_wstring(entries.size()) + L" changes in this project?";
    std::wstring detail = L"Project:\n" + directory + L"\n\n";
    detail += L"Every uncommitted change, staged included, will be replaced with the version in "
              L"HEAD. Git cannot restore the discarded edits.";
    if (!newFiles.empty()) {
        detail += L"\n\n" + std::to_wstring(newFiles.size()) + L" file"
            + (newFiles.size() == 1 ? L"" : L"s")
            + L" never committed will be removed from Git and moved to the Recycle Bin; recovery is "
              L"possible only while the item remains in the Recycle Bin:\n";
        std::vector<std::wstring> lines;
        for (size_t i = 0; i < newFiles.size() && i < 10; ++i) {
            lines.push_back(L"• " + W(newFiles[i].path));
        }
        detail += join(lines, L"\n");
        if (newFiles.size() > 10) {
            detail += L"\n• …and " + std::to_wstring(newFiles.size() - 10) + L" more";
        }
    }
    alert.informativeText = detail;
    alert.buttons = {L"Discard All Changes", L"Cancel"};
    if (alert.runModal(ownerWindow()) != 0 || operation_) return;
    int id = begin(L"Discarding all changes", directory, false);
    auto alive = life_.weak();
    Git::operationQueue().async([this, alive, entries, directory, id] {
        auto result = Git::discardAll(entries, directory);
        Dispatch::main([this, alive, entries, directory, result, id] {
            if (alive.expired() || !operation_ || operation_->id != id) return;
            finish(id);
            if (onChanged) onChanged(directory);
            if (result.second) {
                presentError(L"Discard all changes failed",
                             std::to_string(result.first) + " of " + std::to_string(entries.size())
                                 + " discarded.\n" + *result.second);
            }
        });
    });
}

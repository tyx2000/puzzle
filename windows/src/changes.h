// The changed files of one project, listed beside its file tree, under a line
// to commit them from (ProjectChangesViewController and ProjectCommitBar).
// Clicking a row opens that file's diff; a row offers Discard and Open at its
// trailing edge while the pointer is on it.
#pragma once

#include "gitlist.h"

/// The strip over a project's changes: a one-line message, then Commit and
/// Push, laid out by hand so a narrow column squeezes the message first.
class CommitBar : public View {
public:
    static constexpr float height = 32;
    static constexpr float inset = 6;
    static constexpr float gap = 6;
    static inline const wchar_t* placeholder = L"Commit message";
    CommitBar();
    TextField field;
    BadgeButton commitButton;
    BadgeButton pushButton;
    ProgressShimmer progress;
    void layout() override;
    void draw(Graphics& g) override;
};

class ProjectChangesView : public View {
public:
    ProjectChangesView();
    /// A changed file was clicked: show its diff.
    std::function<void(const Git::StatusEntry&, const std::wstring&)> onOpenDiff;
    /// The open button on a row: the file itself, not its diff.
    std::function<void(const std::wstring&)> onOpenFile;
    /// A commit, push or discard ran in `directory`, whether or not it worked.
    std::function<void(const std::wstring&)> onChanged;

    /// The project's changes and where its branch stands against the remote;
    /// a missing `ahead` means not known yet.
    void setEntries(const std::vector<Git::StatusEntry>& entries,
                    const std::optional<std::wstring>& directory,
                    std::optional<int> ahead = std::nullopt, bool hasUpstream = false);
    void refreshFonts();
    void layout() override;

private:
    void switchDraft(const std::optional<std::wstring>& from, const std::optional<std::wstring>& to);
    std::wstring message() const;
    bool commitIsPossible() const;
    bool pushIsPossible() const;
    void refreshButtons();
    void commitAction();
    void pushAction();
    int begin(const std::wstring& label, const std::wstring& directory, bool locksMessage);
    void finish(int id);
    void activate(int row);
    /// Put one file back the way it was committed, confirmed with the Git
    /// panel's own warning.
    void discard(const Git::StatusEntry& entry, const std::wstring& directory);
    void presentError(const std::wstring& title, const std::string& message);
    HWND ownerWindow() const;
    void drawRow(Graphics& g, int row, const Rect& rect);

    CommitBar bar_;
    GitList list_;
    std::vector<Git::StatusEntry> entries_;
    std::optional<std::wstring> directory_;
    std::optional<std::pair<int, bool>> remote_;
    std::map<std::wstring, std::wstring> drafts_;
    struct Operation {
        int id;
        std::wstring directory;
        bool locksMessage;
    };
    std::optional<Operation> operation_;
    int nextOperation_ = 1;
    Lifetime life_;
};

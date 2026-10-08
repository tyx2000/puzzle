// The small services the window controller leans on: recently opened
// projects, the watchers on a project and its .git, background fetching, and
// the terminal and command-line launchers.
#pragma once

#include "base.h"
#include "dispatch.h"
#include "fswatch.h"

// ── Recent projects ────────────────────────────────────────────────────────

/// Recently opened project folders, newest first; backs the start page, File
/// ▸ Open Recent and the taskbar's jump list.
class RecentProjects {
public:
    static RecentProjects& shared();
    /// How many the start page and the jump list offer.
    static constexpr size_t displayLimit = 20;
    /// Most recent first, with folders that no longer exist left out.
    std::vector<std::wstring> paths() const;
    void add(const std::wstring& path);
    void remove(const std::wstring& path);
    void clear();
    /// Observers run on the main thread after every change.
    int observe(std::function<void()> callback);
    void unobserve(int token);
    /// "~\Desktop" — the parent folder, shown beside each entry.
    static std::wstring displayParent(const std::wstring& path);
private:
    void changed();
    std::map<int, std::function<void()>> observers_;
    int nextToken_ = 1;
};

// ── Watchers ───────────────────────────────────────────────────────────────

/// Watches Git's metadata (`--git-dir` and `--git-common-dir`): commits,
/// checkouts, fetches made anywhere. Coalesced by 0.2 s.
class GitRepositoryMonitor {
public:
    GitRepositoryMonitor(const std::wstring& directory, std::function<void()> onChange);
    ~GitRepositoryMonitor();
    void stop();
    static std::vector<std::wstring> metadataDirectories(const std::wstring& directory);
private:
    void changed();
    std::vector<std::unique_ptr<DirectoryWatcher>> watchers_;
    std::function<void()> onChange_;
    std::shared_ptr<Dispatch::Pending> pending_;
    bool stopped_ = false;
    Lifetime life_;
};

/// Watches the working tree and says only that something changed. Bursts are
/// coalesced: delivered after 0.1 s of quiet, and never held back past 1 s.
class WorkspaceFileMonitor {
public:
    static constexpr double quietWindow = 0.10;
    static constexpr double maximumDelay = 1.0;
    WorkspaceFileMonitor(const std::wstring& directory, std::function<void()> onChange);
    ~WorkspaceFileMonitor();
    void stop();
    void noteChange();
private:
    std::unique_ptr<DirectoryWatcher> watcher_;
    std::function<void()> onChange_;
    std::shared_ptr<Dispatch::Pending> pending_;
    std::optional<double> pendingSince_;
    bool stopped_ = false;
};

// ── Background fetch ───────────────────────────────────────────────────────

/// `git fetch` for a project when it comes on screen, at most every two
/// minutes per project.
namespace BackgroundFetch {
constexpr double minimumInterval = 120;
constexpr double timeout = 60;
/// `started` and `finished` run on the main thread, only for a fetch that
/// actually runs; `finished` says whether a remote-tracking branch moved.
void fetchIfDue(const std::wstring& directory, std::function<void()> started,
                std::function<void(bool refsMoved)> finished);
}  // namespace BackgroundFetch

// ── Launchers ──────────────────────────────────────────────────────────────

namespace TerminalLauncher {
/// Windows Terminal in a window of its own when installed; PowerShell or the
/// Command Prompt otherwise.
void open(const std::wstring& directory);
}

namespace LauncherInstaller {
/// Puts the folder holding the `gift` command on the user's PATH, once, and
/// never over an unrelated command of the same name. Runs in the background.
void installIfNeeded();
}

/// Opens Explorer with `path` selected.
void revealInExplorer(const std::wstring& path);
/// Plain text onto the clipboard.
void copyToClipboard(HWND owner, const std::wstring& text);

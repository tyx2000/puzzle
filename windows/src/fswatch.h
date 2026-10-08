// FSEvents' role on Windows: ReadDirectoryChangesW on a thread of its own,
// reporting only that something under a folder changed.
#pragma once

#include "base.h"

/// Watches one folder tree. `onEvent` runs on the main thread, once per batch
/// the system delivers. The plain form does not read the paths; the other
/// hands over the full paths that changed (the folder itself when the system
/// lost track of them).
class DirectoryWatcher {
public:
    DirectoryWatcher(const std::wstring& directory, std::function<void()> onEvent);
    DirectoryWatcher(const std::wstring& directory,
                     std::function<void(const std::vector<std::wstring>&)> onPaths);
    ~DirectoryWatcher();
    DirectoryWatcher(const DirectoryWatcher&) = delete;
    DirectoryWatcher& operator=(const DirectoryWatcher&) = delete;
    void stop();
    bool isWatching() const { return started_; }

private:
    void start(const std::wstring& directory);
    struct Shared;
    std::shared_ptr<Shared> shared_;
    bool started_ = false;
};

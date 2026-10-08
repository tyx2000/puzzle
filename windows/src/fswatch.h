// FSEvents' role on Windows: ReadDirectoryChangesW on a thread of its own,
// reporting only that something under a folder changed.
#pragma once

#include "base.h"

/// Watches one folder tree. `onEvent` runs on the main thread, once per batch
/// the system delivers; the paths are not read — every event means the same
/// thing to the callers.
class DirectoryWatcher {
public:
    DirectoryWatcher(const std::wstring& directory, std::function<void()> onEvent);
    ~DirectoryWatcher();
    DirectoryWatcher(const DirectoryWatcher&) = delete;
    DirectoryWatcher& operator=(const DirectoryWatcher&) = delete;
    void stop();
    bool isWatching() const { return started_; }

private:
    struct Shared;
    std::shared_ptr<Shared> shared_;
    bool started_ = false;
};

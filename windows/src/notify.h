// The few NotificationCenter names the editor posts, as plain observer lists.
// Everything runs on the main thread.
#pragma once

#include "base.h"

enum class Notice {
    /// A document's foldable blocks, JSX pairs or Markdown presentation changed.
    DocumentStructureDidChange,
    /// A document took the version on disk.
    DocumentDidReloadFromDisk,
    /// The file changed on disk under unsaved edits.
    DocumentDiskConflict,
    /// The highlighter rewrote a document's style bytes.
    DocumentRestyled,
    /// The recent-projects list changed.
    RecentProjectsDidChange,
};

namespace Notifications {
/// The returned id removes the observer.
int add(Notice name, std::function<void(void* object)> observer);
void remove(int id);
void post(Notice name, void* object = nullptr);
}  // namespace Notifications

/// Removes its observer when it goes away.
class Observation {
public:
    Observation() = default;
    Observation(Notice name, std::function<void(void*)> observer)
        : id_(Notifications::add(name, std::move(observer))) {}
    ~Observation() { if (id_) Notifications::remove(id_); }
    Observation(const Observation&) = delete;
    Observation& operator=(const Observation&) = delete;
    Observation(Observation&& o) noexcept : id_(o.id_) { o.id_ = 0; }
    Observation& operator=(Observation&& o) noexcept {
        if (this != &o) {
            if (id_) Notifications::remove(id_);
            id_ = o.id_;
            o.id_ = 0;
        }
        return *this;
    }
private:
    int id_ = 0;
};

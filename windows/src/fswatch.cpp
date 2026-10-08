#include "fswatch.h"

#include "dispatch.h"

#include <thread>

struct DirectoryWatcher::Shared {
    HANDLE directory = INVALID_HANDLE_VALUE;
    HANDLE stopEvent = nullptr;
    std::atomic<bool> stopped{false};
    std::function<void()> onEvent;  // main thread only
    /// Closed by whoever lets go last: the watching thread, after its last
    /// read was cancelled, or the watcher when no thread ever started.
    ~Shared() {
        if (directory != INVALID_HANDLE_VALUE) CloseHandle(directory);
        if (stopEvent) CloseHandle(stopEvent);
    }
};

DirectoryWatcher::DirectoryWatcher(const std::wstring& directory, std::function<void()> onEvent)
    : shared_(std::make_shared<Shared>()) {
    shared_->onEvent = std::move(onEvent);
    shared_->directory = CreateFileW(
        directory.c_str(), FILE_LIST_DIRECTORY,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED, nullptr);
    if (shared_->directory == INVALID_HANDLE_VALUE) return;
    shared_->stopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    started_ = true;
    auto shared = shared_;
    std::thread([shared] {
        std::vector<BYTE> buffer(64 * 1024);
        OVERLAPPED overlapped{};
        overlapped.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        const DWORD filter = FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME
            | FILE_NOTIFY_CHANGE_SIZE | FILE_NOTIFY_CHANGE_LAST_WRITE
            | FILE_NOTIFY_CHANGE_CREATION | FILE_NOTIFY_CHANGE_ATTRIBUTES;
        while (!shared->stopped) {
            ResetEvent(overlapped.hEvent);
            if (!ReadDirectoryChangesW(shared->directory, buffer.data(), (DWORD)buffer.size(),
                                       TRUE, filter, nullptr, &overlapped, nullptr)) {
                break;
            }
            HANDLE waits[2] = {overlapped.hEvent, shared->stopEvent};
            DWORD which = WaitForMultipleObjects(2, waits, FALSE, INFINITE);
            if (which != WAIT_OBJECT_0) {
                CancelIoEx(shared->directory, &overlapped);
                DWORD ignored = 0;
                GetOverlappedResult(shared->directory, &overlapped, &ignored, TRUE);
                break;
            }
            DWORD bytes = 0;
            if (!GetOverlappedResult(shared->directory, &overlapped, &bytes, FALSE)) break;
            // Zero bytes is an overflow: changes were lost, which still means
            // something changed.
            Dispatch::main([shared] {
                if (!shared->stopped && shared->onEvent) shared->onEvent();
            });
        }
        CloseHandle(overlapped.hEvent);
    }).detach();
}

DirectoryWatcher::~DirectoryWatcher() { stop(); }

void DirectoryWatcher::stop() {
    if (!shared_) return;
    shared_->stopped = true;
    shared_->onEvent = nullptr;
    if (shared_->stopEvent) SetEvent(shared_->stopEvent);
    shared_.reset();
    started_ = false;
}

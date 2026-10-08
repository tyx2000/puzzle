// The Grand Central Dispatch the Swift sources lean on, in the shape they use
// it: work handed to the main thread, delayed main-thread work that can be
// called off, and serial background queues.
#pragma once

#include "base.h"

#include <condition_variable>
#include <deque>
#include <thread>

namespace Dispatch {

/// Creates the hidden window main-thread work is delivered through. Called
/// once, on the main thread, before anything is posted.
void initialize();
bool isMainThread();

/// Run `work` on the main thread, after whatever is running there returns.
void main(std::function<void()> work);

/// A main-thread call that can be withdrawn before it runs.
class Pending {
public:
    void cancel() { cancelled_ = true; }
    bool cancelled() const { return cancelled_; }
private:
    std::atomic<bool> cancelled_{false};
};

/// Run `work` on the main thread after `seconds`. The returned handle cancels
/// it; dropping the handle does not.
std::shared_ptr<Pending> after(double seconds, std::function<void()> work);

/// A main-thread timer that fires until stopped.
class RepeatingTimer {
public:
    RepeatingTimer() = default;
    ~RepeatingTimer() { stop(); }
    RepeatingTimer(const RepeatingTimer&) = delete;
    RepeatingTimer& operator=(const RepeatingTimer&) = delete;
    void start(double interval, std::function<void()> tick);
    void stop();
    bool running() const { return id_ != 0; }
private:
    UINT_PTR id_ = 0;
};

/// A serial queue on a thread of its own: work runs one item at a time, in
/// the order it was added.
class Queue {
public:
    explicit Queue(const char* name);
    /// Work already queued still runs; the thread ends after it.
    ~Queue();
    Queue(const Queue&) = delete;
    Queue& operator=(const Queue&) = delete;
    void async(std::function<void()> work);
private:
    struct State {
        std::mutex mutex;
        std::condition_variable wake;
        std::deque<std::function<void()>> items;
        bool stopping = false;
    };
    std::shared_ptr<State> state_;
};

/// Work that no one queue owns — a pipe reader, a stdin writer.
void background(std::function<void()> work);

/// Called by the message loop for the dispatch window's messages.
bool handleMessage(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam, LRESULT* result);

}  // namespace Dispatch

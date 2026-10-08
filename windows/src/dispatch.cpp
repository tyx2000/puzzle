#include "dispatch.h"

namespace Dispatch {

namespace {

constexpr UINT kDrainMessage = WM_APP + 1;

HWND gWindow = nullptr;
DWORD gMainThread = 0;
std::mutex gMutex;
std::deque<std::function<void()>> gPending;
bool gPosted = false;

struct TimerEntry {
    std::function<void()> work;
    bool repeating = false;
    std::shared_ptr<Pending> handle;
};
std::unordered_map<UINT_PTR, TimerEntry> gTimers;
UINT_PTR gNextTimer = 1000;

LRESULT CALLBACK dispatchProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
    LRESULT result = 0;
    if (handleMessage(hwnd, message, wParam, lParam, &result)) return result;
    return DefWindowProcW(hwnd, message, wParam, lParam);
}

void drain() {
    std::deque<std::function<void()>> work;
    {
        std::lock_guard<std::mutex> lock(gMutex);
        work.swap(gPending);
        gPosted = false;
    }
    for (auto& item : work) item();
}

}  // namespace

void initialize() {
    gMainThread = GetCurrentThreadId();
    WNDCLASSW wc{};
    wc.lpfnWndProc = dispatchProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = L"Gift.Dispatch";
    RegisterClassW(&wc);
    gWindow = CreateWindowExW(0, wc.lpszClassName, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr,
                              wc.hInstance, nullptr);
}

bool isMainThread() { return GetCurrentThreadId() == gMainThread; }

void main(std::function<void()> work) {
    bool post = false;
    {
        std::lock_guard<std::mutex> lock(gMutex);
        gPending.push_back(std::move(work));
        if (!gPosted) {
            gPosted = true;
            post = true;
        }
    }
    if (post) PostMessageW(gWindow, kDrainMessage, 0, 0);
}

std::shared_ptr<Pending> after(double seconds, std::function<void()> work) {
    auto handle = std::make_shared<Pending>();
    auto schedule = [handle, seconds, work = std::move(work)]() mutable {
        if (handle->cancelled()) return;
        UINT_PTR id = gNextTimer++;
        gTimers[id] = TimerEntry{std::move(work), false, handle};
        SetTimer(gWindow, id, (UINT)std::max(0.0, std::ceil(seconds * 1000.0)), nullptr);
    };
    if (isMainThread()) schedule();
    else main(std::move(schedule));
    return handle;
}

void RepeatingTimer::start(double interval, std::function<void()> tick) {
    stop();
    id_ = gNextTimer++;
    gTimers[id_] = TimerEntry{std::move(tick), true, nullptr};
    SetTimer(gWindow, id_, (UINT)std::max(1.0, interval * 1000.0), nullptr);
}

void RepeatingTimer::stop() {
    if (!id_) return;
    KillTimer(gWindow, id_);
    gTimers.erase(id_);
    id_ = 0;
}

bool handleMessage(HWND hwnd, UINT message, WPARAM wParam, LPARAM, LRESULT* result) {
    if (hwnd != gWindow) return false;
    if (message == kDrainMessage) {
        drain();
        *result = 0;
        return true;
    }
    if (message == WM_TIMER) {
        auto it = gTimers.find(wParam);
        if (it == gTimers.end()) {
            KillTimer(hwnd, wParam);
            return true;
        }
        if (it->second.repeating) {
            // Copied: the tick may stop (and so erase) its own timer.
            auto tick = it->second.work;
            tick();
        } else {
            KillTimer(hwnd, wParam);
            TimerEntry entry = std::move(it->second);
            gTimers.erase(it);
            if (!entry.handle || !entry.handle->cancelled()) entry.work();
        }
        *result = 0;
        return true;
    }
    return false;
}

Queue::Queue(const char*) : state_(std::make_shared<State>()) {
    std::thread([state = state_] {
        while (true) {
            std::function<void()> work;
            {
                std::unique_lock<std::mutex> lock(state->mutex);
                state->wake.wait(lock, [&] { return state->stopping || !state->items.empty(); });
                if (state->items.empty()) return;
                work = std::move(state->items.front());
                state->items.pop_front();
            }
            work();
        }
    }).detach();
}

Queue::~Queue() {
    {
        std::lock_guard<std::mutex> lock(state_->mutex);
        state_->stopping = true;
    }
    state_->wake.notify_all();
}

void Queue::async(std::function<void()> work) {
    {
        std::lock_guard<std::mutex> lock(state_->mutex);
        state_->items.push_back(std::move(work));
    }
    state_->wake.notify_one();
}

void background(std::function<void()> work) {
    std::thread(std::move(work)).detach();
}

}  // namespace Dispatch

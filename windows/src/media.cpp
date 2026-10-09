#include "previews.h"

#include "theme.h"

#include <mfapi.h>
#include <mfplay.h>

namespace {

constexpr wchar_t kVideoClass[] = L"Puzzle.Video";

std::wstring clock(double seconds) {
    if (!std::isfinite(seconds) || seconds < 0) return L"0:00";
    long long total = std::llround(seconds);
    wchar_t buffer[32];
    long long hours = total / 3600;
    if (hours > 0) swprintf(buffer, 32, L"%lld:%02lld:%02lld", hours, (total / 60) % 60, total % 60);
    else swprintf(buffer, 32, L"%lld:%02lld", total / 60, total % 60);
    return buffer;
}

}  // namespace

/// The MFPlay object and its callback; events arrive on the main thread.
struct MediaPreviewView::Player : public IMFPMediaPlayerCallback {
    MediaPreviewView* owner;
    Com<IMFPMediaPlayer> player;
    std::atomic<ULONG> references{1};
    explicit Player(MediaPreviewView* o) : owner(o) {}
    virtual ~Player() = default;

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** out) override {
        if (riid == IID_IUnknown || riid == __uuidof(IMFPMediaPlayerCallback)) {
            *out = static_cast<IMFPMediaPlayerCallback*>(this);
            AddRef();
            return S_OK;
        }
        *out = nullptr;
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++references; }
    ULONG STDMETHODCALLTYPE Release() override {
        ULONG left = --references;
        if (left == 0) delete this;
        return left;
    }
    void STDMETHODCALLTYPE OnMediaPlayerEvent(MFP_EVENT_HEADER* header) override {
        if (!header || !owner) return;
        owner->playerEvent((int)header->eEventType, header->hrEvent);
    }
};

static LRESULT CALLBACK videoProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) noexcept {
    auto* player = reinterpret_cast<IMFPMediaPlayer*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    switch (message) {
    case WM_PAINT: {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(hwnd, &ps);
        if (player) player->UpdateVideo();
        else FillRect(dc, &ps.rcPaint, (HBRUSH)GetStockObject(BLACK_BRUSH));
        EndPaint(hwnd, &ps);
        return 0;
    }
    case WM_SIZE:
        if (player) player->UpdateVideo();
        return 0;
    case WM_ERASEBKGND:
        return 1;
    default:
        return DefWindowProcW(hwnd, message, wParam, lParam);
    }
}

MediaPreviewView::MediaPreviewView() {
    backgroundColor = Theme::editorBackground;
    static bool started = false;
    if (!started) {
        started = true;
        MFStartup(MF_VERSION, MFSTARTUP_LITE);
        WNDCLASSW wc{};
        wc.lpfnWndProc = videoProc;
        wc.hInstance = GetModuleHandleW(nullptr);
        wc.lpszClassName = kVideoClass;
        wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
        RegisterClassW(&wc);
    }
}

MediaPreviewView::~MediaPreviewView() {
    clear();
    if (videoWindow_) DestroyWindow(videoWindow_);
}

void MediaPreviewView::show(const std::wstring& path, const std::wstring& caption, bool isVideo) {
    if (loadedPath_ == path && player_) return;
    clear();
    loadedPath_ = path;
    baseCaption_ = caption;
    caption_ = caption;
    isVideo_ = isVideo;
    if (isVideo && !videoWindow_ && window()) {
        videoWindow_ = CreateWindowExW(0, kVideoClass, L"", WS_CHILD | WS_CLIPSIBLINGS, 0, 0, 10, 10,
                                       window()->hwnd(), nullptr, GetModuleHandleW(nullptr), nullptr);
    }
    player_ = std::unique_ptr<Player>(new Player(this));
    // Playback never starts on its own: opening a file should not make noise.
    HRESULT hr = MFPCreateMediaPlayer(path.c_str(), FALSE, MFP_OPTION_NONE, player_.get(),
                                      isVideo ? videoWindow_ : nullptr, player_->player.put());
    if (FAILED(hr) || !player_->player) {
        caption_ = baseCaption_ + L"  ·  " + systemErrorMessage((DWORD)hr);
    } else if (isVideo) {
        player_->player->SetBorderColor(Theme::editorBackground.colorref());
        player_->player->SetAspectRatioMode(MFVideoARMode_PreservePicture);
        SetWindowLongPtrW(videoWindow_, GWLP_USERDATA, (LONG_PTR)player_->player.get());
    }
    timer_.start(0.25, [this] { tick(); });
    setNeedsLayout();
    setNeedsDisplay();
    updateNative();
}

void MediaPreviewView::clear() {
    timer_.stop();
    if (player_) {
        player_->owner = nullptr;
        if (player_->player) {
            player_->player->Stop();
            player_->player->Shutdown();
        }
        player_->player.reset();
        // Released through COM: MFPlay may still hold the callback.
        player_.release()->Release();
    }
    if (videoWindow_) {
        SetWindowLongPtrW(videoWindow_, GWLP_USERDATA, 0);
        ShowWindow(videoWindow_, SW_HIDE);
    }
    loadedPath_.clear();
    baseCaption_.clear();
    caption_.clear();
    playing_ = false;
    duration_ = elapsed_ = 0;
    progress_ = 0;
    setNeedsDisplay();
}

void MediaPreviewView::refreshFonts() { setNeedsDisplay(); }

void MediaPreviewView::playerEvent(int kind, HRESULT status) {
    switch ((MFP_EVENT_TYPE)kind) {
    case MFP_EVENT_TYPE_MEDIAITEM_SET:
        if (FAILED(status)) {
            // A supported container can still hold a codec with no decoder.
            caption_ = baseCaption_ + L"  ·  " + systemErrorMessage((DWORD)status);
        } else {
            describe();
        }
        break;
    case MFP_EVENT_TYPE_PLAY:
        playing_ = SUCCEEDED(status);
        break;
    case MFP_EVENT_TYPE_PAUSE:
    case MFP_EVENT_TYPE_STOP:
    case MFP_EVENT_TYPE_PLAYBACK_ENDED:
        playing_ = false;
        break;
    case MFP_EVENT_TYPE_ERROR:
        playing_ = false;
        caption_ = baseCaption_ + L"  ·  " + systemErrorMessage((DWORD)status);
        break;
    default:
        break;
    }
    tick();
    setNeedsDisplay();
}

void MediaPreviewView::describe() {
    if (!player_ || !player_->player) return;
    PROPVARIANT value;
    PropVariantInit(&value);
    if (SUCCEEDED(player_->player->GetDuration(MFP_POSITIONTYPE_100NS, &value)) && value.vt == VT_UI8) {
        duration_ = value.uhVal.QuadPart / 1e7;
    }
    PropVariantClear(&value);
    std::vector<std::wstring> parts{baseCaption_};
    if (isVideo_) {
        SIZE native{}, aspect{};
        if (SUCCEEDED(player_->player->GetNativeVideoSize(&native, &aspect)) && native.cx > 0 && native.cy > 0) {
            parts.push_back(std::to_wstring(native.cx) + L" × " + std::to_wstring(native.cy));
        }
    }
    if (duration_ >= 1) parts.push_back(clock(duration_));
    caption_ = join(parts, L"  ·  ");
}

void MediaPreviewView::tick() {
    if (!player_ || !player_->player) return;
    PROPVARIANT value;
    PropVariantInit(&value);
    if (SUCCEEDED(player_->player->GetPosition(MFP_POSITIONTYPE_100NS, &value)) && value.vt == VT_UI8) {
        elapsed_ = value.uhVal.QuadPart / 1e7;
    }
    PropVariantClear(&value);
    if (!scrubbing_ && duration_ > 0) progress_ = (float)std::clamp(elapsed_ / duration_, 0.0, 1.0);
    setNeedsDisplay();
}

void MediaPreviewView::togglePlayback() {
    if (!player_ || !player_->player) return;
    if (!playing_) {
        // Play on a finished file starts it again.
        if (duration_ > 0 && elapsed_ >= duration_ - 0.05) seek(0);
        player_->player->Play();
    } else {
        player_->player->Pause();
    }
}

void MediaPreviewView::seek(float fraction) {
    if (!player_ || !player_->player || duration_ <= 0) return;
    PROPVARIANT value;
    PropVariantInit(&value);
    value.vt = VT_I8;
    value.hVal.QuadPart = (LONGLONG)(duration_ * fraction * 1e7);
    player_->player->SetPosition(MFP_POSITIONTYPE_100NS, &value);
    elapsed_ = duration_ * fraction;
}

Rect MediaPreviewView::transportRect() const {
    Rect b = bounds();
    float width = std::min(preferredWidth, std::max(0.0f, b.w - 48));
    float captionTop = b.h - 16 - 18;
    return Rect(std::round(b.midX() - width / 2), captionTop - 22 - barHeight, width, barHeight);
}

Rect MediaPreviewView::videoRect() const {
    Rect b = bounds();
    Rect bar = transportRect();
    return Rect(16, 16, std::max(0.0f, b.w - 32), std::max(0.0f, bar.y - 12 - 16));
}

Rect MediaPreviewView::playRect() const {
    Rect bar = transportRect();
    return Rect(bar.x, bar.y + (bar.h - 24) / 2, 24, 24);
}

Rect MediaPreviewView::railRect() const {
    Rect bar = transportRect();
    float left = playRect().maxX() + 8 + 44 + 10;
    float right = bar.maxX() - 44 - 10;
    return Rect(left, bar.y, std::max(0.0f, right - left), bar.h);
}

void MediaPreviewView::layout() { updateNative(); }

void MediaPreviewView::updateNative() {
    if (!videoWindow_) return;
    WindowHost* host = window();
    bool visible = host && isVideo_ && player_ && isVisibleInWindow();
    if (!visible) {
        ShowWindow(videoWindow_, SW_HIDE);
        return;
    }
    float s = host->scale();
    Rect r = convertToWindow(videoRect());
    SetWindowPos(videoWindow_, nullptr, (int)std::lround(r.x * s), (int)std::lround(r.y * s),
                 std::max(1, (int)std::lround(r.w * s)), std::max(1, (int)std::lround(r.h * s)),
                 SWP_NOZORDER | SWP_NOACTIVATE | SWP_SHOWWINDOW);
    if (player_ && player_->player) player_->player->UpdateVideo();
}

void MediaPreviewView::draw(Graphics& g) {
    Rect b = bounds();
    if (!isVideo_ && !loadedPath_.empty()) {
        // A waveform where a video's picture would be.
        Point c(b.midX(), b.midY() - 30);
        float heights[] = {10, 22, 34, 18, 28, 12, 24, 8};
        for (int i = 0; i < 8; ++i) {
            float x = c.x - 28 + i * 8;
            g.line(Point(x, c.y - heights[i] / 2), Point(x, c.y + heights[i] / 2), Theme::dimText, 1.5f, true);
        }
    }
    if (!loadedPath_.empty()) {
        Rect play = playRect();
        Color ink = Theme::foreground;
        if (playing_) {
            g.fillRect(Rect(play.midX() - 4.5f, play.midY() - 6, 3, 12), ink);
            g.fillRect(Rect(play.midX() + 1.5f, play.midY() - 6, 3, 12), ink);
        } else {
            g.polyline({{play.midX() - 4, play.midY() - 6.5f}, {play.midX() + 6, play.midY()},
                        {play.midX() - 4, play.midY() + 6.5f}},
                       ink, 1.5f, true, true);
        }
        Font font = Theme::uiFont(10.5f);
        Rect bar = transportRect();
        g.text(clock(elapsed_), font, Theme::dimText, Rect(play.maxX() + 8, bar.y, 44, bar.h));
        g.text(duration_ > 0 ? L"-" + clock(std::max(0.0, duration_ - elapsed_)) : L"0:00", font, Theme::dimText,
               Rect(bar.maxX() - 44, bar.y, 44, bar.h), LineBreak::Clipping, Align::Right);
        Rect rail = railRect();
        const float knob = 5, railHeight = 3;
        float railWidth = std::max(0.0f, rail.w - knob * 2);
        if (railWidth > 0) {
            Rect track(rail.x + knob, rail.midY() - railHeight / 2, railWidth, railHeight);
            g.fillRoundedRect(track, railHeight / 2, Theme::scrollerSlot);
            g.fillRoundedRect(Rect(track.x, track.y, track.w * progress_, track.h), railHeight / 2, Theme::cursor);
            float kx = track.x + track.w * progress_;
            g.fillEllipse(Rect(kx - knob, rail.midY() - knob, knob * 2, knob * 2), Theme::cursor);
        }
    }
    if (!caption_.empty()) {
        g.text(caption_, Theme::uiFont(10.5f), Theme::dimText, Rect(16, b.h - 16 - 18, std::max(0.0f, b.w - 32), 18),
               LineBreak::TruncatingMiddle, Align::Center);
    }
}

bool MediaPreviewView::mouseDown(const MouseEvent& e) {
    if (playRect().inset(-4, -4).contains(e.location)) {
        togglePlayback();
        return true;
    }
    Rect rail = railRect();
    if (rail.contains(e.location) && duration_ > 0) {
        scrubbing_ = true;
        mouseDragged(e);
        return true;
    }
    return false;
}

void MediaPreviewView::mouseDragged(const MouseEvent& e) {
    if (!scrubbing_) return;
    Rect rail = railRect();
    float fraction = std::clamp((e.location.x - rail.x - 5) / std::max(1.0f, rail.w - 10), 0.0f, 1.0f);
    progress_ = fraction;
    seek(fraction);
    setNeedsDisplay();
}

void MediaPreviewView::mouseUp(const MouseEvent& e) {
    if (scrubbing_) mouseDragged(e);
    scrubbing_ = false;
}

Cursor MediaPreviewView::cursorAt(Point p) {
    if (playRect().inset(-4, -4).contains(p) || railRect().contains(p)) return Cursor::Hand;
    return Cursor::Arrow;
}

// A top-level window drawn by its view tree: the NSWindow the AppKit sources
// configure with a transparent, full-size titlebar. Here the whole window is
// client area — the caption is drawn, the caption buttons are views, and the
// edges answer to resizing the way WindowResizeHandleView's bands did.
#pragma once

#include "view.h"

class WindowHost;

/// A view whose native child (an EDIT) it colours itself: the window passes
/// WM_CTLCOLOREDIT for that child here.
struct NativeColorProvider {
    virtual ~NativeColorProvider() = default;
    virtual HBRUSH controlColor(HDC dc) = 0;
    /// A WM_COMMAND notification from that child (EN_CHANGE and the like).
    virtual void controlCommand(WORD) {}
    /// A WM_NOTIFY from that child; true when handled, with `result` set.
    virtual bool controlNotify(NMHDR*, LRESULT*) { return false; }
    /// A key for the child, before the window's shortcuts see it; true when
    /// the child's host handled it.
    virtual bool nativeKeyDown(const KeyEvent&) { return false; }
};
inline constexpr wchar_t kNativeColorProperty[] = L"Puzzle.NativeColors";

/// Minimise, maximise/restore and close, drawn at the top-right corner.
class CaptionButtonsView : public View {
public:
    static constexpr float buttonWidth = 46;
    static constexpr float buttonHeight = 32;
    CaptionButtonsView();
    /// HTMINBUTTON, HTMAXBUTTON, HTCLOSE or HTNOWHERE for a point in this view.
    int hitCode(Point local) const;
    void setHot(int code);
    void setPressed(int code);
    int pressed() const { return pressed_; }
    void draw(Graphics& g) override;
    float preferredWidth() const { return buttonWidth * 3; }
    bool showsMinimize = true;
    bool showsMaximize = true;
private:
    Rect rectFor(int code) const;
    int hot_ = HTNOWHERE;
    int pressed_ = HTNOWHERE;
};

class WindowHost {
public:
    WindowHost();
    virtual ~WindowHost();
    WindowHost(const WindowHost&) = delete;
    WindowHost& operator=(const WindowHost&) = delete;

    HWND hwnd() const { return hwnd_; }
    static WindowHost* fromHwnd(HWND hwnd);

    View* rootView() const { return root_; }
    void setRootView(View* root);
    float dpi() const { return dpi_; }
    float scale() const { return dpi_ / 96.0f; }
    Size clientSize() const;

    void show(int command = SW_SHOWNORMAL);
    /// As the close box does: asks `windowShouldClose` first.
    void performClose();
    void destroy();
    void setTitle(const std::wstring& title);
    void bringToFront();
    bool isActive() const;
    bool isMinimized() const;
    bool isMaximized() const;

    void invalidate(const Rect& windowRect);
    void invalidateAll();
    void setNeedsLayout();
    void setNeedsNativeUpdate();
    /// Draw now rather than at the next WM_PAINT — a drag that must be seen
    /// to follow the pointer.
    void displayIfNeeded();

    void setFocusedView(View* view);
    View* focusedView() const { return focused_; }
    /// Called by a view leaving the tree (or hidden, or destroyed).
    void viewWillLeave(View* view, bool keepingTree = false);
    /// Hover is read again at the pointer, for a tree that changed under it.
    void refreshHover();
    /// The pointer, in window coordinates.
    Point mouseLocation() const;
    /// Screen pixels for a point in window coordinates.
    POINT screenPoint(Point windowPoint) const;

    /// Whether keyboard focus is in a native child (a text field).
    bool isTextInputFocused() const;

    /// The message loop asks before dispatching a key.
    bool preTranslateKey(const MSG& message);

    // Custom frame.
    CaptionButtonsView* captionButtons = nullptr;
    float resizeBorder = 8;
    Size minimumSize{320, 240};

protected:
    void createWindow(const std::wstring& title, DWORD style, DWORD exStyle, HWND owner,
                      const RECT& pixelFrame);
    virtual LRESULT handleMessage(UINT message, WPARAM wParam, LPARAM lParam);
    LRESULT defaultHandling(UINT message, WPARAM wParam, LPARAM lParam);

    virtual void windowDidActivate(bool) {}
    virtual bool windowShouldClose() { return true; }
    virtual void windowWillClose() {}
    virtual void windowDidResize() {}
    virtual void windowDidMinimize() {}
    virtual bool handleShortcut(const KeyEvent&) { return false; }

private:
    static LRESULT CALLBACK windowProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) noexcept;
    void paint();
    void drawView(View* view, Graphics& g, const Rect& dirty);
    void updateNatives(View* view);
    int nonClientHit(Point windowPoint);
    MouseEvent makeEvent(View* view, Point windowPoint, int clicks) const;
    void mouseMoved(Point windowPoint);
    void setHoverChain(std::vector<View*> chain, Point windowPoint);
    void mouseDown(Point windowPoint, int clicks);
    void mouseUp(Point windowPoint);
    void rightMouseDown(Point windowPoint);
    void wheel(float dx, float dy, Point windowPoint);
    void updateTooltip(Point windowPoint);
    Point pointFromLParam(LPARAM lParam) const;

    HWND hwnd_ = nullptr;
    View* root_ = nullptr;
    std::unique_ptr<Surface> surface_;
    float dpi_ = 96;
    bool needsLayout_ = true;
    bool needsNativeUpdate_ = true;
    bool layoutChangedTree_ = false;
    std::vector<View*> hoverChain_;
    View* pressed_ = nullptr;
    View* focused_ = nullptr;
    bool trackingLeave_ = false;
    bool trackingNonClientLeave_ = false;
    HWND tooltip_ = nullptr;
    std::wstring tooltipText_;
    Rect dirty_;
    bool painting_ = false;
};

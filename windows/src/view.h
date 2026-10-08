// A small retained view tree drawn with Direct2D — the NSView hierarchy the
// AppKit sources build, with the parts of it they use: flipped coordinates,
// draw / layout passes, hover tracking, clicks, drags, wheel and cursors.
#pragma once

#include "render.h"

class WindowHost;

enum class Cursor { Arrow, Hand, ResizeLeftRight, ResizeUpDown, IBeam };

struct MouseEvent {
    /// In the receiving view's own coordinates.
    Point location;
    /// In the window's coordinates (DIPs).
    Point windowLocation;
    int clickCount = 1;
    bool shift = false;
    bool control = false;
    bool alt = false;
};

struct KeyEvent {
    UINT key = 0;  // virtual-key code
    bool shift = false;
    bool control = false;
    bool alt = false;
    bool repeat = false;
};

class View {
public:
    View();
    virtual ~View();
    View(const View&) = delete;
    View& operator=(const View&) = delete;

    // ── Hierarchy (views are not owned by their superview) ──
    void addSubview(View* child);
    void insertSubview(View* child, size_t index);
    void removeFromSuperview();
    const std::vector<View*>& subviews() const { return subviews_; }
    View* superview() const { return superview_; }
    WindowHost* window() const;
    bool isDescendant(const View* ancestor) const;

    // ── Geometry ──
    const Rect& frame() const { return frame_; }
    void setFrame(const Rect& frame);
    Rect bounds() const { return Rect(0, 0, frame_.w, frame_.h); }
    Point convertToWindow(Point p) const;
    Rect convertToWindow(const Rect& r) const;
    Point convertFromWindow(Point p) const;

    bool isHidden() const { return hidden_; }
    void setHidden(bool hidden);
    /// Hidden by neither itself nor anything above it, and in a window.
    bool isVisibleInWindow() const;

    // ── Drawing ──
    Color backgroundColor = Color::clear();
    bool clipsToBounds = true;
    virtual void draw(Graphics&) {}
    virtual void drawOver(Graphics&) {}
    void setNeedsDisplay();
    void setNeedsDisplay(const Rect& local);

    // ── Layout ──
    virtual void layout() {}
    void setNeedsLayout();
    bool needsLayout() const { return needsLayout_; }
    /// Lay out now, and everything under it.
    void layoutSubtreeIfNeeded();

    // ── Events ──
    /// The deepest view under `point` (in this view's coordinates) that takes
    /// the mouse, or nullptr.
    virtual View* hitTest(Point point);
    /// A view that never takes the mouse itself; its subviews still may.
    bool ignoresMouse = false;
    virtual bool mouseDown(const MouseEvent&) { return false; }
    virtual void mouseDragged(const MouseEvent&) {}
    virtual void mouseUp(const MouseEvent&) {}
    virtual void mouseMoved(const MouseEvent&) {}
    virtual void mouseEntered() {}
    virtual void mouseExited() {}
    virtual bool rightMouseDown(const MouseEvent&) { return false; }
    /// `dx`/`dy` are how far the content should move, in DIPs.
    virtual bool scrollWheel(float dx, float dy, const MouseEvent&) { return false; }
    virtual Cursor cursorAt(Point) { return Cursor::Arrow; }
    virtual std::wstring tooltipAt(Point) { return tooltip; }
    std::wstring tooltip;
    virtual bool keyDown(const KeyEvent&) { return false; }
    virtual bool acceptsFocus() const { return false; }
    virtual void focusChanged(bool) {}
    /// Empty band in a custom title bar: dragging it moves the window.
    virtual bool isWindowDragArea(Point) { return false; }
    /// Called once the view (or an ancestor) joined or left a window, and
    /// after every layout pass, so a view hosting a native control can place
    /// it.
    virtual void updateNative() {}
    virtual void viewDidMoveToWindow() {}
    virtual void dpiChanged() {}

protected:
    bool hovered_ = false;

private:
    friend class WindowHost;
    void attach(WindowHost* window);
    Rect frame_;
    bool hidden_ = false;
    bool needsLayout_ = true;
    View* superview_ = nullptr;
    std::vector<View*> subviews_;
    WindowHost* window_ = nullptr;
};

/// Runs `release` on the next turn of the main loop.
void retireLater(std::function<void()> release);

/// Lets go of a view once the current event has been handled: a row whose own
/// click rebuilt the list it was in must outlive that click.
template <class T>
void retireView(std::unique_ptr<T> view) {
    if (!view) return;
    view->removeFromSuperview();
    std::shared_ptr<T> holder(view.release());
    retireLater([holder] {});
}
/// A view that fills itself with one colour and draws optional 1pt edges:
/// `FlatView`.
class FlatView : public View {
public:
    Color fillColor = Color::clear();
    Color edgeColor;
    bool topBorder = false;
    bool bottomBorder = false;
    bool rightBorder = false;
    void draw(Graphics& g) override;
};

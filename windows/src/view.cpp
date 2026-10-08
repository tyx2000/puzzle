#include "view.h"

#include "theme.h"
#include "dispatch.h"
#include "window.h"

void retireLater(std::function<void()> release) { Dispatch::main(std::move(release)); }

View::View() = default;

View::~View() {
    // Whatever still points here — hover, a press, focus — lets go first.
    if (WindowHost* host = window()) host->viewWillLeave(this);
    for (View* child : subviews_) {
        child->superview_ = nullptr;
    }
    if (superview_) {
        auto& siblings = superview_->subviews_;
        siblings.erase(std::remove(siblings.begin(), siblings.end(), this), siblings.end());
        superview_->setNeedsDisplay();
    }
}

WindowHost* View::window() const {
    const View* v = this;
    while (v->superview_) v = v->superview_;
    return v->window_;
}

bool View::isDescendant(const View* ancestor) const {
    for (const View* v = this; v; v = v->superview_) {
        if (v == ancestor) return true;
    }
    return false;
}

void View::addSubview(View* child) { insertSubview(child, subviews_.size()); }

void View::insertSubview(View* child, size_t index) {
    if (!child) return;
    if (child->superview_ == this) {
        // Already here: it moves so that it ends up at `index`.
        auto it = std::find(subviews_.begin(), subviews_.end(), child);
        size_t current = it - subviews_.begin();
        if (current == std::min(index, subviews_.size() - 1)) return;
        subviews_.erase(it);
        subviews_.insert(subviews_.begin() + std::min(index, subviews_.size()), child);
        setNeedsLayout();
        setNeedsDisplay();
        return;
    }
    WindowHost* before = child->window();
    child->removeFromSuperview();
    child->superview_ = this;
    subviews_.insert(subviews_.begin() + std::min(index, subviews_.size()), child);
    WindowHost* after = window();
    if (before != after) child->attach(after);
    setNeedsLayout();
    child->setNeedsLayout();
    setNeedsDisplay();
}

void View::removeFromSuperview() {
    if (!superview_) return;
    WindowHost* host = window();
    if (host) host->viewWillLeave(this);
    auto& siblings = superview_->subviews_;
    siblings.erase(std::remove(siblings.begin(), siblings.end(), this), siblings.end());
    superview_->setNeedsDisplay();
    superview_->setNeedsLayout();
    superview_ = nullptr;
    if (host) attach(nullptr);
}

void View::attach(WindowHost*) {
    viewDidMoveToWindow();
    updateNative();
    for (View* child : subviews_) child->attach(nullptr);
}

void View::setFrame(const Rect& frame) {
    if (frame == frame_) return;
    bool resized = frame.w != frame_.w || frame.h != frame_.h;
    if (superview_) superview_->setNeedsDisplay(frame_);
    frame_ = frame;
    if (resized) setNeedsLayout();
    setNeedsDisplay();
    // A native control under this view follows it even when nothing inside
    // needs laying out.
    if (WindowHost* host = window()) host->setNeedsNativeUpdate();
}

Point View::convertToWindow(Point p) const {
    for (const View* v = this; v; v = v->superview_) {
        p.x += v->frame_.x;
        p.y += v->frame_.y;
    }
    return p;
}

Rect View::convertToWindow(const Rect& r) const {
    Point origin = convertToWindow(Point(r.x, r.y));
    return Rect(origin.x, origin.y, r.w, r.h);
}

Point View::convertFromWindow(Point p) const {
    Point origin = convertToWindow(Point(0, 0));
    return Point(p.x - origin.x, p.y - origin.y);
}

void View::setHidden(bool hidden) {
    if (hidden == hidden_) return;
    hidden_ = hidden;
    if (hidden) {
        if (WindowHost* host = window()) host->viewWillLeave(this, /*keepingTree*/ true);
    }
    if (superview_) superview_->setNeedsDisplay(frame_);
    setNeedsLayout();
    if (WindowHost* host = window()) host->setNeedsNativeUpdate();
}

bool View::isVisibleInWindow() const {
    const View* v = this;
    while (v) {
        if (v->hidden_) return false;
        if (!v->superview_) return v->window_ != nullptr;
        v = v->superview_;
    }
    return false;
}

void View::setNeedsDisplay() { setNeedsDisplay(bounds()); }

void View::setNeedsDisplay(const Rect& local) {
    WindowHost* host = window();
    if (!host) return;
    host->invalidate(convertToWindow(local));
}

void View::setNeedsLayout() {
    needsLayout_ = true;
    if (WindowHost* host = window()) host->setNeedsLayout();
}

void View::layoutSubtreeIfNeeded() {
    if (hidden_) return;
    if (needsLayout_) {
        needsLayout_ = false;
        layout();
    }
    // Copied: a layout pass may rearrange the list it walks.
    auto children = subviews_;
    for (View* child : children) {
        if (child->superview_ == this) child->layoutSubtreeIfNeeded();
    }
}

View* View::hitTest(Point point) {
    if (hidden_) return nullptr;
    if (clipsToBounds && !bounds().contains(point)) return nullptr;
    for (auto it = subviews_.rbegin(); it != subviews_.rend(); ++it) {
        View* child = *it;
        if (child->hidden_) continue;
        Point local(point.x - child->frame_.x, point.y - child->frame_.y);
        if (View* hit = child->hitTest(local)) return hit;
    }
    if (ignoresMouse || !bounds().contains(point)) return nullptr;
    return this;
}

void FlatView::draw(Graphics& g) {
    Rect b = bounds();
    g.fillRect(b, fillColor);
    Color edge = edgeColor.isClear() ? Theme::border : edgeColor;
    if (bottomBorder) g.fillRect(Rect(0, b.h - 1, b.w, 1), edge);
    if (topBorder) g.fillRect(Rect(0, 0, b.w, 1), edge);
    if (rightBorder) g.fillRect(Rect(b.w - 1, 0, 1, b.h), edge);
}

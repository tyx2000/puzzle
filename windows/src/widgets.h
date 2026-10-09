// The controls the panels are built from: a scroll area with Puzzle's own
// overlay scrollers, a virtual list (NSTableView as the panels used it), a
// native text field, and the flat buttons.
#pragma once

#include "dispatch.h"
#include "icons.h"
#include "window.h"

// ── Scrolling ──────────────────────────────────────────────────────────────

/// Content larger than the view, scrolled by the wheel and by overlay
/// scrollers drawn from the theme (PuzzleScroller). Subclasses draw their
/// content in content coordinates.
class ScrollArea : public View {
public:
    ScrollArea();
    Size contentSize() const { return contentSize_; }
    void setContentSize(Size size);
    Point contentOffset() const { return offset_; }
    /// Clamped into range. `flash` shows the scrollers, as scrolling does.
    void setContentOffset(Point offset, bool flash = false);
    Point maximumOffset() const;
    Rect visibleContentRect() const;
    bool hasVerticalScroller = true;
    bool hasHorizontalScroller = false;
    std::function<void()> onScroll;

    void draw(Graphics& g) override;
    void drawOver(Graphics& g) override;
    bool scrollWheel(float dx, float dy, const MouseEvent& e) override;
    bool mouseDown(const MouseEvent& e) override;
    void mouseDragged(const MouseEvent& e) override;
    void mouseUp(const MouseEvent& e) override;
    void mouseMoved(const MouseEvent& e) override;
    void mouseExited() override;
    void layout() override;

protected:
    virtual void drawContent(Graphics&, const Rect& visible) {}
    /// Mouse events in content coordinates, once the scrollers had theirs.
    virtual bool contentMouseDown(const MouseEvent&, Point) { return false; }
    virtual void contentMouseDragged(const MouseEvent&, Point) {}
    virtual void contentMouseUp(const MouseEvent&, Point) {}
    virtual void contentMouseMoved(Point) {}
    virtual void contentMouseExited() {}
    virtual void offsetChanged() {}
    Point toContent(Point local) const { return Point(local.x + offset_.x, local.y + offset_.y); }

private:
    enum class Axis { None, Vertical, Horizontal };
    Rect knobRect(Axis axis) const;
    Rect trackRect(Axis axis) const;
    bool showsScroller(Axis axis) const;
    Axis scrollerAt(Point local) const;
    void flashScrollers();
    Size contentSize_;
    Point offset_;
    Axis dragging_ = Axis::None;
    Axis hot_ = Axis::None;
    float dragStart_ = 0;
    float dragOffsetStart_ = 0;
    bool flashing_ = false;
    std::shared_ptr<Dispatch::Pending> flashEnd_;
    bool contentPressed_ = false;
    Lifetime life_;
};

/// One column of fixed-height rows, drawn rather than built from subviews.
class ListView : public ScrollArea {
public:
    ListView();
    std::function<int()> numberOfRows;
    /// Draws one row. `rect` is in content coordinates.
    std::function<void(Graphics&, int row, const Rect& rect)> drawRow;
    /// The row's ground, before `drawRow`: hover, stripes, selection.
    std::function<Color(int row)> rowBackground;
    std::function<void(int row)> onClick;
    std::function<void(int row)> onDoubleClick;
    std::function<void(int row, POINT screen)> onContextMenu;
    /// Keys ↑↓ and ↩ (lists that take them).
    std::function<void(int row)> onActivate;
    std::function<std::wstring(int row, Point inRow)> tooltipForRow;
    float rowHeight = 22;
    /// Rows are at least this wide; wider than the view, the list scrolls
    /// sideways (the history graph).
    float minimumContentWidth = 0;
    bool keyboardNavigation = false;

    int rowCount() const { return rowCount_; }
    void reloadData();
    int rowAt(Point contentPoint) const;
    Rect rectOfRow(int row) const;
    int hoveredRow() const { return hovered_; }
    int selectedRow() const { return selected_; }
    void setSelectedRow(int row, bool scroll = true);
    void scrollRowToVisible(int row);
    void centerRow(int row);
    void setHoveredRow(int row);
    /// The row under the pointer, read again (the list changed under it).
    void refreshHoverState();

    bool acceptsFocus() const override { return keyboardNavigation; }
    bool keyDown(const KeyEvent& e) override;
    void focusChanged(bool) override { setNeedsDisplay(); }
    bool rightMouseDown(const MouseEvent& e) override;
    std::wstring tooltipAt(Point local) override;
    void layout() override;

protected:
    void drawContent(Graphics& g, const Rect& visible) override;
    bool contentMouseDown(const MouseEvent& e, Point p) override;
    void contentMouseUp(const MouseEvent& e, Point p) override;
    void contentMouseMoved(Point p) override;
    void contentMouseExited() override;
    void offsetChanged() override;

private:
    void updateContentSize();
    int rowCount_ = 0;
    int hovered_ = -1;
    int selected_ = -1;
    int pressedRow_ = -1;
};

// ── Text ───────────────────────────────────────────────────────────────────

/// One line of text drawn by a view: an NSTextField label.
class Label : public View {
public:
    Label() { ignoresMouse = true; }
    std::wstring text;
    Font font;
    Color color;
    Align align = Align::Left;
    LineBreak lineBreak = LineBreak::TruncatingTail;
    bool wraps = false;
    void draw(Graphics& g) override;
    /// The width the text needs on one line.
    float fittingWidth() const;
    float fittingHeight(float width) const;
};

/// A native single-line EDIT, coloured to sit on the view's fill, with a
/// placeholder drawn where the first character will go.
class TextField : public View, public NativeColorProvider {
public:
    TextField();
    ~TextField() override;
    std::wstring text() const;
    /// Setting the text in code still tells `onChange`, as the Swift
    /// `stringValue` observer did.
    void setText(const std::wstring& text);
    std::wstring placeholder;
    Font font;
    Color textColor;
    Color fillColor;
    Color placeholderColor;
    /// A rounded 1pt frame when set — a field in an alert.
    Color borderColor;
    float horizontalInset = 7;
    /// A box of several lines (the Git panel's commit message): Return types a
    /// new line, the text runs from the top, and it scrolls vertically.
    /// Set before the field joins a window.
    bool multiline = false;
    float verticalInset = 4;
    void setEditable(bool editable);
    bool isEditable() const { return editable_; }
    void focus();
    bool isFocused() const;
    void selectAll();

    std::function<void()> onChange;
    std::function<void()> onSubmit;           // ↩
    std::function<void()> onCommitShortcut;   // Ctrl+↩
    std::function<void()> onPushShortcut;     // Ctrl+Shift+↩
    std::function<void()> onEscape;
    std::function<bool(UINT key)> onKey;      // anything else; true when handled
    std::function<void(bool focused)> onFocusChange;

    void draw(Graphics& g) override;
    bool mouseDown(const MouseEvent& e) override;
    Cursor cursorAt(Point) override { return Cursor::IBeam; }
    void updateNative() override;
    void dpiChanged() override;
    HBRUSH controlColor(HDC dc) override;
    void controlCommand(WORD code) override;
    HWND editHandle() const { return edit_; }

private:
    static LRESULT CALLBACK editProc(HWND, UINT, WPARAM, LPARAM, UINT_PTR, DWORD_PTR) noexcept;
    void createEdit();
    void makeFont();
    HWND edit_ = nullptr;
    HFONT gdiFont_ = nullptr;
    HBRUSH brush_ = nullptr;
    Color brushColor_;
    std::wstring pendingText_;
    bool editable_ = true;
    bool settingText_ = false;
};

// ── Buttons ────────────────────────────────────────────────────────────────

/// A borderless symbol button; optionally the rounded hover ground of
/// DiffHeaderButton.
class SymbolButton : public View {
public:
    Symbol symbol = Symbol::Plus;
    Color tint;
    float symbolSize = 14;
    float weight = 1;
    bool hoverBackground = false;
    bool enabled = true;
    std::function<void()> onClick;
    void setEnabled(bool on) { if (on != enabled) { enabled = on; setNeedsDisplay(); } }
    void draw(Graphics& g) override;
    bool mouseDown(const MouseEvent&) override;
    void mouseUp(const MouseEvent& e) override;
    void mouseEntered() override { setNeedsDisplay(); }
    void mouseExited() override { pressed_ = false; setNeedsDisplay(); }
private:
    bool pressed_ = false;
};

/// A count as a filled circle with its digits centred (SidebarCellDrawing.Badge).
namespace Badge {
constexpr float horizontalPadding = 5;
constexpr float verticalPadding = 4;
constexpr float minimumDiameter = 16;
constexpr float gap = 6;
Font font(const Font& labelFont);
float diameter(const std::wstring& value, const Font& labelFont);
/// Draws the circle centred on `centre`.
void draw(Graphics& g, const std::wstring& value, Point centre, const Font& labelFont,
          const Color& background, const Color& foreground);
}  // namespace Badge

/// A flat button with an optional count badge — Commit and Push.
class BadgeButton : public View {
public:
    enum class Style { Bordered, Plain };
    static constexpr float height = 22;
    Style style = Style::Bordered;
    std::wstring title;
    std::wstring badge;
    bool enabled = true;
    std::function<void()> onClick;
    void setTitle(const std::wstring& t) { if (t != title) { title = t; setNeedsDisplay(); } }
    void setBadge(const std::wstring& b) { if (b != badge) { badge = b; setNeedsDisplay(); } }
    void setEnabled(bool on) { if (on != enabled) { enabled = on; setNeedsDisplay(); } }
    float intrinsicWidth() const;
    void draw(Graphics& g) override;
    bool mouseDown(const MouseEvent&) override;
    void mouseUp(const MouseEvent& e) override;
    void mouseEntered() override { setNeedsDisplay(); }
    void mouseExited() override { pressed_ = false; setNeedsDisplay(); }
private:
    Font labelFont() const;
    bool pressed_ = false;
};

/// A rounded push button (the start page's Open, an alert's buttons).
class PushButton : public View {
public:
    std::wstring title;
    bool isDefault = false;
    bool enabled = true;
    std::function<void()> onClick;
    Font font;
    void setEnabled(bool on) { if (on != enabled) { enabled = on; setNeedsDisplay(); } }
    float intrinsicWidth() const;
    void draw(Graphics& g) override;
    bool mouseDown(const MouseEvent&) override;
    void mouseUp(const MouseEvent& e) override;
    void mouseEntered() override { setNeedsDisplay(); }
    void mouseExited() override { pressed_ = false; setNeedsDisplay(); }
private:
    bool pressed_ = false;
};

/// A small check box.
class CheckBox : public View {
public:
    bool checked = false;
    std::function<void(bool)> onToggle;
    void draw(Graphics& g) override;
    bool mouseDown(const MouseEvent&) override;
    void mouseUp(const MouseEvent& e) override;
    void toggle();
private:
    bool pressed_ = false;
};

/// The thin animated band along an edge while Git works (GitProgressShimmerView).
class ProgressShimmer : public View {
public:
    ProgressShimmer() { ignoresMouse = true; setHidden(true); }
    void start();
    void stop();
    bool isRunning() const { return timer_.running(); }
    void draw(Graphics& g) override;
private:
    Dispatch::RepeatingTimer timer_;
    float phase_ = 0;
};

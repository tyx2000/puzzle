// Small borderless windows that float over the editor: the card above a
// Markdown link, and the little diff behind a gutter mark
// (MarkdownLinkPopover.swift, GitChangePopover.swift).
#pragma once

#include "gitlinechanges.h"
#include "widgets.h"

/// A borderless, non-activating window drawn by its own view tree.
class PopupWindow : public WindowHost {
public:
    PopupWindow();
    ~PopupWindow() override;
    /// Shows the popup at a screen rectangle in pixels.
    void showAt(HWND owner, const RECT& screen);
    void close();
    bool isOpen() const { return open_; }
    bool containsCursor() const;
    /// Transient popups close when the user clicks anywhere else.
    bool transient = true;
    std::function<void()> onClose;
    void setContent(View* content);

    /// The message loop asks before dispatching a mouse press, so a click
    /// outside a transient popup closes it.
    static void preTranslate(const MSG& message);
    static void closeAll();

protected:
    LRESULT handleMessage(UINT message, WPARAM wParam, LPARAM lParam) override;

private:
    bool open_ = false;
    View* content_ = nullptr;
};

/// The card above a link: the address, in blue, clickable.
class LinkCard {
public:
    LinkCard();
    ~LinkCard();
    std::function<void()> onOpen;
    void show(const std::wstring& destination, const RECT& anchorScreen, HWND owner);
    void close();
    bool isVisible() const;
    bool containsCursor() const;

    static constexpr float padding = 8;
    static constexpr float gap = 6;
    static constexpr float maximumWidth = 460;

private:
    struct Label;
    std::unique_ptr<PopupWindow> window_;
    std::unique_ptr<Label> label_;
};

/// What the lines were and what they are now, with Revert.
class GitChangePopover {
public:
    GitChangePopover(const GitLineChanges::Change& change, bool canRevert);
    ~GitChangePopover();
    std::function<void()> onRevert;
    /// Beside `anchor` (screen pixels), to its right.
    void show(const RECT& anchorScreen, HWND owner);
    void close();
    bool isOpen() const;

    static constexpr float padding = 8;
    static constexpr float minimumWidth = 170;

private:
    struct Body;
    std::unique_ptr<PopupWindow> window_;
    std::unique_ptr<Body> body_;
};

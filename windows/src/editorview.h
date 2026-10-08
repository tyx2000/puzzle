// The code view: a Scintilla control hosted in the view tree, with the
// gutter, folding, Markdown decorations, search rules, the bracket scope and
// inline blame drawn over it in one double-buffered pass
// (PuzzleTextView.swift, LineNumberRulerView.swift, FoldingLayoutManager).
#pragma once

#include "document.h"
#include "gitlinechanges.h"
#include "widgets.h"

#include <Scintilla.h>

class Menu;

class EditorView : public View, public NativeColorProvider {
public:
    EditorView();
    ~EditorView() override;

    // ── Document ──
    void attach(Document* doc);
    void detach();
    Document* document() const { return doc_; }

    // ── Selection ──
    size_t caret() const;
    TextRange selection() const;
    void setSelection(const TextRange& range);
    void scrollRangeToVisible(const TextRange& range);
    bool hasSingleEmptySelection() const;
    void focus();
    bool isFocused() const;
    /// Text of the whole buffer the view shows.
    std::string text() const;

    // ── Configuration ──
    void setEditable(bool editable);
    bool isEditable() const { return editable_; }
    /// Fonts, line height, tab width and every style again (settings.json).
    void refreshDisplay();
    /// Styles allocated since the last look, applied to this view.
    void syncStyles();
    void setShowsGutter(bool shows);
    bool showsGutter() const { return showsGutter_; }
    /// The measure for rendered Markdown, in DIPs; nullopt fills the view.
    void setReadingWidth(std::optional<float> width);
    void setShowsCurrentLineBand(bool shows);
    /// Soft wrap (the editor) or a horizontal scroll (the history detail).
    void setWraps(bool wraps);
    bool showsCurrentLineBand() const { return showsCurrentLineBand_; }
    bool usesBracketIndent = true;
    std::optional<CommentToggle::Syntax> commentSyntax;

    // ── Decorations ──
    void setSearchMatches(std::vector<TextRange> matches, std::optional<int> current);
    const std::vector<TextRange>& searchMatches() const { return searchMatches_; }
    void setSearchResultLineLocation(std::optional<size_t> location);
    void setDiffLineNumbers(std::vector<std::optional<int>> numbers);
    void setGitChanges(std::vector<GitLineChanges::Change> changes);
    void setInlineBlame(std::optional<std::wstring> blame);
    const std::optional<std::wstring>& inlineBlame() const { return inlineBlame_; }
    void setCommandHoverRange(std::optional<TextRange> range);
    std::optional<TextRange> commandHoverRange() const { return commandHoverRange_; }
    /// The three round buttons beside a search with results.
    void setShowsSearchNavigator(bool shows);

    // ── Structure ──
    void updateCodeBlocks(const std::vector<CodeBlock>& blocks, bool resetFolds);
    const std::vector<CodeBlock>& codeBlocks() const { return blocks_; }
    bool isFolded(const CodeBlock& block) const { return folded_.count(block.identity()) > 0; }
    void toggleFold(const CodeBlock& block);
    bool revealFolds(const std::vector<TextRange>& ranges);
    void unfoldAll();
    const std::set<size_t>& foldedBlockIdentities() const { return folded_; }
    void restoreFoldedBlockIdentities(const std::set<size_t>& identities);
    void updateJSXTagMatches(const std::vector<JSXTagMatch>& matches);
    void refreshBracketMatches();
    /// Markdown: what to collapse, what to draw, and which source range the
    /// caret has revealed.
    void updateMarkdown(const MarkdownPresentation* presentation, std::optional<TextRange> reveal);
    bool isCharacterHidden(size_t position) const;

    // ── Editing ──
    void insertText(const std::string& text, const TextRange& replacing);
    bool deleteCurrentLine();
    bool insertLineBelow();
    bool duplicateCurrentLine();
    void toggleComment();
    void undo();
    void redo();
    void cut();
    void copy();
    void paste();
    void selectAll();
    void emptyUndoBuffer();

    // ── Geometry ──
    /// A range's box on screen, in this view's coordinates (DIPs).
    Rect rectForRange(const TextRange& range) const;
    float gutterWidth() const;

    // ── Callbacks ──
    std::function<void()> onTextChanged;
    std::function<void()> onSelectionChanged;
    /// A real pointer or keyboard interaction, not a programmatic move.
    std::function<void()> onExplicitCaretInteraction;
    std::function<void()> onLostFocus;
    std::function<void()> onGainedFocus;
    /// Ctrl+click: true when it resolved to something.
    std::function<bool(size_t)> onCommandClick;
    /// Ctrl held over the text; nullopt when released or gone.
    std::function<void(std::optional<size_t>)> onCommandHover;
    std::function<void(const GitLineChanges::Change&, const Rect&)> onChangeClicked;
    std::function<void(const MarkdownLinkDecoration&)> onOpenLink;
    std::function<void()> onSearchPrevious;
    std::function<void()> onSearchNext;
    std::function<void()> onSearchClear;

    // View
    void layout() override;
    void updateNative() override;
    void viewDidMoveToWindow() override;
    void dpiChanged() override;
    HBRUSH controlColor(HDC) override { return nullptr; }
    bool controlNotify(NMHDR* header, LRESULT* result) override;
    bool nativeKeyDown(const KeyEvent& e) override;

    sptr_t call(unsigned int message, uptr_t wParam = 0, sptr_t lParam = 0) const;
    HWND handle() const { return sci_; }

    static constexpr float dividerReach = 8;
    static constexpr float changeMarkWidth = 3;
    static constexpr float changeMarkHoverWidth = 8;
    static constexpr float foldArrowColumn = 14;
    static constexpr int minimumDigits = 2;
    /// The Markdown measure in characters of the editor font.
    static constexpr float readingColumns = 114;

private:
    struct Impl;
    std::unique_ptr<Impl> d_;
    friend struct Impl;

    void create();
    static LRESULT CALLBACK subclassProc(HWND, UINT, WPARAM, LPARAM, UINT_PTR, DWORD_PTR);
    LRESULT handle(UINT message, WPARAM wParam, LPARAM lParam, bool* handled);
    void paint();
    void drawOverlay(Graphics& g, float scale);
    void applyHiddenLines();
    void applyMargins();
    void applyStyles(bool all);
    void applyLineHeight();
    void applyImageSpace();
    void requestRepaint();

    HWND sci_ = nullptr;
    SciFnDirect fn_ = nullptr;
    sptr_t ptr_ = 0;
    Document* doc_ = nullptr;
    SciDoc::Handle blank_ = nullptr;
    bool editable_ = true;
    bool showsGutter_ = true;
    bool showsCurrentLineBand_ = false;
    std::optional<float> readingWidth_;
    int appliedStyles_ = 0;

    std::vector<TextRange> searchMatches_;
    std::optional<int> currentMatch_;
    std::optional<size_t> searchResultLine_;
    std::vector<std::optional<int>> diffLineNumbers_;
    std::vector<GitLineChanges::Change> gitChanges_;
    std::optional<std::wstring> inlineBlame_;
    std::optional<TextRange> commandHoverRange_;
    bool showsNavigator_ = false;

    std::vector<CodeBlock> blocks_;
    std::set<size_t> folded_;
    std::vector<JSXTagMatch> jsxMatches_;
    std::vector<TextRange> bracketMatches_;
    std::optional<JSXTagMatch> activeJSX_;
    MarkdownPresentation markdown_;
    std::optional<TextRange> reveal_;
    std::vector<std::pair<int, int>> hiddenLines_;
    Lifetime life_;
};

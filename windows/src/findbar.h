// The in-file find bar: the styled query field, the match count, ↑ ↓ and
// close, and a replace row on request (FindBarView.swift).
#pragma once

#include "editorview.h"
#include "searchinput.h"

class FindBarView : public View {
public:
    struct State {
        bool isVisible = false;
        std::wstring query;
        SearchOptions options;
        std::wstring replacement;
        bool isReplacing = false;
        std::optional<TextRange> currentRange;
    };
    static constexpr size_t maxRetainedMatches = 20000;

    FindBarView();
    std::function<void()> onClose;
    std::function<void()> onHeightChanged;
    std::function<void()> onMatchesChanged;

    State state() const;
    bool hasKeyboardFocus() const;
    void restore(const State& state, EditorView* editor);
    void invalidateMatches();
    void setQuery(const std::wstring& text);
    std::wstring query() const { return input_.text(); }
    void focus();
    void refreshFonts();
    void setReplaceVisible(bool visible, bool focus = true);
    float preferredHeight() const { return replaceVisible_ ? 76 : 42; }
    bool hasMatches() const { return !matches_.empty(); }
    void goToNextMatch() { step(1); }
    void goToPreviousMatch() { step(-1); }
    /// Leave the caret on the match the user stopped at.
    void finish();
    void clearHighlights();

    void layout() override;
    void draw(Graphics& g) override;

private:
    void recompute(const std::wstring& query, const SearchOptions& options,
                   std::optional<TextRange> preferred = std::nullopt, bool reveal = true);
    /// Every match, through Scintilla's own search; `limit` caps what is kept.
    std::vector<TextRange> enumerate(const std::wstring& query, const SearchOptions& options, size_t limit,
                                     size_t* total) const;
    void step(int delta);
    void select(int index);
    void highlight();
    void updateCount();
    void replaceCurrent();
    void replaceAll();

    SearchInputView input_;
    Label count_;
    SymbolButton previous_;
    SymbolButton next_;
    SymbolButton close_;
    SymbolButton replaceToggle_;
    TextField replaceField_;
    PushButton replaceOne_;
    PushButton replaceEvery_;
    bool replaceVisible_ = false;
    EditorView* editor_ = nullptr;
    std::vector<TextRange> matches_;
    int current_ = -1;
    size_t total_ = 0;
};

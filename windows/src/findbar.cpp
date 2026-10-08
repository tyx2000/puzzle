#include "findbar.h"

#include "theme.h"

namespace {

int searchFlags(const SearchOptions& options) {
    int flags = 0;
    if (options.caseSensitive) flags |= SCFIND_MATCHCASE;
    if (options.regex) flags |= SCFIND_REGEXP | SCFIND_CXX11REGEX;
    else if (options.wholeWord) flags |= SCFIND_WHOLEWORD;
    return flags;
}

std::string pattern(const std::wstring& query, const SearchOptions& options) {
    std::string q = U(query);
    if (options.regex && options.wholeWord) return "\\b(?:" + q + ")\\b";
    return q;
}

/// `$1` templates, as NSRegularExpression writes them, in Scintilla's `\1`.
std::string scintillaTemplate(const std::string& t) {
    std::string out;
    for (size_t i = 0; i < t.size(); ++i) {
        char c = t[i];
        if (c == '\\' && i + 1 < t.size()) {
            char next = t[++i];
            if (next == '\\') out += "\\\\";
            else out.push_back(next);
        } else if (c == '$' && i + 1 < t.size() && isdigit((unsigned char)t[i + 1])) {
            out.push_back('\\');
            out.push_back(t[++i]);
        } else if (c == '\\') {
            out += "\\\\";
        } else {
            out.push_back(c);
        }
    }
    return out;
}

}  // namespace

FindBarView::FindBarView() {
    backgroundColor = Theme::barBackground;
    input_.setPlaceholder(L"Find in file…");
    input_.onChange = [this](const std::wstring& text, const SearchOptions& options) { recompute(text, options); };
    input_.onSubmit = [this](const std::wstring&, const SearchOptions&) { step(1); };
    input_.onNavigate = [this](int delta) { step(delta); };
    input_.onCancel = [this] {
        if (onClose) onClose();
    };
    addSubview(&input_);

    count_.font = Theme::uiFont(10.5f);
    count_.color = Theme::dimText;
    count_.align = Align::Right;
    addSubview(&count_);
    auto icon = [this](SymbolButton& b, Symbol symbol, const wchar_t* tip, std::function<void()> action) {
        b.symbol = symbol;
        b.symbolSize = 10;
        b.weight = 1.1f;
        b.tint = Theme::dimText;
        b.tooltip = tip;
        b.onClick = std::move(action);
        addSubview(&b);
    };
    icon(previous_, Symbol::ChevronUp, L"Previous match", [this] { step(-1); });
    icon(next_, Symbol::ChevronDown, L"Next match", [this] { step(1); });
    icon(close_, Symbol::XMark, L"Close", [this] {
        if (onClose) onClose();
    });
    icon(replaceToggle_, Symbol::ChevronRight, L"Replace", [this] { setReplaceVisible(!replaceVisible_); });

    replaceField_.placeholder = L"Replace with…";
    replaceField_.font = Theme::uiFont(12);
    replaceField_.textColor = Theme::foreground;
    replaceField_.fillColor = Theme::inputBackground;
    replaceField_.placeholderColor = Theme::dimText;
    replaceField_.horizontalInset = 6;
    replaceField_.onSubmit = [this] { replaceCurrent(); };
    replaceField_.onEscape = [this] {
        if (onClose) onClose();
    };
    replaceField_.setHidden(true);
    addSubview(&replaceField_);
    replaceOne_.title = L"Replace";
    replaceOne_.font = Theme::uiFont(10.5f);
    replaceOne_.onClick = [this] { replaceCurrent(); };
    replaceOne_.setHidden(true);
    addSubview(&replaceOne_);
    replaceEvery_.title = L"All";
    replaceEvery_.font = Theme::uiFont(10.5f);
    replaceEvery_.onClick = [this] { replaceAll(); };
    replaceEvery_.setHidden(true);
    addSubview(&replaceEvery_);
}

void FindBarView::layout() {
    Rect b = bounds();
    float controlsRight = b.w - 10;
    close_.setFrame(Rect(controlsRight - 20, 6 + 5, 20, 20));
    next_.setFrame(Rect(close_.frame().x - 6 - 20, 11, 20, 20));
    previous_.setFrame(Rect(next_.frame().x - 6 - 20, 11, 20, 20));
    float countWidth = std::max(60.0f, std::ceil(count_.fittingWidth()) + 2);
    count_.setFrame(Rect(previous_.frame().x - 6 - countWidth, 6, countWidth, 30));
    replaceToggle_.setFrame(Rect(6, 6 + 6, 18, 18));
    float inputX = 6 + 18 + 4;
    input_.setFrame(Rect(inputX, 6, std::max(0.0f, count_.frame().x - 8 - inputX), SearchInputView::height));
    float rowY = 6 + SearchInputView::height + 4;
    float allWidth = replaceEvery_.intrinsicWidth(), oneWidth = replaceOne_.intrinsicWidth();
    replaceEvery_.setFrame(Rect(controlsRight - allWidth, rowY + 3, allWidth, 22));
    replaceOne_.setFrame(Rect(replaceEvery_.frame().x - 6 - oneWidth, rowY + 3, oneWidth, 22));
    replaceField_.setFrame(Rect(inputX + 6, rowY, std::max(0.0f, replaceOne_.frame().x - 8 - inputX - 6), 28));
}

void FindBarView::draw(Graphics& g) {
    Rect b = bounds();
    g.fillRect(Rect(0, b.h - 1, b.w, 1), Theme::border);
}

FindBarView::State FindBarView::state() const {
    State s;
    s.isVisible = !isHidden();
    s.query = input_.text();
    s.options = input_.options();
    s.replacement = replaceField_.text();
    s.isReplacing = replaceVisible_;
    if (current_ >= 0 && current_ < (int)matches_.size()) s.currentRange = matches_[current_];
    return s;
}

bool FindBarView::hasKeyboardFocus() const { return input_.hasKeyboardFocus() || replaceField_.isFocused(); }

void FindBarView::restore(const State& state, EditorView* editor) {
    clearHighlights();
    editor_ = editor;
    input_.setText(state.query);
    input_.setOptions(state.options, false);
    replaceField_.setText(state.replacement);
    setReplaceVisible(state.isReplacing, false);
    setHidden(!state.isVisible);
    if (state.isVisible) recompute(state.query, state.options, state.currentRange, false);
}

void FindBarView::invalidateMatches() { recompute(input_.text(), input_.options(), std::nullopt, false); }

void FindBarView::setQuery(const std::wstring& text) {
    input_.setText(text);
    recompute(text, input_.options());
}

void FindBarView::focus() { input_.focus(true); }

void FindBarView::refreshFonts() {
    input_.refreshFonts();
    count_.font = Theme::uiFont(10.5f);
    replaceField_.font = Theme::uiFont(12);
    replaceField_.dpiChanged();
    setNeedsLayout();
}

void FindBarView::setReplaceVisible(bool visible, bool focus) {
    if (replaceVisible_ == visible) return;
    replaceVisible_ = visible;
    replaceField_.setHidden(!visible);
    replaceOne_.setHidden(!visible);
    replaceEvery_.setHidden(!visible);
    replaceToggle_.symbol = visible ? Symbol::ChevronDown : Symbol::ChevronRight;
    replaceToggle_.setNeedsDisplay();
    if (onHeightChanged) onHeightChanged();
    if (visible && focus) replaceField_.focus();
}

std::vector<TextRange> FindBarView::enumerate(const std::wstring& query, const SearchOptions& options, size_t limit,
                                              size_t* total) const {
    std::vector<TextRange> out;
    if (total) *total = 0;
    if (!editor_ || query.empty() || !editor_->document()) return out;
    std::string needle = pattern(query, options);
    size_t length = editor_->document()->length();
    editor_->call(SCI_SETSEARCHFLAGS, searchFlags(options));
    size_t position = 0;
    while (position <= length) {
        editor_->call(SCI_SETTARGETRANGE, position, length);
        sptr_t found = editor_->call(SCI_SEARCHINTARGET, needle.size(), (sptr_t)needle.c_str());
        if (found < 0) break;
        size_t start = (size_t)editor_->call(SCI_GETTARGETSTART);
        size_t end = (size_t)editor_->call(SCI_GETTARGETEND);
        if (end <= start) {
            // A zero-length match is not a result; move past it.
            size_t next = (size_t)editor_->call(SCI_POSITIONAFTER, start);
            if (next <= position) break;
            position = next;
            continue;
        }
        if (total) ++*total;
        if (out.size() < limit) out.push_back(TextRange(start, end - start));
        position = end;
    }
    return out;
}

void FindBarView::recompute(const std::wstring& query, const SearchOptions& options,
                            std::optional<TextRange> preferred, bool reveal) {
    matches_.clear();
    total_ = 0;
    current_ = -1;
    if (editor_ && !query.empty()) {
        matches_ = enumerate(query, options, maxRetainedMatches, &total_);
        // A result inside a collapsed block is opened rather than marked.
        editor_->revealFolds(matches_);
        if (!matches_.empty()) {
            size_t caret = editor_->selection().location;
            current_ = -1;
            if (preferred) {
                for (size_t i = 0; i < matches_.size(); ++i) {
                    if (matches_[i] == *preferred) current_ = (int)i;
                }
            }
            if (current_ < 0) {
                current_ = 0;
                for (size_t i = 0; i < matches_.size(); ++i) {
                    if (matches_[i].location >= caret) {
                        current_ = (int)i;
                        break;
                    }
                }
            }
            if (reveal) select(current_);
        }
    } else if (editor_ && reveal) {
        // An emptied query is no longer a result: collapse its selection.
        TextRange sel = editor_->selection();
        if (sel.length) editor_->setSelection(TextRange(sel.end(), 0));
    }
    updateCount();
    highlight();
}

void FindBarView::step(int delta) {
    if (matches_.empty()) return;
    int n = (int)matches_.size();
    current_ = ((current_ + delta) % n + n) % n;
    select(current_);
    updateCount();
}

void FindBarView::select(int index) {
    if (!editor_ || index < 0 || index >= (int)matches_.size()) return;
    // While the bar is on screen the selection stays put; the rule marks the
    // current match and `finish` moves the caret there.
    if (isHidden() && editor_->isFocused()) editor_->setSelection(matches_[index]);
    editor_->scrollRangeToVisible(matches_[index]);
    highlight();
}

void FindBarView::finish() {
    if (!editor_ || current_ < 0 || current_ >= (int)matches_.size()) return;
    editor_->setSelection(matches_[current_]);
}

void FindBarView::highlight() {
    if (!editor_) return;
    editor_->setSearchMatches(matches_, matches_.empty() ? std::nullopt : std::optional<int>(current_));
    editor_->setSearchResultLineLocation(current_ >= 0 && current_ < (int)matches_.size()
                                             ? std::optional<size_t>(matches_[current_].location)
                                             : std::nullopt);
}

void FindBarView::clearHighlights() {
    matches_.clear();
    total_ = 0;
    current_ = -1;
    if (editor_) {
        editor_->setSearchMatches({}, std::nullopt);
        editor_->setSearchResultLineLocation(std::nullopt);
    }
    count_.text.clear();
    count_.setNeedsDisplay();
    if (onMatchesChanged) onMatchesChanged();
}

void FindBarView::updateCount() {
    if (matches_.empty()) {
        count_.text = input_.text().empty() ? L"" : L"No results";
    } else if (total_ > matches_.size()) {
        count_.text = std::to_wstring(current_ + 1) + L" of " + std::to_wstring(matches_.size()) + L" ("
            + std::to_wstring(total_) + L" found)";
    } else {
        count_.text = std::to_wstring(current_ + 1) + L" of " + std::to_wstring(matches_.size());
    }
    count_.setNeedsDisplay();
    setNeedsLayout();
    if (onMatchesChanged) onMatchesChanged();
}

void FindBarView::replaceCurrent() {
    if (!editor_ || !editor_->isEditable() || current_ < 0 || current_ >= (int)matches_.size()) return;
    TextRange range = matches_[current_];
    SearchOptions options = input_.options();
    std::string replacement = U(replaceField_.text());
    // Each replacement is its own undo step.
    editor_->call(SCI_BEGINUNDOACTION);
    size_t written = replacement.size();
    if (options.regex) {
        std::string needle = pattern(input_.text(), options);
        editor_->call(SCI_SETSEARCHFLAGS, searchFlags(options));
        editor_->call(SCI_SETTARGETRANGE, range.location, range.end());
        if (editor_->call(SCI_SEARCHINTARGET, needle.size(), (sptr_t)needle.c_str()) >= 0) {
            std::string t = scintillaTemplate(replacement);
            written = (size_t)editor_->call(SCI_REPLACETARGETRE, t.size(), (sptr_t)t.c_str());
        }
    } else {
        editor_->call(SCI_SETTARGETRANGE, range.location, range.end());
        editor_->call(SCI_REPLACETARGET, replacement.size(), (sptr_t)replacement.c_str());
    }
    editor_->call(SCI_ENDUNDOACTION);
    editor_->setSelection(TextRange(range.location + written, 0));
    recompute(input_.text(), input_.options());
    step(1);
}

void FindBarView::replaceAll() {
    if (!editor_ || !editor_->isEditable() || total_ == 0) return;
    SearchOptions options = input_.options();
    std::string replacement = U(replaceField_.text());
    std::string t = scintillaTemplate(replacement);
    std::string needle = pattern(input_.text(), options);
    // Enumerated afresh — the kept list is capped — and replaced back to
    // front inside one undo action, so one Ctrl+Z puts them all back.
    auto all = enumerate(input_.text(), options, SIZE_MAX, nullptr);
    editor_->call(SCI_BEGINUNDOACTION);
    for (auto it = all.rbegin(); it != all.rend(); ++it) {
        if (options.regex) {
            editor_->call(SCI_SETSEARCHFLAGS, searchFlags(options));
            editor_->call(SCI_SETTARGETRANGE, it->location, it->end());
            if (editor_->call(SCI_SEARCHINTARGET, needle.size(), (sptr_t)needle.c_str()) >= 0) {
                editor_->call(SCI_REPLACETARGETRE, t.size(), (sptr_t)t.c_str());
            }
        } else {
            editor_->call(SCI_SETTARGETRANGE, it->location, it->end());
            editor_->call(SCI_REPLACETARGET, replacement.size(), (sptr_t)replacement.c_str());
        }
    }
    editor_->call(SCI_ENDUNDOACTION);
    recompute(input_.text(), input_.options());
}

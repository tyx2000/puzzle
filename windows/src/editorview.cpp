#include "editorview.h"

#include "icons.h"
#include "imaging.h"
#include "menu.h"
#include "popover.h"
#include "settings.h"
#include "theme.h"

#include <commctrl.h>
#include <windowsx.h>

namespace {

constexpr UINT_PTR kSubclassId = 0x5053;  // 'PS'
/// The text's distance from the gutter and the right edge: NSTextView's
/// container inset plus its line-fragment padding.
constexpr float kTextInset = 11;
constexpr float kNavigatorButton = 48;
constexpr float kNavigatorSpacing = 8;
constexpr float kNavigatorTrailing = 16;
constexpr float kScrollerHit = 12;
constexpr float kKnobIdle = 6;
constexpr float kKnobHot = 9;
constexpr float kKnobMinimum = 24;
constexpr double kHoverAnimation = 0.12;
constexpr double kLinkHoverDelay = 0.35;
constexpr size_t kImageByteBudget = 48 * 1024 * 1024;
constexpr UINT kImagePixels = 1600;

COLORREF rgb(const Color& c) { return c.colorref(); }

bool isSpace(char c) { return c == ' ' || c == '\t'; }

}  // namespace

// ── State the overlay and the pointer share ────────────────────────────────

struct EditorView::Impl {
    EditorView* owner;
    explicit Impl(EditorView* o) : owner(o) {}

    // Double buffering.
    HDC memDC = nullptr;
    HBITMAP memBitmap = nullptr;
    HGDIOBJ oldBitmap = nullptr;
    int memWidth = 0, memHeight = 0;
    Com<ID2D1DCRenderTarget> target;
    std::optional<bool> printClientWorks;

    // Gutter hover.
    std::optional<size_t> hoveredBlock;
    std::optional<GitLineChanges::Change> hoveredChange;
    double hoverProgress = 0;
    std::optional<GitLineChanges::Change> fadingChange;
    double fadingProgress = 0;
    Dispatch::RepeatingTimer hoverTimer;
    std::map<size_t, Rect> arrowHitRects;  // DIPs
    std::vector<std::pair<GitLineChanges::Change, Rect>> changeMarkRects;

    // Scroller.
    bool scrollerHot = false;
    bool scrollerDragging = false;
    bool scrollerFlashing = false;
    float dragStartY = 0;
    int dragStartLine = 0;
    std::shared_ptr<Dispatch::Pending> flashEnd;
    int lastFirstLine = -1;

    // Navigator.
    int navigatorHot = -1;
    int navigatorPressed = -1;

    // Pointer.
    bool trackingLeave = false;
    Point mouse;  // DIPs, in the control
    bool mouseInside = false;

    // Selection bookkeeping.
    size_t lastAnchor = 0, lastCaret = 0;
    bool selectionCheckPending = false;
    bool textChangePending = false;

    // Markdown pictures, decoded at the size they are drawn at.
    struct CachedImage {
        Com<IWICBitmapSource> source;
        Com<ID2D1Bitmap> bitmap;  // for the current render target
        Size size;
        size_t bytes = 0;
    };
    std::map<std::wstring, std::optional<CachedImage>> images;
    std::vector<std::pair<int, int>> imageAnnotations;  // line, extra lines
    float imageSpaceWidth = -1;

    // Link hover.
    std::optional<TextRange> hoveredLink;
    std::shared_ptr<Dispatch::Pending> linkHoverWork;
    std::unique_ptr<LinkCard> linkCard;

    float scale() const {
        WindowHost* host = owner->window();
        return host ? host->scale() : 1.0f;
    }

    void releaseBuffer() {
        if (memDC) {
            if (oldBitmap) SelectObject(memDC, oldBitmap);
            DeleteDC(memDC);
        }
        if (memBitmap) DeleteObject(memBitmap);
        memDC = nullptr;
        memBitmap = nullptr;
        oldBitmap = nullptr;
        memWidth = memHeight = 0;
    }

    ~Impl() { releaseBuffer(); }
};

// ── Life ───────────────────────────────────────────────────────────────────

EditorView::EditorView() : d_(std::make_unique<Impl>(this)) {
    clipsToBounds = true;
    backgroundColor = Theme::editorBackground;
}

EditorView::~EditorView() {
    if (d_->linkCard) d_->linkCard->close();
    if (sci_) {
        if (doc_) {
            doc_->attachedViews = std::max(0, doc_->attachedViews - 1);
            doc_ = nullptr;
        }
        RemoveWindowSubclass(sci_, &EditorView::subclassProc, kSubclassId);
        RemovePropW(sci_, kNativeColorProperty);
        DestroyWindow(sci_);
        sci_ = nullptr;
    }
    if (blank_) SciDoc::release(blank_);
}

sptr_t EditorView::call(unsigned int message, uptr_t wParam, sptr_t lParam) const {
    if (!fn_ || !ptr_) return 0;
    return fn_(ptr_, message, wParam, lParam);
}

void EditorView::create() {
    WindowHost* host = window();
    if (!host || sci_) return;
    sci_ = CreateWindowExW(0, L"Scintilla", L"", WS_CHILD | WS_CLIPSIBLINGS | WS_TABSTOP, 0, 0, 10, 10,
                           host->hwnd(), nullptr, GetModuleHandleW(nullptr), nullptr);
    if (!sci_) return;
    fn_ = reinterpret_cast<SciFnDirect>(SendMessageW(sci_, SCI_GETDIRECTFUNCTION, 0, 0));
    ptr_ = (sptr_t)SendMessageW(sci_, SCI_GETDIRECTPOINTER, 0, 0);
    SetPropW(sci_, kNativeColorProperty, static_cast<NativeColorProvider*>(this));
    SetWindowSubclass(sci_, &EditorView::subclassProc, kSubclassId, (DWORD_PTR)this);

    call(SCI_SETTECHNOLOGY, SC_TECHNOLOGY_DIRECTWRITEDC);
    call(SCI_SETCODEPAGE, SC_CP_UTF8);
    call(SCI_SETBUFFEREDDRAW, 0);
    call(SCI_SETVSCROLLBAR, 0);
    call(SCI_SETHSCROLLBAR, 0);
    call(SCI_SETWRAPMODE, SC_WRAP_WORD);
    call(SCI_SETLAYOUTCACHE, SC_CACHE_PAGE);
    call(SCI_SETMULTIPLESELECTION, 0);
    call(SCI_SETADDITIONALSELECTIONTYPING, 0);
    call(SCI_USEPOPUP, SC_POPUP_NEVER);
    call(SCI_SETIMEINTERACTION, SC_IME_INLINE);
    call(SCI_SETPASTECONVERTENDINGS, 1);
    call(SCI_SETENDATLASTLINE, 1);
    call(SCI_SETFONTQUALITY, SC_EFF_QUALITY_ANTIALIASED);
    call(SCI_SETMODEVENTMASK, SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT);
    call(SCI_SETCARETWIDTH, 2);
    call(SCI_SETMOUSEDOWNCAPTURES, 1);
    call(SCI_SETMARGINS, 1);
    call(SCI_SETMARGINTYPEN, 0, SC_MARGIN_COLOUR);
    call(SCI_SETMARGINMASKN, 0, 0);
    call(SCI_SETMARGINBACKN, 0, rgb(Theme::editorBackground));
    call(SCI_SETMARGINCURSORN, 0, SC_CURSORARROW);
    call(SCI_SETMARGINSENSITIVEN, 0, 0);
    call(SCI_ANNOTATIONSETVISIBLE, ANNOTATION_STANDARD);
    // Keys that belong to the app, or to nothing here.
    for (int key : std::initializer_list<int>{'D', 'L', 'T', 'U', SCK_ADD, SCK_SUBTRACT, SCK_DIVIDE}) {
        call(SCI_CLEARCMDKEY, key + (SCMOD_CTRL << 16));
        call(SCI_CLEARCMDKEY, key + ((SCMOD_CTRL | SCMOD_SHIFT) << 16));
    }
    // Colours: caret, selection, the caret's line.
    call(SCI_SETELEMENTCOLOUR, SC_ELEMENT_CARET, rgb(Theme::cursor) | 0xff000000);
    call(SCI_SETELEMENTCOLOUR, SC_ELEMENT_SELECTION_BACK, rgb(Theme::selection) | 0xff000000);
    call(SCI_SETELEMENTCOLOUR, SC_ELEMENT_SELECTION_INACTIVE_BACK, rgb(Theme::selection) | 0xff000000);
    call(SCI_SETELEMENTCOLOUR, SC_ELEMENT_SELECTION_ADDITIONAL_BACK, rgb(Theme::selection) | 0xff000000);
    call(SCI_SETSELECTIONLAYER, SC_LAYER_UNDER_TEXT);
    call(SCI_SETELEMENTCOLOUR, SC_ELEMENT_CARET_LINE_BACK, rgb(Theme::lineHighlight) | 0xff000000);
    call(SCI_SETCARETLINEVISIBLEALWAYS, 1);
    call(SCI_SETCARETLINEFRAME, 0);
    // Markers painted under whole lines; an indicator for struck text.
    call(SCI_MARKERDEFINE, Styles::kMarkerDiffAdded, SC_MARK_BACKGROUND);
    call(SCI_MARKERSETBACK, Styles::kMarkerDiffAdded, rgb(Theme::diffAddedBackground));
    call(SCI_MARKERDEFINE, Styles::kMarkerDiffRemoved, SC_MARK_BACKGROUND);
    call(SCI_MARKERSETBACK, Styles::kMarkerDiffRemoved, rgb(Theme::diffRemovedBackground));
    call(SCI_MARKERDEFINE, Styles::kMarkerCodeBlock, SC_MARK_BACKGROUND);
    call(SCI_MARKERSETBACK, Styles::kMarkerCodeBlock, rgb(Theme::inputBackground));
    call(SCI_MARKERDEFINE, Styles::kMarkerSearchLine, SC_MARK_BACKGROUND);
    call(SCI_MARKERSETBACK, Styles::kMarkerSearchLine, rgb(Theme::lineHighlight));
    call(SCI_INDICSETSTYLE, Styles::kStrikeIndicator, INDIC_STRIKE);
    call(SCI_INDICSETFORE, Styles::kStrikeIndicator, rgb(Theme::foreground));

    if (!blank_) blank_ = SciDoc::create();
    if (!doc_) call(SCI_SETDOCPOINTER, 0, (sptr_t)blank_);
    refreshDisplay();
    setEditable(editable_);
    setShowsCurrentLineBand(showsCurrentLineBand_);
}

void EditorView::viewDidMoveToWindow() {
    if (window() && !sci_) create();
    updateNative();
}

void EditorView::updateNative() {
    WindowHost* host = window();
    if (!host) {
        if (sci_) ShowWindow(sci_, SW_HIDE);
        return;
    }
    if (!sci_) create();
    if (!sci_) return;
    bool visible = isVisibleInWindow() && bounds().w > 0 && bounds().h > 0;
    float s = host->scale();
    Rect r = convertToWindow(bounds());
    int x = (int)std::lround(r.x * s), y = (int)std::lround(r.y * s);
    int w = (int)std::lround(r.maxX() * s) - x, h = (int)std::lround(r.maxY() * s) - y;
    SetWindowPos(sci_, nullptr, x, y, std::max(1, w), std::max(1, h),
                 SWP_NOZORDER | SWP_NOACTIVATE | (visible ? SWP_SHOWWINDOW : SWP_HIDEWINDOW));
    applyMargins();
    applyImageSpace();
}

void EditorView::layout() { updateNative(); }

void EditorView::dpiChanged() {
    d_->target.reset();
    d_->images.clear();
    refreshDisplay();
    updateNative();
}

void EditorView::requestRepaint() {
    if (sci_) InvalidateRect(sci_, nullptr, FALSE);
}

// ── Document ───────────────────────────────────────────────────────────────

void EditorView::attach(Document* doc) {
    if (!sci_) create();
    if (doc == doc_) return;
    if (doc_) doc_->attachedViews = std::max(0, doc_->attachedViews - 1);
    doc_ = doc;
    if (doc_) doc_->attachedViews += 1;
    hiddenLines_.clear();
    d_->imageAnnotations.clear();
    d_->imageSpaceWidth = -1;
    call(SCI_SETDOCPOINTER, 0, (sptr_t)(doc ? doc->handle() : blank_));
    // Each view keeps its own copy of the style table and its line height.
    applyStyles(true);
    applyLineHeight();
    setEditable(editable_);
    d_->lastAnchor = d_->lastCaret = 0;
    requestRepaint();
}

void EditorView::detach() { attach(nullptr); }

std::string EditorView::text() const { return doc_ ? doc_->text() : std::string(); }

// ── Selection ──────────────────────────────────────────────────────────────

size_t EditorView::caret() const { return (size_t)call(SCI_GETCURRENTPOS); }

TextRange EditorView::selection() const {
    size_t a = (size_t)call(SCI_GETSELECTIONSTART), b = (size_t)call(SCI_GETSELECTIONEND);
    return TextRange(std::min(a, b), b > a ? b - a : a - b);
}

void EditorView::setSelection(const TextRange& range) {
    size_t n = doc_ ? doc_->length() : 0;
    size_t a = std::min(range.location, n), b = std::min(range.end(), n);
    call(SCI_SETSEL, a, b);
    d_->lastAnchor = a;
    d_->lastCaret = b;
}

void EditorView::scrollRangeToVisible(const TextRange& range) {
    if (!sci_) return;
    int line = (int)call(SCI_LINEFROMPOSITION, range.location);
    if (!call(SCI_GETLINEVISIBLE, line)) call(SCI_ENSUREVISIBLE, line);
    call(SCI_SCROLLRANGE, range.end(), range.location);
}

bool EditorView::hasSingleEmptySelection() const {
    return call(SCI_GETSELECTIONS) == 1 && call(SCI_GETSELECTIONEMPTY);
}

void EditorView::focus() {
    if (sci_) SetFocus(sci_);
}

bool EditorView::isFocused() const { return sci_ && GetFocus() == sci_; }

// ── Configuration ──────────────────────────────────────────────────────────

void EditorView::setEditable(bool editable) {
    editable_ = editable;
    if (sci_) call(SCI_SETREADONLY, editable ? 0 : 1);
    setShowsCurrentLineBand(showsCurrentLineBand_);
}

void EditorView::setShowsCurrentLineBand(bool shows) {
    showsCurrentLineBand_ = shows;
    if (!sci_) return;
    // A buffer that cannot be typed into has no active line; a search result
    // shows its line regardless.
    bool band = editable_ && !searchResultLine_ && shows && hasSingleEmptySelection();
    call(SCI_SETCARETLINEVISIBLE, band ? 1 : 0);
    requestRepaint();
}

void EditorView::setWraps(bool wraps) {
    if (!sci_) create();
    call(SCI_SETWRAPMODE, wraps ? SC_WRAP_WORD : SC_WRAP_NONE);
    call(SCI_SETSCROLLWIDTHTRACKING, wraps ? 0 : 1);
    call(SCI_SETHSCROLLBAR, wraps ? 0 : 1);
}

void EditorView::setShowsGutter(bool shows) {
    if (showsGutter_ == shows) return;
    showsGutter_ = shows;
    applyMargins();
}

void EditorView::setReadingWidth(std::optional<float> width) {
    if (readingWidth_ == width) return;
    readingWidth_ = width;
    applyMargins();
}

float EditorView::gutterWidth() const {
    if (!showsGutter_) return 0;
    int highest = 1;
    if (!diffLineNumbers_.empty()) {
        for (auto& n : diffLineNumbers_) {
            if (n) highest = std::max(highest, *n);
        }
    } else if (doc_) {
        highest = doc_->lineCount();
    }
    int digits = std::max(minimumDigits, (int)std::to_string(std::max(highest, 1)).size());
    std::wstring sample(digits, L'8');
    float width = std::ceil(Text::width(sample, Theme::editorFont()));
    return dividerReach + changeMarkHoverWidth + 2 + width + 4 + foldArrowColumn;
}

void EditorView::applyMargins() {
    if (!sci_) return;
    float s = d_->scale();
    float gutter = gutterWidth();
    call(SCI_SETMARGINWIDTHN, 0, (int)std::lround(gutter * s));
    float inset = kTextInset;
    float right = kTextInset;
    if (readingWidth_) {
        // Split the leftover evenly; never narrower than the pane's margin.
        float spare = (bounds().w - gutter - *readingWidth_) / 2;
        inset = std::max(inset, spare);
        right = std::max(right, spare);
    }
    call(SCI_SETMARGINLEFT, 0, (int)std::lround(inset * s));
    call(SCI_SETMARGINRIGHT, 0, (int)std::lround(right * s));
}

void EditorView::refreshDisplay() {
    if (!sci_) return;
    auto& settings = Settings::shared();
    call(SCI_SETTABWIDTH, settings.tabSize);
    call(SCI_SETUSETABS, 1);
    call(SCI_SETINDENT, 0);
    applyStyles(true);
    applyLineHeight();
    applyMargins();
    d_->imageSpaceWidth = -1;
    applyImageSpace();
    requestRepaint();
}

void EditorView::syncStyles() {
    if (!sci_) return;
    int before = appliedStyles_;
    applyStyles(false);
    if (appliedStyles_ != before) applyLineHeight();
}

void EditorView::applyStyles(bool all) {
    if (!sci_) return;
    auto& settings = Settings::shared();
    std::string family = U(Theme::editorFamily());
    // Typographic points at 96 DPI: a Mac point is a DIP.
    int size100 = (int)std::lround(settings.fontSize * 0.75f * 100);
    bool bold = settings.fontWeight >= 600;
    if (all) {
        call(SCI_STYLESETFONT, STYLE_DEFAULT, (sptr_t)family.c_str());
        call(SCI_STYLESETSIZEFRACTIONAL, STYLE_DEFAULT, size100);
        call(SCI_STYLESETWEIGHT, STYLE_DEFAULT, bold ? SC_WEIGHT_BOLD : SC_WEIGHT_NORMAL);
        call(SCI_STYLESETFORE, STYLE_DEFAULT, rgb(Theme::foreground));
        call(SCI_STYLESETBACK, STYLE_DEFAULT, rgb(Theme::editorBackground));
        call(SCI_STYLECLEARALL);
        call(SCI_STYLESETFORE, STYLE_CONTROLCHAR, rgb(Theme::dimText));
        appliedStyles_ = 0;
    }
    int count = Styles::count();
    float base = settings.fontSize;
    float target = Theme::lineMetrics().target;
    for (int i = appliedStyles_; i < count; ++i) {
        if (i >= Styles::kFirstReserved && i <= Styles::kLastReserved) continue;
        const TextStyle& st = Styles::style(i);
        call(SCI_STYLESETFORE, i, rgb(st.fg));
        call(SCI_STYLESETBACK, i, rgb(st.bg ? *st.bg : Theme::editorBackground));
        call(SCI_STYLESETWEIGHT, i, (st.bold || bold) ? SC_WEIGHT_BOLD : SC_WEIGHT_NORMAL);
        call(SCI_STYLESETITALIC, i, st.italic ? 1 : 0);
        call(SCI_STYLESETUNDERLINE, i, st.underline ? 1 : 0);
        float size = base;
        if (st.heading > 0) {
            static const float scales[] = {1.0f, 1.22f, 1.16f, 1.10f, 1.05f, 1.0f, 1.0f};
            float maximum = std::max(base, target * 0.72f);
            size = std::min(base * scales[std::clamp(st.heading, 1, 6)], maximum);
        }
        if (st.superscript) size = std::max(6.0f, base * 0.75f);
        call(SCI_STYLESETSIZEFRACTIONAL, i, (int)std::lround(size * 0.75f * 100));
        call(SCI_STYLESETVISIBLE, i, (st.hidden || st.replacement) ? 0 : 1);
        if (st.replacement) {
            std::string glyph = U(std::wstring(1, (wchar_t)st.replacement));
            call(SCI_STYLESETINVISIBLEREPRESENTATION, i, (sptr_t)glyph.c_str());
        }
    }
    appliedStyles_ = count;
}

void EditorView::applyLineHeight() {
    if (!sci_) return;
    call(SCI_SETEXTRAASCENT, 0);
    call(SCI_SETEXTRADESCENT, 0);
    int natural = (int)call(SCI_TEXTHEIGHT, 0);
    int target = (int)std::lround(Settings::shared().codeLineHeight * d_->scale());
    int extra = target - natural;
    int ascent = extra / 2;
    call(SCI_SETEXTRAASCENT, ascent);
    call(SCI_SETEXTRADESCENT, extra - ascent);
}

// ── Decorations ────────────────────────────────────────────────────────────

void EditorView::setSearchMatches(std::vector<TextRange> matches, std::optional<int> current) {
    searchMatches_ = std::move(matches);
    currentMatch_ = current;
    requestRepaint();
}

void EditorView::setSearchResultLineLocation(std::optional<size_t> location) {
    searchResultLine_ = location;
    // The band marks the result's line without moving the caret there.
    if (doc_) {
        SciDoc::clearMarker(doc_->handle(), Styles::kMarkerSearchLine);
        if (location && editable_) {
            SciDoc::addMarker(doc_->handle(), SciDoc::lineFromPosition(doc_->handle(), *location),
                              Styles::kMarkerSearchLine);
        }
    }
    setShowsCurrentLineBand(showsCurrentLineBand_);
}

void EditorView::setDiffLineNumbers(std::vector<std::optional<int>> numbers) {
    diffLineNumbers_ = std::move(numbers);
    applyMargins();
    requestRepaint();
}

void EditorView::setGitChanges(std::vector<GitLineChanges::Change> changes) {
    gitChanges_ = std::move(changes);
    requestRepaint();
}

void EditorView::setInlineBlame(std::optional<std::wstring> blame) {
    if (blame == inlineBlame_) return;
    inlineBlame_ = std::move(blame);
    requestRepaint();
}

void EditorView::setCommandHoverRange(std::optional<TextRange> range) {
    if (range == commandHoverRange_) return;
    commandHoverRange_ = range;
    requestRepaint();
}

void EditorView::setShowsSearchNavigator(bool shows) {
    if (shows == showsNavigator_) return;
    showsNavigator_ = shows;
    d_->navigatorHot = d_->navigatorPressed = -1;
    requestRepaint();
}

// ── Folding and hidden lines ───────────────────────────────────────────────

void EditorView::updateCodeBlocks(const std::vector<CodeBlock>& blocks, bool resetFolds) {
    blocks_ = blocks;
    if (resetFolds) {
        folded_.clear();
    } else {
        std::set<size_t> available;
        for (auto& b : blocks_) available.insert(b.identity());
        std::set<size_t> kept;
        for (size_t f : folded_) {
            if (available.count(f)) kept.insert(f);
        }
        folded_ = kept;
    }
    applyHiddenLines();
}

void EditorView::toggleFold(const CodeBlock& block) {
    bool known = false;
    for (auto& b : blocks_) known = known || b == block;
    if (!known) return;
    if (!isFolded(block)) {
        // Never leave the caret inside lines about to disappear.
        setSelection(TextRange(block.openerLocation, 0));
        folded_.insert(block.identity());
    } else {
        folded_.erase(block.identity());
    }
    applyHiddenLines();
}

bool EditorView::revealFolds(const std::vector<TextRange>& ranges) {
    if (ranges.empty()) return false;
    bool opened = false;
    for (auto& block : blocks_) {
        if (!isFolded(block)) continue;
        bool covers = false;
        for (auto& r : ranges) covers = covers || r.intersects(block.hiddenRange);
        if (!covers) continue;
        folded_.erase(block.identity());
        opened = true;
    }
    if (opened) applyHiddenLines();
    return opened;
}

void EditorView::unfoldAll() {
    if (folded_.empty()) return;
    folded_.clear();
    applyHiddenLines();
}

void EditorView::restoreFoldedBlockIdentities(const std::set<size_t>& identities) {
    std::set<size_t> available;
    for (auto& b : blocks_) available.insert(b.identity());
    folded_.clear();
    for (size_t i : identities) {
        if (available.count(i)) folded_.insert(i);
    }
    applyHiddenLines();
}

bool EditorView::isCharacterHidden(size_t position) const {
    for (auto& block : blocks_) {
        if (isFolded(block) && block.hiddenRange.contains(position)) return true;
    }
    if (reveal_ && reveal_->contains(position)) return false;
    const auto& ranges = markdown_.hiddenSyntaxRanges;
    auto it = std::upper_bound(ranges.begin(), ranges.end(), position,
                               [](size_t p, const TextRange& r) { return p < r.location; });
    if (it == ranges.begin()) return false;
    --it;
    return it->contains(position);
}

void EditorView::applyHiddenLines() {
    if (!sci_ || !doc_) return;
    SciDoc::Handle h = doc_->handle();
    std::vector<std::pair<int, int>> wanted;
    auto hideRange = [&](const TextRange& range) {
        if (range.length == 0) return;
        int first = SciDoc::lineFromPosition(h, range.location);
        size_t lastPos = range.end() > 0 ? range.end() - 1 : 0;
        int last = SciDoc::lineFromPosition(h, lastPos);
        // The range runs to the terminator of its last line.
        if (first <= last) wanted.push_back({first, last});
    };
    for (auto& block : blocks_) {
        if (isFolded(block)) hideRange(block.hiddenRange);
    }
    for (auto& line : markdown_.collapsedLineRanges) {
        if (reveal_ && reveal_->intersects(line)) continue;
        hideRange(line);
    }
    std::sort(wanted.begin(), wanted.end());
    std::vector<std::pair<int, int>> merged;
    for (auto& r : wanted) {
        if (!merged.empty() && r.first <= merged.back().second + 1) {
            merged.back().second = std::max(merged.back().second, r.second);
        } else {
            merged.push_back(r);
        }
    }
    if (merged == hiddenLines_) return;
    int last = std::max(0, SciDoc::lineCount(h) - 1);
    call(SCI_SHOWLINES, 0, last);
    for (auto& r : merged) call(SCI_HIDELINES, std::max(1, r.first), r.second);
    hiddenLines_ = merged;
    // The caret must not sit on a line that is gone.
    int caretLine = (int)call(SCI_LINEFROMPOSITION, caret());
    if (!call(SCI_GETLINEVISIBLE, caretLine)) {
        for (auto& block : blocks_) {
            if (isFolded(block) && block.hiddenRange.contains(caret())) {
                setSelection(TextRange(block.openerLocation, 0));
                break;
            }
        }
    }
    requestRepaint();
}

void EditorView::updateMarkdown(const MarkdownPresentation* presentation, std::optional<TextRange> reveal) {
    MarkdownPresentation next = presentation ? *presentation : MarkdownPresentation();
    bool changed = next != markdown_;
    bool revealChanged = reveal != reveal_;
    if (!changed && !revealChanged) return;
    if (changed) {
        // Pictures no longer referenced are let go.
        std::set<std::wstring> retained;
        for (auto& image : next.images) {
            if (image.url && image.url->isFile) retained.insert(image.url->path);
        }
        for (auto it = d_->images.begin(); it != d_->images.end();) {
            if (!retained.count(it->first)) it = d_->images.erase(it);
            else ++it;
        }
        // Links changed: a card for one that is gone must go too.
        if (next.links != markdown_.links && d_->linkCard) {
            d_->linkCard->close();
            d_->hoveredLink.reset();
        }
    }
    markdown_ = std::move(next);
    reveal_ = reveal;
    if (doc_) doc_->applyMarkdownReveal(reveal);
    applyHiddenLines();
    d_->imageSpaceWidth = -1;
    applyImageSpace();
    requestRepaint();
}

// ── Bracket and JSX scope ──────────────────────────────────────────────────

void EditorView::updateJSXTagMatches(const std::vector<JSXTagMatch>& matches) {
    if (matches == jsxMatches_) return;
    jsxMatches_ = matches;
    refreshBracketMatches();
}

void EditorView::refreshBracketMatches() {
    std::vector<TextRange> refreshed;
    std::optional<JSXTagMatch> refreshedTag;
    if (doc_ && hasSingleEmptySelection()) {
        size_t at = caret();
        refreshed = BracketMatcher::ranges(doc_->view(), at);
        // A delimiter beside the caret is more specific than the tag around it.
        if (refreshed.empty()) {
            std::optional<std::pair<JSXTagMatch, size_t>> best;
            for (auto& match : jsxMatches_) {
                std::optional<size_t> narrowest;
                for (auto& r : match.activationRanges()) {
                    if (at >= r.location && at <= r.end()) {
                        if (!narrowest || r.length < *narrowest) narrowest = r.length;
                    }
                }
                if (narrowest && (!best || *narrowest < best->second)) best = {{match, *narrowest}};
            }
            if (best) refreshedTag = best->first;
        }
    }
    if (refreshed == bracketMatches_ && refreshedTag == activeJSX_) return;
    bracketMatches_ = refreshed;
    activeJSX_ = refreshedTag;
    requestRepaint();
}

// ── Pictures in Markdown ───────────────────────────────────────────────────

void EditorView::applyImageSpace() {
    if (!sci_ || !doc_) return;
    float width = bounds().w;
    if (width <= 0 || std::fabs(width - d_->imageSpaceWidth) < 0.5f) return;
    d_->imageSpaceWidth = width;
    SciDoc::Handle h = doc_->handle();
    std::vector<std::pair<int, int>> wanted;
    float row = Settings::shared().codeLineHeight;
    float available = std::max(80.0f, width - gutterWidth() - 2 * kTextInset);
    if (readingWidth_) available = std::max(80.0f, std::min(available, *readingWidth_));
    for (auto& image : markdown_.images) {
        if (reveal_ && reveal_->intersects(image.sourceRange)) continue;
        float height = row * 2;
        if (image.url && image.url->isFile) {
            auto& cached = d_->images[image.url->path];
            if (!cached.has_value()) {
                size_t used = 0;
                for (auto& [path, entry] : d_->images) {
                    if (entry) used += entry->bytes;
                }
                Impl::CachedImage made;
                if (used < kImageByteBudget) {
                    if (auto data = readFile(image.url->path, 32 * 1024 * 1024)) {
                        if (auto info = Imaging::probe(*data)) {
                            made.source = Imaging::decode(*data, kImagePixels);
                            made.size = Size(info->width, info->height);
                            float longest = std::max(info->width, info->height);
                            float s = longest > 0 ? std::min(1.0f, kImagePixels / longest) : 1;
                            made.bytes = (size_t)(info->width * s) * (size_t)(info->height * s) * 4;
                        }
                    }
                }
                cached = made;
            }
            if (cached && cached->source && cached->size.w > 0 && cached->size.h > 0) {
                float s = std::min({1.0f, available / cached->size.w, 320 / cached->size.h});
                height = std::max(row * 2, std::floor(cached->size.h * s) + 8);
            }
        }
        int line = SciDoc::lineFromPosition(h, image.sourceRange.location);
        int extra = std::max(1, (int)std::ceil(height / row)) - 1;
        wanted.push_back({line, extra});
    }
    if (wanted == d_->imageAnnotations) return;
    for (auto& [line, extra] : d_->imageAnnotations) SciDoc::setAnnotationLines(h, line, 0, 0);
    for (auto& [line, extra] : wanted) SciDoc::setAnnotationLines(h, line, extra, 0);
    d_->imageAnnotations = wanted;
    requestRepaint();
}

// ── Editing ────────────────────────────────────────────────────────────────

namespace {

struct Lines {
    std::string_view s;
    TextRange line(size_t location) const {
        if (s.empty()) return TextRange(0, 0);
        size_t probe = std::min(location, s.size());
        if (probe == s.size()) {
            if (s.back() == '\n') return TextRange(s.size(), 0);
            probe = s.size() - 1;
        }
        size_t start = probe;
        while (start > 0 && s[start - 1] != '\n') --start;
        size_t end = s.find('\n', probe);
        end = end == std::string_view::npos ? s.size() : end + 1;
        return TextRange(start, end - start);
    }
    /// Where the line stops carrying text, before its terminator.
    size_t contentEnd(size_t location) const {
        TextRange l = line(location);
        size_t end = l.end();
        if (end > l.location && s[end - 1] == '\n') --end;
        if (end > l.location && s[end - 1] == '\r') --end;
        return end;
    }
    /// The leading whitespace a new line inherits, cut at the caret.
    std::string carriedIndent(size_t location) const {
        TextRange l = line(location);
        size_t end = l.location, limit = std::min(l.end(), s.size());
        while (end < limit && isSpace(s[end])) ++end;
        end = std::min(end, std::max(location, l.location));
        if (end <= l.location) return "";
        return std::string(s.substr(l.location, end - l.location));
    }
    std::string indentOfLine(size_t location) const { return carriedIndent(contentEnd(location)); }
};

std::string indentUnit(const std::string& indent) {
    if (indent.find('\t') != std::string::npos) return "\t";
    return std::string(std::max(1, Settings::shared().tabSize), ' ');
}

char closerFor(char opener) { return opener == '{' ? '}' : opener == '[' ? ']' : ')'; }

}  // namespace

void EditorView::insertText(const std::string& text, const TextRange& replacing) {
    if (!sci_ || !editable_) return;
    call(SCI_BEGINUNDOACTION);
    call(SCI_SETTARGETRANGE, replacing.location, replacing.end());
    call(SCI_REPLACETARGET, text.size(), (sptr_t)text.c_str());
    call(SCI_ENDUNDOACTION);
    call(SCI_GOTOPOS, replacing.location + text.size());
}

bool EditorView::deleteCurrentLine() {
    if (!doc_ || !editable_) return false;
    std::string_view s = doc_->view();
    if (s.empty()) return false;
    Lines lines{s};
    size_t at = std::min(caret(), s.size());
    TextRange range;
    if (at == s.size() && s.back() == '\n') {
        size_t length = s.size() >= 2 && s[s.size() - 2] == '\r' ? 2 : 1;
        range = TextRange(s.size() - length, length);
    } else {
        range = lines.line(std::min(at, s.size() - 1));
        if (range.end() == s.size() && range.location > 0) {
            char previous = s[range.location - 1];
            if (previous == '\n') {
                size_t prefix = range.location >= 2 && s[range.location - 2] == '\r' ? 2 : 1;
                range.location -= prefix;
                range.length += prefix;
            } else if (previous == '\r') {
                range.location -= 1;
                range.length += 1;
            }
        }
    }
    if (range.length == 0) return false;
    insertText("", range);
    setSelection(TextRange(std::min(range.location, doc_->length()), 0));
    refreshBracketMatches();
    return true;
}

namespace {
std::string eolOf(const EditorView& view) {
    return view.call(SCI_GETEOLMODE) == SC_EOL_CRLF ? "\r\n" : "\n";
}
}  // namespace

bool EditorView::insertLineBelow() {
    if (!doc_ || !editable_) return false;
    std::string_view s = doc_->view();
    Lines lines{s};
    size_t at = std::min(caret(), s.size());
    std::string indent = lines.indentOfLine(at);
    size_t insertion = lines.contentEnd(at);
    if (usesBracketIndent) {
        size_t i = insertion;
        TextRange l = lines.line(at);
        while (i > l.location && isSpace(s[i - 1])) --i;
        if (i > l.location && (s[i - 1] == '{' || s[i - 1] == '[' || s[i - 1] == '(')) indent += indentUnit(indent);
    }
    std::string text = eolOf(*this) + indent;
    insertText(text, TextRange(insertion, 0));
    scrollRangeToVisible(selection());
    refreshBracketMatches();
    return true;
}

bool EditorView::duplicateCurrentLine() {
    if (!doc_ || !editable_) return false;
    std::string_view s = doc_->view();
    Lines lines{s};
    TextRange sel = selection();
    size_t at = std::min(sel.location, s.size());
    TextRange first = lines.line(at);
    size_t lastProbe = sel.length ? std::max(first.location, std::min(sel.end(), s.size()) - (sel.end() > at ? 1 : 0))
                                  : at;
    size_t end = lines.contentEnd(lastProbe);
    TextRange block(first.location, end >= first.location ? end - first.location : 0);
    std::string text = eolOf(*this) + std::string(s.substr(block.location, block.length));
    call(SCI_BEGINUNDOACTION);
    call(SCI_SETTARGETRANGE, end, end);
    call(SCI_REPLACETARGET, text.size(), (sptr_t)text.c_str());
    call(SCI_ENDUNDOACTION);
    setSelection(TextRange(std::min(at + text.size(), doc_->length()), 0));
    scrollRangeToVisible(selection());
    refreshBracketMatches();
    return true;
}

void EditorView::toggleComment() {
    if (!doc_ || !editable_ || !commentSyntax) {
        MessageBeep(MB_OK);
        return;
    }
    std::string_view s = doc_->view();
    Lines lines{s};
    TextRange sel = selection();
    size_t start = std::min(sel.location, s.size());
    size_t end = std::min(sel.end(), s.size());
    // Whole lines dragged over end at the start of the next one.
    if (end > start && s[end - 1] == '\n') --end;
    TextRange firstLine = lines.line(start);
    TextRange lastLine = lines.line(end > start ? end - 1 : start);
    TextRange block(firstLine.location, std::max(lastLine.end(), firstLine.location) - firstLine.location);
    std::string original(s.substr(block.location, block.length));
    auto edits = CommentToggle::edits(original, *commentSyntax);
    if (edits.empty()) return;
    std::string replacement = CommentToggle::apply(edits, original);
    call(SCI_BEGINUNDOACTION);
    call(SCI_SETTARGETRANGE, block.location, block.end());
    call(SCI_REPLACETARGET, replacement.size(), (sptr_t)replacement.c_str());
    call(SCI_ENDUNDOACTION);
    bool isCaret = sel.length == 0;
    size_t from = block.location + CommentToggle::map(sel.location - block.location, edits, isCaret);
    size_t to = isCaret ? from : block.location + CommentToggle::map(sel.end() - block.location, edits, true);
    setSelection(TextRange(from, to > from ? to - from : 0));
    refreshBracketMatches();
}

void EditorView::undo() { call(SCI_UNDO); }
void EditorView::redo() { call(SCI_REDO); }
void EditorView::cut() { call(SCI_CUT); }
void EditorView::copy() { call(SCI_COPY); }
void EditorView::paste() { call(SCI_PASTE); }
void EditorView::selectAll() { call(SCI_SELECTALL); }
void EditorView::emptyUndoBuffer() { call(SCI_EMPTYUNDOBUFFER); }

// ── Geometry ───────────────────────────────────────────────────────────────

namespace {

struct Geometry {
    const EditorView& v;
    float scale;
    int lineHeight;
    float ascent, descent;  // px
    explicit Geometry(const EditorView& view, float s) : v(view), scale(s) {
        lineHeight = std::max(1, (int)view.call(SCI_TEXTHEIGHT, 0));
        Font f = Theme::editorFont();
        ascent = f.ascender() * s;
        descent = -f.descender() * s;
    }
    int x(size_t pos) const { return (int)v.call(SCI_POINTXFROMPOSITION, 0, pos); }
    int y(size_t pos) const { return (int)v.call(SCI_POINTYFROMPOSITION, 0, pos); }
    float baseline(int top) const { return top + (lineHeight - (ascent + descent)) / 2 + ascent; }
    float glyphTop(int top) const { return top + (lineHeight - (ascent + descent)) / 2; }
    float glyphHeight() const { return ascent + descent; }
    bool lineVisible(size_t pos) const {
        int line = (int)v.call(SCI_LINEFROMPOSITION, pos);
        return v.call(SCI_GETLINEVISIBLE, line) != 0;
    }
    /// One rect per display line the range covers: (x0, x1, top), in px.
    std::vector<std::tuple<float, float, int>> segments(const TextRange& range) const {
        std::vector<std::tuple<float, float, int>> out;
        size_t end = range.end();
        size_t p = range.location;
        float average = Theme::characterWidth() * scale;
        while (p < end) {
            int top = y(p);
            float x0 = (float)x(p), x1 = x0;
            size_t q = p;
            while (q < end) {
                size_t next = (size_t)v.call(SCI_POSITIONAFTER, q);
                if (next <= q) {
                    next = q + 1;
                }
                if (next < end && y(next) != top) {
                    x1 = (float)x(q) + average;
                    q = next;
                    break;
                }
                x1 = next <= end && y(next) == top ? (float)x(next) : (float)x(q) + average;
                q = next;
            }
            out.emplace_back(x0, x1, top);
            if (q <= p) break;
            p = q;
        }
        return out;
    }
};

}  // namespace

Rect EditorView::rectForRange(const TextRange& range) const {
    if (!sci_) return {};
    float s = d_->scale();
    Geometry g(*this, s);
    auto segs = g.segments(range.length ? range : TextRange(range.location, 1));
    if (segs.empty()) return {};
    float x0 = std::get<0>(segs[0]), x1 = std::get<1>(segs[0]);
    int top = std::get<2>(segs[0]), bottom = top + g.lineHeight;
    for (auto& [a, b, t] : segs) {
        x0 = std::min(x0, a);
        x1 = std::max(x1, b);
        bottom = std::max(bottom, t + g.lineHeight);
    }
    return Rect(x0 / s, top / s, (x1 - x0) / s, (bottom - top) / s);
}

// ── Painting ───────────────────────────────────────────────────────────────

void EditorView::paint() {
    PAINTSTRUCT ps;
    HDC hdc = BeginPaint(sci_, &ps);
    RECT client;
    GetClientRect(sci_, &client);
    int w = std::max(1L, client.right), h = std::max(1L, client.bottom);
    Impl& d = *d_;
    if (!d.memDC || d.memWidth < w || d.memHeight < h) {
        d.releaseBuffer();
        d.memDC = CreateCompatibleDC(hdc);
        d.memBitmap = CreateCompatibleBitmap(hdc, w, h);
        d.oldBitmap = SelectObject(d.memDC, d.memBitmap);
        d.memWidth = w;
        d.memHeight = h;
    }
    if (!d.printClientWorks) {
        // Scintilla paints into another DC only when it judges it compatible;
        // ask once, by looking for its background where a sentinel was.
        SetPixel(d.memDC, w - 1, h - 1, RGB(255, 0, 255));
        DefSubclassProc(sci_, WM_PRINTCLIENT, (WPARAM)d.memDC, PRF_CLIENT);
        d.printClientWorks = GetPixel(d.memDC, w - 1, h - 1) != RGB(255, 0, 255);
    } else if (*d.printClientWorks) {
        DefSubclassProc(sci_, WM_PRINTCLIENT, (WPARAM)d.memDC, PRF_CLIENT);
    }
    if (!*d.printClientWorks) {
        // Fallback: let Scintilla paint the window, then draw over it.
        EndPaint(sci_, &ps);
        InvalidateRect(sci_, nullptr, FALSE);
        DefSubclassProc(sci_, WM_PAINT, 0, 0);
        HDC windowDC = GetDC(sci_);
        BitBlt(d.memDC, 0, 0, w, h, windowDC, 0, 0, SRCCOPY);
        hdc = windowDC;
    }
    if (!d.target) {
        D2D1_RENDER_TARGET_PROPERTIES props = D2D1::RenderTargetProperties(
            D2D1_RENDER_TARGET_TYPE_DEFAULT,
            D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE), 96, 96);
        Render::d2d()->CreateDCRenderTarget(&props, d.target.put());
        for (auto& [path, image] : d.images) {
            if (image) image->bitmap.reset();
        }
    }
    if (d.target) {
        RECT bind{0, 0, w, h};
        if (SUCCEEDED(d.target->BindDC(d.memDC, &bind))) {
            Com<ID2D1DeviceContext> context = d.target.as<ID2D1DeviceContext>();
            if (context) {
                float s = d.scale();
                context->BeginDraw();
                context->SetDpi(96 * s, 96 * s);
                context->SetTransform(D2D1::Matrix3x2F::Identity());
                context->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
                {
                    Graphics g(context.get(), 96 * s);
                    drawOverlay(g, s);
                }
                if (context->EndDraw() == D2DERR_RECREATE_TARGET) d.target.reset();
            }
        }
    }
    BitBlt(hdc, 0, 0, w, h, d.memDC, 0, 0, SRCCOPY);
    if (*d.printClientWorks) {
        EndPaint(sci_, &ps);
    } else {
        ReleaseDC(sci_, hdc);
        ValidateRect(sci_, nullptr);
    }
}

namespace {

void drawFoldArrow(Graphics& g, const Rect& rect, bool folded) {
    Point c(rect.midX(), rect.midY());
    std::vector<Point> points;
    if (folded) points = {{c.x - 1.5f, c.y - 2.5f}, {c.x + 1.5f, c.y}, {c.x - 1.5f, c.y + 2.5f}};
    else points = {{c.x - 2.5f, c.y - 1.5f}, {c.x, c.y + 1.5f}, {c.x + 2.5f, c.y - 1.5f}};
    g.polyline(points, Theme::gutterActive, 1.15f, true);
}

double markWidth(double progress) {
    double clamped = std::clamp(progress, 0.0, 1.0);
    double eased = 1 - (1 - clamped) * (1 - clamped);
    return EditorView::changeMarkWidth
        + (EditorView::changeMarkHoverWidth - EditorView::changeMarkWidth) * eased;
}

}  // namespace

void EditorView::drawOverlay(Graphics& g, float s) {
    Impl& d = *d_;
    RECT client;
    GetClientRect(sci_, &client);
    float viewW = client.right / s, viewH = client.bottom / s;
    Geometry geo(*this, s);
    float lh = geo.lineHeight / s;
    int firstDisplay = (int)call(SCI_GETFIRSTVISIBLELINE);
    int onScreen = (int)call(SCI_LINESONSCREEN) + 2;
    float gutter = gutterWidth();
    float marginLeft = (float)call(SCI_GETMARGINLEFT) / s;
    float textLeft = gutter + marginLeft - 5;  // the container inset, before padding
    float marginRight = (float)call(SCI_GETMARGINRIGHT) / s;
    size_t length = doc_ ? doc_->length() : 0;
    int docFirst = (int)call(SCI_DOCLINEFROMVISIBLE, firstDisplay);
    int docLast = (int)call(SCI_DOCLINEFROMVISIBLE, firstDisplay + onScreen);
    size_t visibleStart = (size_t)call(SCI_POSITIONFROMLINE, docFirst);
    size_t visibleEnd = (size_t)call(SCI_GETLINEENDPOSITION, docLast);
    TextRange visible(visibleStart, visibleEnd >= visibleStart ? visibleEnd - visibleStart + 1 : 0);
    auto revealed = [&](const TextRange& r) { return reveal_ && reveal_->intersects(r); };
    auto top = [&](size_t pos) { return geo.y(pos) / s; };

    if (doc_) {
        // ── Markdown code blocks: the band is a marker; the frame is drawn here.
        for (auto& block : markdown_.codeBlocks) {
            TextRange clamped = block.range.intersection(TextRange(0, length));
            if (!clamped.length || !clamped.intersects(visible)) continue;
            int firstLine = (int)call(SCI_LINEFROMPOSITION, clamped.location);
            int lastLine = (int)call(SCI_LINEFROMPOSITION, clamped.end() - 1);
            float y0 = -1, y1 = -1;
            for (int line = firstLine; line <= lastLine; ++line) {
                if (!call(SCI_GETLINEVISIBLE, line)) continue;
                size_t at = (size_t)call(SCI_POSITIONFROMLINE, line);
                size_t lineEnd = (size_t)call(SCI_GETLINEENDPOSITION, line);
                float t = top(at);
                float b = top(lineEnd) + lh;
                if (y0 < 0) y0 = t;
                y1 = std::max(y1, b);
            }
            if (y0 < 0) continue;
            float inset = textLeft - gutter;
            Rect box(textLeft, y0, std::max(0.0f, viewW - inset - textLeft), y1 - y0);
            g.fillRect(Rect(gutter, y0, std::max(0.0f, textLeft - gutter), y1 - y0), Theme::editorBackground);
            g.fillRect(Rect(box.maxX(), y0, std::max(0.0f, viewW - box.maxX()), y1 - y0), Theme::editorBackground);
            g.strokeRoundedRect(box, 5, Theme::border, 1);
        }

        // ── Search: a rule under every match, yellow for the current one.
        if (!searchMatches_.empty()) {
            auto it = std::lower_bound(searchMatches_.begin(), searchMatches_.end(), visible.location,
                                       [](const TextRange& r, size_t p) { return r.end() < p; });
            for (; it != searchMatches_.end() && it->location <= visible.end(); ++it) {
                TextRange m = it->intersection(TextRange(0, length));
                if (!m.length || isCharacterHidden(m.location) || !geo.lineVisible(m.location)) continue;
                int index = (int)(it - searchMatches_.begin());
                Color color = currentMatch_ && *currentMatch_ == index ? Theme::currentMatchUnderline
                                                                       : Theme::matchUnderline;
                for (auto& [x0, x1, t] : geo.segments(m)) {
                    float baseline = geo.baseline(t) / s;
                    float rowBottom = (t + geo.lineHeight) / s;
                    float y = std::min(baseline + Theme::matchUnderlineOffset, rowBottom - Theme::matchUnderlineWidth);
                    g.fillRect(Rect(x0 / s, y, (x1 - x0) / s, Theme::matchUnderlineWidth), color);
                }
            }
        }

        // ── Tables, drawn over their hidden source rows.
        for (auto& table : markdown_.tables) {
            if (!table.sourceRange.intersects(visible)) continue;
            Font font = Theme::editorFont(), bold = Theme::editorBoldFont();
            float available = std::max(80.0f, viewW - textLeft * 2 + gutter);
            std::vector<float> widths(table.columnCount, 60);
            for (auto& row : table.rows) {
                for (int c = 0; c < (int)row.cells.size() && c < table.columnCount; ++c) {
                    widths[c] = std::max(widths[c],
                                         std::ceil(Text::width(row.cells[c], row.isHeader ? bold : font)) + 20);
                }
            }
            float preferred = 0;
            for (float w : widths) preferred += w;
            if (preferred > available) {
                float sc = available / preferred;
                for (float& w : widths) w = std::max(40.0f, std::floor(w * sc));
            }
            float tableWidth = 0;
            for (float w : widths) tableWidth += w;
            tableWidth = std::min(available, tableWidth);
            for (auto& row : table.rows) {
                if (revealed(row.sourceRange) || !row.sourceRange.length) continue;
                if (!geo.lineVisible(row.sourceRange.location)) continue;
                float y = top(row.sourceRange.location);
                Rect rowRect(textLeft, y, tableWidth, lh);
                g.fillRect(Rect(gutter, y, viewW - gutter, lh), Theme::editorBackground);
                g.fillRect(rowRect, row.isHeader ? Theme::inputBackground : Theme::editorBackground);
                float x = rowRect.x;
                for (int c = 0; c < table.columnCount; ++c) {
                    float width = c < (int)widths.size() ? widths[c] : 60;
                    Rect cell(x + 8, y, std::max(1.0f, width - 16), lh);
                    if (c < (int)row.cells.size()) {
                        g.text(row.cells[c], row.isHeader ? bold : font, Theme::foreground, cell);
                    }
                    x += width;
                }
                g.strokeRect(rowRect, Theme::border, 1);
                x = rowRect.x;
                for (size_t c = 0; c + 1 < widths.size(); ++c) {
                    x += widths[c];
                    g.fillRect(Rect(std::floor(x), y, 1, lh), Theme::border);
                }
            }
        }

        // ── Pictures on lines of their own.
        for (auto& image : markdown_.images) {
            if (revealed(image.sourceRange) || !image.sourceRange.intersects(visible)) continue;
            if (!geo.lineVisible(image.sourceRange.location)) continue;
            int line = (int)call(SCI_LINEFROMPOSITION, image.sourceRange.location);
            int extra = (int)call(SCI_ANNOTATIONGETLINES, line);
            float y = top(image.sourceRange.location);
            Rect row(gutter, y, viewW - gutter, lh * (1 + extra));
            g.fillRect(row, Theme::editorBackground);
            float available = std::max(80.0f, viewW - textLeft * 2 + gutter);
            Impl::CachedImage* cached = nullptr;
            if (image.url && image.url->isFile) {
                auto hit = d.images.find(image.url->path);
                if (hit != d.images.end() && hit->second && hit->second->source) cached = &*hit->second;
            }
            if (cached && cached->size.w > 0 && cached->size.h > 0) {
                if (!cached->bitmap) cached->bitmap = Imaging::bitmap(g.context(), cached->source.get());
                float sc = std::min({1.0f, available / cached->size.w, std::max(1.0f, row.h - 8) / cached->size.h});
                Size size(std::floor(cached->size.w * sc), std::floor(cached->size.h * sc));
                if (cached->bitmap) {
                    g.drawBitmap(cached->bitmap.get(), Rect(textLeft, row.midY() - size.h / 2, size.w, size.h));
                }
            } else {
                std::wstring label = image.alt.empty() ? L"Image" : image.alt;
                drawSymbol(g, Symbol::Photo, Rect(textLeft, row.midY() - 7, 14, 14), Theme::dimText);
                g.text(label, Theme::editorFont(), Theme::dimText,
                       Rect(textLeft + 20, row.midY() - 9, std::max(0.0f, available - 20), 18));
            }
        }

        // ── Bullets, quote bars and footnote labels over their markers.
        for (auto& marker : markdown_.lineMarkers) {
            if (revealed(marker.sourceRange) || !marker.sourceRange.intersects(visible)) continue;
            if (!geo.lineVisible(marker.sourceRange.location)) continue;
            auto segs = geo.segments(marker.sourceRange);
            if (segs.empty()) continue;
            auto [x0, x1, t] = segs.front();
            Rect cover(x0 / s, t / s, (x1 - x0) / s, lh);
            g.fillRect(cover, Theme::editorBackground);
            Font font = Theme::editorFont();
            switch (marker.kind) {
            case MarkdownLineMarkerDecoration::Kind::Bullet:
            case MarkdownLineMarkerDecoration::Kind::Footnote: {
                std::wstring label = marker.kind == MarkdownLineMarkerDecoration::Kind::Bullet
                                         ? marker.label : marker.label + L".";
                float width = Text::width(label, font);
                float x = std::max(cover.x, cover.maxX() - width - 3);
                g.text(label, font, Theme::dimText, Rect(x, cover.y, width + 2, cover.h), LineBreak::Clipping);
                break;
            }
            case MarkdownLineMarkerDecoration::Kind::Quote:
                for (int level = 0; level < marker.depth; ++level) {
                    g.fillRect(Rect(cover.x + level * 4 + 1, cover.y + 2, 2, std::max(0.0f, cover.h - 4)),
                               Theme::border);
                }
                break;
            }
        }

        // ── Task check boxes.
        for (auto& task : markdown_.tasks) {
            if (revealed(task.sourceRange) || !task.sourceRange.intersects(visible)) continue;
            if (!geo.lineVisible(task.sourceRange.location)) continue;
            auto segs = geo.segments(task.sourceRange.intersection(TextRange(0, length)));
            if (segs.empty()) continue;
            auto [x0, x1, t] = segs.front();
            Rect cover(x0 / s, t / s, (x1 - x0) / s, lh);
            g.fillRect(cover, Theme::editorBackground);
            float side = std::min(14.0f, std::max(10.0f, lh - 8));
            Rect box(cover.x + 1, cover.midY() - side / 2, side, side);
            if (task.checked) {
                g.fillRoundedRect(box, 2.5f, Theme::blue);
                g.polyline({{box.x + side * 0.24f, box.midY()},
                            {box.x + side * 0.43f, box.maxY() - side * 0.27f},
                            {box.maxX() - side * 0.20f, box.y + side * 0.27f}},
                           Color(1, 1, 1), 1.6f, true);
            } else {
                g.strokeRoundedRect(box, 2.5f, Theme::dimText, 1.2f);
            }
        }

        // ── Thematic breaks.
        for (auto& rule : markdown_.rules) {
            if (!rule.lineRange.length || !rule.lineRange.intersects(visible)) continue;
            if (!geo.lineVisible(rule.lineRange.location)) continue;
            float y = top(rule.lineRange.location) + lh / 2;
            g.fillRect(Rect(textLeft + 4, std::floor(y), std::max(0.0f, viewW - textLeft * 2 + gutter - 8), 1),
                       Theme::border);
        }

        // ── The language over a fenced block.
        for (auto& block : markdown_.codeBlocks) {
            if (!block.language || block.language->empty() || !block.range.length) continue;
            if (!block.range.intersects(visible) || !geo.lineVisible(block.range.location)) continue;
            Font font = Theme::uiFont(9.5f);
            std::wstring language = W(*block.language);
            float width = Text::width(language, font);
            float y = top(block.range.location) + 2;
            float x = std::max(textLeft, viewW - (textLeft - gutter) - width - 6);
            g.text(language, font, Theme::dimText, font.ascender() + y, Rect(x, y, width + 2, font.lineHeight()),
                   LineBreak::Clipping);
        }

        // ── Ctrl-hover: what a click would open.
        if (commandHoverRange_ && commandHoverRange_->length && commandHoverRange_->end() <= length) {
            for (auto& [x0, x1, t] : geo.segments(*commandHoverRange_)) {
                float y = std::floor((t + geo.lineHeight) / s - 0.5f);
                g.line(Point(x0 / s, y), Point(x1 / s, y), Theme::purple, 1.5f, true);
            }
        }

        // ── The bracket pair, or the JSX element, around the caret.
        auto glyphBox = [&](const TextRange& r) -> std::optional<std::pair<Rect, float>> {
            if (r.end() > length || isCharacterHidden(r.location) || !geo.lineVisible(r.location)) return std::nullopt;
            auto segs = geo.segments(r);
            if (segs.empty()) return std::nullopt;
            auto [x0, x1, t] = segs.front();
            Rect box(x0 / s, geo.glyphTop(t) / s, std::max(1.0f, (x1 - x0) / s), geo.glyphHeight() / s);
            // The line's first written character, for the guide.
            std::string_view text = doc_->view();
            Lines lines{text};
            TextRange line = lines.line(r.location);
            size_t first = line.location;
            size_t lineEnd = std::min(line.end(), text.size());
            while (first < lineEnd && isSpace(text[first])) ++first;
            float leading = box.x;
            if (first < lineEnd && text[first] != '\n' && text[first] != '\r') leading = geo.x(first) / s;
            return std::make_pair(box, leading);
        };
        std::optional<std::pair<Rect, float>> opening, closing;
        if (bracketMatches_.size() == 2) {
            opening = glyphBox(bracketMatches_[0]);
            closing = glyphBox(bracketMatches_[1]);
        } else if (activeJSX_) {
            closing = glyphBox(activeJSX_->closingTerminatorRange);
            opening = glyphBox(activeJSX_->kind == JSXTagMatch::Kind::SelfClosing ? activeJSX_->openingAngleRange
                                                                                   : activeJSX_->openingHeadRange);
            if (opening && activeJSX_->kind == JSXTagMatch::Kind::Paired) {
                // The head as a whole: `<Button` from its angle to its name's end.
                auto segs = geo.segments(activeJSX_->openingHeadRange);
                if (!segs.empty()) {
                    auto [x0, x1, t] = segs.front();
                    opening->first.x = x0 / s;
                    opening->first.w = std::max(1.0f, (x1 - x0) / s);
                }
            }
        }
        if (opening && closing) {
            Rect o = opening->first, c = closing->first;
            g.pushClip(Rect(gutter, 0, viewW - gutter, viewH));
            if (std::fabs(o.midY() - c.midY()) < 0.5f) {
                Rect box = o.united(c).inset(-2, -2);
                g.strokeRect(box, Theme::red, 1.5f);
            } else {
                float minimumGuide = gutter + marginLeft + 1;
                float guide = std::max(minimumGuide, std::min(opening->second, closing->second) - 3);
                guide = std::min({guide, o.x - 3, c.x - 3});
                float oy = o.maxY() + 1, cy = c.maxY() + 1;
                g.polyline({{o.maxX() + 2, oy}, {guide, oy}, {guide, cy}, {c.maxX() + 2, cy}}, Theme::red, 1.5f,
                           false);
            }
            g.popClip();
        }

        // ── Blame after the end of the caret's line.
        if (inlineBlame_ && !inlineBlame_->empty()) {
            size_t at = std::min(caret(), length);
            int line = (int)call(SCI_LINEFROMPOSITION, at);
            if (call(SCI_GETLINEVISIBLE, line)) {
                size_t end = (size_t)call(SCI_GETLINEENDPOSITION, line);
                float x = geo.x(end) / s;
                float t = geo.y(end) / s;
                Font full = Theme::editorFont();
                Font font = Fonts::get(full.family(), std::max(6.0f, full.size() - 1), full.weight());
                std::wstring text = L"    " + *inlineBlame_;
                float available = viewW - x - marginRight;
                if (available >= 60) {
                    float width = std::min(Text::width(text, font), available);
                    g.text(text, font, Theme::dimText.withAlpha(0.75f), Rect(x, t, width, lh));
                }
            }
        }
    }

    // ── The gutter.
    d.arrowHitRects.clear();
    d.changeMarkRects.clear();
    if (showsGutter_ && doc_) {
        g.fillRect(Rect(0, 0, gutter, viewH), Theme::editorBackground);
        Font font = Theme::editorFont();
        float numbersStart = dividerReach + changeMarkHoverWidth + 2;
        float numbersEnd = gutter - foldArrowColumn;
        int caretLine = (int)call(SCI_LINEFROMPOSITION, caret());
        std::map<int, const CodeBlock*> foldable;
        for (auto& block : blocks_) {
            int line = SciDoc::lineFromPosition(doc_->handle(), block.openerLineStart);
            auto hit = foldable.find(line);
            if (hit == foldable.end() || hit->second->endLocation < block.endLocation) foldable[line] = &block;
        }
        for (int display = firstDisplay; display <= firstDisplay + onScreen; ++display) {
            int line = (int)call(SCI_DOCLINEFROMVISIBLE, display);
            if (line >= doc_->lineCount()) break;
            // Wrapped continuations and annotation rows carry no number.
            if ((int)call(SCI_VISIBLEFROMDOCLINE, line) != display) continue;
            float y = (display - firstDisplay) * lh;
            std::optional<int> shown;
            if (diffLineNumbers_.empty()) shown = line + 1;
            else if (line < (int)diffLineNumbers_.size()) shown = diffLineNumbers_[line];
            if (shown) {
                std::wstring value = std::to_wstring(*shown);
                bool active = line == caretLine;
                float textWidth = Text::width(value, font);
                Rect box(numbersStart, y, numbersEnd - numbersStart, lh);
                if (active) {
                    float thickness = 1.5f;
                    float width = std::max(std::ceil(textWidth), 6.0f);
                    float textBottom = y + lh / 2 + font.lineHeight() / 2;
                    float rule = std::min(textBottom + 1, y + lh - thickness);
                    g.fillRect(Rect(box.maxX() - width, rule, width, thickness), Theme::red);
                }
                g.text(value, font, active ? Theme::gutterActive : Theme::gutter, box, LineBreak::Clipping,
                       Align::Right);
            }
            if (const GitLineChanges::Change* change = GitLineChanges::changeAt(line + 1, gitChanges_)) {
                float width = changeMarkWidth;
                if (d.hoveredChange && change->sameLines(*d.hoveredChange)) width = (float)markWidth(d.hoverProgress);
                else if (d.fadingChange && change->sameLines(*d.fadingChange)) width = (float)markWidth(d.fadingProgress);
                Rect mark(dividerReach, y, width, lh);
                if (change->kind == GitLineChanges::Change::Kind::Deleted) {
                    g.fillRoundedRect(Rect(mark.x, mark.y, mark.w, 3), 1.5f, change->colour());
                } else {
                    g.fillRoundedRect(mark, 1.5f, change->colour());
                }
                d.changeMarkRects.push_back({*change, Rect(dividerReach, y, numbersEnd - dividerReach, lh)});
            }
            auto fold = foldable.find(line);
            if (fold != foldable.end()) {
                const CodeBlock& block = *fold->second;
                Rect hit(gutter - foldArrowColumn, y, foldArrowColumn, lh);
                d.arrowHitRects[block.identity()] = hit;
                if (d.hoveredBlock && *d.hoveredBlock == block.identity()) {
                    drawFoldArrow(g, Rect(gutter - foldArrowColumn + 2, y + lh / 2 - 5, 10, 10), isFolded(block));
                }
            }
        }
    }

    // ── The scroller, over everything but the navigator.
    {
        int total = (int)call(SCI_VISIBLEFROMDOCLINE, doc_ ? doc_->lineCount() : 1);
        int lines = (int)call(SCI_LINESONSCREEN);
        if (firstDisplay != d.lastFirstLine) {
            if (d.lastFirstLine >= 0) {
                d.scrollerFlashing = true;
                if (d.flashEnd) d.flashEnd->cancel();
                d.flashEnd = Dispatch::after(1.0, [this, alive = life_.weak()] {
                    if (alive.expired()) return;
                    d_->scrollerFlashing = false;
                    requestRepaint();
                });
            }
            d.lastFirstLine = firstDisplay;
        }
        if (total > lines && (d.scrollerFlashing || d.scrollerHot || d.scrollerDragging)) {
            float thickness = (d.scrollerHot || d.scrollerDragging) ? kKnobHot : kKnobIdle;
            Rect track(viewW - thickness - 2, 2, thickness, viewH - 4);
            float lengthKnob = std::min(track.h, std::max(kKnobMinimum, track.h * lines / (float)total));
            int maxFirst = std::max(1, total - lines);
            float position = (track.h - lengthKnob) * std::clamp(firstDisplay / (float)maxFirst, 0.0f, 1.0f);
            if (d.scrollerHot || d.scrollerDragging) {
                g.fillRoundedRect(track.inset(-1, -1), (track.w + 2) / 2, Theme::scrollerSlot);
            }
            Rect knob(track.x, track.y + position, track.w, lengthKnob);
            float inset = std::min(1.0f, knob.w / 6);
            Rect paint = knob.inset(inset, 0);
            g.fillRoundedRect(paint, paint.w / 2, Theme::scrollerKnob);
        }
    }

    // ── The search navigator.
    if (showsNavigator_) {
        float total = kNavigatorButton * 3 + kNavigatorSpacing * 2;
        float x = viewW - kNavigatorTrailing - kNavigatorButton;
        float y0 = viewH / 2 - total / 2;
        Symbol symbols[3] = {Symbol::ChevronUp, Symbol::ChevronDown, Symbol::XMark};
        for (int i = 0; i < 3; ++i) {
            Rect r(x, y0 + i * (kNavigatorButton + kNavigatorSpacing), kNavigatorButton, kNavigatorButton);
            bool hot = d.navigatorHot == i || d.navigatorPressed == i;
            g.fillEllipse(r.inset(0.5f, 0.5f), hot ? Theme::selectedControl : Theme::activeTab);
            g.strokeEllipse(r.inset(0.5f, 0.5f), Theme::border, 1);
            drawSymbol(g, symbols[i], r.inset(r.w / 3, r.h / 3), hot ? Theme::foreground : Theme::dimText, 1.3f);
        }
    }
}

// ── Messages ───────────────────────────────────────────────────────────────

LRESULT CALLBACK EditorView::subclassProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam, UINT_PTR,
                                          DWORD_PTR data) {
    auto* view = reinterpret_cast<EditorView*>(data);
    bool handled = false;
    LRESULT result = view->handle(message, wParam, lParam, &handled);
    if (handled) return result;
    return DefSubclassProc(hwnd, message, wParam, lParam);
}

bool EditorView::controlNotify(NMHDR* header, LRESULT* result) {
    if (header->hwndFrom != sci_) return false;
    auto* n = reinterpret_cast<SCNotification*>(header);
    *result = 0;
    switch (n->nmhdr.code) {
    case SCN_MODIFIED:
        if (n->modificationType & (SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT)) {
            // Folds are remembered by their opener's offset: shift them with
            // the edit, or one opens on the next analysis.
            if (!folded_.empty()) {
                size_t start = (size_t)n->position;
                bool inserted = n->modificationType & SC_MOD_INSERTTEXT;
                long long delta = inserted ? (long long)n->length : -(long long)n->length;
                size_t removedEnd = inserted ? start : start + (size_t)n->length;
                std::set<size_t> moved;
                for (size_t f : folded_) {
                    if (f < start) moved.insert(f);
                    else if (f < removedEnd) continue;
                    else moved.insert((size_t)((long long)f + delta));
                }
                folded_ = moved;
            }
            if (doc_ && doc_->isApplyingExternalChange()) return true;
            if (!d_->textChangePending) {
                d_->textChangePending = true;
                Dispatch::main([this, alive = life_.weak()] {
                    if (alive.expired()) return;
                    d_->textChangePending = false;
                    if (onTextChanged) onTextChanged();
                });
            }
        }
        return true;
    case SCN_UPDATEUI:
        if (n->updated & (SC_UPDATE_SELECTION | SC_UPDATE_CONTENT)) {
            if (!d_->selectionCheckPending) {
                d_->selectionCheckPending = true;
                Dispatch::main([this, alive = life_.weak()] {
                    if (alive.expired()) return;
                    d_->selectionCheckPending = false;
                    size_t anchor = (size_t)call(SCI_GETANCHOR), at = caret();
                    if (anchor == d_->lastAnchor && at == d_->lastCaret) return;
                    d_->lastAnchor = anchor;
                    d_->lastCaret = at;
                    setShowsCurrentLineBand(showsCurrentLineBand_);
                    if (onSelectionChanged) onSelectionChanged();
                });
            }
        }
        if (n->updated & SC_UPDATE_V_SCROLL) {
            if (d_->linkCard) d_->linkCard->close();
            d_->hoveredLink.reset();
        }
        return true;
    case SCN_FOCUSOUT:
        if (onLostFocus) onLostFocus();
        return true;
    case SCN_FOCUSIN:
        if (WindowHost* host = window()) host->setFocusedView(nullptr);
        if (onGainedFocus) onGainedFocus();
        return true;
    default:
        return false;
    }
}

bool EditorView::nativeKeyDown(const KeyEvent& e) {
    if (!sci_ || GetFocus() != sci_) return false;
    if (onExplicitCaretInteraction) onExplicitCaretInteraction();
    if (e.key == VK_CONTROL || e.key == VK_SHIFT || e.key == VK_MENU) return false;
    bool plain = !e.control && !e.alt;
    if (e.key == VK_BACK && e.shift && plain) return deleteCurrentLine();
    if (e.key == VK_RETURN && e.shift && plain) return insertLineBelow();
    if (e.key == 'D' && e.control && !e.shift && !e.alt) return duplicateCurrentLine();
    if (e.key == VK_OEM_2 && e.control && !e.alt) {
        toggleComment();
        return true;
    }
    if (e.control && e.alt && (e.key == VK_OEM_4 || e.key == VK_OEM_6)) {
        if (e.key == VK_OEM_6) {
            unfoldAll();
            return true;
        }
        size_t at = caret();
        const CodeBlock* innermost = nullptr;
        for (auto& block : blocks_) {
            if (block.fullRange().contains(at) && (!innermost || block.depth > innermost->depth)) innermost = &block;
        }
        if (innermost) toggleFold(*innermost);
        return true;
    }
    if (!editable_ || !doc_) return false;
    if (e.key == VK_RETURN && plain && !e.shift && hasSingleEmptySelection()) {
        // A new line inherits the indent, one level more after an opener, and
        // a split pair puts the closer on a line of its own.
        std::string_view s = doc_->view();
        Lines lines{s};
        size_t at = std::min(caret(), s.size());
        std::string indent = lines.carriedIndent(at);
        std::string eol = eolOf(*this);
        std::optional<char> opener;
        if (usesBracketIndent) {
            TextRange line = lines.line(at);
            size_t i = std::min(at, line.end());
            while (i > line.location && isSpace(s[i - 1])) --i;
            if (i > line.location && (s[i - 1] == '{' || s[i - 1] == '[' || s[i - 1] == '(')) opener = s[i - 1];
        }
        if (!opener) {
            if (indent.empty()) return false;
            insertText(eol + indent, TextRange(at, 0));
            scrollRangeToVisible(selection());
            return true;
        }
        std::string inner = indent + indentUnit(indent);
        size_t i = at;
        while (i < s.size() && isSpace(s[i])) ++i;
        bool closerFollows = i < s.size() && s[i] == closerFor(*opener);
        if (!closerFollows) {
            insertText(eol + inner, TextRange(at, 0));
        } else {
            insertText(eol + inner + eol + indent, TextRange(at, 0));
            setSelection(TextRange(at + eol.size() + inner.size(), 0));
        }
        scrollRangeToVisible(selection());
        return true;
    }
    if (e.key == VK_HOME && plain && !e.shift) {
        // Home goes to the line's first written character, with no toggle.
        std::string_view s = doc_->view();
        size_t at = std::min(caret(), s.size());
        int line = (int)call(SCI_LINEFROMPOSITION, at);
        size_t start = (size_t)call(SCI_POSITIONFROMLINE, line);
        size_t end = (size_t)call(SCI_GETLINEENDPOSITION, line);
        size_t target = start;
        while (target < end && isSpace(s[target])) ++target;
        if (target == end) target = start;
        setSelection(TextRange(target, 0));
        call(SCI_SCROLLCARET);
        return true;
    }
    return false;
}

LRESULT EditorView::handle(UINT message, WPARAM wParam, LPARAM lParam, bool* handled) {
    Impl& d = *d_;
    float s = d.scale();
    auto local = [&](LPARAM lp) { return Point(GET_X_LPARAM(lp) / s, GET_Y_LPARAM(lp) / s); };
    RECT client;
    GetClientRect(sci_, &client);
    float viewW = client.right / s, viewH = client.bottom / s;
    float gutter = gutterWidth();

    auto navigatorAt = [&](Point p) -> int {
        if (!showsNavigator_) return -1;
        float total = kNavigatorButton * 3 + kNavigatorSpacing * 2;
        float x = viewW - kNavigatorTrailing - kNavigatorButton;
        float y0 = viewH / 2 - total / 2;
        for (int i = 0; i < 3; ++i) {
            Rect r(x, y0 + i * (kNavigatorButton + kNavigatorSpacing), kNavigatorButton, kNavigatorButton);
            float dx = p.x - r.midX(), dy = p.y - r.midY();
            if (dx * dx + dy * dy <= (r.w / 2) * (r.w / 2)) return i;
        }
        return -1;
    };
    auto scrollerMetrics = [&](int& total, int& lines) {
        total = (int)call(SCI_VISIBLEFROMDOCLINE, doc_ ? doc_->lineCount() : 1);
        lines = (int)call(SCI_LINESONSCREEN);
    };
    auto onScroller = [&](Point p) {
        int total, lines;
        scrollerMetrics(total, lines);
        return total > lines && p.x >= viewW - kScrollerHit;
    };
    auto positionAt = [&](Point p) -> std::optional<size_t> {
        sptr_t pos = call(SCI_POSITIONFROMPOINTCLOSE, (uptr_t)std::lround(p.x * s), (sptr_t)std::lround(p.y * s));
        if (pos < 0) return std::nullopt;
        return (size_t)pos;
    };

    switch (message) {
    case WM_PAINT:
        *handled = true;
        paint();
        return 0;
    case WM_ERASEBKGND:
        *handled = true;
        return 1;
    case WM_NCHITTEST: {
        // The split divider's handle reaches into the gutter: let it through.
        POINT screen{GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)};
        ScreenToClient(sci_, &screen);
        if (showsGutter_ && screen.x < dividerReach * s) {
            *handled = true;
            return HTTRANSPARENT;
        }
        return 0;
    }
    case WM_SETCURSOR: {
        if (LOWORD(lParam) != HTCLIENT) return 0;
        POINT pt;
        GetCursorPos(&pt);
        ScreenToClient(sci_, &pt);
        Point p(pt.x / s, pt.y / s);
        LPCWSTR cursor = nullptr;
        if (navigatorAt(p) >= 0) cursor = IDC_HAND;
        else if (onScroller(p) || d.scrollerDragging) cursor = IDC_ARROW;
        else if (p.x < gutter) {
            cursor = IDC_ARROW;
            for (auto& [id, r] : d.arrowHitRects) {
                if (r.inset(-3, -3).contains(p)) cursor = IDC_HAND;
            }
            for (auto& [change, r] : d.changeMarkRects) {
                if (r.contains(p)) cursor = IDC_HAND;
            }
        }
        if (cursor) {
            SetCursor(LoadCursorW(nullptr, cursor));
            *handled = true;
            return TRUE;
        }
        return 0;
    }
    case WM_MOUSEMOVE: {
        Point p = local(lParam);
        d.mouse = p;
        if (!d.trackingLeave) {
            TRACKMOUSEEVENT track{sizeof track, TME_LEAVE, sci_, 0};
            TrackMouseEvent(&track);
            d.trackingLeave = true;
        }
        if (d.scrollerDragging) {
            int total, lines;
            scrollerMetrics(total, lines);
            float track = viewH - 4;
            float lengthKnob = std::min(track, std::max(kKnobMinimum, track * lines / (float)std::max(1, total)));
            float travel = std::max(1.0f, track - lengthKnob);
            int maxFirst = std::max(0, total - lines);
            int line = d.dragStartLine + (int)std::lround((p.y - d.dragStartY) / travel * maxFirst);
            call(SCI_SETFIRSTVISIBLELINE, std::clamp(line, 0, maxFirst));
            *handled = true;
            return 0;
        }
        bool hot = onScroller(p);
        if (hot != d.scrollerHot) {
            d.scrollerHot = hot;
            requestRepaint();
        }
        int nav = navigatorAt(p);
        if (nav != d.navigatorHot) {
            d.navigatorHot = nav;
            requestRepaint();
        }
        // Fold arrows appear anywhere on a foldable row, in the gutter or the code.
        std::optional<size_t> block;
        if (doc_ && showsGutter_) {
            for (auto& [id, r] : d.arrowHitRects) {
                if (p.y >= r.y && p.y < r.maxY()) block = id;
            }
        }
        if (block != d.hoveredBlock) {
            d.hoveredBlock = block;
            requestRepaint();
        }
        // Change ribbons grow under the pointer.
        std::optional<GitLineChanges::Change> change;
        bool overArrow = false;
        for (auto& [id, r] : d.arrowHitRects) overArrow = overArrow || r.inset(-3, -3).contains(p);
        if (!overArrow && p.x < gutter) {
            for (auto& [c, r] : d.changeMarkRects) {
                if (r.contains(p)) change = c;
            }
        }
        bool same = (change.has_value() == d.hoveredChange.has_value())
            && (!change || change->sameLines(*d.hoveredChange));
        if (!same) {
            if (d.hoveredChange) {
                d.fadingChange = d.hoveredChange;
                d.fadingProgress = d.hoverProgress;
            }
            d.hoveredChange = change;
            d.hoverProgress = 0;
            if (!d.hoverTimer.running()) {
                d.hoverTimer.start(1.0 / 60, [this] {
                    Impl& dd = *d_;
                    double step = 1 / (kHoverAnimation * 60);
                    if (dd.hoveredChange) dd.hoverProgress = std::min(1.0, dd.hoverProgress + step);
                    dd.fadingProgress = std::max(0.0, dd.fadingProgress - step);
                    if (dd.fadingProgress == 0) dd.fadingChange.reset();
                    requestRepaint();
                    bool growing = dd.hoveredChange && dd.hoverProgress < 1;
                    if (!growing && !dd.fadingChange) dd.hoverTimer.stop();
                });
            }
            requestRepaint();
        }
        // Ctrl over code: what a click would open.
        if (onCommandHover) {
            if ((wParam & MK_CONTROL) && p.x >= gutter) onCommandHover(positionAt(p));
            else if (commandHoverRange_) onCommandHover(std::nullopt);
        }
        // Links in rendered Markdown show where they point after a moment.
        if (!markdown_.links.empty() && p.x >= gutter) {
            std::optional<TextRange> link;
            if (auto pos = positionAt(p)) {
                for (auto& l : markdown_.links) {
                    if (l.sourceRange.contains(*pos)) link = l.sourceRange;
                }
            }
            if (link != d.hoveredLink) {
                if (d.linkHoverWork) d.linkHoverWork->cancel();
                if (!link) {
                    if (!(d.linkCard && d.linkCard->containsCursor())) {
                        if (d.linkCard) d.linkCard->close();
                        d.hoveredLink.reset();
                    }
                } else {
                    d.hoveredLink = link;
                    TextRange wanted = *link;
                    d.linkHoverWork = Dispatch::after(kLinkHoverDelay, [this, wanted, alive = life_.weak()] {
                        if (alive.expired() || d_->hoveredLink != wanted) return;
                        const MarkdownLinkDecoration* found = nullptr;
                        for (auto& l : markdown_.links) {
                            if (l.sourceRange == wanted) found = &l;
                        }
                        if (!found || !window()) return;
                        Rect anchor = rectForRange(wanted);
                        float sc = d_->scale();
                        POINT topLeft{(LONG)std::lround(anchor.x * sc), (LONG)std::lround(anchor.y * sc)};
                        POINT bottom{(LONG)std::lround(anchor.maxX() * sc), (LONG)std::lround(anchor.maxY() * sc)};
                        ClientToScreen(sci_, &topLeft);
                        ClientToScreen(sci_, &bottom);
                        RECT screen{topLeft.x, topLeft.y, bottom.x, bottom.y};
                        MarkdownLinkDecoration link = *found;
                        if (!d_->linkCard) d_->linkCard = std::make_unique<LinkCard>();
                        d_->linkCard->onOpen = [this, link, alive2 = life_.weak()] {
                            if (alive2.expired()) return;
                            if (d_->linkCard) d_->linkCard->close();
                            d_->hoveredLink.reset();
                            if (onOpenLink) onOpenLink(link);
                        };
                        d_->linkCard->show(link.destination, screen, window()->hwnd());
                    });
                }
            }
        }
        return 0;
    }
    case WM_MOUSELEAVE:
        d.trackingLeave = false;
        if (d.scrollerHot || d.navigatorHot >= 0 || d.hoveredBlock) {
            d.scrollerHot = false;
            d.navigatorHot = -1;
            d.hoveredBlock.reset();
            requestRepaint();
        }
        if (d.hoveredChange) {
            d.fadingChange = d.hoveredChange;
            d.fadingProgress = d.hoverProgress;
            d.hoveredChange.reset();
            requestRepaint();
        }
        if (onCommandHover && commandHoverRange_) onCommandHover(std::nullopt);
        if (d.linkHoverWork) d.linkHoverWork->cancel();
        if (d.linkCard && !d.linkCard->containsCursor()) {
            d.linkCard->close();
            d.hoveredLink.reset();
        }
        return 0;
    case WM_LBUTTONDOWN:
    case WM_LBUTTONDBLCLK: {
        Point p = local(lParam);
        int nav = navigatorAt(p);
        if (nav >= 0) {
            d.navigatorPressed = nav;
            SetCapture(sci_);
            requestRepaint();
            *handled = true;
            return 0;
        }
        if (onScroller(p)) {
            int total, lines;
            scrollerMetrics(total, lines);
            float track = viewH - 4;
            float lengthKnob = std::min(track, std::max(kKnobMinimum, track * lines / (float)std::max(1, total)));
            int maxFirst = std::max(1, total - lines);
            int first = (int)call(SCI_GETFIRSTVISIBLELINE);
            float knobTop = 2 + (track - lengthKnob) * first / (float)maxFirst;
            if (p.y < knobTop) call(SCI_PAGEUP);
            else if (p.y > knobTop + lengthKnob) {
                call(SCI_SETFIRSTVISIBLELINE, std::min(maxFirst, first + lines));
            } else {
                d.scrollerDragging = true;
                d.dragStartY = p.y;
                d.dragStartLine = first;
                SetCapture(sci_);
            }
            requestRepaint();
            *handled = true;
            return 0;
        }
        if (showsGutter_ && p.x < gutter) {
            *handled = true;
            // The fold arrow wins where they overlap; it is the smaller target.
            for (auto& [id, r] : d.arrowHitRects) {
                if (!r.inset(-3, -3).contains(p)) continue;
                for (auto& block : blocks_) {
                    if (block.identity() == id) {
                        d.hoveredBlock = id;
                        toggleFold(block);
                        return 0;
                    }
                }
            }
            for (auto& [change, r] : d.changeMarkRects) {
                if (r.contains(p) && onChangeClicked) {
                    GitLineChanges::Change hit = change;
                    onChangeClicked(hit, r);
                    return 0;
                }
            }
            return 0;
        }
        if ((wParam & MK_CONTROL) && onCommandClick) {
            if (auto pos = positionAt(p)) {
                if (onCommandClick(*pos)) {
                    *handled = true;
                    return 0;
                }
            }
        }
        if (onExplicitCaretInteraction) onExplicitCaretInteraction();
        return 0;
    }
    case WM_LBUTTONUP: {
        Point p = local(lParam);
        if (d.navigatorPressed >= 0) {
            int pressed = d.navigatorPressed;
            d.navigatorPressed = -1;
            ReleaseCapture();
            requestRepaint();
            *handled = true;
            if (navigatorAt(p) == pressed) {
                if (pressed == 0 && onSearchPrevious) onSearchPrevious();
                if (pressed == 1 && onSearchNext) onSearchNext();
                if (pressed == 2 && onSearchClear) onSearchClear();
            }
            return 0;
        }
        if (d.scrollerDragging) {
            d.scrollerDragging = false;
            ReleaseCapture();
            requestRepaint();
            *handled = true;
            return 0;
        }
        return 0;
    }
    case WM_RBUTTONDOWN: {
        Point p = local(lParam);
        if (p.x < gutter) {
            *handled = true;
            return 0;
        }
        // A right click outside the selection moves the caret there first.
        if (auto pos = positionAt(p)) {
            TextRange sel = selection();
            if (!(sel.length && *pos >= sel.location && *pos <= sel.end())) setSelection(TextRange(*pos, 0));
        }
        if (!isFocused()) focus();
        return 0;
    }
    case WM_CONTEXTMENU: {
        *handled = true;
        POINT screen{GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)};
        if (screen.x == -1 && screen.y == -1) {
            POINT caretPoint{(LONG)call(SCI_POINTXFROMPOSITION, 0, caret()),
                             (LONG)call(SCI_POINTYFROMPOSITION, 0, caret())};
            ClientToScreen(sci_, &caretPoint);
            screen = caretPoint;
        }
        bool hasSelection = !call(SCI_GETSELECTIONEMPTY);
        auto menu = std::make_shared<Menu>();
        menu->add(L"Cut", [this] { cut(); }, editable_ && hasSelection).shortcut = L"Ctrl+X";
        menu->add(L"Copy", [this] { copy(); }, hasSelection).shortcut = L"Ctrl+C";
        menu->add(L"Paste", [this] { paste(); }, editable_ && call(SCI_CANPASTE)).shortcut = L"Ctrl+V";
        menu->addSeparator();
        menu->add(L"Select All", [this] { selectAll(); }).shortcut = L"Ctrl+A";
        if (commentSyntax) {
            menu->addSeparator();
            menu->add(L"Toggle Comment", [this] { toggleComment(); }, editable_).shortcut = L"Ctrl+/";
        }
        if (WindowHost* host = window()) menu->popup(host->hwnd(), screen);
        return 0;
    }
    case WM_MOUSEWHEEL:
        // Ctrl+wheel zooms in Scintilla; the editor has no zoom.
        if (GET_KEYSTATE_WPARAM(wParam) & MK_CONTROL) {
            *handled = true;
            return 0;
        }
        return 0;
    case WM_CHAR: {
        char typed = (char)wParam;
        if (!usesBracketIndent || !editable_ || !doc_ || !(typed == '}' || typed == ']' || typed == ')')) return 0;
        if (!hasSingleEmptySelection()) return 0;
        // A closer typed on an otherwise empty line pulls it back one level,
        // in the same edit as the character.
        std::string_view text = doc_->view();
        Lines lines{text};
        size_t at = std::min(caret(), text.size());
        TextRange line = lines.line(at);
        std::string prefix(text.substr(line.location, at - line.location));
        if (prefix.empty() || prefix.find_first_not_of(" \t") != std::string::npos) return 0;
        std::string unit = indentUnit(prefix);
        if (prefix.size() < unit.size() || prefix.compare(prefix.size() - unit.size(), unit.size(), unit) != 0) {
            return 0;
        }
        std::string dedented = prefix.substr(0, prefix.size() - unit.size()) + typed;
        insertText(dedented, TextRange(line.location, at - line.location));
        *handled = true;
        return 0;
    }
    case WM_DESTROY:
        d.hoverTimer.stop();
        return 0;
    default:
        return 0;
    }
}

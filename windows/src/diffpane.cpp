#include "diffpane.h"

#include "menu.h"
#include "services.h"
#include "theme.h"

// ── DiffView ───────────────────────────────────────────────────────────────

DiffView::DiffView() {
    backgroundColor = Theme::diffBackground;
    addSubview(&list_);
    list_.rowHeight = Theme::diffRowHeight();
    list_.numberOfRows = [this] { return (int)rows_.size(); };
    list_.drawRow = [this](Graphics& g, int row, const Rect& rect) { drawRow(g, row, rect); };
    note_.font = Theme::uiFont(12);
    note_.color = Theme::dimText;
    note_.align = Align::Center;
    note_.wraps = true;
    note_.setHidden(true);
    addSubview(&note_);
}

void DiffView::layout() {
    Rect b = bounds();
    list_.setFrame(b);
    float width = std::max(0.0f, b.w - 40);
    float h = note_.fittingHeight(width);
    note_.setFrame(Rect(20, std::round((b.h - h) / 2), width, h));
}

void DiffView::configure(const std::string& diff, bool keepingPosition) {
    Point offset = list_.contentOffset();
    diff_ = diff;
    rebuild();
    // A clip view left alone keeps its place; a fresh diff starts at its top.
    list_.setContentOffset(keepingPosition ? offset : Point(0, 0));
}

void DiffView::setMode(DiffMode mode) {
    if (mode == mode_) return;
    mode_ = mode;
    rebuild();
    list_.setContentOffset(Point(0, 0));
}

void DiffView::rebuild() {
    DiffRows::Parsed parsed = mode_ == DiffMode::Unified ? DiffRows::unified(diff_)
                                                        : DiffRows::sideBySide(diff_);
    rows_ = std::move(parsed.rows);
    omittedLines_ = parsed.omittedLines;
    changeStarts_ = DiffRows::changeBlockStarts(rows_);
    currentBlock_ = -1;
    currentRow_.reset();
    // Only built when there is nothing to draw.
    note_.text = rows_.empty() ? note(diff_) : L"";
    note_.setHidden(!rows_.empty());
    list_.setHidden(rows_.empty());
    list_.reloadData();
    setNeedsLayout();
}

std::wstring DiffView::note(const std::string& diff) {
    if (contains(diff, "Binary files") || contains(diff, "GIT binary patch")
        || contains(diff, "new file (binary")) {
        return L"Binary file — no text to compare";
    }
    std::string text = trim(diff);
    if (text.empty()) return L"No changes";
    if (contains(diff, "old mode") || contains(diff, "new mode")) return L"Only the file mode changed";
    std::wstring wide = W(text);
    return wide.size() <= noteLimit ? wide : wide.substr(0, noteLimit) + L"…";
}

void DiffView::step(bool forward) {
    if (changeStarts_.empty()) return;
    int count = (int)changeStarts_.size();
    if (forward) currentBlock_ = currentBlock_ + 1 >= count ? 0 : currentBlock_ + 1;
    else currentBlock_ = currentBlock_ <= 0 ? count - 1 : currentBlock_ - 1;
    int row = changeStarts_[currentBlock_];
    currentRow_ = row;
    // Centred, and marked, so a jump inside the visible area is still seen.
    list_.centerRow(row);
    list_.setNeedsDisplay();
}

void DiffView::drawSide(Graphics& g, const Rect& rect, std::optional<int> number,
                        const std::optional<std::wstring>& text, const Color* background,
                        const Color& ink) {
    Font font = Theme::monoFont();
    if (background) g.fillRect(rect, *background);
    if (number) {
        g.text(std::to_wstring(*number), font, Theme::gutter,
               Rect(rect.x, rect.y, gutterWidth - 8, rect.h), LineBreak::Clipping, Align::Right);
    }
    if (!text) return;
    g.text(*text, font, ink,
           Rect(rect.x + gutterWidth, rect.y, std::max(0.0f, rect.w - gutterWidth - 6), rect.h));
}

void DiffView::drawRow(Graphics& g, int index, const Rect& rect) {
    const DiffRows::Row& row = rows_[index];
    Font font = Theme::monoFont();
    float gutter = gutterWidth;
    bool isCurrent = currentRow_ && *currentRow_ == index;
    if (row.kind == DiffRows::Row::Kind::Hunk) {
        g.fillRect(rect, Theme::lineHighlight);
        g.text(row.header, font, Theme::blue, Rect(rect.x + 8, rect.y, rect.w - 16, rect.h));
        return;
    }
    if (mode_ == DiffMode::Unified) {
        bool removed = row.isChange() && row.leftText;
        bool added = row.isChange() && row.rightText;
        if (removed || added) {
            g.fillRect(rect, removed ? Theme::diffRemovedBackground : Theme::diffAddedBackground);
        }
        bool context = row.kind == DiffRows::Row::Kind::Context;
        std::optional<int> left = (context || removed) ? row.leftNumber : std::nullopt;
        std::optional<int> right = (context || added) ? row.rightNumber : std::nullopt;
        if (left) {
            g.text(std::to_wstring(*left), font, Theme::gutter, Rect(rect.x, rect.y, gutter - 8, rect.h),
                   LineBreak::Clipping, Align::Right);
        }
        if (right) {
            g.text(std::to_wstring(*right), font, Theme::gutter,
                   Rect(rect.x + gutter, rect.y, gutter - 8, rect.h), LineBreak::Clipping, Align::Right);
        }
        std::wstring sign = removed ? L"-" : added ? L"+" : L" ";
        Color ink = removed ? Theme::diffRemovedText : added ? Theme::diffAddedText : Theme::foreground;
        const std::optional<std::wstring>& text = removed ? row.leftText : added ? row.rightText : row.leftText;
        g.text(sign + L" " + text.value_or(L""), font, ink,
               Rect(rect.x + gutter * 2, rect.y, std::max(0.0f, rect.w - gutter * 2 - 6), rect.h));
        if (isCurrent) g.fillRect(Rect(rect.x, rect.y, 3, rect.h), Theme::accent);
        return;
    }
    float half = std::round(rect.w / 2);
    bool leftChanged = row.isChange() && row.leftText;
    bool rightChanged = row.isChange() && row.rightText;
    // Left = the file as it was, right = as it is. A missing side stays empty
    // so the eye sees which side gained or lost the line.
    drawSide(g, Rect(rect.x, rect.y, half, rect.h), row.leftNumber, row.leftText,
             leftChanged ? &Theme::diffRemovedBackground : nullptr,
             leftChanged ? Theme::diffRemovedText : Theme::foreground);
    drawSide(g, Rect(rect.x + half, rect.y, rect.w - half, rect.h), row.rightNumber, row.rightText,
             rightChanged ? &Theme::diffAddedBackground : nullptr,
             rightChanged ? Theme::diffAddedText : Theme::foreground);
    g.fillRect(Rect(rect.x + half, rect.y, 1, rect.h), Theme::border);
    if (isCurrent) {
        g.fillRect(Rect(rect.x, rect.y, 3, rect.h), Theme::accent);
        g.fillRect(Rect(rect.x + half + 1, rect.y, 3, rect.h), Theme::accent);
    }
}

// ── DiffHeaderView ─────────────────────────────────────────────────────────

DiffHeaderView::DiffHeaderView() {
    backgroundColor = Theme::barBackground;
    auto configure = [this](SymbolButton& button, Symbol symbol, const wchar_t* label,
                            std::function<void()> action) {
        button.symbol = symbol;
        button.symbolSize = 11;
        button.weight = 1.1f;
        button.tint = Theme::foreground;
        button.hoverBackground = true;
        button.tooltip = label;
        button.onClick = std::move(action);
        addSubview(&button);
    };
    configure(previous_, Symbol::ChevronUp, L"Previous change", [this] { if (onPrevious) onPrevious(); });
    configure(next_, Symbol::ChevronDown, L"Next change", [this] { if (onNext) onNext(); });
    configure(mode_, Symbol::SplitRectangle, L"Show side by side",
              [this] { if (onToggleMode) onToggleMode(); });
}

void DiffHeaderView::configure(const std::string& path, int changes, long long omittedLines) {
    folder_ = W(deletingLastPathComponent(path));
    name_ = W(lastPathComponent(path));
    summary_ = changes == 1 ? L"1 change" : std::to_wstring(changes) + L" changes";
    if (omittedLines > 0) {
        summary_ += L"  ·  " + formatCount(omittedLines) + L" more lines not shown";
    }
    previous_.setEnabled(changes > 0);
    next_.setEnabled(changes > 0);
    tooltip = W(path);
    setNeedsDisplay();
}

void DiffHeaderView::setMode(DiffMode mode) {
    // The icon shows what clicking it gives you.
    mode_.symbol = mode == DiffMode::Unified ? Symbol::SplitRectangle : Symbol::Rectangle;
    mode_.tooltip = mode == DiffMode::Unified ? L"Show side by side" : L"Show as one file";
    mode_.setNeedsDisplay();
    setNeedsDisplay();
}

void DiffHeaderView::layout() {
    Rect b = bounds();
    float w = 30, h = 22;
    float y = std::floor((b.h - h) / 2);
    mode_.setFrame(Rect(std::max(0.0f, b.w - 6 - w), y, w, h));
    next_.setFrame(Rect(std::max(0.0f, mode_.frame().x - 6 - w), y, w, h));
    previous_.setFrame(Rect(std::max(0.0f, next_.frame().x - w), y, w, h));
}

void DiffHeaderView::draw(Graphics& g) {
    Rect b = bounds();
    g.fillRect(Rect(0, b.h - 1, b.w, 1), Theme::border);
    Font font = Theme::uiFont(11);
    Font summaryFont = Theme::uiFont(10);
    float baseline = Text::centeredBaseline(font, b);
    float summaryWidth = summary_.empty() ? 0 : std::ceil(Text::width(summary_, summaryFont)) + 10;
    float right = std::max(0.0f, previous_.frame().x - 6 - summaryWidth);
    if (!summary_.empty()) {
        g.text(summary_, summaryFont, Theme::dimText, baseline, Rect(right, 0, summaryWidth, b.h),
               LineBreak::TruncatingTail, Align::Right);
    }
    // The folder is context; the name is what is looked for, so it keeps
    // full contrast and the path gives way from its head.
    std::wstring separator = folder_.empty() ? L"" : folder_ + L"/";
    float nameWidth = std::ceil(Text::width(name_, font));
    float folderWidth = std::max(0.0f, right - 10 - nameWidth);
    g.text(separator, font, Theme::dimText, baseline, Rect(10, 0, folderWidth, b.h),
           LineBreak::TruncatingHead);
    float measured = std::min(folderWidth, std::ceil(Text::width(separator, font)));
    g.text(name_, font, Theme::foreground, baseline,
           Rect(10 + measured, 0, std::max(0.0f, right - 10 - measured), b.h),
           LineBreak::TruncatingMiddle);
}

// ── Tabs ───────────────────────────────────────────────────────────────────

TabPillView::TabPillView() {
    close_.symbol = Symbol::XMark;
    close_.symbolSize = 11;
    close_.weight = 1.0f;
    close_.tooltip = L"Close tab";
    close_.onClick = [this] { if (onClose) onClose(); };
    addSubview(&close_);
}

void TabPillView::configure(const std::wstring& title, bool active, const std::wstring& path) {
    title_ = title;
    active_ = active;
    // The open tab reads like the selected item everywhere else does.
    close_.tint = active ? Theme::selectedControlText : Theme::foreground;
    tooltip = path;
    setNeedsDisplay();
    setNeedsLayout();
}

float TabPillView::preferredWidth() const {
    return 12 + std::ceil(Text::width(title_, Theme::uiFont(11.5f))) + 8 + 14 + 10;
}

void TabPillView::layout() {
    Rect b = bounds();
    close_.setFrame(Rect(b.w - 22, (b.h - 14) / 2, 14, 14));
}

void TabPillView::draw(Graphics& g) {
    Rect b = bounds();
    if (active_) g.fillRect(b, Theme::selectedControl);
    g.text(title_, Theme::uiFont(11.5f), active_ ? Theme::selectedControlText : Theme::foreground,
           Rect(12, 0, std::max(0.0f, b.w - 12 - 26), b.h));
}

bool TabPillView::mouseDown(const MouseEvent&) {
    if (onSelect) onSelect();
    return true;
}

bool TabPillView::rightMouseDown(const MouseEvent& e) {
    WindowHost* host = window();
    if (!host) return true;
    Menu menu;
    menu.add(L"Close", [this] { if (onClose) onClose(); });
    menu.addSeparator();
    menu.add(L"Close Others", [this] { if (onCloseOthers) onCloseOthers(); }, canCloseOthers);
    menu.add(L"Close Tabs to the Right", [this] { if (onCloseRight) onCloseRight(); }, canCloseRight);
    menu.popup(host->hwnd(), host->screenPoint(e.windowLocation));
    return true;
}

void DiffTabBar::reload(const std::vector<TabInfo>& tabs, int active) {
    while (pills_.size() > tabs.size()) {
        retireView(std::move(pills_.back()));
        pills_.pop_back();
    }
    while (pills_.size() < tabs.size()) {
        auto pill = std::make_unique<TabPillView>();
        addSubview(pill.get());
        pills_.push_back(std::move(pill));
    }
    for (size_t index = 0; index < tabs.size(); ++index) {
        TabPillView& pill = *pills_[index];
        int i = (int)index;
        pill.configure(tabs[index].title, i == active, tabs[index].path);
        pill.onSelect = [this, i] { if (onSelect) onSelect(i); };
        pill.onClose = [this, i] { if (onClose) onClose(i); };
        pill.onCloseOthers = [this, i] { if (onCloseOthers) onCloseOthers(i); };
        pill.onCloseRight = [this, i] { if (onCloseRight) onCloseRight(i); };
        pill.canCloseOthers = tabs.size() > 1;
        pill.canCloseRight = index + 1 < tabs.size();
    }
    setNeedsLayout();
}

float DiffTabBar::layoutPills(bool apply) {
    float available = std::max(80.0f, bounds().w);
    float x = 0, y = 0;
    int rows = 1;
    for (auto& pill : pills_) {
        float rowAvailable = rows == 1 ? std::max(80.0f, available - trailingReserve) : available;
        float width = std::min(pill->preferredWidth(), rowAvailable);
        if (x + width > rowAvailable && x > 0) {
            x = 0;
            y += rowHeight;
            ++rows;
            width = std::min(pill->preferredWidth(), available);
        }
        if (apply) pill->setFrame(Rect(x, y, width, rowHeight));
        x += width;
    }
    return rows * rowHeight;
}

float DiffTabBar::currentHeight() { return std::max(rowHeight, layoutPills(false)); }

void DiffTabBar::layout() { layoutPills(true); }

// ── WelcomeView ────────────────────────────────────────────────────────────

/// One recent project: a box to tick, its name, and its dimmed parent.
class WelcomeView::RecentRow : public View {
public:
    RecentRow(const std::wstring& path, bool checked, WelcomeView* owner) : path_(path), owner_(owner) {
        check_.checked = checked;
        check_.onToggle = [this](bool on) { owner_->setChecked(path_, on); };
        name_.text = lastPathComponent(path);
        name_.font = Theme::uiFont(12);
        name_.color = Theme::foreground;
        name_.lineBreak = LineBreak::Clipping;
        parent_.text = RecentProjects::displayParent(path);
        parent_.font = Theme::uiFont(10);
        parent_.color = Theme::dimText;
        parent_.lineBreak = LineBreak::TruncatingHead;
        remove_.symbol = Symbol::XMark;
        remove_.symbolSize = 10;
        remove_.tint = Theme::dimText;
        remove_.tooltip = L"Remove from Recent";
        remove_.setHidden(true);
        remove_.onClick = [path] { RecentProjects::shared().remove(path); };
        addSubview(&check_);
        addSubview(&name_);
        addSubview(&parent_);
        addSubview(&remove_);
        tooltip = path;
    }
    void layout() override {
        Rect b = bounds();
        check_.setFrame(Rect(6, 0, 18, b.h));
        float x = check_.frame().maxX() + 4;
        float nameWidth = std::min(name_.fittingWidth() + 2, std::max(0.0f, b.w - x - 28));
        name_.setFrame(Rect(x, 0, nameWidth, b.h));
        float parentX = x + nameWidth + 8;
        parent_.setFrame(Rect(parentX, 0, std::max(0.0f, b.w - 6 - 16 - 6 - parentX), b.h));
        remove_.setFrame(Rect(b.w - 6 - 16, (b.h - 16) / 2, 16, 16));
    }
    void draw(Graphics& g) override {
        if (hovered_) g.fillRoundedRect(bounds(), 5, Theme::activeRow);
    }
    void mouseEntered() override {
        remove_.setHidden(false);
        setNeedsDisplay();
    }
    void mouseExited() override {
        remove_.setHidden(true);
        setNeedsDisplay();
    }
    /// A click ticks the row; a double click opens it.
    bool mouseDown(const MouseEvent& e) override {
        if (e.clickCount >= 2) {
            if (owner_->onOpenRecent) owner_->onOpenRecent(path_);
            return true;
        }
        check_.toggle();
        return true;
    }
    bool rightMouseDown(const MouseEvent& e) override {
        WindowHost* host = window();
        if (!host) return true;
        Menu menu;
        std::wstring path = path_;
        menu.add(L"Remove from Recent", [path] { RecentProjects::shared().remove(path); });
        menu.add(L"Show in Explorer", [path] { revealInExplorer(path); });
        menu.popup(host->hwnd(), host->screenPoint(e.windowLocation));
        return true;
    }
private:
    std::wstring path_;
    WelcomeView* owner_;
    CheckBox check_;
    Label name_;
    Label parent_;
    SymbolButton remove_;
};

WelcomeView::WelcomeView() {
    title_.text = APP_NAME;
    title_.font = Theme::uiFont(22);
    title_.color = Theme::foreground;
    title_.align = Align::Center;
    addSubview(&title_);
    openButton_.title = L"Open";
    openButton_.isDefault = true;
    openButton_.font = Theme::uiFont(12);
    openButton_.onClick = [this] { if (onOpenFolder) onOpenFolder(); };
    addSubview(&openButton_);
    // Open everything ticked below; off until something is.
    openCheckedButton_.title = L"Open Checked";
    openCheckedButton_.font = Theme::uiFont(12);
    openCheckedButton_.enabled = false;
    openCheckedButton_.onClick = [this] {
        std::vector<std::wstring> wanted;
        for (auto& path : RecentProjects::shared().paths()) {
            for (auto& ticked : checked_) {
                if (samePath(ticked, path)) {
                    wanted.push_back(path);
                    break;
                }
            }
        }
        if (!wanted.empty() && onOpenChecked) onOpenChecked(wanted);
    };
    addSubview(&openCheckedButton_);
    observer_ = RecentProjects::shared().observe([this] { reloadRecents(); });
    reloadRecents();
}

WelcomeView::~WelcomeView() { RecentProjects::shared().unobserve(observer_); }

void WelcomeView::setChecked(const std::wstring& path, bool on) {
    if (on) checked_.insert(path);
    else checked_.erase(path);
    openCheckedButton_.setEnabled(!checked_.empty());
}

void WelcomeView::reloadRecents() {
    for (auto& row : rows_) retireView(std::move(row));
    rows_.clear();
    auto recents = RecentProjects::shared().paths();
    // A project that has left the list cannot stay ticked.
    std::set<std::wstring> still;
    for (auto& path : recents) {
        if (checked_.count(path)) still.insert(path);
    }
    checked_ = still;
    openCheckedButton_.setEnabled(!checked_.empty());
    for (size_t i = 0; i < recents.size() && i < RecentProjects::displayLimit; ++i) {
        auto row = std::make_unique<RecentRow>(recents[i], checked_.count(recents[i]) > 0, this);
        addSubview(row.get());
        rows_.push_back(std::move(row));
    }
    setNeedsLayout();
    setNeedsDisplay();
}

void WelcomeView::layout() {
    Rect b = bounds();
    float titleHeight = std::ceil(title_.font.lineHeight()) + 4;
    float buttonHeight = 24;
    float rowsHeight = rows_.empty() ? 0 : rows_.size() * 22 + (rows_.size() - 1) * 2;
    float total = titleHeight + 18 + buttonHeight + (rows_.empty() ? 0 : 10 + rowsHeight);
    float width = std::min(420.0f, std::max(0.0f, b.w - 40));
    float y = std::round((b.h - total) / 2);
    float x = std::round((b.w - width) / 2);
    title_.setFrame(Rect(x, y, width, titleHeight));
    y += titleHeight + 18;
    float openWidth = openButton_.intrinsicWidth();
    float checkedWidth = openCheckedButton_.intrinsicWidth();
    float buttonsX = std::round((b.w - (openWidth + 8 + checkedWidth)) / 2);
    openButton_.setFrame(Rect(buttonsX, y, openWidth, buttonHeight));
    openCheckedButton_.setFrame(Rect(buttonsX + openWidth + 8, y, checkedWidth, buttonHeight));
    y += buttonHeight + 10;
    for (auto& row : rows_) {
        row->setFrame(Rect(x, y, width, 22));
        y += 24;
    }
}

// ── DiffPane ───────────────────────────────────────────────────────────────

DiffMode DiffPane::mode_ = DiffMode::Unified;
size_t DiffPane::bodyByteBudget = 24 * 1024 * 1024;

std::wstring DiffPane::Tab::id() const {
    std::wstring base = lowercased(directory) + L"|" + W(path);
    return source == Source::WorkingTree ? base : base + L"|" + W(hash);
}

std::wstring DiffPane::Tab::title() const {
    std::wstring name = W(lastPathComponent(path));
    return source == Source::WorkingTree ? name : name + L" @ " + W(hash);
}

DiffPane::DiffPane() {
    backgroundColor = Theme::diffBackground;
    addSubview(&tabBar_);
    addSubview(&header_);
    addSubview(&diffView_);
    hint_.text = L"Select a change or a commit's file to see its diff";
    hint_.font = Theme::uiFont(12);
    hint_.color = Theme::dimText;
    hint_.align = Align::Center;
    addSubview(&hint_);
    tabBar_.onSelect = [this](int i) { select(i); };
    tabBar_.onClose = [this](int i) { close(i); };
    tabBar_.onCloseOthers = [this](int i) { closeOthers(i); };
    tabBar_.onCloseRight = [this](int i) { closeRight(i); };
    header_.onPrevious = [this] { diffView_.step(false); };
    header_.onNext = [this] { diffView_.step(true); };
    header_.onToggleMode = [this] { toggleMode(); };
    header_.setMode(mode_);
    diffView_.setMode(mode_);
    reload();
}

void DiffPane::setHasProject(bool hasProject) {
    if (hasProject == hasProject_) return;
    hasProject_ = hasProject;
    updatePlaceholder();
}

void DiffPane::setTabRowHeight(float height) {
    tabBar_.rowHeight = std::max(20.0f, height);
    setNeedsLayout();
}

void DiffPane::setCaptionReserve(float width) {
    tabBar_.trailingReserve = width;
    setNeedsLayout();
}

void DiffPane::layout() {
    Rect b = bounds();
    float tabHeight = tabBar_.currentHeight();
    tabBar_.setFrame(Rect(0, 0, b.w, tabHeight));
    header_.setFrame(Rect(0, tabHeight, b.w, DiffHeaderView::height));
    float top = tabHeight + DiffHeaderView::height;
    diffView_.setFrame(Rect(0, top, b.w, std::max(0.0f, b.h - top)));
    float hintWidth = std::min(std::max(0.0f, b.w - 40), hint_.fittingWidth() + 4);
    hint_.setFrame(Rect(std::round((b.w - hintWidth) / 2), std::round(b.h / 2 - 10), hintWidth, 20));
    if (welcome_) welcome_->setFrame(b);
}

void DiffPane::open(const Tab& tab) {
    std::wstring id = tab.id();
    auto existing = std::find_if(tabs_.begin(), tabs_.end(), [&](const Tab& t) { return t.id() == id; });
    if (existing != tabs_.end()) {
        int index = (int)(existing - tabs_.begin());
        bool unchanged = existing->diff == tab.diff && activeIndex_ && *activeIndex_ == index;
        *existing = tab;
        activeIndex_ = index;
        if (unchanged) return;
    } else {
        // Next to the one being read, the way a browser opens a link.
        int at = activeIndex_ ? *activeIndex_ + 1 : (int)tabs_.size();
        tabs_.insert(tabs_.begin() + at, tab);
        activeIndex_ = at;
    }
    reload();
}

void DiffPane::update(const std::wstring& id, const std::string& diff) {
    auto it = std::find_if(tabs_.begin(), tabs_.end(), [&](const Tab& t) { return t.id() == id; });
    if (it == tabs_.end() || (it->diff == diff && !it->needsReread)) return;
    it->diff = diff;
    it->needsReread = false;
    if (!activeIndex_ || *activeIndex_ != (int)(it - tabs_.begin())) return;
    showActive(true);
}

void DiffPane::select(int index) {
    if (index < 0 || index >= (int)tabs_.size() || (activeIndex_ && *activeIndex_ == index)) return;
    activeIndex_ = index;
    reload();
}

void DiffPane::readAgainIfNeeded() {
    const Tab* tab = activeTab();
    if (!tab || !tab->needsReread || !onReadAgain) return;
    onReadAgain(tab->directory, tab->path, tab->source, tab->hash);
}

void DiffPane::noteShown(const std::wstring& id) {
    std::set<std::wstring> open;
    for (auto& tab : tabs_) open.insert(tab.id());
    shownOrder_.erase(std::remove_if(shownOrder_.begin(), shownOrder_.end(),
                                     [&](const std::wstring& s) { return s == id || !open.count(s); }),
                      shownOrder_.end());
    shownOrder_.push_back(id);
}

void DiffPane::enforceBodyBudget() {
    size_t held = 0;
    for (auto& tab : tabs_) held += tab.diff.size();
    if (held <= bodyByteBudget) return;
    std::optional<std::wstring> activeID;
    if (const Tab* active = activeTab()) activeID = active->id();
    std::set<std::wstring> shown(shownOrder_.begin(), shownOrder_.end());
    std::vector<std::wstring> oldestFirst;
    for (auto& tab : tabs_) {
        if (!shown.count(tab.id())) oldestFirst.push_back(tab.id());
    }
    oldestFirst.insert(oldestFirst.end(), shownOrder_.begin(), shownOrder_.end());
    for (auto& id : oldestFirst) {
        if (held <= bodyByteBudget) break;
        if (activeID && id == *activeID) continue;
        auto it = std::find_if(tabs_.begin(), tabs_.end(), [&](const Tab& t) { return t.id() == id; });
        if (it == tabs_.end() || it->diff.empty()) continue;
        held -= it->diff.size();
        it->diff.clear();
        it->diff.shrink_to_fit();
        it->needsReread = true;
    }
}

void DiffPane::markWorkingTreeTabsStale(const std::wstring& directory,
                                        const std::optional<std::wstring>& except) {
    for (auto& tab : tabs_) {
        if (samePath(tab.directory, directory) && tab.source == Tab::Source::WorkingTree
            && (!except || tab.id() != *except)) {
            tab.diff.clear();
            tab.diff.shrink_to_fit();
            tab.needsReread = true;
        }
    }
}

void DiffPane::releaseInactiveBodies() {
    closed_.clear();
    for (size_t i = 0; i < tabs_.size(); ++i) {
        if (activeIndex_ && *activeIndex_ == (int)i) continue;
        if (tabs_[i].diff.empty()) continue;
        tabs_[i].diff.clear();
        tabs_[i].diff.shrink_to_fit();
        tabs_[i].needsReread = true;
    }
}

void DiffPane::close(int index) {
    if (index < 0 || index >= (int)tabs_.size()) return;
    remember(tabs_[index]);
    tabs_.erase(tabs_.begin() + index);
    if (activeIndex_) {
        int active = *activeIndex_;
        if (tabs_.empty()) activeIndex_.reset();
        else if (index < active || active >= (int)tabs_.size()) activeIndex_ = active - 1;
    }
    reload();
}

bool DiffPane::closeActive() {
    if (!activeIndex_) return false;
    close(*activeIndex_);
    return true;
}

void DiffPane::closeOthers(int index) {
    if (index < 0 || index >= (int)tabs_.size()) return;
    Tab kept = tabs_[index];
    for (auto& tab : tabs_) {
        if (tab.id() != kept.id()) remember(tab);
    }
    tabs_ = {kept};
    activeIndex_ = 0;
    reload();
}

void DiffPane::closeRight(int index) {
    if (index < 0 || index + 1 >= (int)tabs_.size()) return;
    for (size_t i = index + 1; i < tabs_.size(); ++i) remember(tabs_[i]);
    tabs_.erase(tabs_.begin() + index + 1, tabs_.end());
    if (activeIndex_ && *activeIndex_ > index) activeIndex_ = index;
    reload();
}

void DiffPane::closeAll() {
    for (auto& tab : tabs_) remember(tab);
    tabs_.clear();
    activeIndex_.reset();
    reload();
}

void DiffPane::closeTabs(const std::wstring& directory) {
    std::vector<Tab> kept;
    for (auto& tab : tabs_) {
        if (!samePath(tab.directory, directory)) kept.push_back(tab);
    }
    if (kept.size() == tabs_.size()) return;
    std::optional<std::wstring> activeID;
    if (const Tab* active = activeTab()) activeID = active->id();
    for (auto& tab : tabs_) {
        if (samePath(tab.directory, directory)) remember(tab);
    }
    tabs_ = kept;
    activeIndex_.reset();
    if (activeID) {
        for (size_t i = 0; i < tabs_.size(); ++i) {
            if (tabs_[i].id() == *activeID) activeIndex_ = (int)i;
        }
    }
    if (!activeIndex_ && !tabs_.empty()) activeIndex_ = 0;
    reload();
}

void DiffPane::step(int offset) {
    if (tabs_.empty()) return;
    int count = (int)tabs_.size();
    int current = activeIndex_.value_or(0);
    activeIndex_ = ((current + offset) % count + count) % count;
    reload();
}

bool DiffPane::reopenLastClosed() {
    if (closed_.empty()) return false;
    ClosedTab tab = closed_.back();
    closed_.pop_back();
    if (onReadAgain) onReadAgain(tab.directory, tab.path, tab.source, tab.hash);
    return true;
}

void DiffPane::remember(const Tab& tab) {
    ClosedTab closing{tab.directory, tab.path, tab.source, tab.hash};
    closed_.erase(std::remove_if(closed_.begin(), closed_.end(),
                                 [&](const ClosedTab& c) {
                                     return samePath(c.directory, closing.directory)
                                         && c.path == closing.path && c.source == closing.source
                                         && c.hash == closing.hash;
                                 }),
                  closed_.end());
    closed_.push_back(closing);
    if (closed_.size() > 20) closed_.erase(closed_.begin());
}

const DiffPane::Tab* DiffPane::activeTab() const {
    if (!activeIndex_ || *activeIndex_ < 0 || *activeIndex_ >= (int)tabs_.size()) return nullptr;
    return &tabs_[*activeIndex_];
}

bool DiffPane::copyActiveDiff(HWND owner) {
    const Tab* tab = activeTab();
    if (!tab || tab->diff.empty() || tab->needsReread) return false;
    std::wstring text = W(tab->diff);
    // The clipboard's plain text is CRLF on Windows.
    std::wstring crlf;
    crlf.reserve(text.size() + text.size() / 32);
    for (size_t i = 0; i < text.size(); ++i) {
        if (text[i] == L'\n' && (i == 0 || text[i - 1] != L'\r')) crlf.push_back(L'\r');
        crlf.push_back(text[i]);
    }
    copyToClipboard(owner, crlf);
    return true;
}

std::wstring DiffPane::tooltip(const Tab& tab) const {
    return tab.source == Tab::Source::WorkingTree ? W(tab.path) : W(tab.path) + L" @ " + W(tab.hash);
}

void DiffPane::reload() {
    std::vector<DiffTabBar::TabInfo> infos;
    for (auto& tab : tabs_) infos.push_back({tab.title(), tooltip(tab)});
    tabBar_.reload(infos, activeIndex_.value_or(-1));
    setNeedsLayout();
    showActive(false);
    updatePlaceholder();
    readAgainIfNeeded();
}

void DiffPane::showActive(bool keepingPosition) {
    const Tab* tab = activeTab();
    if (!tab) {
        diffView_.configure("");
        return;
    }
    std::wstring id = tab->id();
    noteShown(id);
    enforceBodyBudget();
    tab = activeTab();
    diffView_.configure(tab->diff, keepingPosition);
    header_.configure(tab->path, diffView_.changeCount(), diffView_.omittedLines());
}

void DiffPane::toggleMode() {
    mode_ = mode_ == DiffMode::Unified ? DiffMode::SideBySide : DiffMode::Unified;
    header_.setMode(mode_);
    diffView_.setMode(mode_);
    if (const Tab* tab = activeTab()) {
        header_.configure(tab->path, diffView_.changeCount(), diffView_.omittedLines());
    }
}

void DiffPane::updatePlaceholder() {
    bool hasTabs = !tabs_.empty();
    tabBar_.setHidden(!hasTabs);
    header_.setHidden(!hasTabs);
    diffView_.setHidden(!hasTabs);
    updateWelcome();
    hint_.setHidden(hasTabs || !hasProject_);
}

void DiffPane::updateWelcome() {
    bool wanted = tabs_.empty() && !hasProject_;
    if (!wanted) {
        if (welcome_) retireView(std::move(welcome_));
        welcome_.reset();
        return;
    }
    if (welcome_ || welcomePending_) return;
    // A window opened for a project is handed it straight after it is made;
    // waiting one turn means such a window never builds a page to drop it.
    welcomePending_ = true;
    Dispatch::main([this, alive = life_.weak()] {
        if (alive.expired()) return;
        welcomePending_ = false;
        if (welcome_ || !tabs_.empty() || hasProject_) return;
        welcome_ = std::make_unique<WelcomeView>();
        welcome_->onOpenFolder = [this] { if (onOpenFolder) onOpenFolder(); };
        welcome_->onOpenRecent = [this](const std::wstring& path) { if (onOpenRecent) onOpenRecent(path); };
        welcome_->onOpenChecked = [this](const std::vector<std::wstring>& paths) {
            if (onOpenChecked) onOpenChecked(paths);
        };
        insertSubview(welcome_.get(), subviews().size() - 1);  // under the hint
        welcome_->setFrame(bounds());
        setNeedsLayout();
    });
}

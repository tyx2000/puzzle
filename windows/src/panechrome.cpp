#include "panechrome.h"

#include "menu.h"
#include "services.h"
#include "theme.h"

// ── SideBySideDiffView ─────────────────────────────────────────────────────

SideBySideDiffView::SideBySideDiffView() {
    backgroundColor = Theme::editorBackground;
    addSubview(&list_);
    list_.rowHeight = Theme::lineMetrics().target;
    list_.numberOfRows = [this] { return (int)rows_.size(); };
    list_.drawRow = [this](Graphics& g, int row, const Rect& rect) { drawRow(g, row, rect); };
}

void SideBySideDiffView::layout() { list_.setFrame(bounds()); }

void SideBySideDiffView::refreshAppearance() {
    backgroundColor = Theme::editorBackground;
    list_.rowHeight = Theme::lineMetrics().target;
    list_.reloadData();
    setNeedsDisplay();
}

void SideBySideDiffView::configure(const std::string& diff) {
    rows_ = DiffRows::sideBySide(diff).rows;
    changeStarts_ = DiffRows::changeBlockStarts(rows_);
    currentBlock_ = -1;
    currentRow_.reset();
    list_.rowHeight = Theme::lineMetrics().target;
    list_.reloadData();
    // A fresh diff starts at its top.
    list_.setContentOffset(Point(0, 0));
}

void SideBySideDiffView::step(bool forward) {
    if (changeStarts_.empty()) return;
    int count = (int)changeStarts_.size();
    if (forward) currentBlock_ = currentBlock_ + 1 >= count ? 0 : currentBlock_ + 1;
    else currentBlock_ = currentBlock_ <= 0 ? count - 1 : currentBlock_ - 1;
    int row = changeStarts_[currentBlock_];
    currentRow_ = row;
    list_.centerRow(row);
    list_.setNeedsDisplay();
}

void SideBySideDiffView::drawSide(Graphics& g, const Rect& rect, std::optional<int> number,
                                  const std::optional<std::wstring>& text, const Color* background,
                                  const Color& ink) {
    Font font = Theme::editorFont();
    if (background) g.fillRect(rect, *background);
    if (number) {
        g.text(std::to_wstring(*number), font, Theme::gutter, Rect(rect.x, rect.y, gutterWidth - 8, rect.h),
               LineBreak::Clipping, Align::Right);
    }
    if (!text) return;
    g.text(*text, font, ink, Rect(rect.x + gutterWidth, rect.y, std::max(0.0f, rect.w - gutterWidth - 6), rect.h));
}

void SideBySideDiffView::drawRow(Graphics& g, int index, const Rect& rect) {
    const DiffRows::Row& row = rows_[index];
    Font font = Theme::editorFont();
    bool isCurrent = currentRow_ && *currentRow_ == index;
    if (row.kind == DiffRows::Row::Kind::Hunk) {
        g.fillRect(rect, Theme::lineHighlight);
        g.text(row.header, font, Theme::blue, Rect(rect.x + 8, rect.y, rect.w - 16, rect.h));
        return;
    }
    float half = std::round(rect.w / 2);
    bool leftChanged = row.isChange() && row.leftText;
    bool rightChanged = row.isChange() && row.rightText;
    // Left = the file as it was, right = as it is; a missing side stays empty.
    drawSide(g, Rect(rect.x, rect.y, half, rect.h), row.leftNumber, row.leftText,
             leftChanged ? &Theme::diffRemovedBackground : nullptr,
             leftChanged ? Theme::diffRemovedText : Theme::foreground);
    drawSide(g, Rect(rect.x + half, rect.y, rect.w - half, rect.h), row.rightNumber, row.rightText,
             rightChanged ? &Theme::diffAddedBackground : nullptr,
             rightChanged ? Theme::diffAddedText : Theme::foreground);
    g.fillRect(Rect(rect.x + half, rect.y, 1, rect.h), Theme::border);
    if (isCurrent) {
        g.fillRect(Rect(rect.x, rect.y, 3, rect.h), Theme::cursor);
        g.fillRect(Rect(rect.x + half + 1, rect.y, 3, rect.h), Theme::cursor);
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

void DiffHeaderView::configure(const std::string& path, int changes) {
    path_ = path;
    folder_ = W(deletingLastPathComponent(path));
    name_ = W(lastPathComponent(path));
    summary_ = changes == 1 ? L"1 change" : std::to_wstring(changes) + L" changes";
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

void TabPillView::configure(const std::wstring& title, bool modified, bool active, const std::wstring& path) {
    title_ = modified ? title + L" ●" : title;
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

void EditorTabBar::reload(const std::vector<TabInfo>& tabs, int active) {
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
        pill.configure(tabs[index].title, tabs[index].modified, i == active, tabs[index].path);
        pill.onSelect = [this, i] { if (onSelect) onSelect(i); };
        pill.onClose = [this, i] { if (onClose) onClose(i); };
        pill.onCloseOthers = [this, i] { if (onCloseOthers) onCloseOthers(i); };
        pill.onCloseRight = [this, i] { if (onCloseRight) onCloseRight(i); };
        pill.canCloseOthers = tabs.size() > 1;
        pill.canCloseRight = index + 1 < tabs.size();
    }
    setNeedsLayout();
}

float EditorTabBar::layoutPills(bool apply) {
    float available = std::max(80.0f, bounds().w);
    float x = 0, y = 0;
    int rows = 1;
    for (auto& pill : pills_) {
        float rowAvailable = rows == 1 ? std::max(80.0f, available - actionAreaWidth - captionReserve)
                                       : std::max(80.0f, available - actionAreaWidth);
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

float EditorTabBar::currentHeight() { return std::max(rowHeight, layoutPills(false)); }

void EditorTabBar::layout() { layoutPills(true); }

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

void WelcomeView::refreshFonts() {
    title_.font = Theme::uiFont(22);
    openButton_.font = Theme::uiFont(12);
    openCheckedButton_.font = Theme::uiFont(12);
    reloadRecents();
}

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


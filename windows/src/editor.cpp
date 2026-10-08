#include "editor.h"

#include "theme.h"

const std::vector<std::pair<std::wstring, std::wstring>>& EmptyEditorHintView::lines() {
    // The keys the app menu gives these items.
    static const std::vector<std::pair<std::wstring, std::wstring>> list = {
        {L"Quick Open", L"Ctrl+P"},
        {L"Find in Folder", L"Ctrl+Shift+F"},
        {L"Show Git", L"Ctrl+3"},
        {L"Reopen Closed Tab", L"Ctrl+Shift+T"},
        {L"Open", L"Ctrl+O"},
    };
    return list;
}

void EmptyEditorHintView::draw(Graphics& g) {
    Font font = Theme::uiFont(12);
    const float rowHeight = 28, gap = 40;
    float titleWidth = 0, keysWidth = 0;
    for (auto& [title, keys] : lines()) {
        titleWidth = std::max(titleWidth, std::ceil(Text::width(title, font)) + 2);
        keysWidth = std::max(keysWidth, std::ceil(Text::width(keys, font)) + 2);
    }
    Rect b = bounds();
    float blockWidth = std::min(titleWidth + gap + keysWidth, b.w - 32);
    if (blockWidth <= 0) return;
    float height = lines().size() * rowHeight;
    float x = std::floor(b.midX() - blockWidth / 2), y = std::floor(b.midY() - height / 2);
    for (auto& [title, keys] : lines()) {
        Rect row(x, y, blockWidth, rowHeight);
        g.text(title, font, Theme::dimText, Rect(row.x, row.y, std::max(0.0f, row.w - keysWidth - gap / 2), row.h));
        g.text(keys, font, Theme::gutterActive, Rect(row.maxX() - keysWidth, row.y, keysWidth, row.h),
               LineBreak::Clipping, Align::Right);
        y += rowHeight;
    }
}

EditorArea::EditorArea() {
    backgroundColor = Theme::editorBackground;
    addSubview(&pane_);
    addSubview(&emptyHints_);
    settingsButton_.symbol = Symbol::Gear;
    settingsButton_.symbolSize = 13;
    settingsButton_.tint = Theme::dimText;
    settingsButton_.tooltip = L"Settings";
    settingsButton_.onClick = [this] {
        if (onOpenSettings) onOpenSettings();
    };
    addSubview(&settingsButton_);
    pane_.setActive(true);
    pane_.fileHistoryProvider = [this](const std::wstring& url) -> const FileHistoryModel* {
        auto hit = fileHistories_.find(url);
        return hit == fileHistories_.end() ? nullptr : &hit->second;
    };
    pane_.onDocumentSaved = [this](const std::wstring& url) {
        pane_.reloadTabs();
        if (onDocumentSaved) onDocumentSaved(url);
    };
    pane_.onDocumentEdited = [this] { pane_.reloadTabs(); };
    pane_.onActiveDocumentChanged = [this](const std::optional<std::wstring>& url) {
        if (onActiveDocumentChanged) onActiveDocumentChanged(url);
        updatePlaceholder();
    };
    pane_.onEmptied = [this] { updatePlaceholder(); };
    pane_.onTabOpened = [this](const std::wstring& url) { DocumentStore::shared().registerOpen(url, &pane_); };
    pane_.onTabClosed = [this](const std::wstring& url) {
        DocumentStore::shared().unregisterOpen(url, &pane_);
        fileHistories_.erase(url);
    };
    updatePlaceholder();
}

EditorArea::~EditorArea() {
    if (welcome_) welcome_->removeFromSuperview();
}

void EditorArea::setTabRowHeight(float height) {
    tabRowHeight_ = height;
    pane_.setTabRowHeight(height);
    setNeedsLayout();
}

void EditorArea::setCaptionReserve(float width) {
    captionReserve_ = width;
    pane_.setCaptionReserve(width);
    setNeedsLayout();
}

void EditorArea::layout() {
    Rect b = bounds();
    pane_.setFrame(b);
    emptyHints_.setFrame(b);
    if (welcome_) welcome_->setFrame(b);
    float x = b.w - captionReserve_ - 10 - 22;
    settingsButton_.setFrame(Rect(x, std::round((tabRowHeight_ - 20) / 2), 22, 20));
}

void EditorArea::setHasProject(bool hasProject) {
    hasProject_ = hasProject;
    updatePlaceholder();
}

void EditorArea::updatePlaceholder() {
    bool hasOpenFiles = !pane_.openURLs().empty();
    updateWelcome();
    emptyHints_.setHidden(hasOpenFiles || !hasProject_);
    // The pane and its blank code view must not cover the start page.
    pane_.setHidden(!hasOpenFiles);
    setNeedsLayout();
    setNeedsDisplay();
}

void EditorArea::updateWelcome() {
    bool wants = pane_.openURLs().empty() && !hasProject_;
    if (!wants) {
        if (welcome_) retireView(std::move(welcome_));
        return;
    }
    if (welcome_ || welcomePending_) return;
    // A window opened for a project is handed it straight after it is made:
    // wait a turn, so such a window never builds a page only to drop it.
    welcomePending_ = true;
    Dispatch::main([this, alive = life_.weak()] {
        if (alive.expired()) return;
        welcomePending_ = false;
        if (welcome_ || !(pane_.openURLs().empty() && !hasProject_)) return;
        welcome_ = std::make_unique<WelcomeView>();
        welcome_->onOpenFolder = [this] {
            if (onOpenFolder) onOpenFolder();
        };
        welcome_->onOpenRecent = [this](const std::wstring& path) {
            if (onOpenRecent) onOpenRecent(path);
        };
        welcome_->onOpenChecked = [this](const std::vector<std::wstring>& paths) {
            if (onOpenChecked) onOpenChecked(paths);
        };
        // Over the pane, under the hints and the gear.
        insertSubview(welcome_.get(), 1);
        setNeedsLayout();
    });
}

void EditorArea::open(const std::wstring& url, bool replacingContent) {
    pane_.open(url, replacingContent);
    updatePlaceholder();
}

void EditorArea::showFileHistory(const FileHistoryModel& model) {
    fileHistories_[model.tabURL] = model;
    // A tiny virtual document gives the tab a stable identity.
    DocumentStore::shared().setVirtualDocument(model.tabURL, "", model.displayName);
    open(model.tabURL, true);
}

bool EditorArea::confirmClose() { return pane_.confirmClose(pane_.openURLs()); }

void EditorArea::detachAllPanes() { pane_.prepareForClose(); }

void EditorArea::releaseTransientMemory() { pane_.releaseTransientMemory(); }

bool EditorArea::reopenLastClosedTab() {
    bool reopened = pane_.reopenLastClosedTab();
    updatePlaceholder();
    return reopened;
}

bool EditorArea::closeActiveTab() {
    auto index = pane_.activeTabIndex();
    if (!index) return false;
    pane_.close(*index);
    return true;
}

bool EditorArea::canMutatePath(const std::wstring& base) const {
    std::wstring path = lowercased(base);
    std::wstring prefix = endsWith(path, L"\\") ? path : path + L"\\";
    for (auto& url : pane_.openURLs()) {
        std::wstring candidate = lowercased(url);
        if (candidate != path && !startsWith(candidate, prefix)) continue;
        Document* doc = DocumentStore::shared().cachedDocument(url);
        if (doc && doc->isModified) return false;
    }
    return true;
}

void EditorArea::pathRenamed(const std::wstring& from, const std::wstring& to) {
    pane_.pathRenamed(from, to);
    if (onActiveDocumentChanged) onActiveDocumentChanged(pane_.currentURL());
}

void EditorArea::pathDeleted(const std::wstring& path) {
    pane_.pathDeleted(path);
    updatePlaceholder();
    if (onActiveDocumentChanged) onActiveDocumentChanged(pane_.currentURL());
}

void EditorArea::refreshDisplay() {
    pane_.refreshDisplay();
    if (welcome_) welcome_->refreshFonts();
    setNeedsDisplay();
}

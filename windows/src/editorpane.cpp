#include "editorpane.h"

#include "definition.h"
#include "dialog.h"
#include "gitservice.h"
#include "highlight.h"
#include "services.h"
#include "settings.h"
#include "theme.h"

#include <shellapi.h>

DiffMode EditorPane::diffMode_ = DiffMode::Unified;

namespace {
Dispatch::Queue& liveMarkQueue() {
    static Dispatch::Queue* queue = new Dispatch::Queue("app.puzzle.line-marks");
    return *queue;
}
Dispatch::Queue& definitionHoverQueue() {
    static Dispatch::Queue* queue = new Dispatch::Queue("app.puzzle.definition-hover");
    return *queue;
}
}  // namespace

EditorPane::EditorPane() {
    backgroundColor = Theme::editorBackground;
    addSubview(&tabBar_);
    addSubview(&editor_);
    addSubview(&diffHeader_);
    addSubview(&findBar_);
    findBar_.setHidden(true);
    diffHeader_.setHidden(true);
    editor_.setShowsCurrentLineBand(false);
    saveCoordinator_.host = this;

    tabBar_.onSelect = [this](int i) { activate(i); };
    tabBar_.onClose = [this](int i) { close(i); };
    tabBar_.onCloseOthers = [this](int i) { closeOtherTabs(i); };
    tabBar_.onCloseRight = [this](int i) { closeTabsToTheRight(i); };

    findBar_.onClose = [this] { hideFindBar(); };
    findBar_.onHeightChanged = [this] { setNeedsLayout(); };
    findBar_.onMatchesChanged = [this] { refreshSearchNavigator(); };

    editor_.onTextChanged = [this] { textDidChange(); };
    editor_.onSelectionChanged = [this] { selectionDidChange(); };
    editor_.onExplicitCaretInteraction = [this] {
        auto url = currentURL();
        if (!url) return;
        editor_.setSearchResultLineLocation(std::nullopt);
        lineActivatedURLs_.insert(*url);
        Document* doc = currentDocument();
        editor_.setShowsCurrentLineBand(doc && doc->languageName() != "markdown");
    };
    // Deferred: a window being torn down loses focus too, and by the time
    // this runs a closed pane has nothing to write.
    editor_.onLostFocus = [this] {
        Dispatch::main([this, alive = life_.weak()] {
            if (alive.expired() || !window()) return;
            autosaveIfNeeded();
        });
    };
    editor_.onCommandClick = [this](size_t location) { return navigateToDefinition(location); };
    editor_.onCommandHover = [this](std::optional<size_t> location) { updateDefinitionHover(location); };
    editor_.onChangeClicked = [this](const GitLineChanges::Change& change, const Rect& rect) {
        showGitChange(change, rect);
    };
    editor_.onOpenLink = [this](const MarkdownLinkDecoration& link) { openMarkdownLink(link); };
    editor_.onSearchPrevious = [this] { findBar_.goToPreviousMatch(); };
    editor_.onSearchNext = [this] { findBar_.goToNextMatch(); };
    editor_.onSearchClear = [this] { hideFindBar(); };

    diffHeader_.onPrevious = [this] { stepThroughDiff(false); };
    diffHeader_.onNext = [this] { stepThroughDiff(true); };
    diffHeader_.onToggleMode = [this] { toggleDiffMode(); };

    observations_.emplace_back(Notice::DocumentStructureDidChange,
                               [this](void* object) { structureChanged(static_cast<Document*>(object)); });
    observations_.emplace_back(Notice::DocumentDidReloadFromDisk,
                               [this](void* object) { reloadedFromDisk(static_cast<Document*>(object)); });
    observations_.emplace_back(Notice::DocumentRestyled,
                               [this](void* object) { restyled(static_cast<Document*>(object)); });
    reloadTabs();
}

EditorPane::~EditorPane() {
    if (gitChangePopover_) gitChangePopover_->close();
    editor_.detach();
}

std::optional<std::wstring> EditorPane::currentURL() const {
    if (!activeIndex_ || *activeIndex_ < 0 || *activeIndex_ >= (int)openURLs_.size()) return std::nullopt;
    return openURLs_[*activeIndex_];
}

Document* EditorPane::currentDocument() const {
    auto url = currentURL();
    if (!url) return nullptr;
    return &DocumentStore::shared().document(*url);
}

void EditorPane::setTabRowHeight(float height) {
    tabBar_.rowHeight = height;
    setNeedsLayout();
}

void EditorPane::setCaptionReserve(float width) {
    tabBar_.captionReserve = width;
    setNeedsLayout();
}

void EditorPane::setActive(bool active) { tabBar_.paneActive = active; }

void EditorPane::setRepositoryRoot(const std::optional<std::wstring>& root) {
    repositoryRoot_ = root;
    refreshGitLineChanges();
}

// ── Layout ─────────────────────────────────────────────────────────────────

void EditorPane::layout() {
    Rect b = bounds();
    float tabHeight = tabBar_.currentHeight();
    tabBar_.setFrame(Rect(0, 0, b.w, tabHeight));
    float y = tabHeight;
    float findHeight = findBar_.isHidden() ? 0 : findBar_.preferredHeight();
    findBar_.setFrame(Rect(0, y, b.w, findHeight));
    y += findHeight;
    float diffHeight = showsDiffHeader_ ? DiffHeaderView::height : 0;
    diffHeader_.setHidden(!showsDiffHeader_);
    diffHeader_.setFrame(Rect(0, y, b.w, diffHeight));
    y += diffHeight;
    Rect content(0, y, b.w, std::max(0.0f, b.h - y));
    for (View* preview : std::initializer_list<View*>{imagePreview_.get(), mediaPreview_.get(), pdfPreview_.get(),
                                                      epubReader_.get(), fileHistoryView_.get(), sideBySide_.get()}) {
        if (preview) preview->setFrame(content);
    }
    if (svgPreview_ && !svgPreview_->isHidden()) {
        float height = std::round(b.h * 0.45f);
        svgPreview_->setFrame(Rect(0, y, b.w, std::min(height, content.h)));
        float editorTop = y + std::min(height, content.h);
        editor_.setFrame(Rect(0, editorTop, b.w, std::max(0.0f, b.maxY() - editorTop)));
    } else {
        editor_.setFrame(content);
    }
    editor_.setHidden(!showsEditor_ || openURLs_.empty());
}

// ── Find bar ───────────────────────────────────────────────────────────────

void EditorPane::showFindBar(const std::optional<std::wstring>& seed, bool replacing) {
    auto url = currentURL();
    if (!url) return;
    TextRange selected = editor_.selection();
    std::optional<std::wstring> selectionSeed;
    if (selected.length > 0) {
        Document* doc = currentDocument();
        if (doc && selected.end() <= doc->length()) {
            std::string text(doc->view().substr(selected.location, selected.length));
            if (text.find('\n') == std::string::npos && text.find('\r') == std::string::npos) selectionSeed = W(text);
        }
    }
    std::wstring query = seed ? *seed : selectionSeed ? *selectionSeed : findBar_.state().query;
    findBar_.setHidden(false);
    findBarURL_ = url;
    FindBarView::State state = findBar_.state();
    state.query = query;
    state.currentRange.reset();
    state.isVisible = true;
    findBar_.restore(state, &editor_);
    findBar_.setQuery(query);
    findBar_.setReplaceVisible(replacing, replacing);
    setNeedsLayout();
    if (!replacing) findBar_.focus();
    refreshSearchNavigator();
}

void EditorPane::refreshSearchNavigator() {
    editor_.setShowsSearchNavigator(!findBar_.isHidden() && findBar_.hasMatches());
}

void EditorPane::saveFindState() {
    if (!findBarURL_) return;
    if (std::find(openURLs_.begin(), openURLs_.end(), *findBarURL_) == openURLs_.end()) return;
    findStates_[*findBarURL_] = findBar_.state();
}

void EditorPane::restoreFindState(const std::optional<std::wstring>& url) {
    if (findBarURL_ != url && findBar_.hasKeyboardFocus()) editor_.focus();
    findBarURL_ = url;
    FindBarView::State state;
    if (url) {
        auto hit = findStates_.find(*url);
        if (hit != findStates_.end()) state = hit->second;
    }
    findBar_.restore(state, &editor_);
    setNeedsLayout();
    refreshSearchNavigator();
}

void EditorPane::hideFindBar() {
    findBar_.finish();
    findBar_.clearHighlights();
    findBar_.setHidden(true);
    setNeedsLayout();
    refreshSearchNavigator();
    editor_.focus();
}

// ── Tabs and documents ─────────────────────────────────────────────────────

void EditorPane::open(const std::wstring& url, bool replacingContent) {
    auto existing = std::find(openURLs_.begin(), openURLs_.end(), url);
    if (existing != openURLs_.end()) {
        // The buffer behind a refreshed diff was swapped: bind to it again.
        if (replacingContent) editor_.detach();
        activate((int)(existing - openURLs_.begin()));
        return;
    }
    openURLs_.push_back(url);
    if (onTabOpened) onTabOpened(url);
    activate((int)openURLs_.size() - 1);
}

void EditorPane::pathRenamed(const std::wstring& oldBase, const std::wstring& newBase) {
    saveFindState();
    std::wstring oldPath = lowercased(oldBase);
    std::wstring oldPrefix = endsWith(oldPath, L"\\") ? oldPath : oldPath + L"\\";
    struct Replacement {
        int index;
        std::wstring from, to;
    };
    std::vector<Replacement> replacements;
    for (int i = 0; i < (int)openURLs_.size(); ++i) {
        std::wstring path = lowercased(openURLs_[i]);
        if (path == oldPath) replacements.push_back({i, openURLs_[i], newBase});
        else if (startsWith(path, oldPrefix)) {
            replacements.push_back({i, openURLs_[i], pathJoin(newBase, openURLs_[i].substr(oldPrefix.size()))});
        }
    }
    if (replacements.empty()) return;
    bool activeReplaced = false;
    for (auto& r : replacements) activeReplaced = activeReplaced || (activeIndex_ && r.index == *activeIndex_);
    if (activeReplaced) detachFromDocument();
    for (auto& r : replacements) {
        moveState(r.from, r.to);
        if (onTabClosed) onTabClosed(r.from);
        openURLs_[r.index] = r.to;
        if (onTabOpened) onTabOpened(r.to);
    }
    invalidateBlame();
    if (activeReplaced && activeIndex_) activate(*activeIndex_);
    else reloadTabs();
}

void EditorPane::pathDeleted(const std::wstring& base) {
    std::wstring path = lowercased(base);
    std::wstring prefix = endsWith(path, L"\\") ? path : path + L"\\";
    std::vector<int> matching;
    for (int i = 0; i < (int)openURLs_.size(); ++i) {
        std::wstring candidate = lowercased(openURLs_[i]);
        if (candidate == path || startsWith(candidate, prefix)) matching.push_back(i);
    }
    for (auto it = matching.rbegin(); it != matching.rend(); ++it) close(*it);
}

void EditorPane::moveState(const std::wstring& from, const std::wstring& to) {
    auto move = [&](auto& map) {
        auto hit = map.find(from);
        if (hit == map.end()) return;
        auto value = hit->second;
        map.erase(hit);
        map[to] = value;
    };
    move(findStates_);
    move(selections_);
    move(foldedBlocks_);
    if (findBarURL_ == from) findBarURL_ = to;
    if (lineActivatedURLs_.erase(from)) lineActivatedURLs_.insert(to);
}

void EditorPane::stepTab(int offset) {
    if (openURLs_.size() <= 1 || !activeIndex_) return;
    int count = (int)openURLs_.size();
    activate(((*activeIndex_ + offset) % count + count) % count);
}

bool EditorPane::reopenLastClosedTab() {
    while (!closedURLs_.empty()) {
        std::wstring url = closedURLs_.back();
        closedURLs_.pop_back();
        // Deleted since, or already open again: not what was meant.
        if (!fileExists(url) || std::find(openURLs_.begin(), openURLs_.end(), url) != openURLs_.end()) continue;
        open(url);
        return true;
    }
    return false;
}

void EditorPane::detachFromDocument() { editor_.detach(); }

void EditorPane::activate(int index) {
    if (index < 0 || index >= (int)openURLs_.size()) return;
    saveFindState();
    findBar_.clearHighlights();
    // Remember where the caret was, and write the buffer being left.
    if (auto previous = currentURL()) {
        selections_[*previous] = editor_.selection();
        foldedBlocks_[*previous] = editor_.foldedBlockIdentities();
        if (*previous != openURLs_[index]) autosaveIfNeeded();
    }
    activeIndex_ = index;
    clearDefinitionHover();
    std::wstring url = openURLs_[index];
    Document& doc = DocumentStore::shared().document(url);

    editor_.attach(&doc);
    editor_.call(SCI_SETUNDOCOLLECTION, 1);
    size_t length = doc.length();
    auto saved = selections_.find(url);
    TextRange caret(std::min(saved != selections_.end() ? saved->second.location : 0, length), 0);
    suppressSelectionSideEffects_ = true;
    editor_.setSelection(caret);
    suppressSelectionSideEffects_ = false;
    editor_.updateJSXTagMatches(doc.jsxTagMatches());
    editor_.refreshBracketMatches();
    editor_.scrollRangeToVisible(caret);
    // Binaries, previews and diffs are read-only.
    editor_.setEditable(!doc.isReadOnly());
    bool lineIsActive = lineActivatedURLs_.count(url) > 0;
    bool markdown = doc.languageName() == "markdown";
    editor_.setShowsCurrentLineBand(lineIsActive && !markdown);
    // Brackets open blocks in code; in prose a line ending in "(" is just that.
    editor_.usesBracketIndent = doc.languageSpec() && !markdown;
    std::string ext;
    {
        std::wstring name = lastPathComponent(url);
        size_t dot = name.rfind(L'.');
        if (dot != std::wstring::npos && dot > 0) ext = U(name.substr(dot + 1));
    }
    editor_.commentSyntax = CommentToggle::syntax(doc.languageName(), ext);
    if (!lineIsActive) clearInlineBlameRequest();
    editor_.setDiffLineNumbers(doc.diffLineNumbers);
    editor_.updateCodeBlocks(doc.codeBlocks(), false);
    auto folds = foldedBlocks_.find(url);
    editor_.restoreFoldedBlockIdentities(folds != foldedBlocks_.end() ? folds->second : std::set<size_t>{});
    applyMarkdown(doc);

    if (!doc.isPDF()) releasePDFPreview();
    const FileHistoryModel* historyModel = fileHistoryProvider ? fileHistoryProvider(url) : nullptr;
    if (historyModel) {
        if (!fileHistoryView_) {
            fileHistoryView_ = std::make_unique<FileHistoryView>();
            addSubview(fileHistoryView_.get());
        }
        fileHistoryView_->configure(*historyModel);
        fileHistoryView_->setHidden(false);
        hidePreviews();
        showsEditor_ = false;
        showDiffHeader(std::nullopt);
    } else if (doc.isImage()) {
        if (fileHistoryView_) fileHistoryView_->setHidden(true);
        releaseMediaPreview();
        releaseEPUBReader();
        releaseSVGPreview();
        if (!imagePreview_) {
            imagePreview_ = std::make_unique<ImagePreviewView>();
            addSubview(imagePreview_.get());
        }
        imagePreview_->show(url, Size(doc.previewImage()->width, doc.previewImage()->height), W(doc.text()));
        imagePreview_->setHidden(false);
        showsEditor_ = false;
        showDiffHeader(std::nullopt);
    } else if (doc.isMedia()) {
        if (fileHistoryView_) fileHistoryView_->setHidden(true);
        releaseImagePreview();
        releaseEPUBReader();
        releaseSVGPreview();
        if (!mediaPreview_) {
            mediaPreview_ = std::make_unique<MediaPreviewView>();
            addSubview(mediaPreview_.get());
        }
        mediaPreview_->setHidden(false);
        mediaPreview_->show(url, W(doc.text()), doc.isVideoMedia());
        showsEditor_ = false;
        showDiffHeader(std::nullopt);
    } else if (doc.isPDF()) {
        if (fileHistoryView_) fileHistoryView_->setHidden(true);
        releaseImagePreview();
        releaseMediaPreview();
        releaseEPUBReader();
        releaseSVGPreview();
        if (!pdfPreview_) {
            pdfPreview_ = std::make_unique<PDFPreviewView>();
            pdfPreview_->setThumbnailsVisible(pdfThumbnailsVisible_);
            addSubview(pdfPreview_.get());
        }
        pdfPreview_->show(url, W(doc.text()));
        pdfPreview_->setHidden(false);
        showsEditor_ = false;
        showDiffHeader(std::nullopt);
    } else if (doc.isEPUB() && [&] {
                   if (!epubReader_) {
                       epubReader_ = std::make_unique<EPUBReaderView>();
                       epubReader_->setContentsVisible(epubContentsVisible_);
                       epubReader_->setHidden(true);
                       addSubview(epubReader_.get());
                   }
                   return epubReader_->show(url);
               }()) {
        // A file that claims to be an EPUB but is not falls through to the
        // text path, where it reports itself as unsupported.
        if (fileHistoryView_) fileHistoryView_->setHidden(true);
        releaseImagePreview();
        releaseMediaPreview();
        releaseSVGPreview();
        epubReader_->setHidden(false);
        showsEditor_ = false;
        showDiffHeader(std::nullopt);
    } else {
        if (fileHistoryView_) fileHistoryView_->setHidden(true);
        hidePreviews();
        showsEditor_ = true;
        // An SVG is source with its picture above it; a diff of one shows both.
        if (doc.isSVG() || doc.svgDiffSides) {
            if (!svgPreview_) {
                svgPreview_ = std::make_unique<SVGPreviewView>();
                addSubview(svgPreview_.get());
            }
            svgPreview_->setHidden(false);
            refreshSVGPreview(doc);
        }
        // Rendered Markdown reads like a document: no gutter, a readable measure.
        editor_.setShowsGutter(!markdown);
        editor_.setReadingWidth(markdown ? std::optional<float>(EditorView::readingColumns * Theme::characterWidth())
                                         : std::nullopt);
        showDiffHeader(doc.diffLineNumbers.empty() ? std::nullopt : std::optional<std::wstring>(url));
    }

    restoreFindState(url);
    reloadTabs();
    refreshGitLineChanges();
    setNeedsLayout();
    if (onActiveDocumentChanged) onActiveDocumentChanged(url);
    if (lineIsActive) scheduleInlineBlame();
}

void EditorPane::close(int index) {
    if (index < 0 || index >= (int)openURLs_.size()) return;
    std::wstring url = openURLs_[index];
    if (!confirmClose({url})) return;
    openURLs_.erase(openURLs_.begin() + index);
    if (!DiffURL::is(url)) {
        closedURLs_.erase(std::remove(closedURLs_.begin(), closedURLs_.end(), url), closedURLs_.end());
        closedURLs_.push_back(url);
        if (closedURLs_.size() > reopenableTabs) closedURLs_.erase(closedURLs_.begin());
    }
    selections_.erase(url);
    findStates_.erase(url);
    lineActivatedURLs_.erase(url);
    foldedBlocks_.erase(url);
    if (openURLs_.empty()) {
        activeIndex_.reset();
        editor_.detach();
        restoreFindState(std::nullopt);
        editor_.setShowsCurrentLineBand(false);
        editor_.updateCodeBlocks({}, false);
        editor_.updateJSXTagMatches({});
        editor_.updateMarkdown(nullptr, std::nullopt);
        editor_.setGitChanges({});
        editor_.setInlineBlame(std::nullopt);
        hidePreviews();
        if (fileHistoryView_) fileHistoryView_->setHidden(true);
        showsEditor_ = true;
        showDiffHeader(std::nullopt);
        reloadTabs();
        setNeedsLayout();
        if (onTabClosed) onTabClosed(url);
        if (onActiveDocumentChanged) onActiveDocumentChanged(std::nullopt);
        if (onEmptied) onEmptied();
        return;
    }
    activate(std::min(index, (int)openURLs_.size() - 1));
    if (onTabClosed) onTabClosed(url);
}

void EditorPane::closeAllTabs() {
    while (!openURLs_.empty()) {
        size_t before = openURLs_.size();
        close((int)openURLs_.size() - 1);
        // A refused close (a conflict the user cancelled) stops the walk.
        if (openURLs_.size() >= before) return;
    }
}

void EditorPane::closeOtherTabs(int index) {
    if (index < 0 || index >= (int)openURLs_.size()) return;
    std::vector<int> doomed;
    for (int i = 0; i < (int)openURLs_.size(); ++i) {
        if (i != index) doomed.push_back(i);
    }
    closeTabs(doomed, index);
}

void EditorPane::closeTabsToTheRight(int index) {
    if (index < 0 || index >= (int)openURLs_.size()) return;
    std::vector<int> doomed;
    for (int i = index + 1; i < (int)openURLs_.size(); ++i) doomed.push_back(i);
    closeTabs(doomed, index);
}

void EditorPane::closeTabs(const std::vector<int>& doomed, int anchor) {
    if (doomed.empty() || anchor < 0 || anchor >= (int)openURLs_.size()) return;
    std::wstring anchorURL = openURLs_[anchor];
    std::vector<std::wstring> closed;
    for (int i : doomed) {
        if (i >= 0 && i < (int)openURLs_.size()) closed.push_back(openURLs_[i]);
    }
    if (!confirmClose(closed)) return;
    saveFindState();
    for (auto& url : closed) {
        selections_.erase(url);
        findStates_.erase(url);
        lineActivatedURLs_.erase(url);
        foldedBlocks_.erase(url);
    }
    std::set<int> doomedSet(doomed.begin(), doomed.end());
    std::vector<std::wstring> kept;
    for (int i = 0; i < (int)openURLs_.size(); ++i) {
        if (!doomedSet.count(i)) kept.push_back(openURLs_[i]);
    }
    openURLs_ = kept;
    auto it = std::find(openURLs_.begin(), openURLs_.end(), anchorURL);
    if (it != openURLs_.end()) {
        activeIndex_.reset();
        activate((int)(it - openURLs_.begin()));
    }
    for (auto& url : closed) {
        if (onTabClosed) onTabClosed(url);
    }
}

void EditorPane::save() {
    if (Document* doc = currentDocument()) saveCoordinator_.save(*doc, DocumentSaveCoordinator::Reason::Explicit);
}

void EditorPane::autosaveIfNeeded() {
    if (idleSaveWork_) idleSaveWork_->cancel();
    // Leaving a diff tab is no reason to replay it into a source file.
    Document* doc = currentDocument();
    if (!doc || doc->isVirtual()) return;
    saveCoordinator_.save(*doc, DocumentSaveCoordinator::Reason::Leaving);
}

bool EditorPane::confirmClose(const std::vector<std::wstring>& urls) {
    std::set<std::wstring> seen;
    for (auto& url : urls) {
        if (!seen.insert(url).second) continue;
        Document* doc = DocumentStore::shared().cachedDocument(url);
        if (!doc) continue;
        if (!saveCoordinator_.save(*doc, DocumentSaveCoordinator::Reason::Closing)) return false;
    }
    return true;
}

void EditorPane::markLineActive() {
    if (auto url = currentURL()) lineActivatedURLs_.insert(*url);
    Document* doc = currentDocument();
    editor_.setShowsCurrentLineBand(doc && doc->languageName() != "markdown");
}

void EditorPane::jumpToLine(int line, std::optional<int> column) {
    Document* doc = currentDocument();
    if (!doc) return;
    int count = doc->lineCount();
    int target = std::clamp(line, 1, std::max(1, count));
    size_t location = line > count ? doc->length() : SciDoc::lineStart(doc->handle(), target - 1);
    size_t lineEnd = line > count ? doc->length() : SciDoc::lineEnd(doc->handle(), target - 1);
    size_t lineLength = lineEnd >= location ? lineEnd - location : 0;
    // A column past the end of the line lands at its end.
    size_t offset = column ? std::min((size_t)std::max(0, *column - 1), lineLength) : 0;
    TextRange caret(std::min(location + offset, doc->length()), 0);
    editor_.setSearchResultLineLocation(std::nullopt);
    markLineActive();
    editor_.setSelection(caret);
    editor_.scrollRangeToVisible(caret);
    editor_.focus();
    scheduleInlineBlame();
}

void EditorPane::prepareForClose() {
    clearDefinitionHover();
    ++blameGeneration_;
    if (blameWork_) blameWork_->cancel();
    blameCache_.clear();
    blameOrder_.clear();
    hidePreviews();
    editor_.updateCodeBlocks({}, false);
    editor_.updateJSXTagMatches({});
    detachFromDocument();
    std::vector<std::wstring> urls = openURLs_;
    openURLs_.clear();
    activeIndex_.reset();
    selections_.clear();
    findStates_.clear();
    restoreFindState(std::nullopt);
    lineActivatedURLs_.clear();
    foldedBlocks_.clear();
    for (auto& url : urls) {
        if (onTabClosed) onTabClosed(url);
    }
}

void EditorPane::releaseTransientMemory() {
    if (svgPreview_ && svgPreview_->isHidden()) releaseSVGPreview();
    if (imagePreview_ && imagePreview_->isHidden()) releaseImagePreview();
    if (mediaPreview_ && mediaPreview_->isHidden()) releaseMediaPreview();
    if (epubReader_ && epubReader_->isHidden()) releaseEPUBReader();
    if (pdfPreview_ && pdfPreview_->isHidden()) releasePDFPreview();
    if (findBar_.isHidden()) findBar_.clearHighlights();
}

void EditorPane::refreshDisplay() {
    for (auto& url : openURLs_) {
        if (Document* doc = DocumentStore::shared().cachedDocument(url)) HighlightService::highlight(*doc);
    }
    editor_.refreshDisplay();
    findBar_.refreshFonts();
    if (sideBySide_) sideBySide_->refreshAppearance();
    if (imagePreview_) imagePreview_->refreshFonts();
    if (mediaPreview_) mediaPreview_->refreshFonts();
    if (pdfPreview_) pdfPreview_->refreshFonts();
    if (epubReader_) epubReader_->refreshFonts();
    if (Document* doc = currentDocument()) {
        if (doc->languageName() == "markdown") {
            editor_.setReadingWidth(EditorView::readingColumns * Theme::characterWidth());
        }
    }
    reloadTabs();
    setNeedsLayout();
    setNeedsDisplay();
}

void EditorPane::reloadTabs() {
    std::vector<EditorTabBar::TabInfo> infos;
    for (auto& url : openURLs_) {
        Document* doc = DocumentStore::shared().cachedDocument(url);
        std::wstring title;
        bool modified = false;
        std::wstring path = url;
        if (doc) {
            title = doc->displayName() ? *doc->displayName()
                                       : (doc->isVirtual() ? lastPathComponent(url) + L" (diff)" : lastPathComponent(url));
            modified = doc->isModified;
            path = tabPath(url, *doc, title);
        } else if (auto parts = DiffURL::parse(url)) {
            title = W(lastPathComponent(parts->path)) + L" (diff)";
            path = pathJoinGit(parts->directory, parts->path);
        } else {
            title = lastPathComponent(url);
        }
        infos.push_back({title, modified, path});
    }
    tabBar_.reload(infos, activeIndex_ ? *activeIndex_ : -1);
    setNeedsLayout();
}

std::wstring EditorPane::tabPath(const std::wstring& url, Document& doc, const std::wstring& fallback) {
    if (!doc.isVirtual()) return url;
    auto parts = DiffURL::parse(url);
    if (!parts || parts->path.empty()) return fallback;
    return pathJoinGit(parts->directory, parts->path);
}

std::optional<std::string> EditorPane::diffPath(const std::wstring& url) {
    auto parts = DiffURL::parse(url);
    if (!parts || parts->path.empty()) return std::nullopt;
    return parts->path;
}

// ── Editing ────────────────────────────────────────────────────────────────

void EditorPane::textDidChange() {
    Document* doc = currentDocument();
    if (!doc || doc->isApplyingExternalChange()) return;
    clearDefinitionHover();
    markLineActive();
    bool wasModified = doc->isModified;
    doc->markLocalEdit();
    if (!wasModified) {
        reloadTabs();
        if (onDocumentEdited) onDocumentEdited();
    }
    // Blame belongs to the committed file; the buffer no longer matches it.
    clearInlineBlameRequest();
    // Parsed JSX ranges belong to the previous text.
    doc->updateJSXTagMatches({});
    HighlightService::scheduleHighlight(*doc);
    applyMarkdown(*doc);
    editor_.refreshBracketMatches();
    scheduleGitLineChanges();
    scheduleIdleSave(*doc);
    if (doc->isSVG()) scheduleSVGRender(*doc);
}

void EditorPane::scheduleIdleSave(Document& doc) {
    if (idleSaveWork_) idleSaveWork_->cancel();
    if (!doc.isModified || doc.isReadOnly() || doc.isVirtual()) return;
    std::wstring url = doc.url;
    idleSaveWork_ = Dispatch::after(idleSaveDelay, [this, url, alive = life_.weak()] {
        if (alive.expired()) return;
        Document* target = DocumentStore::shared().cachedDocument(url);
        if (target) saveCoordinator_.save(*target, DocumentSaveCoordinator::Reason::Leaving);
    });
}

void EditorPane::selectionDidChange() {
    if (suppressSelectionSideEffects_) return;
    editor_.refreshBracketMatches();
    auto url = currentURL();
    if (url) selections_[*url] = editor_.selection();
    if (Document* doc = currentDocument()) applyMarkdown(*doc);
    if (!url || !lineActivatedURLs_.count(*url)) {
        editor_.setShowsCurrentLineBand(false);
        editor_.setInlineBlame(std::nullopt);
        return;
    }
    Document* doc = currentDocument();
    editor_.setShowsCurrentLineBand(doc && doc->languageName() != "markdown");
    scheduleInlineBlame();
}

std::optional<TextRange> EditorPane::markdownRevealRange(Document& doc) {
    auto url = currentURL();
    if (doc.languageName() != "markdown" || !url || !lineActivatedURLs_.count(*url)) return std::nullopt;
    std::string_view s = doc.view();
    TextRange sel = editor_.selection();
    size_t location = std::min(sel.location, s.size());
    size_t end = std::min(sel.end(), s.size());
    size_t start = location;
    while (start > 0 && s[start - 1] != '\n') --start;
    size_t stop = s.find('\n', end > location ? end - 1 : end);
    stop = stop == std::string_view::npos ? s.size() : stop + 1;
    return TextRange(start, stop - start);
}

void EditorPane::applyMarkdown(Document& doc) {
    auto reveal = markdownRevealRange(doc);
    editor_.syncStyles();
    editor_.updateMarkdown(&doc.markdown(), reveal);
}

void EditorPane::structureChanged(Document* doc) {
    if (!doc || !currentURL() || doc->url != *currentURL()) return;
    editor_.updateCodeBlocks(doc->codeBlocks(), false);
    editor_.updateJSXTagMatches(doc->jsxTagMatches());
    applyMarkdown(*doc);
}

void EditorPane::restyled(Document* doc) {
    if (!doc || !currentURL() || doc->url != *currentURL()) return;
    editor_.syncStyles();
    editor_.setDiffLineNumbers(doc->diffLineNumbers);
    // New style bytes undid any revealed line: reveal it again.
    editor_.updateMarkdown(nullptr, std::nullopt);
    applyMarkdown(*doc);
    if (!doc->diffLineNumbers.empty() && !showsDiffHeader_) showDiffHeader(doc->url);
    else if (showsDiffHeader_) showDiffHeader(doc->url);
    if (doc->svgDiffSides && svgPreview_) refreshSVGPreview(*doc);
}

void EditorPane::reloadedFromDisk(Document* doc) {
    if (!doc || std::find(openURLs_.begin(), openURLs_.end(), doc->url) == openURLs_.end()) return;
    reloadTabs();
    if (!currentURL() || doc->url != *currentURL()) return;
    size_t location = std::min(editor_.selection().location, doc->length());
    suppressSelectionSideEffects_ = true;
    editor_.setSelection(TextRange(location, 0));
    suppressSelectionSideEffects_ = false;
    editor_.emptyUndoBuffer();
    // The reload re-decides whether the file can be shown in full.
    editor_.setEditable(!doc->isReadOnly());
    findBar_.invalidateMatches();
    clearInlineBlameRequest();
    editor_.updateCodeBlocks(doc->codeBlocks(), false);
    editor_.updateJSXTagMatches(doc->jsxTagMatches());
    applyMarkdown(*doc);
    editor_.refreshBracketMatches();
}

// ── Diffs ──────────────────────────────────────────────────────────────────

void EditorPane::showDiffHeader(const std::optional<std::wstring>& url) {
    auto path = url ? diffPath(*url) : std::nullopt;
    if (!path) {
        showsDiffHeader_ = false;
        if (sideBySide_) sideBySide_->setHidden(true);
        setNeedsLayout();
        return;
    }
    diffHeader_.setMode(diffMode_);
    diffHeader_.configure(*path, (int)changeBlocks().size());
    showsDiffHeader_ = true;
    applyDiffMode();
    setNeedsLayout();
}

void EditorPane::toggleDiffMode() {
    diffMode_ = diffMode_ == DiffMode::Unified ? DiffMode::SideBySide : DiffMode::Unified;
    diffHeader_.setMode(diffMode_);
    applyDiffMode();
}

void EditorPane::applyDiffMode() {
    Document* doc = currentDocument();
    if (!showsDiffHeader_ || !doc) {
        if (sideBySide_) sideBySide_->setHidden(true);
        return;
    }
    if (diffMode_ != DiffMode::SideBySide) {
        if (sideBySide_) sideBySide_->setHidden(true);
        showsEditor_ = true;
        setNeedsLayout();
        return;
    }
    if (!sideBySide_) {
        sideBySide_ = std::make_unique<SideBySideDiffView>();
        addSubview(sideBySide_.get());
    }
    sideBySide_->configure(doc->text());
    sideBySide_->setHidden(false);
    showsEditor_ = false;
    diffHeader_.configure(diffHeader_.path(), sideBySide_->changeCount());
    setNeedsLayout();
}

std::vector<TextRange> EditorPane::changeBlocks() const {
    std::vector<TextRange> blocks;
    Document* doc = currentDocument();
    if (!doc) return blocks;
    for (auto& [range, color] : doc->diffBands) {
        if (!blocks.empty() && blocks.back().end() >= range.location) blocks.back() = blocks.back().united(range);
        else blocks.push_back(range);
    }
    return blocks;
}

void EditorPane::stepThroughDiff(bool forward) {
    if (sideBySide_ && !sideBySide_->isHidden()) {
        sideBySide_->step(forward);
        return;
    }
    auto blocks = changeBlocks();
    if (blocks.empty()) return;
    size_t caret = editor_.selection().location;
    TextRange target = forward ? blocks.front() : blocks.back();
    if (forward) {
        for (auto& b : blocks) {
            if (b.location > caret) {
                target = b;
                break;
            }
        }
    } else {
        for (auto it = blocks.rbegin(); it != blocks.rend(); ++it) {
            if (it->end() <= caret) {
                target = *it;
                break;
            }
        }
    }
    editor_.setSelection(TextRange(target.location, 0));
    editor_.scrollRangeToVisible(target);
}

// ── Previews ───────────────────────────────────────────────────────────────

void EditorPane::releaseImagePreview() {
    if (!imagePreview_) return;
    imagePreview_->clear();
    retireView(std::move(imagePreview_));
}

void EditorPane::releaseMediaPreview() {
    if (!mediaPreview_) return;
    mediaPreview_->clear();
    mediaPreview_->setHidden(true);
    retireView(std::move(mediaPreview_));
}

void EditorPane::releaseEPUBReader() {
    if (!epubReader_) return;
    epubContentsVisible_ = epubReader_->contentsVisible();
    epubReader_->clear();
    retireView(std::move(epubReader_));
}

void EditorPane::releasePDFPreview() {
    if (!pdfPreview_) return;
    pdfThumbnailsVisible_ = pdfPreview_->thumbnailsVisible();
    pdfPreview_->clear();
    retireView(std::move(pdfPreview_));
}

void EditorPane::releaseSVGPreview() {
    if (svgRenderWork_) svgRenderWork_->cancel();
    svgRenderWork_.reset();
    lastRenderedSVG_.reset();
    if (!svgPreview_) return;
    svgPreview_->clear();
    retireView(std::move(svgPreview_));
    setNeedsLayout();
}

void EditorPane::hidePreviews() {
    releasePDFPreview();
    releaseImagePreview();
    releaseMediaPreview();
    releaseEPUBReader();
    releaseSVGPreview();
}

void EditorPane::refreshSVGPreview(Document& doc) {
    if (!svgPreview_) return;
    if (doc.svgDiffSides) {
        auto side = [](const std::optional<std::string>& data) -> std::optional<SVGImage> {
            return data ? SVGPreviewView::render(*data) : std::nullopt;
        };
        auto before = side(doc.svgDiffSides->before), after = side(doc.svgDiffSides->after);
        auto pane = [](std::optional<std::wstring> title, std::optional<SVGImage> image,
                       const std::optional<std::string>& data) {
            SVGPreviewView::Pane p;
            p.title = title;
            p.caption = SVGPreviewView::caption(std::nullopt, image, data ? data->size() : 0);
            if (!image) p.note = L"Nothing to draw";
            p.image = std::move(image);
            return p;
        };
        // Two versions only when there are two.
        if (!before) svgPreview_->show({pane(std::nullopt, after, doc.svgDiffSides->after)});
        else if (!after) svgPreview_->show({pane(L"Deleted", before, doc.svgDiffSides->before)});
        else svgPreview_->show({pane(L"Before", before, doc.svgDiffSides->before), pane(L"After", after, doc.svgDiffSides->after)});
        return;
    }
    // The buffer, not the file: the caption describes what is on screen.
    std::string text = doc.text();
    std::wstring name = doc.name();
    SVGPreviewView::Pane p;
    if (auto image = SVGPreviewView::render(text)) {
        lastRenderedSVG_ = image;
        p.image = image;
        p.caption = SVGPreviewView::caption(name, image, text.size());
    } else {
        p.image = lastRenderedSVG_;
        p.caption = SVGPreviewView::caption(name, lastRenderedSVG_, text.size());
        p.note = lastRenderedSVG_ ? L"Showing the last version that rendered" : L"Nothing to draw yet";
    }
    svgPreview_->show({p});
}

void EditorPane::scheduleSVGRender(Document& doc) {
    if (svgRenderWork_) svgRenderWork_->cancel();
    std::wstring url = doc.url;
    svgRenderWork_ = Dispatch::after(svgRenderDelay, [this, url, alive = life_.weak()] {
        if (alive.expired() || !currentURL() || *currentURL() != url) return;
        if (Document* d = currentDocument()) refreshSVGPreview(*d);
    });
}

void EditorPane::openMarkdownLink(const MarkdownLinkDecoration& link) {
    if (!link.url) return;
    if (link.url->isFile) {
        const std::wstring& path = link.url->path;
        if (!fileExists(path) || directoryExists(path)) {
            revealInExplorer(path);
            return;
        }
        open(path);
        return;
    }
    ShellExecuteW(nullptr, L"open", link.url->url.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
}

// ── Git marks ──────────────────────────────────────────────────────────────

void EditorPane::refreshGitLineChanges(bool reloadBaseline) {
    if (liveMarkWork_) liveMarkWork_->cancel();
    auto url = currentURL();
    // Saving cannot move HEAD: mark against the copy already in hand.
    if (!reloadBaseline && gitBaseline_ && gitBaselineURL_ == url) {
        recomputeGitLineChanges();
        return;
    }
    Document* doc = currentDocument();
    if (!url || !doc || doc->isVirtual() || doc->isPreviewOnly() || !repositoryRoot_) {
        gitBaseline_.reset();
        gitBaselineURL_.reset();
        applyGitLineChanges({}, std::nullopt);
        return;
    }
    int generation = ++gitLineChangeGeneration_;
    bool formatted = doc->isDisplayFormatted();
    if (gitBaselineToken_) gitBaselineToken_->cancel();
    auto token = std::make_shared<CancelToken>();
    gitBaselineToken_ = token;
    std::wstring file = *url, root = *repositoryRoot_;
    Git::workQueue().async([this, alive = life_.weak(), token, generation, file, root, formatted] {
        if (token->isCancelled()) return;
        auto baseline = GitLineChanges::baseline(file, root);
        // A re-indented buffer is compared against a re-indented HEAD.
        if (formatted && baseline.kind == GitLineChanges::Baseline::Kind::Lines && !baseline.lines.empty()) {
            if (auto pretty = JSONFormatter::pretty(join(baseline.lines, "\n"))) {
                baseline.lines = GitLineChanges::lines(*pretty);
            }
        }
        if (token->isCancelled()) return;
        Dispatch::main([this, alive, generation, file, baseline] {
            if (alive.expired() || gitLineChangeGeneration_ != generation || currentURL() != file) return;
            switch (baseline.kind) {
            case GitLineChanges::Baseline::Kind::Lines:
                gitBaseline_ = baseline.lines;
                gitBaselineURL_ = file;
                recomputeGitLineChanges();
                break;
            case GitLineChanges::Baseline::Kind::Untracked:
                gitBaseline_.reset();
                gitBaselineURL_ = file;
                recomputeGitLineChanges();
                break;
            case GitLineChanges::Baseline::Kind::Unavailable:
                // Not an answer: marks up for this file stay.
                if (gitBaselineURL_ == file) return;
                gitBaseline_.reset();
                gitBaselineURL_.reset();
                applyGitLineChanges({}, file);
                break;
            }
        });
    });
}

void EditorPane::scheduleGitLineChanges() {
    if (!gitBaselineURL_ || gitBaselineURL_ != currentURL()) return;
    if (liveMarkWork_) liveMarkWork_->cancel();
    liveMarkWork_ = Dispatch::after(liveMarkDelay, [this, alive = life_.weak()] {
        if (!alive.expired()) recomputeGitLineChanges();
    });
}

void EditorPane::recomputeGitLineChanges() {
    if (liveMarkWork_) liveMarkWork_->cancel();
    auto url = currentURL();
    Document* doc = currentDocument();
    if (!url || url != gitBaselineURL_ || !gitBaseline_ || !doc || doc->isVirtual() || doc->isMinifiedPreview()) {
        applyGitLineChanges({}, gitBaselineURL_ == url ? url : std::nullopt);
        return;
    }
    // A copy: the diff runs off the main thread while typing goes on.
    std::string snapshot = doc->text();
    std::vector<std::string> baseline = *gitBaseline_;
    int generation = gitLineChangeGeneration_;
    if (liveMarkToken_) liveMarkToken_->cancel();
    auto token = std::make_shared<CancelToken>();
    liveMarkToken_ = token;
    std::wstring file = *url;
    liveMarkQueue().async([this, alive = life_.weak(), token, snapshot, baseline, generation, file] {
        if (token->isCancelled()) return;
        auto changes = GitLineChanges::changes(baseline, GitLineChanges::lines(snapshot),
                                               [token] { return token->isCancelled(); });
        if (!changes) return;
        Dispatch::main([this, alive, generation, file, changes = *changes] {
            if (alive.expired() || gitLineChangeGeneration_ != generation || currentURL() != file) return;
            applyGitLineChanges(changes, file);
        });
    });
}

void EditorPane::applyGitLineChanges(std::vector<GitLineChanges::Change> changes,
                                     const std::optional<std::wstring>& url) {
    gitLineChanges_ = changes;
    gitLineChangesURL_ = url;
    editor_.setGitChanges(std::move(changes));
}

void EditorPane::showGitChange(const GitLineChanges::Change& change, const Rect& rect) {
    if (gitChangePopover_) gitChangePopover_->close();
    Document* doc = currentDocument();
    gitChangePopover_ = std::make_unique<GitChangePopover>(change, doc && !doc->isReadOnly());
    GitLineChanges::Change copy = change;
    gitChangePopover_->onRevert = [this, copy, alive = life_.weak()] {
        if (alive.expired()) return;
        if (gitChangePopover_) gitChangePopover_->close();
        revertGitChange(copy);
    };
    WindowHost* host = window();
    if (!host) return;
    float s = host->scale();
    POINT topLeft{(LONG)std::lround(rect.x * s), (LONG)std::lround(rect.y * s)};
    POINT bottomRight{(LONG)std::lround(rect.maxX() * s), (LONG)std::lround(rect.maxY() * s)};
    ClientToScreen(editor_.handle(), &topLeft);
    ClientToScreen(editor_.handle(), &bottomRight);
    gitChangePopover_->show(RECT{topLeft.x, topLeft.y, bottomRight.x, bottomRight.y}, host->hwnd());
}

bool EditorPane::revertGitChange(const GitLineChanges::Change& change) {
    Document* doc = currentDocument();
    if (!doc || doc->isReadOnly() || !editor_.isEditable()) return false;
    SciDoc::Handle h = doc->handle();
    int lines = doc->lineCount();
    auto start = [&](int line) -> size_t {
        line = std::max(1, line);
        if (line > lines) return doc->length();
        return SciDoc::lineStart(h, line - 1);
    };
    TextRange target;
    if (change.kind == GitLineChanges::Change::Kind::Deleted) {
        target = TextRange(start(change.first), 0);
    } else {
        size_t from = start(change.first), to = start(change.last + 1);
        target = TextRange(from, to >= from ? to - from : 0);
    }
    if (target.end() > doc->length()) return false;
    std::string eol = SciDoc::usesCRLF(h) ? "\r\n" : "\n";
    std::string replacement = join(change.removed, eol);
    // Keep the file's line structure.
    if (!replacement.empty()) {
        bool replacedTerminator = target.length > 0 && SciDoc::charAt(h, target.end() - 1) == '\n';
        if (replacedTerminator || target.length == 0) replacement += eol;
    }
    editor_.insertText(replacement, target);
    editor_.setSelection(TextRange(target.location, 0));
    editor_.scrollRangeToVisible(editor_.selection());
    return true;
}

// ── Inline blame ───────────────────────────────────────────────────────────

int EditorPane::caretLine() const {
    Document* doc = currentDocument();
    if (!doc) return 1;
    size_t caret = std::min(editor_.selection().location, doc->length());
    size_t length = doc->length();
    // At the end of a file that ends in a newline, the caret's line is the
    // last written one.
    if (caret == length && length > 0 && SciDoc::charAt(doc->handle(), length - 1) == '\n') {
        return SciDoc::lineFromPosition(doc->handle(), length - 1) + 1;
    }
    return SciDoc::lineFromPosition(doc->handle(), caret) + 1;
}

void EditorPane::cacheBlame(const std::string& text, const std::wstring& key) {
    blameCache_[key] = text;
    blameOrder_.erase(std::remove(blameOrder_.begin(), blameOrder_.end(), key), blameOrder_.end());
    blameOrder_.push_back(key);
    while (blameOrder_.size() > maxBlameEntries) {
        blameCache_.erase(blameOrder_.front());
        blameOrder_.erase(blameOrder_.begin());
    }
}

void EditorPane::scheduleInlineBlame() {
    auto url = currentURL();
    if (!Settings::shared().showInlineBlame || !url || !repositoryRoot_ || !lineActivatedURLs_.count(*url)) {
        clearInlineBlameRequest();
        return;
    }
    Document* doc = currentDocument();
    // A modified buffer's lines no longer match what Git knows.
    if (!doc || doc->isVirtual() || doc->isUnsupported() || doc->isPreviewOnly() || doc->isModified) {
        clearInlineBlameRequest();
        return;
    }
    int line = caretLine();
    std::wstring key = *url + L":" + std::to_wstring(line);
    auto hit = blameCache_.find(key);
    if (hit != blameCache_.end()) {
        if (requestedBlameKey_ != key) {
            ++blameGeneration_;
            if (blameWork_) blameWork_->cancel();
            blameWork_.reset();
            requestedBlameKey_ = key;
        }
        blameOrder_.erase(std::remove(blameOrder_.begin(), blameOrder_.end(), key), blameOrder_.end());
        blameOrder_.push_back(key);
        std::optional<std::wstring> visible = hit->second.empty() ? std::nullopt : std::optional<std::wstring>(W(hit->second));
        displayedBlameKey_ = hit->second.empty() ? std::nullopt : std::optional<std::wstring>(key);
        editor_.setInlineBlame(visible);
        return;
    }
    // Repeated notifications for the same line keep the one request.
    if (requestedBlameKey_ == key && blameWork_) return;
    int generation = ++blameGeneration_;
    if (blameWork_) blameWork_->cancel();
    requestedBlameKey_ = key;
    if (displayedBlameKey_ != key) {
        displayedBlameKey_.reset();
        editor_.setInlineBlame(std::nullopt);
    }
    std::wstring file = *url, root = *repositoryRoot_;
    blameWork_ = Dispatch::after(0.25, [this, alive = life_.weak(), generation, file, root, line, key] {
        if (alive.expired() || blameGeneration_ != generation) return;
        Dispatch::background([this, alive, generation, file, root, line, key] {
            auto blame = Git::blame(file, line, root);
            std::string text = blame ? blame->inlineText() : "";
            Dispatch::main([this, alive, generation, file, line, key, text] {
                if (alive.expired() || blameGeneration_ != generation) return;
                // The caret may have moved on while Git ran.
                if (currentURL() != file || caretLine() != line) return;
                cacheBlame(text, key);
                blameWork_.reset();
                displayedBlameKey_ = text.empty() ? std::nullopt : std::optional<std::wstring>(key);
                editor_.setInlineBlame(text.empty() ? std::nullopt : std::optional<std::wstring>(W(text)));
            });
        });
    });
}

void EditorPane::clearInlineBlameRequest() {
    ++blameGeneration_;
    if (blameWork_) blameWork_->cancel();
    blameWork_.reset();
    requestedBlameKey_.reset();
    displayedBlameKey_.reset();
    editor_.setInlineBlame(std::nullopt);
}

void EditorPane::invalidateBlame(const std::optional<std::wstring>& url) {
    if (url) {
        std::wstring prefix = *url + L":";
        for (auto it = blameCache_.begin(); it != blameCache_.end();) {
            if (startsWith(it->first, prefix)) it = blameCache_.erase(it);
            else ++it;
        }
        blameOrder_.erase(std::remove_if(blameOrder_.begin(), blameOrder_.end(),
                                         [&](const std::wstring& k) { return startsWith(k, prefix); }),
                          blameOrder_.end());
    } else {
        blameCache_.clear();
        blameOrder_.clear();
    }
    requestedBlameKey_.reset();
    scheduleInlineBlame();
}

// ── Definitions ────────────────────────────────────────────────────────────

bool EditorPane::navigateToDefinition(size_t location) {
    auto url = currentURL();
    Document* doc = currentDocument();
    if (!url || DiffURL::is(*url) || !repositoryRoot_ || !doc || doc->isVirtual() || doc->isUnsupported()
        || doc->isPreviewOnly()) {
        return false;
    }
    std::string source = doc->text();
    if (!DefinitionNavigator::hasNavigableToken(source, location)) return false;
    int generation = ++definitionNavigationGeneration_;
    std::wstring sourcePath = *url, root = *repositoryRoot_;
    Dispatch::background([this, alive = life_.weak(), generation, source, sourcePath, root, location] {
        auto destination = DefinitionNavigator::resolve(source, sourcePath, root, location);
        Dispatch::main([this, alive, generation, destination] {
            if (alive.expired() || definitionNavigationGeneration_ != generation) return;
            if (!destination) {
                MessageBeep(MB_OK);
                return;
            }
            open(destination->path);
            if (currentURL() != destination->path) return;
            Document* d = currentDocument();
            TextRange target(std::min(destination->location, d ? d->length() : 0), 0);
            selections_[destination->path] = target;
            markLineActive();
            suppressSelectionSideEffects_ = true;
            editor_.setSelection(target);
            suppressSelectionSideEffects_ = false;
            editor_.scrollRangeToVisible(target);
            editor_.focus();
            scheduleInlineBlame();
        });
    });
    return true;
}

void EditorPane::updateDefinitionHover(std::optional<size_t> location) {
    auto url = currentURL();
    Document* doc = currentDocument();
    if (!location || !url || !repositoryRoot_ || !doc || doc->isVirtual() || doc->isUnsupported()
        || doc->isPreviewOnly()) {
        clearDefinitionHover();
        return;
    }
    std::string source = doc->text();
    auto range = DefinitionNavigator::targetRange(source, *location);
    if (!range) {
        clearDefinitionHover();
        return;
    }
    if (definitionHoverURL_ == url && definitionHoverCandidate_ == range) return;
    int generation = ++definitionHoverGeneration_;
    if (definitionHoverWork_) definitionHoverWork_->cancel();
    definitionHoverURL_ = url;
    definitionHoverCandidate_ = range;
    editor_.setCommandHoverRange(std::nullopt);
    std::wstring sourcePath = *url, root = *repositoryRoot_;
    size_t at = *location;
    TextRange candidate = *range;
    definitionHoverWork_ = Dispatch::after(0.08, [this, alive = life_.weak(), generation, source, sourcePath, root, at,
                                                   candidate] {
        if (alive.expired() || definitionHoverGeneration_ != generation) return;
        definitionHoverQueue().async([this, alive, generation, source, sourcePath, root, at, candidate] {
            auto destination = DefinitionNavigator::resolve(source, sourcePath, root, at);
            bool found = destination.has_value();
            Dispatch::main([this, alive, generation, sourcePath, candidate, found] {
                if (alive.expired() || definitionHoverGeneration_ != generation) return;
                if (definitionHoverURL_ != sourcePath || definitionHoverCandidate_ != candidate) return;
                editor_.setCommandHoverRange(found ? std::optional<TextRange>(candidate) : std::nullopt);
            });
        });
    });
}

void EditorPane::clearDefinitionHover() {
    if (!definitionHoverURL_ && !definitionHoverCandidate_ && !editor_.commandHoverRange()) return;
    ++definitionHoverGeneration_;
    if (definitionHoverWork_) definitionHoverWork_->cancel();
    definitionHoverWork_.reset();
    definitionHoverURL_.reset();
    definitionHoverCandidate_.reset();
    editor_.setCommandHoverRange(std::nullopt);
}

// ── Saving ─────────────────────────────────────────────────────────────────

void EditorPane::presentSaveError(const std::wstring& message) {
    Alert::inform(saveDialogOwner(), L"The document could not be saved.", message, Alert::Style::Warning);
}

void EditorPane::documentDidPersist(Document& document, const std::wstring& writtenTo) {
    reloadTabs();
    if (!document.isVirtual()) refreshGitLineChanges(false);
    if (onDocumentSaved) onDocumentSaved(writtenTo);
}

void EditorPane::documentDidReloadFromDisk(Document&) { reloadTabs(); }

HWND EditorPane::saveDialogOwner() { return window() ? window()->hwnd() : nullptr; }

// One editor pane: its tab strip, the code view and gutter, the find bar, the
// diff header and every preview (EditorPaneViewController.swift). Buffers are
// shared through DocumentStore; the pane owns its tabs and their state.
#pragma once

#include "documentstore.h"
#include "editorview.h"
#include "epub.h"
#include "filehistory.h"
#include "findbar.h"
#include "notify.h"
#include "panechrome.h"
#include "popover.h"
#include "previews.h"

class EditorPane : public View, public DocumentSaveHost {
public:
    EditorPane();
    ~EditorPane() override;

    std::function<void(const std::optional<std::wstring>&)> onActiveDocumentChanged;
    std::function<void()> onEmptied;
    std::function<void()> onDocumentEdited;
    std::function<void(const std::wstring&)> onDocumentSaved;
    std::function<void(const std::wstring&)> onTabOpened;
    std::function<void(const std::wstring&)> onTabClosed;
    std::function<const FileHistoryModel*(const std::wstring&)> fileHistoryProvider;

    static constexpr int undoLevels = 200;
    static constexpr size_t reopenableTabs = 10;
    static constexpr double idleSaveDelay = 1;
    static constexpr double liveMarkDelay = 0.25;
    static constexpr double svgRenderDelay = 0.25;

    const std::vector<std::wstring>& openURLs() const { return openURLs_; }
    std::optional<int> activeTabIndex() const { return activeIndex_; }
    std::optional<std::wstring> currentURL() const;
    Document* currentDocument() const;
    void setTabRowHeight(float height);
    void setCaptionReserve(float width);
    void setActive(bool active);

    void open(const std::wstring& url, bool replacingContent = false);
    void activate(int index);
    void close(int index);
    void closeAllTabs();
    void closeOtherTabs(int index);
    void closeTabsToTheRight(int index);
    void stepTab(int offset);
    bool reopenLastClosedTab();
    void save();
    void autosaveIfNeeded();
    bool confirmClose(const std::vector<std::wstring>& urls);
    void jumpToLine(int line, std::optional<int> column = std::nullopt);
    void prepareForClose();
    void releaseTransientMemory();
    void refreshDisplay();
    void reloadTabs();
    void pathRenamed(const std::wstring& from, const std::wstring& to);
    void pathDeleted(const std::wstring& path);
    void showFindBar(const std::optional<std::wstring>& seed = std::nullopt, bool replacing = false);
    void hideFindBar();
    void refreshGitLineChanges(bool reloadBaseline = true);
    void invalidateBlame(const std::optional<std::wstring>& url = std::nullopt);
    void setRepositoryRoot(const std::optional<std::wstring>& root);
    EditorView& editor() { return editor_; }
    bool isEditorFocused() const { return editor_.isFocused(); }
    void focusEditor() { editor_.focus(); }

    void layout() override;

    // DocumentSaveHost
    void presentSaveError(const std::wstring& message) override;
    void documentDidPersist(Document& document, const std::wstring& writtenTo) override;
    void documentDidReloadFromDisk(Document& document) override;
    HWND saveDialogOwner() override;

    /// The repository-relative path a diff buffer was built from.
    static std::optional<std::string> diffPath(const std::wstring& url);

private:
    void textDidChange();
    void selectionDidChange();
    void structureChanged(Document* doc);
    void restyled(Document* doc);
    void reloadedFromDisk(Document* doc);
    std::optional<TextRange> markdownRevealRange(Document& doc);
    void applyMarkdown(Document& doc);
    void detachFromDocument();
    void moveState(const std::wstring& from, const std::wstring& to);
    void closeTabs(const std::vector<int>& doomed, int anchor);
    void saveFindState();
    void restoreFindState(const std::optional<std::wstring>& url);
    void refreshSearchNavigator();
    void scheduleIdleSave(Document& doc);
    std::wstring tabPath(const std::wstring& url, Document& doc, const std::wstring& fallback);
    void markLineActive();

    // Diffs.
    void showDiffHeader(const std::optional<std::wstring>& url);
    void toggleDiffMode();
    void applyDiffMode();
    std::vector<TextRange> changeBlocks() const;
    void stepThroughDiff(bool forward);

    // Previews.
    void hidePreviews();
    void releaseImagePreview();
    void releaseMediaPreview();
    void releaseEPUBReader();
    void releasePDFPreview();
    void releaseSVGPreview();
    void refreshSVGPreview(Document& doc);
    void scheduleSVGRender(Document& doc);
    void openMarkdownLink(const MarkdownLinkDecoration& link);

    // Git marks and blame.
    void scheduleGitLineChanges();
    void recomputeGitLineChanges();
    void applyGitLineChanges(std::vector<GitLineChanges::Change> changes, const std::optional<std::wstring>& url);
    void showGitChange(const GitLineChanges::Change& change, const Rect& rect);
    bool revertGitChange(const GitLineChanges::Change& change);
    int caretLine() const;
    void scheduleInlineBlame();
    void clearInlineBlameRequest();
    void cacheBlame(const std::string& text, const std::wstring& key);

    // Definitions.
    bool navigateToDefinition(size_t location);
    void updateDefinitionHover(std::optional<size_t> location);
    void clearDefinitionHover();

    EditorTabBar tabBar_;
    FindBarView findBar_;
    DiffHeaderView diffHeader_;
    EditorView editor_;
    std::unique_ptr<SideBySideDiffView> sideBySide_;
    std::unique_ptr<ImagePreviewView> imagePreview_;
    std::unique_ptr<SVGPreviewView> svgPreview_;
    std::unique_ptr<MediaPreviewView> mediaPreview_;
    std::unique_ptr<PDFPreviewView> pdfPreview_;
    std::unique_ptr<EPUBReaderView> epubReader_;
    std::unique_ptr<FileHistoryView> fileHistoryView_;
    bool showsEditor_ = true;
    bool showsDiffHeader_ = false;
    bool pdfThumbnailsVisible_ = true;
    bool epubContentsVisible_ = true;
    std::optional<SVGImage> lastRenderedSVG_;
    std::shared_ptr<Dispatch::Pending> svgRenderWork_;

    std::vector<std::wstring> openURLs_;
    std::optional<int> activeIndex_;
    std::map<std::wstring, TextRange> selections_;
    std::set<std::wstring> lineActivatedURLs_;
    std::map<std::wstring, std::set<size_t>> foldedBlocks_;
    std::map<std::wstring, FindBarView::State> findStates_;
    std::optional<std::wstring> findBarURL_;
    std::vector<std::wstring> closedURLs_;
    bool suppressSelectionSideEffects_ = false;
    static DiffMode diffMode_;

    std::optional<std::wstring> repositoryRoot_;
    std::vector<GitLineChanges::Change> gitLineChanges_;
    std::optional<std::wstring> gitLineChangesURL_;
    std::optional<std::vector<std::string>> gitBaseline_;
    std::optional<std::wstring> gitBaselineURL_;
    int gitLineChangeGeneration_ = 0;
    std::shared_ptr<CancelToken> gitBaselineToken_;
    std::shared_ptr<CancelToken> liveMarkToken_;
    std::shared_ptr<Dispatch::Pending> liveMarkWork_;
    std::shared_ptr<Dispatch::Pending> idleSaveWork_;
    std::unique_ptr<GitChangePopover> gitChangePopover_;
    DocumentSaveCoordinator saveCoordinator_;

    std::shared_ptr<Dispatch::Pending> blameWork_;
    int blameGeneration_ = 0;
    std::optional<std::wstring> requestedBlameKey_;
    std::optional<std::wstring> displayedBlameKey_;
    std::map<std::wstring, std::string> blameCache_;
    std::vector<std::wstring> blameOrder_;
    static constexpr size_t maxBlameEntries = 500;

    int definitionNavigationGeneration_ = 0;
    int definitionHoverGeneration_ = 0;
    std::optional<std::wstring> definitionHoverURL_;
    std::optional<TextRange> definitionHoverCandidate_;
    std::shared_ptr<Dispatch::Pending> definitionHoverWork_;

    std::vector<Observation> observations_;
    Lifetime life_;
};

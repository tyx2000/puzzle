// The editor area: its one pane, the start page behind it, the faint
// shortcuts shown with a project and no file, and the settings gear
// (EditorViewController.swift).
#pragma once

#include "editorpane.h"

/// A project open and no file: a few faint shortcuts where the text goes.
class EmptyEditorHintView : public View {
public:
    EmptyEditorHintView() { ignoresMouse = true; }
    /// The listed menu items, by title, with their keys.
    static const std::vector<std::pair<std::wstring, std::wstring>>& lines();
    void draw(Graphics& g) override;
};

class EditorArea : public View {
public:
    EditorArea();
    ~EditorArea() override;

    std::function<void(const std::wstring&)> onDocumentSaved;
    std::function<void()> onOpenSettings;
    std::function<void(const std::optional<std::wstring>&)> onActiveDocumentChanged;
    std::function<void()> onOpenFolder;
    std::function<void(const std::wstring&)> onOpenRecent;
    std::function<void(const std::vector<std::wstring>&)> onOpenChecked;

    void setHasProject(bool hasProject);
    bool hasProject() const { return hasProject_; }
    void setRepositoryRoot(const std::optional<std::wstring>& root) { pane_.setRepositoryRoot(root); }
    void setTabRowHeight(float height);
    void setCaptionReserve(float width);

    std::optional<std::wstring> currentURL() const { return pane_.currentURL(); }
    const std::vector<std::wstring>& openURLs() const { return pane_.openURLs(); }
    bool hasOpenDocument() const { return pane_.currentURL().has_value(); }
    EditorPane& pane() { return pane_; }

    void open(const std::wstring& url, bool replacingContent = false);
    void showFileHistory(const FileHistoryModel& model);
    bool confirmClose();
    void detachAllPanes();
    void releaseTransientMemory();
    void stepTab(int offset) { pane_.stepTab(offset); }
    void closeAllTabs() { pane_.closeAllTabs(); }
    bool reopenLastClosedTab();
    bool closeActiveTab();
    bool canMutatePath(const std::wstring& base) const;
    void pathRenamed(const std::wstring& from, const std::wstring& to);
    void pathDeleted(const std::wstring& path);
    void save() { pane_.save(); }
    void autosaveAll() { pane_.autosaveIfNeeded(); }
    void showFindBar(const std::optional<std::wstring>& seed = std::nullopt, bool replacing = false) {
        pane_.showFindBar(seed, replacing);
    }
    void jumpToLine(int line, std::optional<int> column = std::nullopt) { pane_.jumpToLine(line, column); }
    void refreshGitLineChanges() { pane_.refreshGitLineChanges(); }
    void invalidateBlame(const std::optional<std::wstring>& url = std::nullopt) { pane_.invalidateBlame(url); }
    void refreshDisplay();

    void layout() override;
    bool isWindowDragArea(Point p) override { return p.y < tabRowHeight_; }

private:
    void updatePlaceholder();
    void updateWelcome();

    EditorPane pane_;
    EmptyEditorHintView emptyHints_;
    std::unique_ptr<WelcomeView> welcome_;
    SymbolButton settingsButton_;
    bool hasProject_ = false;
    bool welcomePending_ = false;
    float tabRowHeight_ = EditorTabBar::defaultRowHeight;
    float captionReserve_ = 0;
    std::map<std::wstring, FileHistoryModel> fileHistories_;
    Lifetime life_;
};

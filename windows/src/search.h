// Project-wide content search, grouped by file like Zed: each file is a header
// row (name + folder) with its matching lines beneath. Clicking a file opens
// it; clicking a line opens it at that line (SearchViewController.swift,
// SearchSupport.swift).
#pragma once

#include "searchinput.h"

#include <regex>

/// One compiled query: literal or regular expression, case and whole-word
/// rules applied the way NSRegularExpression applied them.
class SearchMatcher {
public:
    /// Nullopt for an empty query or a pattern that does not compile.
    static std::optional<SearchMatcher> make(const std::wstring& query, const SearchOptions& options);
    /// (start, length) in UTF-16 units of the first match.
    std::optional<std::pair<size_t, size_t>> firstRange(const std::wstring& text) const;

private:
    std::wstring needle_;  // lowered when the search ignores case
    std::shared_ptr<std::wregex> regex_;
    SearchOptions options_;
};

class SearchPanel : public View {
public:
    SearchPanel();
    ~SearchPanel() override;

    std::function<void(const std::wstring&, int)> onOpenResult;
    std::function<void(const std::wstring&)> onOpenFile;

    struct Hit {
        int line = 0;
        std::wstring preview;
        std::optional<std::pair<size_t, size_t>> matchRange;  // inside `preview`
    };
    struct FileGroup {
        std::wstring path;
        std::wstring relative;  // with the platform's separators
        std::vector<Hit> hits;
        bool expanded = true;
        std::wstring folder() const;
        std::wstring name() const;
    };

    void setDirectory(const std::optional<std::wstring>& directory);
    void focusSearchField() { field_.focus(true); }
    void refreshFonts();
    void releaseTransientMemory();
    /// Run a query programmatically (the `--search` launch flag).
    void performSearch(const std::wstring& query);

    /// The search itself, off the main thread.
    static std::vector<FileGroup> search(const std::wstring& query, const std::wstring& directory,
                                         const SearchOptions& options,
                                         const std::vector<std::pair<std::wstring, std::string>>& inMemoryFiles,
                                         const std::shared_ptr<CancelToken>& cancellation);
    static bool isGeneratedArtifact(const std::wstring& name);

    void layout() override;

private:
    struct Row {
        int group = 0;
        int hit = -1;  // -1: the file's own row
    };
    void searchChanged();
    void updatePlaceholder(const std::wstring& query, std::optional<int> matches);
    void rebuildRows();
    void drawRow(Graphics& g, int row, const Rect& rect);
    void rowClicked(int row);

    /// The outline: remembers where a press landed, so the disclosure
    /// triangle can toggle instead of opening the file.
    class ResultList : public ListView {
    public:
        float pressX = 0;
    protected:
        bool contentMouseDown(const MouseEvent& e, Point p) override {
            pressX = p.x;
            return ListView::contentMouseDown(e, p);
        }
    };

    std::optional<std::wstring> directory_;
    SearchInputView field_;
    Label summary_;
    Label placeholder_;
    ResultList list_;
    std::vector<FileGroup> groups_;
    std::vector<Row> rows_;
    std::shared_ptr<Dispatch::Pending> searchWork_;
    std::shared_ptr<CancelToken> searchToken_;
    int searchGeneration_ = 0;
    Lifetime life_;
};

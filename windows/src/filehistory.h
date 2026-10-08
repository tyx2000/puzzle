// A file's history as a tab: four columns of commits and, under them, the
// diff of the one opened (FileHistoryView.swift).
#pragma once

#include "editorview.h"
#include "gitservice.h"

struct FileHistoryModel {
    std::wstring tabURL;
    std::wstring repository;
    std::string relativePath;
    std::wstring displayName;
    std::vector<Git::Commit> commits;
};

class FileHistoryView : public View {
public:
    FileHistoryView();
    ~FileHistoryView() override;
    void configure(const FileHistoryModel& model);
    void layout() override;
    void draw(Graphics& g) override;
    bool mouseDown(const MouseEvent& e) override;
    void mouseDragged(const MouseEvent& e) override;
    void mouseUp(const MouseEvent& e) override;
    Cursor cursorAt(Point p) override;

    static constexpr float headerHeight = 24;

private:
    std::vector<float> columnWidths() const;
    void toggleDetail(int row);
    void collapseDetail();
    void setDetailText(const std::string& text, bool highlightingDiff);
    float applyDetailHeight(float requested);
    Rect detailRect() const;

    std::optional<FileHistoryModel> model_;
    ListView table_;
    Label empty_;
    Label detailTitle_;
    EditorView detail_;
    std::unique_ptr<Document> detailDocument_;
    std::optional<int> expandedRow_;
    int detailGeneration_ = 0;
    std::optional<float> preferredDetailHeight_;
    float detailHeight_ = 0;
    bool resizing_ = false;
    Lifetime life_;
};

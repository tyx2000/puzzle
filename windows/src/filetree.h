// The project's files as a lazily loaded tree (FileTreeViewController.swift,
// FileNode.swift): Git colours, the active file's row, inline create and
// rename, and the context menu.
#pragma once

#include "widgets.h"

/// A lazily populated node; only the root keeps a full path.
class FileNode {
public:
    FileNode(const std::wstring& rootPath, bool isDirectory);
    FileNode(const std::wstring& name, bool isDirectory, FileNode* parent);
    std::wstring name;
    bool isDirectory = false;
    FileNode* parent = nullptr;
    bool expanded = false;
    std::wstring path() const;
    const std::vector<std::unique_ptr<FileNode>>& children();
    bool childrenLoaded() const { return loaded_; }
    void invalidate();
    /// Re-read a loaded directory, keeping the nodes that still exist.
    void refreshChildren();
    void releaseChildren();
private:
    std::vector<std::unique_ptr<FileNode>> load();
    std::wstring rootPath_;
    std::vector<std::unique_ptr<FileNode>> children_;
    bool loaded_ = false;
};

class FileTreeView : public View {
public:
    FileTreeView();
    ~FileTreeView() override;

    std::function<void(const std::wstring&)> onOpenFile;
    std::function<void(const std::wstring&)> onGitHistory;
    std::function<void(const std::wstring&)> onOpenInTerminal;
    std::function<void()> onFileSystemChanged;
    std::function<bool(const std::wstring&)> canMutatePath;
    std::function<void(const std::wstring&, const std::wstring&)> onPathRenamed;
    std::function<void(const std::wstring&)> onPathDeleted;

    void setRoot(const std::wstring& path);
    void clearRoot();
    void refresh();
    void refresh(const std::vector<std::wstring>& changed);
    void setStatus(const std::set<std::string>& modified, const std::set<std::string>& untracked,
                   const std::set<std::string>& ignored);
    void selectFile(const std::wstring& path);
    void refreshAppearance();

    void layout() override;

private:
    struct Row {
        FileNode* node = nullptr;  // nullptr: the pending new item
        int level = 0;
    };
    struct PendingEdit {
        enum class Kind { File, Folder, Rename } kind;
        FileNode* parent = nullptr;
        FileNode* original = nullptr;
        std::wstring initialName;
        size_t insertionIndex = 0;
    };

    void rebuildRows();
    void collect(FileNode* node, int level);
    void toggle(FileNode* node);
    void drawRow(Graphics& g, int row, const Rect& rect);
    void contextMenu(int row, POINT screen);
    FileNode* nodeFor(const std::wstring& path);
    std::optional<std::string> relativePath(FileNode* node) const;
    std::optional<Color> statusColor(FileNode* node) const;
    bool isIgnored(FileNode* node) const;
    int rowFor(const std::wstring& path) const;

    void beginCreate(PendingEdit::Kind kind, FileNode* parent, FileNode* after);
    void beginRename(FileNode* node);
    void placeEditor();
    void cancelPendingEdit();
    bool completePendingEdit(const std::wstring& name);
    void reloadAfterMutation(FileNode* parent, const std::optional<std::wstring>& selecting);
    bool canMutate(const std::wstring& path, const std::wstring& verb);
    void presentFileError(const std::wstring& title, const std::wstring& message);
    void applyDeferredReload();

    ListView list_;
    TextField editor_;
    std::unique_ptr<FileNode> root_;
    std::vector<Row> rows_;
    std::set<std::string> dirty_, untracked_, dirtyDirectories_, untrackedDirectories_, ignored_;
    std::wstring activePath_;
    std::optional<PendingEdit> pending_;
    bool deferredReload_ = false;
    bool deferredDiskRefresh_ = false;
    bool completing_ = false;
    Lifetime life_;
};

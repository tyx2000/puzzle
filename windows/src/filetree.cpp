#include "filetree.h"

#include "dialog.h"
#include "gitservice.h"
#include "icons.h"
#include "menu.h"
#include "services.h"
#include "theme.h"

#include <shellapi.h>

namespace {
constexpr float kIndent = 14;
constexpr float kLeading = 6;
constexpr float kDisclosureSlot = 12;
constexpr float kDisclosure = 10;
constexpr float kIconSize = 14;
constexpr float kGap = 4;
constexpr float kIconX = kDisclosureSlot + kGap;
constexpr float kTitleX = kIconX + kIconSize + kGap;

/// Never shown: version-control internals and OS bookkeeping.
const std::set<std::wstring>& excludedNames() {
    static const std::set<std::wstring> names = {L".git", L".svn", L".hg", L"CVS", L".DS_Store", L"Thumbs.db",
                                                 L"desktop.ini"};
    return names;
}

std::set<std::string> ancestors(const std::set<std::string>& paths) {
    std::set<std::string> out;
    for (auto& path : paths) {
        auto parts = split(path, '/');
        if (parts.size() <= 1) continue;
        std::string prefix;
        for (size_t i = 0; i + 1 < parts.size(); ++i) {
            prefix = prefix.empty() ? parts[i] : prefix + "/" + parts[i];
            out.insert(prefix);
        }
    }
    return out;
}

Rect centered(float x, float size, const Rect& row) { return Rect(x, row.y + (row.h - size) / 2, size, size); }
}  // namespace

// ── FileNode ───────────────────────────────────────────────────────────────

FileNode::FileNode(const std::wstring& rootPath, bool isDirectory)
    : name(lastPathComponent(rootPath)), isDirectory(isDirectory), rootPath_(rootPath) {}

FileNode::FileNode(const std::wstring& name_, bool isDirectory_, FileNode* parent_)
    : name(name_), isDirectory(isDirectory_), parent(parent_) {}

std::wstring FileNode::path() const {
    if (!rootPath_.empty()) return rootPath_;
    return parent ? pathJoin(parent->path(), name) : name;
}

std::vector<std::unique_ptr<FileNode>> FileNode::load() {
    std::vector<std::unique_ptr<FileNode>> nodes;
    WIN32_FIND_DATAW data;
    HANDLE find = FindFirstFileExW(pathJoin(path(), L"*").c_str(), FindExInfoBasic, &data, FindExSearchNameMatch,
                                   nullptr, FIND_FIRST_EX_LARGE_FETCH);
    if (find == INVALID_HANDLE_VALUE) return nodes;
    do {
        std::wstring entry = data.cFileName;
        if (entry == L"." || entry == L".." || excludedNames().count(entry)) continue;
        // Dotfiles are shown: in a JS project they are most of the configuration.
        bool directory = (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
        nodes.push_back(std::make_unique<FileNode>(entry, directory, this));
    } while (FindNextFileW(find, &data));
    FindClose(find);
    // Directories first, then files, each case-insensitively alphabetical.
    std::sort(nodes.begin(), nodes.end(), [](const auto& a, const auto& b) {
        if (a->isDirectory != b->isDirectory) return a->isDirectory;
        return naturalCompare(lowercased(U(a->name)), lowercased(U(b->name))) < 0;
    });
    return nodes;
}

const std::vector<std::unique_ptr<FileNode>>& FileNode::children() {
    if (!loaded_) {
        children_ = load();
        loaded_ = true;
    }
    return children_;
}

void FileNode::invalidate() {
    children_.clear();
    loaded_ = false;
}

void FileNode::refreshChildren() {
    if (!loaded_) return;
    auto refreshed = load();
    for (auto& candidate : refreshed) {
        for (auto& existing : children_) {
            if (existing && existing->isDirectory == candidate->isDirectory && existing->name == candidate->name) {
                candidate = std::move(existing);
                break;
            }
        }
    }
    children_ = std::move(refreshed);
}

void FileNode::releaseChildren() {
    for (auto& child : children_) child->releaseChildren();
    children_.clear();
    loaded_ = false;
}

// ── FileTreeView ───────────────────────────────────────────────────────────

FileTreeView::FileTreeView() {
    backgroundColor = Theme::panelBackground;
    list_.backgroundColor = Theme::panelBackground;
    list_.rowHeight = Theme::treeRowHeight();
    list_.numberOfRows = [this] { return (int)rows_.size(); };
    list_.drawRow = [this](Graphics& g, int row, const Rect& rect) { drawRow(g, row, rect); };
    list_.rowBackground = [this](int row) {
        if (row >= 0 && row < (int)rows_.size() && rows_[row].node && !activePath_.empty()
            && samePath(rows_[row].node->path(), activePath_)) {
            return Theme::activeRow;
        }
        return row == list_.hoveredRow() ? Theme::hover : Theme::panelBackground;
    };
    list_.onClick = [this](int row) {
        if (row < 0 || row >= (int)rows_.size() || !rows_[row].node) return;
        FileNode* node = rows_[row].node;
        if (pending_ && pending_->original == node) return;
        if (node->isDirectory) toggle(node);
        else if (onOpenFile) onOpenFile(node->path());
    };
    list_.onContextMenu = [this](int row, POINT screen) { contextMenu(row, screen); };
    list_.tooltipForRow = [this](int row, Point) -> std::wstring {
        if (row < 0 || row >= (int)rows_.size() || !rows_[row].node) return L"";
        return rows_[row].node->name;
    };
    list_.onScroll = [this] { placeEditor(); };
    addSubview(&list_);
    editor_.font = Theme::uiFont(12);
    editor_.textColor = Theme::foreground;
    editor_.fillColor = Theme::inputBackground;
    editor_.borderColor = Theme::inputBorderFocused;
    editor_.horizontalInset = 4;
    editor_.setHidden(true);
    editor_.onSubmit = [this] { completePendingEdit(editor_.text()); };
    editor_.onEscape = [this] { cancelPendingEdit(); };
    editor_.onFocusChange = [this](bool focused) {
        // Clicking away cancels, as resigning the field editor did.
        if (!focused && pending_ && !completing_) {
            Dispatch::main([this, alive = life_.weak()] {
                if (!alive.expired() && pending_ && !editor_.isFocused() && !completing_) cancelPendingEdit();
            });
        }
    };
    addSubview(&editor_);
}

FileTreeView::~FileTreeView() = default;

void FileTreeView::layout() {
    list_.setFrame(bounds());
    placeEditor();
}

void FileTreeView::refreshAppearance() {
    list_.rowHeight = Theme::treeRowHeight();
    editor_.font = Theme::uiFont(12);
    editor_.dpiChanged();
    list_.reloadData();
    setNeedsDisplay();
}

void FileTreeView::setRoot(const std::wstring& path) {
    cancelPendingEdit();
    deferredReload_ = deferredDiskRefresh_ = false;
    root_ = std::make_unique<FileNode>(path, true);
    root_->expanded = true;
    rebuildRows();
    list_.setContentOffset(Point(0, 0));
}

void FileTreeView::clearRoot() {
    cancelPendingEdit();
    deferredReload_ = deferredDiskRefresh_ = false;
    root_.reset();
    rebuildRows();
}

void FileTreeView::collect(FileNode* node, int level) {
    size_t index = 0;
    auto& kids = node->children();
    bool pendingHere = pending_ && !pending_->original && pending_->parent == node;
    size_t insertion = pendingHere ? std::min(pending_->insertionIndex, kids.size()) : 0;
    for (auto& child : kids) {
        if (pendingHere && index == insertion) rows_.push_back({nullptr, level});
        rows_.push_back({child.get(), level});
        if (child->isDirectory && child->expanded) collect(child.get(), level + 1);
        ++index;
    }
    if (pendingHere && insertion >= kids.size()) rows_.push_back({nullptr, level});
}

void FileTreeView::rebuildRows() {
    rows_.clear();
    // The project's own folder is not a row: the list above already names it.
    if (root_) collect(root_.get(), 0);
    list_.reloadData();
    list_.refreshHoverState();
    placeEditor();
    setNeedsDisplay();
}

void FileTreeView::toggle(FileNode* node) {
    node->expanded = !node->expanded;
    // A collapsed folder lets go of what it loaded.
    if (!node->expanded) node->releaseChildren();
    rebuildRows();
}

void FileTreeView::refresh() {
    if (pending_) {
        deferredReload_ = deferredDiskRefresh_ = true;
        return;
    }
    if (!root_) return;
    // Keep expansion: refresh every loaded directory in place.
    std::function<void(FileNode*)> walk = [&](FileNode* node) {
        if (!node->childrenLoaded()) return;
        node->refreshChildren();
        for (auto& child : node->children()) {
            if (child->isDirectory) walk(child.get());
        }
    };
    walk(root_.get());
    rebuildRows();
}

void FileTreeView::refresh(const std::vector<std::wstring>& changed) {
    if (!root_ || changed.empty()) return;
    if (pending_) {
        deferredReload_ = deferredDiskRefresh_ = true;
        return;
    }
    std::wstring rootPath = lowercased(root_->path());
    std::wstring rootPrefix = rootPath + L"\\";
    std::set<FileNode*> affected;
    for (auto& raw : changed) {
        std::wstring candidate = raw;
        if (!directoryExists(candidate)) candidate = deletingLastPathComponent(candidate);
        while (true) {
            std::wstring lowered = lowercased(candidate);
            if (lowered != rootPath && !startsWith(lowered, rootPrefix)) break;
            if (FileNode* node = nodeFor(candidate); node && node->isDirectory) {
                affected.insert(node);
                break;
            }
            if (lowered == rootPath) break;
            candidate = deletingLastPathComponent(candidate);
        }
    }
    if (affected.empty()) return;
    for (FileNode* node : affected) node->refreshChildren();
    rebuildRows();
}

void FileTreeView::setStatus(const std::set<std::string>& modified, const std::set<std::string>& untracked,
                             const std::set<std::string>& ignored) {
    dirty_ = modified;
    untracked_ = untracked;
    ignored_ = ignored;
    dirtyDirectories_ = ancestors(modified);
    untrackedDirectories_ = ancestors(untracked);
    list_.setNeedsDisplay();
}

std::optional<std::string> FileTreeView::relativePath(FileNode* node) const {
    if (!root_ || !node) return std::nullopt;
    std::vector<std::string> parts;
    for (FileNode* n = node; n && n != root_.get(); n = n->parent) parts.push_back(U(n->name));
    std::reverse(parts.begin(), parts.end());
    return join(parts, "/");
}

std::optional<Color> FileTreeView::statusColor(FileNode* node) const {
    auto path = relativePath(node);
    if (!path) return std::nullopt;
    if (node->isDirectory) {
        if (untrackedDirectories_.count(*path)) return Theme::green;
        if (dirtyDirectories_.count(*path)) return Theme::yellow;
        return std::nullopt;
    }
    if (untracked_.count(*path)) return Theme::green;
    if (dirty_.count(*path)) return Theme::yellow;
    return std::nullopt;
}

bool FileTreeView::isIgnored(FileNode* node) const {
    if (ignored_.empty()) return false;
    auto path = relativePath(node);
    if (!path) return false;
    if (ignored_.count(*path)) return true;
    std::string prefix = *path;
    size_t slash;
    while ((slash = prefix.rfind('/')) != std::string::npos) {
        prefix = prefix.substr(0, slash);
        if (ignored_.count(prefix)) return true;
    }
    return false;
}

void FileTreeView::drawRow(Graphics& g, int index, const Rect& rect) {
    const Row& row = rows_[index];
    float base = rect.x + kLeading + row.level * kIndent;
    bool editingThis = pending_ && (row.node == nullptr || row.node == pending_->original);
    FileNode* node = row.node;
    bool isDirectory = node ? node->isDirectory : (pending_ && pending_->kind == PendingEdit::Kind::Folder);
    bool expanded = node && node->expanded;
    if (isDirectory) {
        drawSymbol(g, expanded ? Symbol::ChevronDown : Symbol::ChevronRight,
                   centered(base + (kDisclosureSlot - kDisclosure) / 2, kDisclosure, rect), Theme::dimText, 0.9f);
    }
    Rect iconRect = centered(base + kIconX, kIconSize, rect);
    bool dimmed = node && isIgnored(node);
    std::string icon;
    if (isDirectory) icon = FileIcons::folderIconName(node ? U(node->name) : "", expanded);
    else icon = FileIcons::fileIconName(node ? U(node->name) : (pending_ && !editingThis ? "" : "file"));
    if (!node && pending_) icon = pending_->kind == PendingEdit::Kind::Folder ? FileIcons::folderIconName("", false)
                                                                              : FileIcons::fileIconName("file");
    if (dimmed) {
        // Faded with the name: there, but not part of the project's work.
        if (ID2D1Bitmap* bitmap = FileIcons::bitmap(icon, iconRect, g.scale())) g.drawBitmap(bitmap, iconRect, 0.45f);
    } else if (!FileIcons::draw(g, icon, iconRect)) {
        drawSymbol(g, isDirectory ? Symbol::Folder : Symbol::Document, iconRect, Theme::dimText);
    }
    if (editingThis || !node) return;
    Color color = statusColor(node).value_or(dimmed ? Theme::dimText : Theme::foreground);
    g.text(node->name, Theme::uiFont(12), color,
           Rect(base + kTitleX, rect.y, std::max(0.0f, rect.maxX() - base - kTitleX - 5), rect.h),
           LineBreak::TruncatingMiddle);
}

FileNode* FileTreeView::nodeFor(const std::wstring& path) {
    if (!root_) return nullptr;
    std::wstring rootPath = root_->path();
    if (samePath(path, rootPath)) return root_.get();
    std::wstring lowered = lowercased(path), prefix = lowercased(rootPath) + L"\\";
    if (!startsWith(lowered, prefix)) return nullptr;
    std::wstring relative = path.substr(prefix.size());
    FileNode* current = root_.get();
    size_t start = 0;
    while (start <= relative.size()) {
        size_t slash = relative.find(L'\\', start);
        std::wstring component = relative.substr(start, slash == std::wstring::npos ? std::wstring::npos : slash - start);
        if (component.empty()) break;
        FileNode* next = nullptr;
        for (auto& child : current->children()) {
            if (lowercased(child->name) == lowercased(component)) {
                next = child.get();
                break;
            }
        }
        if (!next) return nullptr;
        current = next;
        if (slash == std::wstring::npos) break;
        start = slash + 1;
    }
    return current;
}

int FileTreeView::rowFor(const std::wstring& path) const {
    for (int i = 0; i < (int)rows_.size(); ++i) {
        if (rows_[i].node && samePath(rows_[i].node->path(), path)) return i;
    }
    return -1;
}

void FileTreeView::selectFile(const std::wstring& path) {
    activePath_ = path;
    list_.setNeedsDisplay();
    if (!root_) return;
    std::wstring rootPath = root_->path();
    std::wstring prefix = lowercased(rootPath) + L"\\";
    // Files outside the project (settings.json) just clear the highlight.
    if (!startsWith(lowercased(path), prefix)) return;
    std::wstring relative = path.substr(prefix.size());
    FileNode* current = root_.get();
    bool changed = false;
    size_t start = 0;
    while (true) {
        size_t slash = relative.find(L'\\', start);
        std::wstring component = relative.substr(start, slash == std::wstring::npos ? std::wstring::npos : slash - start);
        auto findChild = [&]() -> FileNode* {
            for (auto& child : current->children()) {
                if (lowercased(child->name) == lowercased(component)) return child.get();
            }
            return nullptr;
        };
        FileNode* child = findChild();
        if (!child) {
            // The open can beat the file-system event for a new file.
            current->refreshChildren();
            child = findChild();
        }
        if (!child) break;
        if (child->isDirectory && !child->expanded) {
            child->expanded = true;
            changed = true;
        }
        current = child;
        if (slash == std::wstring::npos) break;
        start = slash + 1;
    }
    if (changed) rebuildRows();
    int row = rowFor(path);
    if (row >= 0) list_.scrollRowToVisible(row);
}

// ── Context menu ───────────────────────────────────────────────────────────

void FileTreeView::contextMenu(int row, POINT screen) {
    FileNode* node = row >= 0 && row < (int)rows_.size() ? rows_[row].node : root_.get();
    if (!node) return;
    WindowHost* host = window();
    if (!host) return;
    // A stable path, not the node: a refresh can rebuild the tree meanwhile.
    std::wstring path = node->path();
    bool isRoot = node == root_.get();
    bool isDirectory = node->isDirectory;
    auto withNode = [this, path](std::function<void(FileNode*)> action) {
        return [this, path, action] {
            if (FileNode* n = nodeFor(path)) action(n);
        };
    };
    Menu menu;
    menu.add(L"New File", withNode([this](FileNode* n) {
        FileNode* parent = n->isDirectory ? n : n->parent;
        if (parent) beginCreate(PendingEdit::Kind::File, parent, n->isDirectory ? nullptr : n);
    }));
    menu.add(L"New Folder", withNode([this](FileNode* n) {
        FileNode* parent = n->isDirectory ? n : n->parent;
        if (parent) beginCreate(PendingEdit::Kind::Folder, parent, n->isDirectory ? nullptr : n);
    }));
    menu.addSeparator();
    menu.add(L"Rename", withNode([this](FileNode* n) { beginRename(n); }), !isRoot);
    menu.add(L"Duplicate", withNode([this](FileNode* n) {
                 if (n == root_.get()) return;
                 std::wstring name = n->name;
                 size_t dot = n->isDirectory ? std::wstring::npos : name.rfind(L'.');
                 if (dot == 0) dot = std::wstring::npos;
                 std::wstring base = dot == std::wstring::npos ? name : name.substr(0, dot);
                 std::wstring ext = dot == std::wstring::npos ? L"" : name.substr(dot);
                 std::wstring parent = deletingLastPathComponent(n->path());
                 std::wstring candidate = base + L" copy";
                 int counter = 2;
                 while (fileExists(pathJoin(parent, candidate + ext))) candidate = base + L" copy " + std::to_wstring(counter++);
                 std::wstring destination = pathJoin(parent, candidate + ext);
                 std::wstring from = n->path() + L'\0';
                 std::wstring to = destination + L'\0';
                 SHFILEOPSTRUCTW op{};
                 op.wFunc = FO_COPY;
                 op.pFrom = from.c_str();
                 op.pTo = to.c_str();
                 op.fFlags = FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_SILENT | FOF_NOCONFIRMMKDIR;
                 if (SHFileOperationW(&op) != 0 || op.fAnyOperationsAborted) {
                     presentFileError(L"Duplicate failed", L"The item could not be copied.");
                     return;
                 }
                 reloadAfterMutation(n->parent, destination);
             }),
             !isRoot);
    menu.addSeparator();
    menu.add(L"Show in Explorer", [path] { revealInExplorer(path); });
    menu.add(L"Copy Path", [host, path] { copyToClipboard(host->hwnd(), path); });
    menu.add(L"Copy Relative Path", [this, host, path] {
        std::wstring rootPath = root_ ? normalizedPath(root_->path()) : L"";
        std::wstring resolved = normalizedPath(path);
        std::wstring prefix = rootPath + L"\\";
        std::wstring relative = startsWith(lowercased(resolved), lowercased(prefix)) ? resolved.substr(prefix.size()) : resolved;
        copyToClipboard(host->hwnd(), relative);
    });
    menu.add(L"Open in Terminal", [this, path, isDirectory] {
        // A file opens a terminal in its folder.
        if (onOpenInTerminal) onOpenInTerminal(isDirectory ? path : deletingLastPathComponent(path));
    });
    menu.addSeparator();
    menu.add(L"Git History", [this, path] {
        if (onGitHistory) onGitHistory(path);
    }, !isDirectory);
    menu.addSeparator();
    menu.add(L"Delete", withNode([this](FileNode* n) {
                 if (n == root_.get()) return;
                 std::wstring target = n->path();
                 if (!canMutate(target, L"delete")) return;
                 Alert alert;
                 alert.style = Alert::Style::Warning;
                 alert.messageText = L"Delete “" + n->name + L"”?";
                 std::wstring kind = n->isDirectory ? L"folder and everything inside it" : L"file";
                 alert.informativeText = target + L"\n\nThe " + kind
                     + L" will be moved to the Recycle Bin and removed from the project. Open tabs at this path will "
                       L"close. Recovery is possible only while the item remains in the Recycle Bin.";
                 alert.buttons = {L"Delete", L"Cancel"};
                 if (alert.runModal(window() ? window()->hwnd() : nullptr) != 0) return;
                 std::string error;
                 if (!Git::moveToRecycleBin(target, &error)) {
                     presentFileError(L"Delete failed", W(error));
                     return;
                 }
                 if (onPathDeleted) onPathDeleted(target);
                 FileNode* parent = nodeFor(deletingLastPathComponent(target));
                 reloadAfterMutation(parent, std::nullopt);
             }),
             !isRoot);
    menu.popup(host->hwnd(), screen);
}

// ── Inline edits ───────────────────────────────────────────────────────────

void FileTreeView::beginCreate(PendingEdit::Kind kind, FileNode* parent, FileNode* after) {
    cancelPendingEdit();
    parent->expanded = true;
    size_t insertion = 0;
    if (after && after->parent == parent) {
        auto& kids = parent->children();
        for (size_t i = 0; i < kids.size(); ++i) {
            if (kids[i].get() == after) insertion = i + 1;
        }
    }
    pending_ = PendingEdit{kind, parent, nullptr, L"", insertion};
    rebuildRows();
    editor_.setText(L"");
    editor_.setHidden(false);
    placeEditor();
    Dispatch::main([this, alive = life_.weak()] {
        if (!alive.expired() && pending_) editor_.focus();
    });
}

void FileTreeView::beginRename(FileNode* node) {
    if (!node || node == root_.get()) return;
    if (!canMutate(node->path(), L"rename")) return;
    cancelPendingEdit();
    pending_ = PendingEdit{PendingEdit::Kind::Rename, node->parent, node, node->name, 0};
    rebuildRows();
    editor_.setText(node->name);
    editor_.setHidden(false);
    placeEditor();
    Dispatch::main([this, alive = life_.weak()] {
        if (alive.expired() || !pending_) return;
        editor_.focus();
        editor_.selectAll();
    });
}

void FileTreeView::placeEditor() {
    if (!pending_) {
        editor_.setHidden(true);
        return;
    }
    int row = -1;
    for (int i = 0; i < (int)rows_.size(); ++i) {
        if (rows_[i].node == pending_->original) row = i;  // nullptr matches the placeholder
    }
    if (row < 0) {
        editor_.setHidden(true);
        return;
    }
    list_.scrollRowToVisible(row);
    Rect r = list_.rectOfRow(row);
    Point offset = list_.contentOffset();
    float base = kLeading + rows_[row].level * kIndent;
    editor_.setFrame(Rect(base + kTitleX - 4, r.y - offset.y, std::max(0.0f, bounds().w - base - kTitleX + 2), r.h));
    editor_.setHidden(false);
}

void FileTreeView::cancelPendingEdit() {
    if (!pending_) return;
    pending_.reset();
    editor_.setHidden(true);
    rebuildRows();
    applyDeferredReload();
}

bool FileTreeView::completePendingEdit(const std::wstring& rawName) {
    if (!pending_ || !pending_->parent) return false;
    std::wstring name = trim(rawName);
    bool invalid = name.empty() || name == L"." || name == L".." || name.find_first_of(L"\\/:*?\"<>|") != std::wstring::npos;
    if (invalid) {
        completing_ = true;
        presentFileError(L"Invalid name", L"Enter a name that does not contain \\ / : * ? \" < > or |.");
        completing_ = false;
        editor_.focus();
        return false;
    }
    PendingEdit edit = *pending_;
    std::wstring destination = pathJoin(edit.parent->path(), name);
    // Renaming Readme.md to README.md is the same file, not a clash.
    bool sameItem = edit.original && samePath(destination, edit.original->path());
    if (fileExists(destination) && !sameItem) {
        completing_ = true;
        presentFileError(L"Name already exists", L"An item named " + name + L" already exists here.");
        completing_ = false;
        editor_.focus();
        return false;
    }
    bool ok = true;
    std::wstring failure;
    switch (edit.kind) {
    case PendingEdit::Kind::File: {
        HANDLE h = CreateFileW(destination.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
        ok = h != INVALID_HANDLE_VALUE;
        if (ok) CloseHandle(h);
        else failure = systemErrorMessage(GetLastError());
        break;
    }
    case PendingEdit::Kind::Folder:
        ok = CreateDirectoryW(destination.c_str(), nullptr) != 0;
        if (!ok) failure = systemErrorMessage(GetLastError());
        break;
    case PendingEdit::Kind::Rename: {
        std::wstring source = edit.original->path();
        if (source != destination) {
            ok = MoveFileExW(source.c_str(), destination.c_str(), 0) != 0;
            if (!ok) failure = systemErrorMessage(GetLastError());
            else if (onPathRenamed) onPathRenamed(source, destination);
        }
        break;
    }
    }
    if (!ok) {
        completing_ = true;
        presentFileError(L"File operation failed", failure);
        completing_ = false;
        editor_.focus();
        return false;
    }
    pending_.reset();
    editor_.setHidden(true);
    FileNode* parent = edit.parent;
    reloadAfterMutation(parent, destination);
    applyDeferredReload();
    if (edit.kind == PendingEdit::Kind::File && onOpenFile) onOpenFile(destination);
    return true;
}

void FileTreeView::reloadAfterMutation(FileNode* parent, const std::optional<std::wstring>& selecting) {
    if (parent) {
        parent->refreshChildren();
        parent->expanded = true;
        rebuildRows();
    } else {
        refresh();
    }
    if (selecting) {
        int row = rowFor(*selecting);
        if (row >= 0) list_.scrollRowToVisible(row);
    }
    if (onFileSystemChanged) onFileSystemChanged();
}

bool FileTreeView::canMutate(const std::wstring& path, const std::wstring& verb) {
    if (canMutatePath && !canMutatePath(path)) {
        Alert::inform(window() ? window()->hwnd() : nullptr, L"Cannot " + verb + L" " + lastPathComponent(path),
                      L"Save or close modified files at this location first.");
        return false;
    }
    return true;
}

void FileTreeView::presentFileError(const std::wstring& title, const std::wstring& message) {
    Alert::inform(window() ? window()->hwnd() : nullptr, title, message);
}

void FileTreeView::applyDeferredReload() {
    if (!deferredReload_) return;
    bool disk = deferredDiskRefresh_;
    deferredReload_ = deferredDiskRefresh_ = false;
    if (disk) refresh();
    else rebuildRows();
}

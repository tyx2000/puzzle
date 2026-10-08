// The registry of open documents, keyed by path (DocumentStore.swift), and
// the one place that decides when a buffer is written
// (DocumentSaveCoordinator.swift).
#pragma once

#include "document.h"

class DocumentStore {
public:
    static DocumentStore& shared();

    /// How many buffers to keep at once, by count and by size. Tabs stay open;
    /// their text is read again from disk when they come back.
    size_t maxCachedDocuments = 12;
    size_t maxCachedBytes = 24 * 1024 * 1024;

    Document* cachedDocument(const std::wstring& url) const;
    bool documentIsCached(const std::wstring& url) const { return cachedDocument(url) != nullptr; }
    size_t cachedBytes() const;

    /// The buffer for `url`, read (or rebuilt) on demand.
    Document& document(const std::wstring& url);

    /// What a synthetic URL stands for, rebuilt from the URL alone.
    struct VirtualContent {
        std::string text;
        std::optional<std::wstring> displayName;
        std::optional<SVGDiffSides> svgSides;
    };
    /// Registered at launch; runs off the main thread.
    std::function<std::optional<VirtualContent>(const std::wstring&)> virtualContentProvider;

    /// Register (or replace) an in-memory document, e.g. a Git diff.
    Document& setVirtualDocument(const std::wstring& url, const std::string& text,
                                 const std::optional<std::wstring>& displayName = std::nullopt);

    void registerOpen(const std::wstring& url, const void* owner);
    void unregisterOpen(const std::wstring& url, const void* owner);

    /// Immutable copies of unsaved text inside a project, for project search.
    std::vector<std::pair<std::wstring, std::string>> modifiedTextSnapshots(const std::wstring& directory) const;
    /// Reconcile cached documents touched by a batch of file-system events.
    std::vector<std::wstring> reloadExternalChanges(const std::vector<std::wstring>& changed,
                                                    int64_t observedAt = 0);
    /// Re-apply fonts and line heights to every open buffer.
    void reapplyDisplaySettings();
    /// Discard every clean, regenerable buffer not on screen.
    void releaseTransientMemory();

private:
    void touch(const std::wstring& url);
    void evictIfNeeded(const std::wstring* protectedURL = nullptr);
    void releaseUnowned(const std::wstring& url);
    void drop(const std::wstring& url);
    bool isRegenerable(const std::wstring& url) const;
    void evictUnusedGrammars();

    std::map<std::wstring, std::unique_ptr<Document>> docs_;
    std::map<std::wstring, std::set<const void*>> owners_;
    /// Least-recently-used first.
    std::vector<std::wstring> order_;
};

/// What a save needs from the pane that asked for it.
struct DocumentSaveHost {
    virtual ~DocumentSaveHost() = default;
    virtual void presentSaveError(const std::wstring& message) = 0;
    virtual void documentDidPersist(Document& document, const std::wstring& writtenTo) = 0;
    virtual void documentDidReloadFromDisk(Document& document) = 0;
    /// The window conflict questions are asked over.
    virtual HWND saveDialogOwner() = 0;
};

class DocumentSaveCoordinator {
public:
    enum class Reason {
        /// Ctrl+S: the user is watching; a change on disk is a question and a
        /// failure is an alert.
        Explicit,
        /// Leaving the buffer, or the typing stopping. Silent by design.
        Leaving,
        /// Closing a tab, a window or the app. Silent first, then it may ask.
        Closing,
    };
    DocumentSaveHost* host = nullptr;
    /// False only when the user was asked and said no.
    bool save(Document& document, Reason reason);

private:
    struct Policy {
        bool overwritesDiskChanges;
        bool mayInterrupt;
        bool notifies;
    };
    bool write(Document& document, const Policy& policy);
    enum class Choice { Overwrite, Reload, Cancel };
    Choice askAboutDiskConflict(Document& document);
};

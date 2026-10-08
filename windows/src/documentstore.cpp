#include "documentstore.h"

#include "dialog.h"
#include "gitservice.h"
#include "highlight.h"
#include "notify.h"

DocumentStore& DocumentStore::shared() {
    static DocumentStore* store = new DocumentStore();
    return *store;
}

Document* DocumentStore::cachedDocument(const std::wstring& url) const {
    auto hit = docs_.find(url);
    return hit == docs_.end() ? nullptr : hit->second.get();
}

size_t DocumentStore::cachedBytes() const {
    size_t total = 0;
    for (auto& [url, doc] : docs_) total += doc->estimatedMemoryCost();
    return total;
}

void DocumentStore::touch(const std::wstring& url) {
    order_.erase(std::remove(order_.begin(), order_.end(), url), order_.end());
    order_.push_back(url);
}

bool DocumentStore::isRegenerable(const std::wstring& url) const {
    return DiffURL::is(url) && (bool)virtualContentProvider;
}

void DocumentStore::evictUnusedGrammars() {
    std::set<std::string> needed;
    for (auto& [url, doc] : docs_) {
        if (doc->languageSpec()) needed.insert(doc->languageSpec()->name);
    }
    HighlightService::evictUnused(needed);
}

void DocumentStore::drop(const std::wstring& url) {
    auto hit = docs_.find(url);
    if (hit == docs_.end()) return;
    HighlightService::documentWillClose(*hit->second);
    docs_.erase(hit);
}

Document& DocumentStore::document(const std::wstring& url) {
    if (Document* existing = cachedDocument(url)) {
        touch(url);
        return *existing;
    }
    // A released diff tab is rebuilt from what its URL names, off the main
    // thread: the buffer comes back at once and fills itself in.
    if (DiffURL::is(url)) {
        std::wstring name = L"diff";
        if (auto parts = DiffURL::parse(url)) name = lastPathComponent(W(parts->path));
        if (!virtualContentProvider) return setVirtualDocument(url, "No diff available.\n", name + L" (diff)");
        Document& placeholder = setVirtualDocument(url, "Rebuilding this diff…\n", name + L" (diff)");
        int generation = placeholder.contentReplacements();
        auto provider = virtualContentProvider;
        Git::workQueue().async([this, url, provider, generation] {
            auto content = provider(url);
            Dispatch::main([this, url, content, generation] {
                Document* doc = cachedDocument(url);
                if (!doc || doc->contentReplacements() != generation) return;
                doc->replaceVirtualContent(content ? content->text : "No diff available.\n",
                                           content ? content->displayName : std::nullopt);
                doc->svgDiffSides = content ? content->svgSides : std::nullopt;
                HighlightService::highlight(*doc);
            });
        });
        return placeholder;
    }
    auto made = std::make_unique<Document>(url);
    Document& doc = *made;
    docs_[url] = std::move(made);
    touch(url);
    HighlightService::highlight(doc);
    // The caller has not attached its view yet: protect this one.
    evictIfNeeded(&url);
    return doc;
}

Document& DocumentStore::setVirtualDocument(const std::wstring& url, const std::string& text,
                                            const std::optional<std::wstring>& displayName) {
    if (Document* existing = cachedDocument(url); existing && existing->isVirtual()) {
        existing->replaceVirtualContent(text, displayName);
        touch(url);
        HighlightService::highlight(*existing);
        return *existing;
    }
    auto made = std::make_unique<Document>(url, text, displayName.value_or(lastPathComponent(url)));
    Document& doc = *made;
    docs_[url] = std::move(made);
    touch(url);
    HighlightService::highlight(doc);
    evictIfNeeded(&url);
    return doc;
}

void DocumentStore::evictIfNeeded(const std::wstring* protectedURL) {
    auto over = [&] { return docs_.size() > maxCachedDocuments || cachedBytes() > maxCachedBytes; };
    if (!over()) return;
    // Never evicted: modified documents, virtual ones that cannot be rebuilt,
    // and anything a view is showing.
    std::vector<std::wstring> snapshot = order_;
    for (auto& url : snapshot) {
        if (!over()) break;
        if (protectedURL && url == *protectedURL) continue;
        Document* doc = cachedDocument(url);
        if (!doc || doc->isModified) continue;
        if (doc->isVirtual() && !isRegenerable(url)) continue;
        if (doc->attachedViews > 0) continue;
        drop(url);
    }
    order_.erase(std::remove_if(order_.begin(), order_.end(), [&](const std::wstring& u) { return !docs_.count(u); }),
                 order_.end());
    evictUnusedGrammars();
}

void DocumentStore::registerOpen(const std::wstring& url, const void* owner) { owners_[url].insert(owner); }

void DocumentStore::unregisterOpen(const std::wstring& url, const void* owner) {
    auto hit = owners_.find(url);
    if (hit != owners_.end()) {
        hit->second.erase(owner);
        if (hit->second.empty()) owners_.erase(hit);
    }
    if (owners_.count(url)) return;
    releaseUnowned(url);
}

void DocumentStore::releaseUnowned(const std::wstring& url) {
    Document* doc = cachedDocument(url);
    if (doc && doc->attachedViews > 0) return;
    drop(url);
    order_.erase(std::remove(order_.begin(), order_.end(), url), order_.end());
    evictUnusedGrammars();
}

std::vector<std::pair<std::wstring, std::string>> DocumentStore::modifiedTextSnapshots(
    const std::wstring& directory) const {
    std::wstring root = lowercased(directory);
    if (!endsWith(root, L"\\")) root += L"\\";
    std::vector<std::pair<std::wstring, std::string>> out;
    for (auto& [url, doc] : docs_) {
        if (!doc->isModified || doc->isReadOnly() || DiffURL::is(url)) continue;
        if (!startsWith(lowercased(url), root)) continue;
        out.emplace_back(url, doc->text());
    }
    return out;
}

std::vector<std::wstring> DocumentStore::reloadExternalChanges(const std::vector<std::wstring>& changed,
                                                              int64_t observedAt) {
    std::vector<std::wstring> reloaded;
    if (changed.empty()) return reloaded;
    std::vector<std::wstring> changes;
    for (auto& c : changed) changes.push_back(lowercased(c));
    std::vector<Document*> candidates;
    for (auto& [url, doc] : docs_) candidates.push_back(doc.get());
    for (Document* document : candidates) {
        if (document->isVirtual()) continue;
        std::wstring file = lowercased(document->url);
        std::wstring parent = deletingLastPathComponent(file);
        bool affected = false;
        for (auto& change : changes) {
            std::wstring prefix = endsWith(change, L"\\") ? change : change + L"\\";
            if (change == file || change == parent || deletingLastPathComponent(change) == parent
                || startsWith(file, prefix)) {
                affected = true;
                break;
            }
        }
        if (!affected || !document->reloadFromDiskIfLatest(observedAt)) continue;
        HighlightService::highlight(*document);
        Notifications::post(Notice::DocumentDidReloadFromDisk, document);
        reloaded.push_back(document->url);
    }
    return reloaded;
}

void DocumentStore::reapplyDisplaySettings() {
    std::vector<Document*> all;
    for (auto& [url, doc] : docs_) all.push_back(doc.get());
    for (Document* doc : all) HighlightService::highlight(*doc);
}

void DocumentStore::releaseTransientMemory() {
    std::vector<std::wstring> doomed;
    for (auto& [url, doc] : docs_) {
        if (doc->isModified || doc->attachedViews > 0) continue;
        if (doc->isVirtual() && !isRegenerable(url)) continue;
        doomed.push_back(url);
    }
    for (auto& url : doomed) drop(url);
    order_.erase(std::remove_if(order_.begin(), order_.end(), [&](const std::wstring& u) { return !docs_.count(u); }),
                 order_.end());
    HighlightService::discardParseTrees();
    evictUnusedGrammars();
}

// ── Saving ─────────────────────────────────────────────────────────────────

bool DocumentSaveCoordinator::save(Document& document, Reason reason) {
    switch (reason) {
    case Reason::Explicit:
        return write(document, {true, true, true});
    case Reason::Leaving:
        return write(document, {false, false, true});
    case Reason::Closing:
        // The silent pass first: the common close has nothing to ask about.
        if (write(document, {false, false, true})) return true;
        return write(document, {false, true, true});
    }
    return true;
}

bool DocumentSaveCoordinator::write(Document& document, const Policy& policy) {
    if (!document.isModified || document.isReadOnly()) return true;
    if (!policy.overwritesDiskChanges && (document.hasDiskConflict() || document.diskChangedSinceLastSync())) {
        if (!policy.mayInterrupt) return false;
        switch (askAboutDiskConflict(document)) {
        case Choice::Overwrite:
            document.resolveDiskConflict();
            break;
        case Choice::Reload:
            document.discardEditsAndReloadFromDisk();
            HighlightService::highlight(document);
            Notifications::post(Notice::DocumentDidReloadFromDisk, &document);
            if (host) host->documentDidReloadFromDisk(document);
            return true;
        case Choice::Cancel:
            return false;
        }
    }
    std::wstring error;
    if (document.save(&error)) {
        if (policy.notifies && host) host->documentDidPersist(document, document.url);
        return true;
    }
    if (policy.mayInterrupt && host) host->presentSaveError(error);
    return false;
}

DocumentSaveCoordinator::Choice DocumentSaveCoordinator::askAboutDiskConflict(Document& document) {
    Alert alert;
    alert.style = Alert::Style::Warning;
    alert.messageText = L"“" + document.name() + L"” changed on disk since you started editing";
    alert.informativeText = L"File:\n" + document.url + L"\n\n"
        L"Saving replaces the version on disk with what is in this editor. "
        L"Reloading replaces what is in this editor with the version on disk, "
        L"discarding your unsaved edits. Neither can be undone.";
    alert.buttons = {L"Save Anyway", L"Reload from Disk", L"Cancel"};
    switch (alert.runModal(host ? host->saveDialogOwner() : nullptr)) {
    case 0: return Choice::Overwrite;
    case 1: return Choice::Reload;
    default: return Choice::Cancel;
    }
}

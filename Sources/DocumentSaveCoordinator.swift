import AppKit

/// What a save needs from the pane that asked for it.
protocol DocumentSaveHost: AnyObject {
    /// Errors go up the responder chain, so the window holding the buffer is
    /// the one that shows them.
    func presentSaveError(_ error: Error)
    /// A write landed. `url` is the file that changed on disk, which for an
    /// edited diff is the file the diff describes rather than the diff buffer.
    func documentDidPersist(_ document: Document, writtenTo url: URL)
    /// The user answered a conflict by taking the version on disk instead.
    func documentDidReloadFromDisk(_ document: Document)
}

/// Where the decision to write a buffer lives.
///
/// Six ways in — ⌘S, leaving the buffer, the typing stopping, closing a tab,
/// closing a window, quitting the app — and they differ in exactly two ways:
/// whether anyone is looking, and whether the user has just chosen this buffer
/// over the version on disk. Everything else about writing is the same, so it
/// is written here once rather than at each door.
///
/// That is not tidiness. Each door used to carry its own copy of the rules, and
/// the copies fell out of step: quitting never ran them at all, and the diff
/// write-back grew a second set. A door added later — a timer, a crash
/// handler, a new menu item — should inherit the policy by naming its reason,
/// not by remembering the details.
final class DocumentSaveCoordinator {

    /// How the caller got here. The only input the policy takes.
    enum Reason {
        /// ⌘S. The user picked this buffer and is watching, so a change on disk
        /// is a question to put to them and a failure is an alert.
        case explicit
        /// Leaving the buffer — another tab, another window, another app — or
        /// the typing stopping. Silent by design: a write that cannot go
        /// through leaves the document dirty and says nothing, because the
        /// person it would ask has already looked away.
        case leaving
        /// Closing a tab, a window, or the app. Tries silently first; only a
        /// write that cannot go through on its own is worth stopping for, and
        /// closing without asking would drop one of the two versions for good.
        case closing
        /// The regression suite: never draws, never notifies.
        case test
    }

    private struct Policy {
        /// ⌘S means "this buffer, the one I am looking at". Every other door
        /// defers to the version on disk instead of overwriting it silently.
        let overwritesDiskChanges: Bool
        let mayInterrupt: Bool
        let notifies: Bool
    }

    weak var host: DocumentSaveHost?

    /// Returns false only when the user was asked and said no, which is what
    /// keeps a tab — or a window, or the app — from closing.
    @discardableResult
    func save(_ document: Document, because reason: Reason) -> Bool {
        switch reason {
        case .explicit:
            return write(document, Policy(overwritesDiskChanges: true,
                                          mayInterrupt: true, notifies: true))
        case .leaving:
            return write(document, Policy(overwritesDiskChanges: false,
                                          mayInterrupt: false, notifies: true))
        case .closing:
            // The silent pass first: the common close has nothing to ask about,
            // and asking anyway is the "Save changes?" sheet this editor does
            // not have.
            let quiet = Policy(overwritesDiskChanges: false,
                               mayInterrupt: false, notifies: true)
            if write(document, quiet) { return true }
            return write(document, Policy(overwritesDiskChanges: false,
                                          mayInterrupt: true, notifies: true))
        case .test:
            return write(document, Policy(overwritesDiskChanges: false,
                                          mayInterrupt: false, notifies: false))
        }
    }

    private func write(_ document: Document, _ policy: Policy) -> Bool {
        guard document.isModified, !document.isReadOnly else { return true }
        if document.editableDiff != nil {
            return applyEditedDiff(document, policy)
        }
        if !policy.overwritesDiskChanges,
           document.hasDiskConflict || document.diskChangedSinceLastSync {
            guard policy.mayInterrupt else { return false }
            switch askAboutDiskConflict(for: document) {
            case .overwrite: document.resolveDiskConflict()
            case .reload:
                document.discardEditsAndReloadFromDisk()
                host?.documentDidReloadFromDisk(document)
                return true
            case .cancel: return false
            }
        }
        do {
            try document.save()
            if policy.notifies {
                host?.documentDidPersist(document, writtenTo: document.url)
            }
            return true
        } catch {
            if policy.mayInterrupt { host?.presentSaveError(error) }
            return false
        }
    }

    // MARK: - Edited diffs

    /// Write an edited diff back into the file it describes.
    ///
    /// The diff is replayed over the pre-image it was taken against rather than
    /// merged into the file as it stands: the new side of the diff *is* the
    /// file the user is asking for, and everything the diff does not mention is
    /// carried through from the pre-image untouched.
    private func applyEditedDiff(_ document: Document, _ policy: Policy) -> Bool {
        guard let source = document.editableDiff else { return true }
        let diff = document.text
        let file = source.directory.appendingPathComponent(source.path)
        // Replaying a diff writes the whole file: everything the diff does not
        // mention comes from the pre-image, so a version that arrived on disk
        // since the diff was taken would be erased without trace. That is the
        // same question a buffer asks, and it gets the same answer — the silent
        // doors refuse, and only someone who is looking may overrule it.
        if let taken = source.sourceModified,
           let current = Document.modificationDate(for: file), current != taken {
            guard policy.mayInterrupt, askAboutChangedDiffSource(source.path) else {
                return false
            }
        }
        guard let preimage = GitService.diffPreimage(diff, path: source.path,
                                                     in: source.directory) else {
            report("Git could not produce the version of \(source.path) this diff "
                     + "was taken against, so there is nothing to replay it over. "
                     + "Edit the file itself instead.", policy)
            return false
        }
        guard let updated = UnifiedDiff.apply(diff, to: preimage) else {
            report("The hunks no longer line up with \(source.path). Check that "
                     + "each @@ header still sits above the lines it describes, or "
                     + "close this tab and edit the file itself.", policy)
            return false
        }
        // Through the open buffer when there is one, so the file's own tab,
        // its gutter marks and its undo stack all see the change arrive.
        let store = DocumentStore.shared
        do {
            if let open = store.cachedDocument(for: file) {
                open.storage.replaceCharacters(
                    in: NSRange(location: 0, length: open.storage.length), with: updated)
                try open.save()
            } else {
                try Data(updated.utf8).write(to: file, options: .atomic)
            }
        } catch {
            if policy.mayInterrupt { host?.presentSaveError(error) }
            return false
        }
        document.markSaved()
        document.diffSourceWasWritten()
        if policy.notifies { host?.documentDidPersist(document, writtenTo: file) }
        return true
    }

    private func askAboutChangedDiffSource(_ path: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(path)” changed since this diff was taken"
        alert.informativeText =
            "Saving this diff rewrites the whole file from the version it "
            + "describes, which would discard whatever was written to it since. "
            + "Close this tab and open the file itself to keep both."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Replace the File")
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func report(_ detail: String, _ policy: Policy) {
        guard policy.mayInterrupt else { return }
        let alert = NSAlert()
        alert.messageText = "Cannot apply this diff"
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Conflicts

    private enum DiskConflictChoice { case overwrite, reload, cancel }

    private func askAboutDiskConflict(for document: Document) -> DiskConflictChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(document.name)” changed on disk since you started editing"
        alert.informativeText = "File:\n\(document.url.path)\n\n"
            + "Saving replaces the version on disk with what is in this editor. "
            + "Reloading replaces what is in this editor with the version on disk, "
            + "discarding your unsaved edits. Neither can be undone."
        alert.addButton(withTitle: "Save Anyway")
        alert.addButton(withTitle: "Reload from Disk")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .overwrite
        case .alertSecondButtonReturn: return .reload
        default: return .cancel
        }
    }
}

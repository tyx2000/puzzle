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

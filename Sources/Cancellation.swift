import Foundation

/// Cooperative cancellation, the way every editor does it: the worker checks
/// the token at its own loop boundaries and returns, and anything external it
/// owns — a subprocess, most of the time — is torn down through a handler.
/// Nothing is ever killed from the outside.
///
/// A generation counter checked when the result arrives is not cancellation: it
/// throws away work that has already been done. This stops the work.
final class CancellationToken {
    /// For call sites that have nothing to cancel — tests, and the synchronous
    /// paths that run to completion by definition.
    static let none = CancellationToken(neverCancels: true)

    /// The shared `none` lives for the life of the process, so a handler
    /// registered on it would never be released and never be called. It takes
    /// none rather than collecting them.
    private let neverCancels: Bool
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [() -> Void] = []

    init(neverCancels: Bool = false) { self.neverCancels = neverCancels }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        guard !neverCancels else { return }
        lock.lock()
        let alreadyCancelled = cancelled
        cancelled = true
        let pending = handlers
        handlers = []
        lock.unlock()
        guard !alreadyCancelled else { return }
        pending.forEach { $0() }
    }

    /// Run `handler` when the token is cancelled — or right now if it already
    /// has been, so a process started after the cancel does not outlive it.
    func whenCancelled(_ handler: @escaping () -> Void) {
        guard !neverCancels else { return }
        lock.lock()
        if cancelled {
            lock.unlock()
            handler()
            return
        }
        handlers.append(handler)
        lock.unlock()
    }
}

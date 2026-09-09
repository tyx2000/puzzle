import Foundation

/// Waits for a subprocess to exit without running a run loop.
///
/// `Process.waitUntilExit()` spins a CFRunLoop on the calling thread. On a
/// dispatch queue that is not a harmless implementation detail: dispatch worker
/// threads are pooled and shared, so a timer or `performSelector:afterDelay:`
/// that some other framework left on that thread — normally dormant, because
/// nothing ever runs the run loop there — gets its chance to fire in the middle
/// of a Git call, on a background thread.
///
/// That is how Puzzle died: PDFKit had left a coalesced annotations-changed
/// notification on a pooled thread, `git status` picked the same thread up and
/// ran the run loop inside `waitUntilExit()`, and the notification drove
/// `NSCollectionView.reloadItems` → `addSubview:` → the Auto Layout engine off
/// the main thread. AppKit threw, and an Objective-C exception crossing Swift
/// frames is an abort, not an error.
///
/// The latch has to be built before `run()`: a termination handler installed
/// after the process has already exited may never be called.
final class ProcessExitLatch {
    private let exited = DispatchSemaphore(value: 0)

    init(_ process: Process) {
        process.terminationHandler = { [exited] _ in exited.signal() }
    }

    func wait() { exited.wait() }

    /// False when the process was still running when the time ran out.
    func wait(seconds: TimeInterval) -> Bool {
        exited.wait(timeout: .now() + seconds) == .success
    }
}

import CoreServices
import Foundation

/// Watches ordinary project files and says only that something changed: the
/// answer is always the same, a fresh `git status` for the whole project, so
/// the paths are never read and are not carried.
///
/// Events are coalesced so an atomic save (temporary file + rename) is
/// observed as one final state rather than a sequence of incomplete ones.
final class WorkspaceFileMonitor {
    private var stream: FSEventStreamRef?
    private var pendingDelivery: DispatchWorkItem?
    /// When the burst now waiting to be delivered began.
    private var pendingSince: Date?
    private var onChange: (() -> Void)?
    private var stopped = false

    /// How long the tree has to be quiet before a burst is delivered.
    static let quietWindow: TimeInterval = 0.10
    /// …and how long a burst may hold delivery back. Without this, a build
    /// writing a file every few milliseconds pushed the refresh out for as
    /// long as it ran, and the changes list sat still through all of it.
    static let maximumDelay: TimeInterval = 1.0

    init(directory: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange
        start(path: directory.standardizedFileURL.path)
    }

    private func start(path: String) {
        guard !stopped else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil)
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagUseCFTypes)
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            workspaceFileEventCallback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.08,
            flags) else { return }

        stream = created
        FSEventStreamSetDispatchQueue(created, .main)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            stream = nil
            return
        }
    }

    deinit { stop() }

    func stop() {
        stopped = true
        pendingDelivery?.cancel()
        pendingDelivery = nil
        pendingSince = nil
        onChange = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Something under the project changed. Called on the main queue, from
    /// the stream and from tests.
    func noteChange() {
        guard !stopped else { return }
        let now = Date()
        let since = pendingSince ?? now
        pendingSince = since
        // Settle after the last event, but never past the burst's deadline.
        let delay = min(Self.quietWindow,
                        max(0, Self.maximumDelay - now.timeIntervalSince(since)))
        pendingDelivery?.cancel()
        let delivery = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.pendingSince = nil
            self.onChange?()
        }
        pendingDelivery = delivery
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: delivery)
    }
}

private let workspaceFileEventCallback: FSEventStreamCallback = {
    _, context, _, _, _, _ in
    guard let context else { return }
    // The paths are deliberately not read: every event means the same thing,
    // and turning thousands of them into strings was work for nobody.
    Unmanaged<WorkspaceFileMonitor>.fromOpaque(context)
        .takeUnretainedValue()
        .noteChange()
}

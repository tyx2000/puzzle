import CoreServices
import Foundation

/// Watches ordinary project files. Events are coalesced briefly so an atomic
/// save (temporary file + rename) is observed as one final state rather than a
/// sequence of incomplete intermediate states.
final class WorkspaceFileMonitor {
    private var stream: FSEventStreamRef?
    private var pendingDelivery: DispatchWorkItem?
    private var pendingPaths: Set<String> = []
    private var onChange: (([URL], Date) -> Void)?
    private var stopped = false

    init(directory: URL, onChange: @escaping ([URL], Date) -> Void) {
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
        pendingPaths.removeAll()
        onChange = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    fileprivate func filesChanged(paths: [String]) {
        guard !stopped else { return }
        pendingPaths.formUnion(paths)
        pendingDelivery?.cancel()
        let delivery = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            let urls = self.pendingPaths.map { URL(fileURLWithPath: $0) }
            self.pendingPaths.removeAll(keepingCapacity: true)
            self.onChange?(urls, Date())
        }
        pendingDelivery = delivery
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: delivery)
    }
}

private let workspaceFileEventCallback: FSEventStreamCallback = {
    _, context, count, paths, _, _ in
    guard let context else { return }
    let raw = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
    let changed = (0..<count).compactMap { raw[Int($0)] as? String }
    Unmanaged<WorkspaceFileMonitor>.fromOpaque(context)
        .takeUnretainedValue()
        .filesChanged(paths: changed)
}

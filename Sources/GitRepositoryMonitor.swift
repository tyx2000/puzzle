import CoreServices
import Foundation

/// Watches Git's private metadata rather than the whole project tree. External
/// commit, push, fetch, checkout, branch and index operations all update this
/// area, while ordinary compiler/build output does not continuously wake the
/// Git panel.
final class GitRepositoryMonitor {
    private static let resolutionQueue = DispatchQueue(
        label: "app.puzzle.git-monitor-resolution", qos: .utility)
    private var stream: FSEventStreamRef?
    private var pendingDelivery: DispatchWorkItem?
    private var onChange: (() -> Void)?
    private var stopped = false
    private(set) var isMonitoring = false

    init(directory: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange
        Self.resolutionQueue.async { [weak self] in
            let paths = Self.metadataDirectories(in: directory).map(\.path)
            DispatchQueue.main.async { [weak self] in self?.start(paths: paths) }
        }
    }

    private func start(paths: [String]) {
        guard !stopped else { return }
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil)
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            gitRepositoryEventCallback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.15,
            flags) else { return }

        stream = created
        FSEventStreamSetDispatchQueue(created, .main)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            stream = nil
            return
        }
        isMonitoring = true
    }

    deinit { stop() }

    func stop() {
        stopped = true
        isMonitoring = false
        pendingDelivery?.cancel()
        pendingDelivery = nil
        onChange = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// `--git-dir` differs from `--git-common-dir` for linked worktrees. Watch
    /// both so HEAD/index changes and shared refs/remotes changes are covered.
    static func metadataDirectories(in directory: URL) -> [URL] {
        let inside = GitService.run(["rev-parse", "--is-inside-work-tree"], in: directory)
        guard inside.code == 0,
              inside.out.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            return []
        }

        var result: [URL] = []
        var seen: Set<String> = []
        for option in ["--git-dir", "--git-common-dir"] {
            guard let url = metadataDirectory(option, in: directory) else { continue }
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            guard seen.insert(canonical.path).inserted else { continue }
            result.append(canonical)
        }
        return result
    }

    private static func metadataDirectory(_ option: String, in directory: URL) -> URL? {
        var result = GitService.run(["rev-parse", "--path-format=absolute", option],
                                    in: directory)
        if result.code != 0 {
            result = GitService.run(["rev-parse", option], in: directory)
        }
        guard result.code == 0 else { return nil }
        let path = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path, isDirectory: true) }
        return directory.appendingPathComponent(path, isDirectory: true)
    }

    fileprivate func repositoryMetadataChanged() {
        pendingDelivery?.cancel()
        let delivery = DispatchWorkItem { [weak self] in self?.onChange?() }
        pendingDelivery = delivery
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: delivery)
    }
}

private let gitRepositoryEventCallback: FSEventStreamCallback = {
    _, context, _, _, _, _ in
    guard let context else { return }
    Unmanaged<GitRepositoryMonitor>.fromOpaque(context)
        .takeUnretainedValue()
        .repositoryMetadataChanged()
}

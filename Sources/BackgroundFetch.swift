import Foundation

/// Brings a project's picture of its remotes up to date when it comes on
/// screen — opened, or switched to — and at no other time.
///
/// `git fetch`, never `pull`: the remote-tracking branches move, while the
/// branch that is checked out and the files in the working tree do not, so it
/// is safe to run without asking. Bringing the remote's commits into the
/// branch stays the user's to ask for.
enum BackgroundFetch {
    /// A queue of its own. A fetch waits on the network, and must not sit in
    /// front of a commit or a push on `GitService.operationQueue`, nor in front
    /// of the short reads on `GitService.workQueue`.
    static let queue = DispatchQueue(label: "app.puzzle.git-fetch", qos: .utility)
    /// Switching away from a project and straight back does not fetch it again.
    static var minimumInterval: TimeInterval = 120
    /// Long enough for a slow remote, short enough that a stalled one lets go.
    static var timeout: TimeInterval = 60

    /// When each project last had a fetch started. Main thread only.
    private static var lastStarted: [URL: Date] = [:]
    /// Projects with a fetch queued or running. Main thread only. The queue
    /// runs one fetch at a time, so a project can wait behind another's slow
    /// remote for up to `timeout`; it is not queued a second time meanwhile.
    private static var outstanding: Set<URL> = []

    /// Fetch every remote of `directory`, unless it was fetched a moment ago
    /// or a fetch of it is already queued.
    ///
    /// Returns true when a fetch was queued. From then until `finished` runs,
    /// the project's remote-tracking branches may move under anything else
    /// run in it: a fetch waiting its turn is as much "out" as one running.
    ///
    /// `started` runs on the main thread when the fetch actually starts, and
    /// only for one that does — a folder with no remote shows nothing
    /// happening, because nothing does. `finished` runs on the main thread
    /// exactly once for every queued fetch, after `started` when there was
    /// one. It says whether the fetch moved a remote-tracking branch: one that
    /// brought nothing, or found no remote, costs no re-read. A failure —
    /// offline, a remote that wants a password — is only `false`; the next
    /// time the project comes on screen tries again.
    @discardableResult
    static func fetchIfDue(_ directory: URL, now: Date = Date(),
                           started: @escaping () -> Void = {},
                           finished: @escaping (_ refsMoved: Bool) -> Void) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !outstanding.contains(directory) else { return false }
        if let last = lastStarted[directory], now.timeIntervalSince(last) < minimumInterval {
            return false
        }
        lastStarted[directory] = now
        outstanding.insert(directory)
        let finish: (Bool) -> Void = { moved in
            DispatchQueue.main.async {
                outstanding.remove(directory)
                finished(moved)
            }
        }
        queue.async {
            // A folder with no remote, or no repository, has nothing to fetch.
            let remotes = GitService.run(["remote"], in: directory)
            guard remotes.code == 0,
                  !remotes.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                finish(false)
                return
            }
            // Its turn in the repository first: a pull, a push or a branch
            // delete there — from any window, or the Git panel — waits for
            // this fetch, and this fetch for one of them, rather than either
            // failing on Git's ref locks. Said to have started only once it
            // has the repository, so whatever waits on `started` knows the
            // others are held off.
            let moved = GitService.exclusively(in: directory) { () -> Bool in
                DispatchQueue.main.async {
                    fetchedForTesting.append(directory)
                    started()
                }
                if delayForTesting > 0 { Thread.sleep(forTimeInterval: delayForTesting) }
                let before = remoteRefs(in: directory)
                let fetched = GitService.run(["fetch", "--all", "--prune", "--quiet"],
                                             in: directory, timeout: timeout)
                return fetched.code == 0 && remoteRefs(in: directory) != before
            }
            finish(moved)
        }
        return true
    }

    /// Every remote-tracking branch and the commit it names.
    private static func remoteRefs(in directory: URL) -> String {
        GitService.run(["for-each-ref", "--format=%(refname) %(objectname)", "refs/remotes"],
                       in: directory).out
    }

    // MARK: - Regression-test surface

    /// Holds each fetch back, so a test can act while one is still out. The
    /// fetch holds its repository meanwhile, as a slow remote would.
    static var delayForTesting: TimeInterval = 0
    /// Every directory a fetch was run in, in order.
    private(set) static var fetchedForTesting: [URL] = []
    /// Forget every fetch, so a test starts as a fresh launch would.
    static func resetForTesting() {
        lastStarted = [:]
        fetchedForTesting = []
        delayForTesting = 0
    }
}

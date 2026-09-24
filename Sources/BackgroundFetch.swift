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

    /// Fetch every remote of `directory`, unless it was fetched a moment ago.
    ///
    /// `started` and `finished` run on the main thread, in that order, and
    /// only for a fetch that actually runs — a folder with no remote shows
    /// nothing happening, because nothing does. `finished` says whether the
    /// fetch moved a remote-tracking branch: one that brought nothing costs no
    /// re-read. A failure — offline, a remote that wants a password — is only
    /// `false`; the next time the project comes on screen tries again.
    static func fetchIfDue(_ directory: URL, now: Date = Date(),
                           started: @escaping () -> Void = {},
                           finished: @escaping (_ refsMoved: Bool) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let last = lastStarted[directory], now.timeIntervalSince(last) < minimumInterval {
            return
        }
        lastStarted[directory] = now
        queue.async {
            // A folder with no remote, or no repository, has nothing to fetch.
            let remotes = GitService.run(["remote"], in: directory)
            guard remotes.code == 0,
                  !remotes.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            DispatchQueue.main.async {
                fetchedForTesting.append(directory)
                started()
            }
            if delayForTesting > 0 { Thread.sleep(forTimeInterval: delayForTesting) }
            let before = remoteRefs(in: directory)
            let fetched = GitService.run(["fetch", "--all", "--prune", "--quiet"],
                                         in: directory, timeout: timeout)
            let moved = fetched.code == 0 && remoteRefs(in: directory) != before
            DispatchQueue.main.async { finished(moved) }
        }
    }

    /// Every remote-tracking branch and the commit it names.
    private static func remoteRefs(in directory: URL) -> String {
        GitService.run(["for-each-ref", "--format=%(refname) %(objectname)", "refs/remotes"],
                       in: directory).out
    }

    // MARK: - Regression-test surface

    /// Holds each fetch back, so a test can act while one is still out.
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

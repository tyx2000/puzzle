import Foundation

/// Thin wrapper over the `git` CLI, run in the project directory.
enum GitService {
    struct Status {
        struct Entry {
            let code: String     // raw two-char porcelain code
            let path: String
            var indexStatus: Character { code.first ?? " " }
            var worktreeStatus: Character { code.count > 1 ? Array(code)[1] : " " }
            var isStaged: Bool { indexStatus != " " && indexStatus != "?" }
            var isUntracked: Bool { code == "??" }
            var displayCode: String {
                if isUntracked { return "U" }
                let c = worktreeStatus != " " ? worktreeStatus : indexStatus
                return String(c)
            }
        }
        var branch: String
        var entries: [Entry]
        var isRepo: Bool
        /// Commits on this branch that the upstream doesn't have yet.
        var ahead: Int = 0
        /// False when the branch tracks nothing — then "unpushed" is meaningless.
        var hasUpstream: Bool = false
    }

    struct Commit {
        let shortHash: String
        let subject: String
        let author: String
        /// Full timestamp, shown below the commit subject in History.
        let absoluteDate: String
        let email: String

        /// Blame summary shown as the commit record's secondary line.
        var blameSummary: String { "\(author)  ·  \(absoluteDate)" }
    }

    @discardableResult
    static func run(_ args: [String], in directory: URL) -> (out: String, err: String, code: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = directory

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return ("", "\(error)", -1)
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: outData, as: UTF8.self),
                String(decoding: errData, as: UTF8.self),
                process.terminationStatus)
    }

    /// Raw bytes from a git command. `run` decodes to String, which mangles
    /// binary payloads — image blobs must come back as Data.
    static func runData(_ args: [String], in directory: URL) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = directory
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    /// A file's contents as of a commit (`git show <hash>:<path>`).
    static func blob(inCommit hash: String, path: String, in directory: URL) -> Data? {
        runData(["--no-pager", "show", "\(hash):\(path)"], in: directory)
    }

    static func status(in directory: URL) -> Status {
        let inside = run(["rev-parse", "--is-inside-work-tree"], in: directory)
        guard inside.code == 0, inside.out.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            return Status(branch: "", entries: [], isRepo: false)
        }
        let branchResult = run(["rev-parse", "--abbrev-ref", "HEAD"], in: directory)
        let branch = branchResult.out.trimmingCharacters(in: .whitespacesAndNewlines)

        // `--untracked-files=all` lists individual files instead of collapsing
        // whole untracked directories into one entry (matches Zed's panel).
        let statusResult = run(["status", "--porcelain", "--untracked-files=all"], in: directory)
        var entries: [Status.Entry] = []
        for line in statusResult.out.split(separator: "\n", omittingEmptySubsequences: true) {
            let raw = String(line)
            guard raw.count > 3 else { continue }
            let code = String(raw.prefix(2))
            var path = String(raw.dropFirst(3))
            // Renames come through as "old -> new"; keep the new path.
            if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
            entries.append(Status.Entry(code: code, path: path))
        }
        let (ahead, hasUpstream) = aheadCount(in: directory)
        return Status(branch: branch.isEmpty ? "detached" : branch, entries: entries,
                      isRepo: true, ahead: ahead, hasUpstream: hasUpstream)
    }

    /// How many commits are ahead of the tracking branch, and whether there is
    /// one at all. A branch with no upstream returns `(0, false)`: nothing has
    /// been pushed anywhere, so calling every commit "unpushed" would be noise.
    static func aheadCount(in directory: URL) -> (ahead: Int, hasUpstream: Bool) {
        let upstream = run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
                           in: directory)
        guard upstream.code == 0 else { return (0, false) }
        let counted = run(["rev-list", "--count", "@{u}..HEAD"], in: directory)
        guard counted.code == 0,
              let n = Int(counted.out.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return (0, true)
        }
        return (n, true)
    }

    /// Short hashes of commits not yet on the upstream branch.
    static func unpushedHashes(in directory: URL) -> Set<String> {
        let upstream = run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
                           in: directory)
        guard upstream.code == 0 else { return [] }
        let result = run(["--no-pager", "rev-list", "--abbrev-commit", "@{u}..HEAD"],
                         in: directory)
        guard result.code == 0 else { return [] }
        return Set(result.out.split(separator: "\n", omittingEmptySubsequences: true)
                     .map { $0.trimmingCharacters(in: .whitespaces) })
    }

    /// Result of a remote operation, for reporting success or failure.
    struct RemoteResult {
        let ok: Bool
        let message: String
    }

    private static func remote(_ args: [String], in directory: URL,
                               verb: String) -> RemoteResult {
        let result = run(args, in: directory)
        if result.code == 0 {
            let text = (result.out + result.err).trimmingCharacters(in: .whitespacesAndNewlines)
            return RemoteResult(ok: true, message: text.isEmpty ? "\(verb) succeeded." : text)
        }
        let text = result.err.isEmpty ? result.out : result.err
        return RemoteResult(ok: false, message: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func push(in directory: URL) -> RemoteResult {
        // A branch with no upstream needs one setting, or push fails with a
        // "no upstream" error that reads like a bug rather than a first push.
        if aheadCount(in: directory).hasUpstream {
            return remote(["push"], in: directory, verb: "Push")
        }
        let branch = run(["rev-parse", "--abbrev-ref", "HEAD"], in: directory)
            .out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty, branch != "HEAD" else {
            return RemoteResult(ok: false, message: "Detached HEAD — nothing to push.")
        }
        return remote(["push", "--set-upstream", "origin", branch], in: directory, verb: "Push")
    }

    static func fetch(in directory: URL) -> RemoteResult {
        remote(["fetch", "--all", "--prune"], in: directory, verb: "Fetch")
    }

    static func pull(in directory: URL) -> RemoteResult {
        remote(["pull", "--ff-only"], in: directory, verb: "Pull")
    }

    static func forcePush(in directory: URL) -> RemoteResult {
        // --force-with-lease refuses to clobber commits the remote gained since
        // the last fetch; plain --force would discard a colleague's work.
        remote(["push", "--force-with-lease"], in: directory, verb: "Force push")
    }

    /// Authorship of a single line, for the inline blame annotation.
    struct BlameLine {
        let author: String
        let date: String            // "2026-07-27 12:04"
        let summary: String         // commit subject
        let isUncommitted: Bool

        /// What the editor renders at the end of the line.
        var inlineText: String {
            isUncommitted ? "You · Uncommitted changes"
                          : "\(author) · \(date) · \(summary)"
        }
    }

    /// Blame one line of a file. `line` is 1-based.
    ///
    /// Uses `--porcelain` because the human-readable format's columns shift
    /// with name and date width, and it's the only form that reliably marks an
    /// uncommitted line (all-zero hash).
    static func blame(file: URL, line: Int, in directory: URL) -> BlameLine? {
        guard line > 0 else { return nil }
        let relative = file.path.hasPrefix(directory.path + "/")
            ? String(file.path.dropFirst(directory.path.count + 1))
            : file.path
        let result = run(["--no-pager", "blame", "--porcelain",
                          "-L", "\(line),\(line)", "--", relative], in: directory)
        guard result.code == 0, !result.out.isEmpty else { return nil }

        var author = "", summary = ""
        var timestamp: TimeInterval?
        var uncommitted = false
        for raw in result.out.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(raw)
            if text.hasPrefix("author ") {
                author = String(text.dropFirst(7))
            } else if text.hasPrefix("author-time ") {
                timestamp = TimeInterval(String(text.dropFirst(12)))
            } else if text.hasPrefix("summary ") {
                summary = String(text.dropFirst(8))
            }
            // A not-yet-committed line blames to the all-zero hash.
            if text.hasPrefix("00000000") { uncommitted = true }
        }
        guard !author.isEmpty || uncommitted else { return nil }

        var stamp = ""
        if let timestamp {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            stamp = formatter.string(from: Date(timeIntervalSince1970: timestamp))
        }
        return BlameLine(author: author.isEmpty ? "You" : author, date: stamp,
                         summary: summary, isUncommitted: uncommitted)
    }

    /// Recent commits for the History tab.
    static func log(in directory: URL, limit: Int = 40) -> [Commit] {
        // %h hash, %s subject, %an author, %ad date, %ae email
        let format = "%h\u{1}%s\u{1}%an\u{1}%ad\u{1}%ae"
        let result = run(["--no-pager", "log", "--pretty=format:" + format,
                          "--date=format:%Y-%m-%d %H:%M", "-n", "\(limit)"], in: directory)
        guard result.code == 0 else { return [] }
        return result.out.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let p = line.split(separator: "\u{1}", maxSplits: 4, omittingEmptySubsequences: false)
            guard p.count == 5 else { return nil }
            return Commit(shortHash: String(p[0]), subject: String(p[1]), author: String(p[2]),
                          absoluteDate: String(p[3]), email: String(p[4]))
        }
    }

    /// Unified diff for one path. Untracked files have no diff against the
    /// index, so they're rendered as an all-additions diff of the file itself.
    static func diff(for entry: Status.Entry, in directory: URL) -> String {
        if entry.isUntracked {
            let url = directory.appendingPathComponent(entry.path)
            guard let data = try? Data(contentsOf: url),
                  !data.prefix(8192).contains(0),
                  let text = String(data: data, encoding: .utf8) else {
                return "diff --git a/\(entry.path) b/\(entry.path)\n" +
                       "new file (binary or unreadable)\n"
            }
            var out = "diff --git a/\(entry.path) b/\(entry.path)\n"
            out += "new file\n--- /dev/null\n+++ b/\(entry.path)\n"
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let count = lines.last?.isEmpty == true ? lines.count - 1 : lines.count
            out += "@@ -0,0 +1,\(count) @@\n"
            for (i, line) in lines.enumerated() {
                if i == lines.count - 1 && line.isEmpty { break }
                out += "+\(line)\n"
            }
            return out
        }

        // Staged changes live in the index; unstaged in the worktree. Show
        // whichever this entry actually has (staged takes precedence).
        var args = ["--no-pager", "diff", "--no-color"]
        if entry.isStaged && entry.worktreeStatus == " " { args.append("--cached") }
        args += ["--", entry.path]
        let result = run(args, in: directory)
        let text = result.out
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // e.g. a staged-only change when we asked the worktree, or no change.
            let cached = run(["--no-pager", "diff", "--no-color", "--cached", "--", entry.path],
                             in: directory)
            return cached.out.isEmpty ? "No changes to show for \(entry.path)\n" : cached.out
        }
        return text
    }

    /// One file touched by a commit.
    struct CommitFile {
        let status: String      // A, M, D, R…
        let path: String
    }

    /// Files changed by a commit, for expanding a History row.
    static func files(inCommit hash: String, in directory: URL) -> [CommitFile] {
        // --format= suppresses the commit header so only the name-status list
        // remains; -m --first-parent makes merge commits list files too.
        let result = run(["--no-pager", "show", "--name-status", "--format=",
                          "-m", "--first-parent", hash], in: directory)
        guard result.code == 0 else { return [] }
        var seen = Set<String>()
        var out: [CommitFile] = []
        for line in result.out.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            // Renames come through as "R100 old new" — keep the new path.
            let path = String(parts[parts.count - 1])
            let status = String(parts[0].prefix(1))
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            out.append(CommitFile(status: status, path: path))
        }
        return out
    }

    /// Diff a single file as it changed in one commit.
    static func diff(inCommit hash: String, path: String, in directory: URL) -> String {
        let result = run(["--no-pager", "show", "--no-color", "-m", "--first-parent",
                          "--format=", hash, "--", path], in: directory)
        let text = result.out
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "No changes recorded for \(path) in \(hash).\n"
            : text
    }

    /// Relative paths of changed files, for marking the tree.
    static func dirtyPaths(in directory: URL) -> Set<String> {
        let s = status(in: directory)
        return Set(s.entries.map { $0.path })
    }

    /// Changed paths split by kind, for colouring the file tree the way git
    /// itself distinguishes them: new files read differently from edited ones.
    static func trackedAndUntracked(in directory: URL) -> (modified: Set<String>,
                                                           untracked: Set<String>) {
        let s = status(in: directory)
        var modified: Set<String> = []
        var untracked: Set<String> = []
        for entry in s.entries {
            if entry.isUntracked { untracked.insert(entry.path) }
            else { modified.insert(entry.path) }
        }
        return (modified, untracked)
    }
}

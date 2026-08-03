import Foundation

/// Thin wrapper over the `git` CLI, run in the project directory.
enum GitService {
    private final class PipeCapture: @unchecked Sendable {
        var data = Data()
        var truncated = false
    }

    struct ProcessResult {
        let stdout: Data
        let stderr: Data
        let code: Int32
        let stdoutTruncated: Bool
    }

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

    struct Branch {
        let name: String
        let author: String
        let createdAt: String
        let createdTimestamp: Int64
        let isCurrent: Bool
        let isRemote: Bool
        let upstreamRemote: String?
        let upstreamBranch: String?
    }

    struct Remote {
        let name: String
        let fetchURL: String
        let pushURL: String
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
        let result = runProcess(executable: URL(fileURLWithPath: "/usr/bin/env"),
                                arguments: ["git"] + args, in: directory)
        return (String(decoding: result.stdout, as: UTF8.self),
                String(decoding: result.stderr, as: UTF8.self),
                result.code)
    }

    /// Run a process while draining both output streams concurrently.
    ///
    /// Reading stdout to EOF before touching stderr can deadlock when the child
    /// fills stderr's finite pipe buffer. Git writes progress, hook output and
    /// remote diagnostics to stderr, so this is reachable during normal use.
    static func runProcess(executable: URL, arguments: [String],
                           in directory: URL, stdoutLimit: Int? = nil) -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return ProcessResult(stdout: Data(), stderr: Data("\(error)".utf8), code: -1,
                                 stdoutTruncated: false)
        }

        let stdout = PipeCapture()
        let stderr = PipeCapture()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = outPipe.fileHandleForReading.readData(ofLength: 64 * 1024)
                guard !chunk.isEmpty else { break }
                if let limit = stdoutLimit {
                    let remaining = max(0, limit - stdout.data.count)
                    if remaining > 0 { stdout.data.append(chunk.prefix(remaining)) }
                    if chunk.count > remaining { stdout.truncated = true }
                } else {
                    stdout.data.append(chunk)
                }
            }
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = errPipe.fileHandleForReading.readData(ofLength: 64 * 1024)
                guard !chunk.isEmpty else { break }
                let remaining = max(0, Self.maxProcessStderrBytes - stderr.data.count)
                if remaining > 0 { stderr.data.append(chunk.prefix(remaining)) }
                if chunk.count > remaining { stderr.truncated = true }
            }
            readers.leave()
        }
        process.waitUntilExit()
        readers.wait()
        return ProcessResult(stdout: stdout.data, stderr: stderr.data,
                             code: process.terminationStatus,
                             stdoutTruncated: stdout.truncated)
    }

    static let maxDiffBytes = 8 * 1024 * 1024
    static let maxBlobBytes = Document.maxImageFileBytes
    static let maxProcessStderrBytes = 1024 * 1024

    enum BlobResult {
        case data(Data)
        case tooLarge(Int)
        case unavailable(String)
    }

    /// Capture a bounded prefix while continuing to drain Git's pipe, so the
    /// child cannot block and a pathological diff cannot consume unbounded RAM.
    private static func runDiff(_ args: [String], in directory: URL)
        -> (out: String, code: Int32) {
        let result = runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["git"] + args, in: directory, stdoutLimit: maxDiffBytes)
        var text = String(decoding: result.stdout, as: UTF8.self)
        if result.stdoutTruncated {
            text += "\n\n[Diff truncated at 8 MB to limit memory use.]\n"
        }
        return (text, result.code)
    }

    /// Raw bytes from a git command. `run` decodes to String, which mangles
    /// binary payloads — image blobs must come back as Data.
    static func runData(_ args: [String], in directory: URL,
                        limit: Int? = nil) -> Data? {
        let result = runProcess(executable: URL(fileURLWithPath: "/usr/bin/env"),
                                arguments: ["git"] + args, in: directory,
                                stdoutLimit: limit)
        return result.code == 0 && !result.stdoutTruncated ? result.stdout : nil
    }

    /// A file's contents as of a commit (`git show <hash>:<path>`).
    static func blob(inCommit hash: String, path: String, in directory: URL) -> BlobResult {
        let repoPath = repositoryRelativePath(path, in: directory)
        let object = "\(hash):\(repoPath)"
        let sizeResult = run(["cat-file", "-s", object], in: directory)
        guard sizeResult.code == 0,
              let size = Int(sizeResult.out.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .unavailable(sizeResult.err.isEmpty ? sizeResult.out : sizeResult.err)
        }
        guard size <= maxBlobBytes else { return .tooLarge(size) }
        guard let data = runData(["--no-pager", "show", object],
                                 in: directory, limit: maxBlobBytes) else {
            return .unavailable("Git could not read the image blob.")
        }
        return .data(data)
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
        // Porcelain v1 paths are rooted at the repository even when Git runs
        // from a nested project. Limit the command to this project, then strip
        // that repository prefix so every UI consumer gets project-relative
        // paths. `-z` also disables C-style quoting and supports newlines,
        // quotes, backslashes and the literal text " -> " in file names.
        let prefix = repositoryPrefix(for: directory)
        let statusResult = run(["status", "--porcelain=v1", "-z",
                                "--untracked-files=all", "--", "."], in: directory)
        var entries: [Status.Entry] = []
        let records = statusResult.out.split(separator: "\0", omittingEmptySubsequences: true)
        var index = 0
        while index < records.count {
            let raw = String(records[index])
            guard raw.count > 3 else {
                index += 1
                continue
            }
            let code = String(raw.prefix(2))
            let repositoryPath = String(raw.dropFirst(3))
            if let path = projectRelativePath(repositoryPath, prefix: prefix) {
                entries.append(Status.Entry(code: code, path: path))
            }
            // In -z mode a rename/copy is `XY new-path NUL old-path NUL`.
            if code.contains("R") || code.contains("C") { index += 1 }
            index += 1
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

    static func branches(in directory: URL) -> [Branch] {
        let current = run(["branch", "--show-current"], in: directory)
            .out.trimmingCharacters(in: .whitespacesAndNewlines)
        // `for-each-ref` uses `%00` for a NUL byte. `%x00` belongs to the
        // pretty-log formatter and is emitted literally here, which previously
        // turned `main` into an invalid name such as `main%x00origin/main`.
        // Read tip metadata in the same `for-each-ref` process. The previous
        // implementation spawned an additional `git log` for every branch,
        // making the Branch tab scale linearly with process startup cost.
        let refs = run([
            "for-each-ref",
            "--format=%(refname:short)%00%(upstream:short)%00%(authorname)%00%(authordate:format:%Y-%m-%d %H:%M)%00%(authordate:unix)",
            "refs/heads",
        ], in: directory)
        guard refs.code == 0 else { return [] }

        var branches: [Branch] = []
        var localNames: Set<String> = []
        var representedRemoteRefs: Set<String> = []
        for record in refs.out.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = record.split(separator: "\0", omittingEmptySubsequences: false)
            guard let rawName = fields.first else { continue }
            let name = String(rawName)
            localNames.insert(name)
            guard fields.count >= 5,
                  let timestamp = Int64(fields[4]) else { continue }
            let upstream = String(fields[1])
            if !upstream.isEmpty { representedRemoteRefs.insert(upstream) }
            let upstreamParts = upstream.split(separator: "/", maxSplits: 1).map(String.init)
            branches.append(Branch(
                name: name,
                author: String(fields[2]),
                createdAt: String(fields[3]),
                createdTimestamp: timestamp,
                isCurrent: name == current,
                isRemote: false,
                upstreamRemote: upstreamParts.first,
                upstreamBranch: upstreamParts.count > 1 ? upstreamParts[1] : nil))
        }

        // Include remote-only branches already known to this clone. Symbolic
        // refs such as origin/HEAD and refs represented by a local branch are
        // omitted so the list has one actionable row per logical branch.
        let remoteRefs = run([
            "for-each-ref",
            "--format=%(refname:short)%00%(symref)%00%(authorname)%00%(authordate:format:%Y-%m-%d %H:%M)%00%(authordate:unix)",
            "refs/remotes",
        ], in: directory)
        if remoteRefs.code == 0 {
            for record in remoteRefs.out.split(separator: "\n", omittingEmptySubsequences: true) {
                let fields = record.split(separator: "\0", omittingEmptySubsequences: false)
                guard let rawName = fields.first else { continue }
                let name = String(rawName)
                guard fields.count >= 5,
                      let timestamp = Int64(fields[4]) else { continue }
                let symref = String(fields[1])
                guard symref.isEmpty,
                      !representedRemoteRefs.contains(name) else { continue }
                let parts = name.split(separator: "/", maxSplits: 1).map(String.init)
                guard parts.count == 2,
                      !localNames.contains(parts[1]) else { continue }
                branches.append(Branch(
                    name: name,
                    author: String(fields[2]),
                    createdAt: String(fields[3]),
                    createdTimestamp: timestamp,
                    isCurrent: false,
                    isRemote: true,
                    upstreamRemote: parts[0],
                    upstreamBranch: parts[1]))
            }
        }
        return branches.sorted {
            if $0.createdTimestamp != $1.createdTimestamp {
                return $0.createdTimestamp > $1.createdTimestamp
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func remotes(in directory: URL) -> [Remote] {
        let names = run(["remote"], in: directory)
        guard names.code == 0 else { return [] }
        return names.out.split(separator: "\n", omittingEmptySubsequences: true).compactMap { raw in
            let name = String(raw)
            let fetch = run(["remote", "get-url", name], in: directory)
            guard fetch.code == 0 else { return nil }
            let push = run(["remote", "get-url", "--push", name], in: directory)
            return Remote(
                name: name,
                fetchURL: fetch.out.trimmingCharacters(in: .whitespacesAndNewlines),
                pushURL: (push.code == 0 ? push.out : fetch.out)
                    .trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func createBranch(_ name: String, from base: String,
                             in directory: URL) -> RemoteResult {
        remote(["checkout", "-b", name, base], in: directory, verb: "Create branch")
    }

    static func switchBranch(_ name: String, in directory: URL) -> RemoteResult {
        remote(["checkout", name], in: directory, verb: "Switch branch")
    }

    static func switchBranch(_ branch: Branch, in directory: URL) -> RemoteResult {
        guard branch.isRemote,
              let localName = branch.upstreamBranch else {
            return switchBranch(branch.name, in: directory)
        }
        return remote(["checkout", "--track", "-b", localName, branch.name],
                      in: directory, verb: "Switch branch")
    }

    static func deleteBranch(_ name: String, in directory: URL) -> RemoteResult {
        remote(["branch", "-d", name], in: directory, verb: "Delete branch")
    }

    static func deleteBranch(_ branch: Branch, in directory: URL) -> RemoteResult {
        guard branch.isRemote,
              let remoteName = branch.upstreamRemote,
              let remoteBranch = branch.upstreamBranch else {
            return deleteBranch(branch.name, in: directory)
        }
        return remote(["push", remoteName, "--delete", remoteBranch],
                      in: directory, verb: "Delete remote branch")
    }

    static func saveRemote(name: String, fetchURL: String, pushURL: String,
                           in directory: URL) -> RemoteResult {
        let existing = run(["remote", "get-url", name], in: directory).code == 0
        let result = existing
            ? run(["remote", "set-url", name, fetchURL], in: directory)
            : run(["remote", "add", name, fetchURL], in: directory)
        guard result.code == 0 else {
            return RemoteResult(ok: false, message: result.err.isEmpty ? result.out : result.err)
        }

        let push = pushURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !push.isEmpty, push != fetchURL else {
            // An omitted/equal push URL means "use the fetch URL". Remove a
            // previously configured pushurl instead of silently retaining it.
            let unset = run(["config", "--unset-all", "remote.\(name).pushurl"],
                            in: directory)
            guard unset.code == 0 || unset.code == 5 else {
                return RemoteResult(ok: false,
                                    message: unset.err.isEmpty ? unset.out : unset.err)
            }
            return RemoteResult(ok: true, message: "Remote \(name) saved.")
        }
        let pushResult = run(["remote", "set-url", "--push", name, push], in: directory)
        guard pushResult.code == 0 else {
            return RemoteResult(ok: false,
                                message: pushResult.err.isEmpty ? pushResult.out : pushResult.err)
        }
        return RemoteResult(ok: true, message: "Remote \(name) saved.")
    }

    static func push(to remoteName: String, in directory: URL) -> RemoteResult {
        let branch = run(["branch", "--show-current"], in: directory)
            .out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else {
            return RemoteResult(ok: false, message: "Detached HEAD — nothing to push.")
        }
        let hasUpstream = aheadCount(in: directory).hasUpstream
        let args = hasUpstream
            ? ["push", remoteName, branch]
            : ["push", "--set-upstream", remoteName, branch]
        return remote(args, in: directory, verb: "Push")
    }

    private static func remote(_ args: [String], in directory: URL,
                               verb: String) -> RemoteResult {
        let result = run(args, in: directory)
        if result.code == 0 {
            let text = (result.out + result.err).trimmingCharacters(in: .whitespacesAndNewlines)
            return RemoteResult(ok: true, message: text.isEmpty ? "\(verb) succeeded." : text)
        }
        let text = result.err.isEmpty ? result.out : result.err
        let detail = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return RemoteResult(
            ok: false,
            message: detail.isEmpty ? "\(verb) failed (Git exit code \(result.code))." : detail)
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
        let remoteNames = run(["remote"], in: directory).out
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
        let target: String
        if remoteNames.contains("origin") {
            target = "origin"
        } else if remoteNames.count == 1, let onlyRemote = remoteNames.first {
            target = onlyRemote
        } else if remoteNames.isEmpty {
            return RemoteResult(ok: false, message: "No remote repository is configured.")
        } else {
            return RemoteResult(
                ok: false,
                message: "This branch has no upstream. Choose a specific ‘Push to …’ item from the Push menu.")
        }
        return remote(["push", "--set-upstream", target, branch], in: directory, verb: "Push")
    }

    static func fetch(in directory: URL) -> RemoteResult {
        remote(["fetch", "--all", "--prune"], in: directory, verb: "Fetch")
    }

    static func pull(in directory: URL) -> RemoteResult {
        remote(["pull", "--ff-only"], in: directory, verb: "Pull")
    }

    /// Stage every change inside the opened project, without reaching into
    /// sibling paths when the project is a subfolder of a larger repository.
    @discardableResult
    static func stageAll(in directory: URL) -> (out: String, err: String, code: Int32) {
        run(["add", "-A", "--", "."], in: directory)
    }

    /// Stage and commit every change in the opened project. Staging at the
    /// commit boundary captures edits made after the last panel refresh. The
    /// path-limited commit keeps staged sibling-project changes in the index.
    @discardableResult
    static func commit(_ message: String,
                       in directory: URL) -> (out: String, err: String, code: Int32) {
        let staged = stageAll(in: directory)
        guard staged.code == 0 else { return staged }
        return run(["commit", "-m", message, "--", "."], in: directory)
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
        // NUL is the one byte commit metadata cannot contain, so neither an
        // unusual subject nor an author name can shift these fields.
        let format = "%h%x00%s%x00%an%x00%ad%x00%ae"
        let result = run(["--no-pager", "log", "-z", "--pretty=format:" + format,
                          "--date=format:%Y-%m-%d %H:%M", "-n", "\(limit)",
                          "--", "."], in: directory)
        guard result.code == 0 else { return [] }
        let fields = result.out.split(separator: "\0", omittingEmptySubsequences: false)
        var commits: [Commit] = []
        var index = 0
        while index + 4 < fields.count {
            commits.append(Commit(shortHash: String(fields[index]),
                                  subject: String(fields[index + 1]),
                                  author: String(fields[index + 2]),
                                  absoluteDate: String(fields[index + 3]),
                                  email: String(fields[index + 4])))
            index += 5
        }
        return commits
    }

    /// Unified diff for one path. Untracked files have no diff against the
    /// index, so they're rendered as an all-additions diff of the file itself.
    static func diff(for entry: Status.Entry, in directory: URL) -> String {
        if entry.isUntracked {
            let url = directory.appendingPathComponent(entry.path)
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let fileSize = values.fileSize, fileSize <= maxDiffBytes,
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  !data.prefix(8192).contains(0),
                  String(data: data, encoding: .utf8) != nil else {
                return "diff --git a/\(entry.path) b/\(entry.path)\n" +
                       "new file (binary, unreadable, or larger than 8 MB)\n"
            }
            let newlineCount = data.reduce(into: 0) { count, byte in
                if byte == 0x0A { count += 1 }
            }
            let lineCount = newlineCount + (!data.isEmpty && data.last != 0x0A ? 1 : 0)
            var output = Data(
                ("diff --git a/\(entry.path) b/\(entry.path)\n" +
                 "new file\n--- /dev/null\n+++ b/\(entry.path)\n" +
                 "@@ -0,0 +1,\(lineCount) @@\n").utf8)
            output.reserveCapacity(min(maxDiffBytes, output.count + data.count + lineCount))
            var truncated = false

            func appendAddedLine(_ bytes: Data.SubSequence) -> Bool {
                let required = 1 + bytes.count + 1
                guard output.count + required <= maxDiffBytes else {
                    truncated = true
                    return false
                }
                output.append(0x2B) // +
                output.append(contentsOf: bytes)
                output.append(0x0A)
                return true
            }

            var start = data.startIndex
            for index in data.indices where data[index] == 0x0A {
                guard appendAddedLine(data[start..<index]) else { break }
                start = data.index(after: index)
            }
            if !truncated, start < data.endIndex {
                _ = appendAddedLine(data[start..<data.endIndex])
            }
            if truncated {
                output.append(contentsOf: "\n[Diff truncated at 8 MB to limit memory use.]\n".utf8)
            }
            return String(decoding: output, as: UTF8.self)
        }

        // Staged changes live in the index; unstaged in the worktree. Show
        // whichever this entry actually has (staged takes precedence).
        var args = ["--no-pager", "diff", "--no-color"]
        if entry.isStaged && entry.worktreeStatus == " " { args.append("--cached") }
        args += ["--", entry.path]
        let result = runDiff(args, in: directory)
        let text = result.out
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // e.g. a staged-only change when we asked the worktree, or no change.
            let cached = runDiff(
                ["--no-pager", "diff", "--no-color", "--cached", "--", entry.path],
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
        let result = run(["--no-pager", "show", "--name-status", "-z", "--format=",
                          "-m", "--first-parent", hash, "--", "."], in: directory)
        guard result.code == 0 else { return [] }
        let prefix = repositoryPrefix(for: directory)
        let fields = result.out.split(separator: "\0", omittingEmptySubsequences: true)
        var seen = Set<String>()
        var out: [CommitFile] = []
        var index = 0
        while index < fields.count {
            let rawStatus = String(fields[index])
            index += 1
            guard index < fields.count else { break }
            let status = String(rawStatus.prefix(1))
            var repositoryPath = String(fields[index])
            index += 1
            // Rename/copy records contain old path followed by new path.
            if (status == "R" || status == "C"), index < fields.count {
                repositoryPath = String(fields[index])
                index += 1
            }
            guard let path = projectRelativePath(repositoryPath, prefix: prefix) else { continue }
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            out.append(CommitFile(status: status, path: path))
        }
        return out
    }

    /// Diff a single file as it changed in one commit.
    static func diff(inCommit hash: String, path: String, in directory: URL) -> String {
        let result = runDiff(
            ["--no-pager", "show", "--no-color", "-m", "--first-parent",
             "--format=", hash, "--", path],
            in: directory)
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

    /// Repository-root prefix of the opened project, with no trailing slash.
    private static func repositoryPrefix(for directory: URL) -> String {
        let result = run(["rev-parse", "--show-toplevel"], in: directory)
        guard result.code == 0 else { return "" }
        var rootPath = result.out
        if rootPath.last == "\n" { rootPath.removeLast() }
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.resolvingSymlinksInPath()
        let project = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard project.path != root.path, project.path.hasPrefix(root.path + "/") else { return "" }
        return String(project.path.dropFirst(root.path.count + 1))
    }

    private static func projectRelativePath(_ path: String, prefix: String) -> String? {
        guard !prefix.isEmpty else { return path }
        let marker = prefix + "/"
        guard path.hasPrefix(marker) else { return nil }
        return String(path.dropFirst(marker.count))
    }

    private static func repositoryRelativePath(_ path: String, in directory: URL) -> String {
        let prefix = repositoryPrefix(for: directory)
        return prefix.isEmpty ? path : prefix + "/" + path
    }
}

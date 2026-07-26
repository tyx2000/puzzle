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
    }

    struct Commit {
        let shortHash: String
        let subject: String
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
        return Status(branch: branch.isEmpty ? "detached" : branch, entries: entries, isRepo: true)
    }

    /// Recent commits for the History tab.
    static func log(in directory: URL, limit: Int = 40) -> [Commit] {
        let result = run(["log", "--pretty=format:%h\u{1}%s", "-n", "\(limit)"], in: directory)
        guard result.code == 0 else { return [] }
        return result.out.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let parts = line.split(separator: "\u{1}", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return Commit(shortHash: String(parts[0]), subject: String(parts[1]))
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

    /// Relative paths of changed files, for marking the tree.
    static func dirtyPaths(in directory: URL) -> Set<String> {
        let s = status(in: directory)
        return Set(s.entries.map { $0.path })
    }
}

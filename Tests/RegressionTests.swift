import AppKit
import UniformTypeIdentifiers
import Foundation

@main
enum RegressionTests {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func main() throws {
        _ = NSApplication.shared
        try testProcessDrain()
        try testProcessTimeoutsAndIconCache()
        try testTimeoutSurvivesAHeldPipe()
        try testScopedStatusAndStaging()
        try testFileNamesAreNotPatterns()
        try testGitIgnoreRefreshReconciliation()
        try testPushSelection()
        try testWorkspaceFileMonitorDelivery()
        try testGitRepositoryMonitor()
        try testBranchListing()
        try testDockRecentProjectsMenu()
        try testDefaultWindowPlacement()
        try testIndexLockContention()
        try testStartPageOpensProjects()
        try testSubprocessWaitsDoNotRunARunLoop()
        try testHoverSurvivesTheRowsGoingAway()
        try testExceptionLogKeepsTheReason()
        try testProjectTitleStrip()
        try testProjectCommitLine()
        try testStripedGitLists()
        try testBranchMenu()
        try testBranchesHeldByAnotherWorktree()
        try testTerminalLaunchScripts()
        try testBranchMenuActions()
        try testSplitterAndRowGestures()
        try testMaterialFileIcons()
        try testScrollersFollowTheTheme()
        try testAyuDarkTheme()
        try testDiffHeaderStepsThroughChanges()
        try testThemeIsReadyBeforeAnyView()
        try testChangesContextMenu()
        try testSelectedControlsAgree()
        try testHistoryLogDetails()
        try testScopedHistoryGraphParents()
        try testAllBranchesHistoryGraph()
        try testHistoryGraphLayout()
        try testCommitIdentityFollowsGitConfig()
        try testCommitNeedsChangesAndAMessage()
        try testStatusMatchesPorcelainV1()
        try testSideBySideDiff()
        try testOpenDiffRefreshesCoalesce()
        try testDiffTabs()
        try testTabBodiesStayWithinBudget()
        try testRefreshReadsOnlyTheTabOnScreen()
        try testFoldersRouteToTheirProjectWindow()
        print("Regression tests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool,
                               _ message: String) throws {
        guard condition() else { throw Failure(description: message) }
    }

    private static func temporaryDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gift-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func sameColor(_ lhs: NSColor?, _ rhs: NSColor?) -> Bool {
        guard let lhs = lhs?.usingColorSpace(.sRGB),
              let rhs = rhs?.usingColorSpace(.sRGB) else { return lhs == nil && rhs == nil }
        return abs(lhs.redComponent - rhs.redComponent) < 0.002
            && abs(lhs.greenComponent - rhs.greenComponent) < 0.002
            && abs(lhs.blueComponent - rhs.blueComponent) < 0.002
            && abs(lhs.alphaComponent - rhs.alphaComponent) < 0.002
    }

    private static func testProcessDrain() throws {
        let directory = try temporaryDirectory("pipes")
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = GitService.runProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "dd if=/dev/zero bs=65536 count=32 1>&2; printf ok"],
            in: directory)
        try expect(result.code == 0, "large-stderr process failed")
        try expect(String(decoding: result.stdout, as: UTF8.self) == "ok",
                   "stdout was not captured")
        try expect(result.stderr.count == GitService.maxProcessStderrBytes,
                   "stderr was not drained with bounded retention")

        let bounded = GitService.runProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "dd if=/dev/zero bs=65536 count=4 2>/dev/null"],
            in: directory, stdoutLimit: 32_768)
        try expect(bounded.code == 0 && bounded.stdout.count == 32_768,
                   "bounded process capture did not retain the requested prefix")
        try expect(bounded.stdoutTruncated,
                   "bounded process capture did not report discarded output")
    }

    /// A deadline has to hold even when the process leaves something behind
    /// that keeps its output open: `git push` over a stuck `ssh`, a hook's
    /// daemon. Killing the child does not close the pipes, and waiting for
    /// them to end gave the deadline away entirely.
    private static func testTimeoutSurvivesAHeldPipe() throws {
        let directory = try temporaryDirectory("held-pipe")
        defer { try? FileManager.default.removeItem(at: directory) }
        let timeout: TimeInterval = 0.2
        let started = Date()
        let result = GitService.runProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            // The child ignores TERM and a grandchild holds stdout open.
            arguments: ["-c", "sh -c 'trap \"\" TERM; sleep 5' & wait"],
            in: directory, timeout: timeout)
        let elapsed = Date().timeIntervalSince(started)
        try expect(result.code != 0, "a process past its deadline reported success")
        try expect(elapsed < timeout + GitService.readerGrace + 1,
                   "the deadline waited \(elapsed)s for a pipe nothing was going to close")
        let said = String(decoding: result.stderr, as: UTF8.self)
        try expect(said.contains("gave up"), "the timeout did not say what happened")
        try expect(said.contains("holding its output open"),
                   "it did not say the result may be partial: \(said)")
    }

    private static func testProcessTimeoutsAndIconCache() throws {
        let directory = try temporaryDirectory("review-fixes")
        defer { try? FileManager.default.removeItem(at: directory) }

        // Network git calls are bounded; local ones are not.
        try expect(GitService.networkTimeout > 0,
                   "network git operations have no ceiling")
        let slow = GitService.runProcess(
            executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
            in: directory, timeout: 1)
        try expect(slow.code != 0,
                   "a process past its timeout reported success")
        try expect(String(decoding: slow.stderr, as: UTF8.self).contains("gave up"),
                   "the timeout did not say what happened")

        // Repointing the icon resources resets the LRU bookkeeping with it.
        FileIcons.useResources(at: directory)
        try expect(FileIcons.cachedImageCountForTesting == 0,
                   "the icon cache survived a resource switch")
        try expect(FileIcons.lastUsedCountForTesting == 0,
                   "the LRU table kept stale keys, which would absorb evictions")
        FileIcons.useResources(at: nil)
    }

    private static func testScopedStatusAndStaging() throws {
        let root = try temporaryDirectory("git")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        try expect(GitService.run(["init", "-q"], in: root).code == 0, "git init failed")
        _ = GitService.run(["config", "user.name", "Gift Test"], in: root)
        _ = GitService.run(["config", "user.email", "gift@example.invalid"], in: root)

        let special = "quoted \" name\nline -> here.txt"
        try Data("inside".utf8).write(to: project.appendingPathComponent(special))
        try Data("outside".utf8).write(to: root.appendingPathComponent("outside.txt"))

        let status = GitService.status(in: project)
        try expect(status.entries.map(\.path) == [special],
                   "status was not project-relative or lossless: \(status.entries.map(\.path))")
        try expect(status.entries.first?.isUntracked == true,
                   "a new file was not reported as untracked")
        try expect(status.userName == "Gift Test",
                   "status did not report git config user.name: \(status.userName)")

        try expect(GitService.stageAll(in: project).code == 0, "scoped staging failed")
        let staged = GitService.run(["diff", "--cached", "--name-only", "-z"], in: root)
            .out.split(separator: "\0").map(String.init)
        try expect(staged == ["project/\(special)"],
                   "stageAll escaped the opened project: \(staged)")

        _ = GitService.run(["add", "--", "outside.txt"], in: root)
        try expect(GitService.commit("scoped", in: project).code == 0,
                   "scoped commit failed")
        let committed = GitService.run(
            ["show", "--pretty=format:", "--name-only", "-z", "HEAD"], in: root)
            .out.split(separator: "\0").map(String.init)
        try expect(committed == ["project/\(special)"],
                   "commit escaped the opened project: \(committed)")
        let stillStaged = GitService.run(["diff", "--cached", "--name-only", "-z"], in: root)
            .out.split(separator: "\0").map(String.init)
        try expect(stillStaged == ["outside.txt"],
                   "commit disturbed staged changes outside the project")

        // Discarding everything restores each tracked file to HEAD in one pass.
        let firstFile = project.appendingPathComponent("bulk-one.txt")
        let secondFile = project.appendingPathComponent("bulk-two.txt")
        try Data("one\n".utf8).write(to: firstFile)
        try Data("two\n".utf8).write(to: secondFile)
        try expect(GitService.commit("bulk baseline", in: project).code == 0,
                   "bulk baseline commit failed")
        try Data("one edited\n".utf8).write(to: firstFile)
        try Data("two edited\n".utf8).write(to: secondFile)
        let dirty = GitService.status(in: project)
        try expect(dirty.entries.count == 2,
                   "expected two dirty files, got \(dirty.entries.map(\.path))")
        // Neither is a new file, so nothing here goes to the Trash.
        try expect(dirty.entries.allSatisfy { !GitService.discardRemovesFile($0, in: project) },
                   "a tracked edit was classified as a file to remove")
        let bulk = GitService.discardAll(dirty.entries, in: project)
        try expect(bulk.discarded == 2 && bulk.failure == nil,
                   "discardAll reported \(bulk)")
        let restoredFirst = String(decoding: try Data(contentsOf: firstFile), as: UTF8.self)
        let restoredSecond = String(decoding: try Data(contentsOf: secondFile), as: UTF8.self)
        try expect(restoredFirst == "one\n" && restoredSecond == "two\n",
                   "discardAll did not restore the files to HEAD: "
                    + "\(restoredFirst.debugDescription), \(restoredSecond.debugDescription)")
        try expect(GitService.status(in: project).entries.isEmpty,
                   "the project still reports changes after discarding everything")

        // The panel may have refreshed before the user's final edit. Commit
        // must stage once more at the operation boundary so that edit is not
        // silently omitted.
        let lateFile = project.appendingPathComponent("late.txt")
        try Data("late edit".utf8).write(to: lateFile)
        try expect(GitService.commit("late edit", in: project).code == 0,
                   "commit did not stage a last-moment edit")
        let lateCommitted = GitService.run(
            ["show", "--pretty=format:", "--name-only", "-z", "HEAD"], in: root)
            .out.split(separator: "\0").map(String.init)
        try expect(lateCommitted == ["project/late.txt"],
                   "last-moment edit was omitted from commit: \(lateCommitted)")
        let outsideAfterLateCommit = GitService.run(
            ["diff", "--cached", "--name-only", "-z"], in: root)
            .out.split(separator: "\0").map(String.init)
        try expect(outsideAfterLateCommit == ["outside.txt"],
                   "final staging disturbed changes outside the project")

        let renamed = "renamed -> \"value\"\nnext.txt"
        try FileManager.default.moveItem(at: project.appendingPathComponent(special),
                                         to: project.appendingPathComponent(renamed))
        try expect(GitService.stageAll(in: project).code == 0, "rename staging failed")
        let renamedStatus = GitService.status(in: project)
        try expect(renamedStatus.entries.count == 1 && renamedStatus.entries[0].path == renamed,
                   "rename path was parsed incorrectly")
        let unusualSubject = "rename\u{1}subject"
        try expect(GitService.commit(unusualSubject, in: project).code == 0,
                   "rename commit failed")
        let hash = GitService.run(["rev-parse", "--short", "HEAD"], in: project)
            .out.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = GitService.files(inCommit: hash, in: project)
        try expect(files.count == 1 && files[0].path == renamed,
                   "history path was not project-relative or lossless")
        guard let newest = GitService.log(in: project, limit: 1).first else {
            throw Failure(description: "the log is empty after a commit")
        }
        try expect(newest.subject == unusualSubject,
                   "commit metadata delimiters corrupted the history subject")
        // The time the history shows is the author date, to the minute.
        try expect(newest.absoluteDate.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$"#,
                                             options: .regularExpression) != nil,
                   "the log's time is not yyyy-MM-dd HH:mm: \(newest.absoluteDate)")

        try Data("changed".utf8).write(to: project.appendingPathComponent(renamed))
        try expect(GitService.stageAll(in: project).code == 0,
                   "discard fixture staging failed")
        guard let modifiedEntry = GitService.status(in: project).entries.first else {
            throw Failure(description: "discard fixture did not produce a status entry")
        }
        let discarded = GitService.discard(modifiedEntry, in: project)
        try expect(discarded.ok, "tracked file discard failed: \(discarded.message)")
        let restoredContents = try String(contentsOf: project.appendingPathComponent(renamed),
                                          encoding: .utf8)
        try expect(restoredContents == "inside",
                   "tracked file discard did not restore HEAD contents")

        let secondRename = "discarded-rename.txt"
        try expect(GitService.run(["mv", "--", renamed, secondRename], in: project).code == 0,
                   "rename discard fixture failed")
        guard let renameEntry = GitService.status(in: project).entries.first else {
            throw Failure(description: "rename discard fixture did not produce a status entry")
        }
        try expect(renameEntry.originalPath == renamed,
                   "porcelain rename did not retain its original path")
        let discardedRename = GitService.discard(renameEntry, in: project)
        try expect(discardedRename.ok, "rename discard failed: \(discardedRename.message)")
        try expect(FileManager.default.fileExists(
            atPath: project.appendingPathComponent(renamed).path),
                   "rename discard did not restore the original path")
        try expect(!FileManager.default.fileExists(
            atPath: project.appendingPathComponent(secondRename).path),
                   "rename discard left the renamed path behind")

    }

    /// A file name is a name, not a pattern. Git reads the paths after `--`
    /// as pathspecs, so a file called `*.txt` matched — and discarded — every
    /// other `.txt` beside it. `--` only ends option parsing; what stops the
    /// pattern is GIT_LITERAL_PATHSPECS.
    private static func testFileNamesAreNotPatterns() throws {
        let root = try temporaryDirectory("literal-pathspecs")
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) -> String {
            GitService.run(args, in: root).out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = git(["init", "-q", "-b", "main"])
        _ = git(["config", "user.name", "Gift Test"])
        _ = git(["config", "user.email", "gift@example.invalid"])
        // Names Git would otherwise read as patterns, beside the ordinary
        // files they would match.
        let patterns = ["*.txt", "?.txt", "[ab].txt", ":x.txt"]
        let bystanders = ["important.txt", "a.txt", "b.txt"]
        for name in patterns + bystanders {
            try Data("committed\n".utf8).write(to: root.appendingPathComponent(name))
        }
        try expect(GitService.commit("fixture", in: root).code == 0, "fixture commit failed")
        func contents(_ name: String) -> String {
            (try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)) ?? ""
        }
        func entry(_ name: String) throws -> GitService.Status.Entry {
            guard let found = GitService.status(in: root).entries.first(where: { $0.path == name })
            else { throw Failure(description: "\(name) is not listed as changed") }
            return found
        }

        for name in patterns {
            for edited in patterns + bystanders {
                try Data("edited \(edited)\n".utf8).write(to: root.appendingPathComponent(edited))
            }
            // The diff belongs to the one file, not to everything its name matches.
            let diff = GitService.diff(for: try entry(name), in: root)
            let named = diff.split(separator: "\n").filter { $0.hasPrefix("diff --git") }
            try expect(named.count == 1 && named[0].contains(name),
                       "the diff for “\(name)” covers \(named.count) files: \(named)")

            let discarded = GitService.discard(try entry(name), in: root)
            try expect(discarded.ok, "discarding “\(name)” failed: \(discarded.message)")
            try expect(contents(name) == "committed\n",
                       "discarding “\(name)” did not restore it")
            let survivors = (patterns + bystanders).filter { $0 != name }
            for other in survivors {
                try expect(contents(other) == "edited \(other)\n",
                           "discarding “\(name)” also reverted \(other): \(contents(other))")
            }
            // And nothing else was taken out of the index on the way.
            let staged = Set(GitService.status(in: root).entries.map(\.path))
            try expect(staged == Set(survivors),
                       "the other files left the change list: \(staged)")
            _ = git(["checkout", "--", "."])
        }

        // A new file whose name is a pattern goes to the Trash on its own.
        let fresh = "*.log"
        try Data("new\n".utf8).write(to: root.appendingPathComponent(fresh))
        try Data("other\n".utf8).write(to: root.appendingPathComponent("keep.log"))
        _ = GitService.stageAll(in: root)
        let freshEntry = try entry(fresh)
        try expect(GitService.discardRemovesFile(freshEntry, in: root),
                   "a never-committed file was not recognised as one")
        let trashed = GitService.discard(freshEntry, in: root)
        try expect(trashed.ok, "discarding the new file failed: \(trashed.message)")
        try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(fresh).path),
                   "the new file is still there")
        try expect(contents("keep.log") == "other\n",
                   "discarding “\(fresh)” took keep.log with it: \(contents("keep.log"))")
    }

    private static func testGitIgnoreRefreshReconciliation() throws {
        let directory = try temporaryDirectory("gitignore-refresh")
        defer { try? FileManager.default.removeItem(at: directory) }
        try expect(GitService.run(["init", "-q"], in: directory).code == 0,
                   "gitignore fixture git init failed")
        _ = GitService.run(["config", "user.name", "Gift Test"], in: directory)
        _ = GitService.run(["config", "user.email", "gift@example.invalid"], in: directory)

        let tracked = directory.appendingPathComponent("tracked.log")
        try Data("baseline\n".utf8).write(to: tracked)
        try expect(GitService.stageAll(in: directory).code == 0,
                   "gitignore fixture baseline staging failed")
        try expect(GitService.commit("baseline", in: directory).code == 0,
                   "gitignore fixture baseline commit failed")

        let generated = directory.appendingPathComponent("generated.log")
        try Data("generated\n".utf8).write(to: generated)
        try expect(GitService.stageAll(in: directory).code == 0,
                   "generated file was not staged before ignore edit")
        try expect(GitService.status(in: directory).entries.contains {
            $0.path == "generated.log" && $0.indexStatus == "A"
        }, "gitignore fixture did not start with a staged addition")

        try Data("generated.log\ntracked.log\n".utf8)
            .write(to: directory.appendingPathComponent(".gitignore"))
        try Data("modified but still tracked\n".utf8).write(to: tracked)
        try expect(GitService.stageAll(in: directory).code == 0,
                   "staging after .gitignore save failed")

        let paths = GitService.status(in: directory).entries.map(\.path).sorted()
        try expect(paths == [".gitignore", "tracked.log"],
                   "saved .gitignore did not remove only ignored additions: \(paths)")
        try expect(FileManager.default.fileExists(atPath: generated.path),
                   "reconciling ignored additions deleted the working-copy file")
    }

    private static func testPushSelection() throws {
        let root = try temporaryDirectory("remotes")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("repository", isDirectory: true)
        let remote = root.appendingPathComponent("backup.git", isDirectory: true)

        try expect(GitService.run(["init", "--bare", "-q", remote.path], in: root).code == 0,
                   "remote fixture init failed")
        try expect(GitService.run(["init", "-q", "-b", "main", repository.path], in: root).code == 0,
                   "repository fixture init failed")
        _ = GitService.run(["config", "user.name", "Remote Test"], in: repository)
        _ = GitService.run(["config", "user.email", "remote@example.invalid"], in: repository)
        try Data("fixture".utf8).write(to: repository.appendingPathComponent("file.txt"))
        try expect(GitService.commit("initial", in: repository).code == 0,
                   "remote fixture commit failed")
        let noRemote = GitService.push(in: repository)
        try expect(!noRemote.ok && noRemote.message.contains("No remote"),
                   "push without a remote did not return a useful error")

        try expect(GitService.run(["remote", "add", "backup", remote.path],
                                  in: repository).code == 0,
                   "remote fixture configuration failed")

        let pushed = GitService.push(in: repository)
        try expect(pushed.ok, "single non-origin remote was not selected: \(pushed.message)")
        let upstream = GitService.run(["rev-parse", "--abbrev-ref", "@{upstream}"],
                                      in: repository).out
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try expect(upstream == "backup/main",
                   "push configured the wrong upstream: \(upstream)")

        _ = GitService.run(["branch", "--unset-upstream"], in: repository)
        let secondRemote = root.appendingPathComponent("second.git", isDirectory: true)
        try expect(GitService.run(["init", "--bare", "-q", secondRemote.path], in: root).code == 0,
                   "second remote fixture init failed")
        try expect(GitService.run(["remote", "add", "second", secondRemote.path],
                                  in: repository).code == 0,
                   "second remote fixture configuration failed")
        let ambiguous = GitService.push(in: repository)
        try expect(!ambiguous.ok && ambiguous.message.contains("backup, second"),
                   "push arbitrarily selected one of multiple non-origin remotes, or did "
                     + "not name them: \(ambiguous.message)")
    }

    /// The working-tree watcher says only that something changed, coalesces a
    /// burst into one refresh, and delivers even while the events keep coming.
    private static func testWorkspaceFileMonitorDelivery() throws {
        let directory = try temporaryDirectory("workspace-monitor")
        defer { try? FileManager.default.removeItem(at: directory) }
        var deliveries = 0
        let monitor = WorkspaceFileMonitor(directory: directory) { deliveries += 1 }
        defer { monitor.stop() }
        func spin(_ seconds: TimeInterval) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }

        // A burst — one save is several events — is one refresh.
        for _ in 0..<20 { monitor.noteChange() }
        try expect(deliveries == 0, "the burst was delivered before it settled")
        spin(WorkspaceFileMonitor.quietWindow + 0.2)
        try expect(deliveries == 1, "a burst delivered \(deliveries) refreshes, not one")

        // Events that never stop — a build writing files — must not hold the
        // refresh back past the deadline. Each one lands inside the quiet
        // window, so a plain trailing debounce would deliver nothing at all.
        deliveries = 0
        let started = Date()
        var deliveredAfter: TimeInterval?
        while Date().timeIntervalSince(started) < WorkspaceFileMonitor.maximumDelay * 1.5 {
            monitor.noteChange()
            spin(WorkspaceFileMonitor.quietWindow / 2)
            if deliveries > 0, deliveredAfter == nil {
                deliveredAfter = Date().timeIntervalSince(started)
            }
        }
        guard let deliveredAfter else {
            throw Failure(description: "continuous events never delivered a refresh")
        }
        try expect(deliveredAfter <= WorkspaceFileMonitor.maximumDelay + 0.3,
                   "the deadline delivered after \(deliveredAfter)s")

        // Stopped, it is done: nothing is delivered afterwards.
        monitor.stop()
        deliveries = 0
        monitor.noteChange()
        spin(WorkspaceFileMonitor.quietWindow + 0.2)
        try expect(deliveries == 0, "a stopped monitor still delivered \(deliveries)")
    }

    private static func testGitRepositoryMonitor() throws {
        let root = try temporaryDirectory("git-monitor")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("repository", isDirectory: true)

        try expect(GitService.run(["init", "-q", "-b", "main", repository.path], in: root).code == 0,
                   "monitor fixture init failed")
        _ = GitService.run(["config", "user.name", "Monitor Test"], in: repository)
        _ = GitService.run(["config", "user.email", "monitor@example.invalid"], in: repository)
        try Data("initial".utf8).write(to: repository.appendingPathComponent("file.txt"))
        try expect(GitService.commit("initial", in: repository).code == 0,
                   "monitor fixture commit failed")
        let remote = root.appendingPathComponent("remote.git", isDirectory: true)
        try expect(GitService.run(["init", "--bare", "-q", remote.path], in: root).code == 0,
                   "monitor remote fixture init failed")
        try expect(GitService.run(["remote", "add", "origin", remote.path],
                                  in: repository).code == 0,
                   "monitor remote fixture configuration failed")

        let metadata = GitRepositoryMonitor.metadataDirectories(in: repository)
        try expect(metadata.count == 1 && metadata[0].lastPathComponent == ".git",
                   "regular repository metadata directory was not resolved: \(metadata)")

        var observedChange = false
        let monitor = GitRepositoryMonitor(directory: repository) {
            observedChange = true
        }
        let monitorDeadline = Date().addingTimeInterval(3)
        while !monitor.isMonitoring && Date() < monitorDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        try expect(monitor.isMonitoring, "Git metadata monitor did not start")
        try Data("external commit".utf8)
            .write(to: repository.appendingPathComponent("external.txt"))
        try expect(GitService.commit("external", in: repository).code == 0,
                   "external commit fixture failed")
        let deadline = Date().addingTimeInterval(3)
        while !observedChange && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        monitor.stop()
        try expect(observedChange,
                   "Git metadata monitor did not observe an external commit")

        var observedPush = false
        let pushMonitor = GitRepositoryMonitor(directory: repository) {
            observedPush = true
        }
        let pushMonitorDeadline = Date().addingTimeInterval(3)
        while !pushMonitor.isMonitoring && Date() < pushMonitorDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        try expect(pushMonitor.isMonitoring, "Git push monitor did not start")
        try expect(GitService.run(["push", "-q", "-u", "origin", "main"],
                                  in: repository).code == 0,
                   "external push fixture failed")
        let pushDeadline = Date().addingTimeInterval(3)
        while !observedPush && Date() < pushDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        pushMonitor.stop()
        try expect(observedPush,
                   "Git metadata monitor did not observe an external push")

        let linked = root.appendingPathComponent("linked", isDirectory: true)
        try expect(GitService.run(["worktree", "add", "-q", "-b", "linked-test", linked.path],
                                  in: repository).code == 0,
                   "linked worktree fixture failed")
        let linkedMetadata = GitRepositoryMonitor.metadataDirectories(in: linked)
        try expect(linkedMetadata.count == 2,
                   "linked worktree did not resolve private and common Git directories")
    }

    private static func testBranchListing() throws {
        let root = try temporaryDirectory("branches")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("repository", isDirectory: true)
        let remote = root.appendingPathComponent("remote.git", isDirectory: true)

        try expect(GitService.run(["init", "--bare", "-q", remote.path], in: root).code == 0,
                   "bare remote init failed")
        try expect(GitService.run(["init", "-q", "-b", "main", repository.path], in: root).code == 0,
                   "branch fixture init failed")
        _ = GitService.run(["config", "user.name", "Branch Author"], in: repository)
        _ = GitService.run(["config", "user.email", "branch@example.invalid"], in: repository)
        try Data("fixture".utf8).write(to: repository.appendingPathComponent("file.txt"))
        try expect(GitService.run(["add", "file.txt"], in: repository).code == 0,
                   "branch fixture staging failed")
        try expect(GitService.run(["commit", "-q", "-m", "initial"], in: repository).code == 0,
                   "branch fixture commit failed")
        try expect(GitService.run(["remote", "add", "origin", remote.path], in: repository).code == 0,
                   "branch fixture remote failed")
        try expect(GitService.run(["push", "-q", "-u", "origin", "main"], in: repository).code == 0,
                   "branch fixture push failed")

        try expect(GitService.run(["checkout", "-q", "-b", "feature/test"],
                                  in: repository).code == 0,
                   "remote-only branch fixture checkout failed")
        try Data("feature".utf8).write(to: repository.appendingPathComponent("feature.txt"))
        try expect(GitService.run(["add", "feature.txt"], in: repository).code == 0,
                   "remote-only branch fixture staging failed")
        try expect(GitService.run(["commit", "-q", "-m", "feature"], in: repository).code == 0,
                   "remote-only branch fixture commit failed")
        try expect(GitService.run(["push", "-q", "-u", "origin", "feature/test"],
                                  in: repository).code == 0,
                   "remote-only branch fixture push failed")
        try expect(GitService.run(["checkout", "-q", "main"], in: repository).code == 0,
                   "branch fixture return to main failed")
        try expect(GitService.run(["branch", "-D", "feature/test"], in: repository).code == 0,
                   "remote-only local branch removal failed")

        let branches = GitService.branches(in: repository)
        let main = branches.first(where: { $0.name == "main" })
        try expect(main != nil,
                   "local main branch was omitted: \(branches.map(\.name))")
        try expect(main?.isCurrent == true,
                   "main branch was not marked current")
        try expect(main?.upstreamRemote == "origin"
                   && main?.upstreamBranch == "main",
                   "main upstream was parsed incorrectly")

        guard let remoteOnly = branches.first(where: { $0.name == "origin/feature/test" }) else {
            throw Failure(description: "known remote-only branch was omitted: \(branches.map(\.name))")
        }
        try expect(remoteOnly.isRemote,
                   "remote-only branch was not identified as remote")
        let switched = GitService.switchBranch(remoteOnly, in: repository)
        try expect(switched.ok, "remote-only branch switch failed: \(switched.message)")
        let current = GitService.run(["branch", "--show-current"], in: repository)
            .out.trimmingCharacters(in: .whitespacesAndNewlines)
        try expect(current == "feature/test",
                   "remote-only branch did not create its local tracking branch")
    }

    private static func testDockRecentProjectsMenu() throws {
        let directory = try temporaryDirectory("dock-recents")
        defer { try? FileManager.default.removeItem(at: directory) }

        let suiteName = "GiftRegressionDockRecents-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw Failure(description: "could not create isolated recent-project defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recents = RecentProjects(defaults: defaults, key: "recents", limit: 12)

        var projects: [URL] = []
        for index in 0..<12 {
            let project = directory.appendingPathComponent("project-\(index)",
                                                            isDirectory: true)
            try FileManager.default.createDirectory(at: project,
                                                    withIntermediateDirectories: true)
            projects.append(project)
            recents.add(project)
        }

        // The start page offers twenty, and the store keeps exactly that many:
        // a page that showed eight of twelve sent the reader to the Dock menu
        // to find the rest.
        try expect(RecentProjects.displayLimit == 20,
                   "the start page offers \(RecentProjects.displayLimit) recent projects")
        let deep = RecentProjects(defaults: defaults, key: "deep-recents")
        for index in 0..<25 {
            let project = directory.appendingPathComponent("deep-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: project,
                                                    withIntermediateDirectories: true)
            deep.add(project)
        }
        try expect(deep.urls.count == RecentProjects.displayLimit,
                   "the store kept \(deep.urls.count) projects")
        try expect(deep.urls.first?.lastPathComponent == "deep-24",
                   "the most recent project is not first: "
                     + "\(deep.urls.first?.lastPathComponent ?? "none")")

        // Invalid paths are filtered before applying the Dock's ten-item cap.
        let missing = directory.appendingPathComponent("missing", isDirectory: true)
        recents.add(missing)

        let delegate = AppDelegate(recentProjects: recents)
        guard let menu = delegate.applicationDockMenu(NSApplication.shared) else {
            throw Failure(description: "applicationDockMenu returned nil")
        }
        try expect(menu.items.count == 10,
                   "Dock recent-project menu did not cap valid projects at ten")

        let expected = Array(projects.reversed().prefix(10))
        for (item, url) in zip(menu.items, expected) {
            try expect(item.title == url.lastPathComponent,
                       "Dock recent-project menu was not newest-first")
            try expect((item.representedObject as? URL)?.standardizedFileURL == url.standardizedFileURL,
                       "Dock recent-project item did not retain its project URL")
            try expect(item.target === delegate && item.action != nil,
                       "Dock recent-project item was not wired to the app delegate")
        }
    }

    private static func testDefaultWindowPlacement() throws {
        let visible = NSRect(x: 100, y: 50, width: 1500, height: 900)
        let frame = WorkspaceWindowController.defaultWindowFrame(in: visible)
        try expect(frame == NSRect(x: 350, y: 50, width: 1000, height: 900),
                   "default window was not full-height, two-thirds width, and centered")

        let sidebar = SidebarViewController()
        _ = sidebar.view
        sidebar.setTabRowHeight(72)
        try expect(sidebar.panelTopInsetForTesting == 72,
                   "the projects panel's top inset did not follow the tab height")

        let workspace = WorkspaceWindowController()
        workspace.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        let titlebarHeight = workspace.trafficLightTopInset * 2
            + workspace.trafficLightHeight
        try expect(workspace.sidebar.panelTopInsetForTesting == titlebarHeight,
                   "the projects panel's top inset did not follow traffic-light geometry")
        try expect(workspace.diffs.tabRowHeightForTesting == titlebarHeight,
                   "the diff tab height did not follow traffic-light geometry")

        // A window with nothing open draws no lists and no note: they belong
        // to a project that is open.
        let panel = workspace.sidebar.projectsPanel
        try expect(!panel.gitListsVisibleForTesting && !panel.notRepositoryVisibleForTesting,
                   "an empty window still shows a project's lists")
        // And the diff side is the start page, not a hint about diffs.
        try expect(workspace.diffs.welcomeVisibleForTesting
                    && !workspace.diffs.hintVisibleForTesting,
                   "an empty window does not show the start page")
        workspace.close()
    }

    private static func testIndexLockContention() throws {
        // Which subcommands are guarded, decided from the arguments as spawned.
        try expect(GitService.writesIndex(["add", "-A", "--", "."]),
                   "`git add` was not treated as an index write")
        try expect(GitService.writesIndex(["-c", "core.hooksPath=/dev/null", "commit", "-m", "x"]),
                   "a `-c` option hid the subcommand behind it")
        try expect(!GitService.writesIndex(["--no-pager", "status", "--porcelain=v2"]),
                   "`git status` was serialized as though it wrote the index")
        try expect(!GitService.writesIndex(["--no-pager", "show", "HEAD:file.txt"]),
                   "a read was serialized as though it wrote the index")

        let root = try temporaryDirectory("index-lock")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("repository", isDirectory: true)
        try expect(GitService.run(["init", "-q", "-b", "main", repository.path], in: root).code == 0,
                   "index-lock fixture init failed")
        _ = GitService.run(["config", "user.name", "Lock Test"], in: repository)
        _ = GitService.run(["config", "user.email", "lock@example.invalid"], in: repository)
        for index in 1...8 {
            try Data("file \(index)".utf8)
                .write(to: repository.appendingPathComponent("file\(index).txt"))
        }
        try expect(GitService.commit("initial", in: repository).code == 0,
                   "index-lock fixture commit failed")

        // Staging and reading at once, the way the panel and the editor do it.
        let failures = NSMutableArray()
        DispatchQueue.concurrentPerform(iterations: 8) { iteration in
            try? Data("edit \(iteration)".utf8)
                .write(to: repository.appendingPathComponent("file\(iteration + 1).txt"))
            let staged = GitService.stageAll(in: repository)
            if staged.code != 0 {
                synchronized(failures) { failures.add(staged.err) }
            }
            _ = GitService.status(in: repository)
        }
        try expect(failures.count == 0,
                   "concurrent staging hit the index lock: \(failures)")

        // A lock held from outside the app — a terminal, another window — is
        // waited out rather than reported.
        let lock = repository.appendingPathComponent(".git/index.lock")
        try Data().write(to: lock)
        defer { try? FileManager.default.removeItem(at: lock) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            try? FileManager.default.removeItem(at: lock)
        }
        try Data("later".utf8).write(to: repository.appendingPathComponent("file1.txt"))
        let contended = GitService.stageAll(in: repository)
        try expect(contended.code == 0,
                   "a lock held for 200ms was reported instead of waited out: \(contended.err)")
    }

    /// `NSMutableArray` is not thread-safe, and the failure list is written
    /// from every worker at once.
    private static func synchronized(_ token: AnyObject, _ body: () -> Void) {
        objc_sync_enter(token)
        defer { objc_sync_exit(token) }
        body()
    }

    /// The start page is where projects are chosen when none is showing: one
    /// click opens one, and the tick boxes gather several.
    private static func testStartPageOpensProjects() throws {
        let root = try temporaryDirectory("start-page")
        defer { try? FileManager.default.removeItem(at: root) }
        var projects: [URL] = []
        for name in ["alpha", "beta", "gamma"] {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            projects.append(url)
            RecentProjects.shared.add(url)
        }
        defer { projects.forEach { RecentProjects.shared.remove($0) } }

        let welcome = WelcomeView(frame: NSRect(x: 0, y: 0, width: 620, height: 420))
        welcome.reloadRecents()
        var openedOne: URL?
        var openedMany: [URL] = []
        welcome.onOpenRecent = { openedOne = $0 }
        welcome.onOpenChecked = { openedMany = $0 }

        // Nothing ticked, nothing to do.
        try expect(welcome.openCheckedTitleForTesting == "Open Checked",
                   "the button reads \(welcome.openCheckedTitleForTesting)")
        try expect(!welcome.openCheckedEnabledForTesting,
                   "Open Checked is offered with nothing ticked")
        welcome.openCheckedForTesting()
        try expect(openedMany.isEmpty, "Open Checked opened something with nothing ticked")

        // Ticking two and asking for them opens exactly those, in the order
        // they are listed.
        let rows = welcome.rowsForTesting()
        try expect(rows.count == 3, "the start page lists \(rows.count) recents, not 3")
        welcome.toggleCheckForTesting(at: 0)
        welcome.toggleCheckForTesting(at: 2)
        try expect(welcome.openCheckedEnabledForTesting,
                   "Open Checked stayed unavailable with two projects ticked")
        welcome.openCheckedForTesting()
        try expect(openedMany.count == 2,
                   "Open Checked opened \(openedMany.count) projects, not the two ticked")
        try expect(openedMany == welcome.checkedForTesting,
                   "Open Checked did not open the ticked projects in listed order")

        // A single click ticks the row — gathering several is the common
        // errand here, and the box alone is a small target. Opening one on its
        // own is a double click.
        try expect(!welcome.isRowCheckedForTesting(1), "the fixture row was already ticked")
        welcome.toggleCheckForTesting(at: 1)
        try expect(welcome.isRowCheckedForTesting(1) && openedOne == nil,
                   "clicking a recent project opened it instead of ticking it")
        welcome.openRowForTesting(1)
        try expect(openedOne != nil, "double-clicking a recent project did not open it")
    }

    private static func testSubprocessWaitsDoNotRunARunLoop() throws {
        let root = try temporaryDirectory("runloop")
        defer { try? FileManager.default.removeItem(at: root) }

        var fired = false
        let finished = DispatchSemaphore(value: 0)
        var result: GitService.ProcessResult?
        DispatchQueue(label: "test.runloop", qos: .utility).async {
            // Dormant on a dispatch worker thread — nothing runs the run loop
            // there — unless something spins one while it waits.
            _ = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { _ in
                fired = true
            }
            result = GitService.runProcess(executable: URL(fileURLWithPath: "/bin/sleep"),
                                           arguments: ["0.4"], in: root)
            finished.signal()
        }
        finished.wait()
        try expect(result?.code == 0, "the fixture process did not run")
        try expect(!fired,
                   "waiting for a subprocess ran the run loop on its worker thread")

        // The timeout path is the other half of that wait, and it still ends
        // a process that overstays.
        let started = Date()
        let timedOut = GitService.runProcess(executable: URL(fileURLWithPath: "/bin/sleep"),
                                             arguments: ["30"], in: root, timeout: 0.3)
        try expect(timedOut.code != 0, "a process past its deadline reported success")
        try expect(Date().timeIntervalSince(started) < 10,
                   "the deadline did not end the process promptly")
    }

    /// The hovered row is remembered from before the list changed. Asking a
    /// table for a row it no longer has raises, and this runs from `layout()`,
    /// where AppKit turns an exception into a hard crash instead of letting it
    /// propagate — EXC_BREAKPOINT in +[NSApplication _crashOnException:].
    private static func testHoverSurvivesTheRowsGoingAway() throws {
        final class Rows: NSObject, NSTableViewDataSource {
            var count = 0
            func numberOfRows(in tableView: NSTableView) -> Int { count }
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let table = GitTableView()
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c")))
        let rows = Rows()
        rows.count = 30
        table.dataSource = rows
        table.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        window.contentView?.addSubview(table)
        table.reloadData()
        table.layoutSubtreeIfNeeded()
        defer { window.close() }

        try expect(table.numberOfRows == 30, "the fixture table has \(table.numberOfRows) rows")
        table.setHoveredRowForTesting(25)
        try expect(table.hoveredRow == 25, "the row did not take the hover")

        // The panel refreshes with a shorter list — a commit, a stage, or a
        // switch to another project.
        rows.count = 1
        table.reloadData()
        table.layoutSubtreeIfNeeded()

        // Moving the hover now has to let go of a row that no longer exists.
        table.setHoveredRowForTesting(0)
        try expect(table.hoveredRow == 0,
                   "the hover did not move: \(table.hoveredRow)")
        // And clearing it from a list that shrank to nothing.
        rows.count = 0
        table.reloadData()
        table.setHoveredRowForTesting(-1)
        try expect(table.hoveredRow == -1, "the hover did not clear")

    }

    /// A crash report carries the frames but not the exception. When the throw
    /// is entirely inside AppKit — a window frame rejected during a display
    /// pass — neither the reason nor a frame of ours reaches the report, and
    /// there is nothing to diagnose from. This keeps the reason.
    private static func testExceptionLogKeepsTheReason() throws {
        let url = ExceptionLog.fileURL
        let before = (try? Data(contentsOf: url).count) ?? 0
        defer {
            // Leave the file as it was found: truncate back to its old length.
            if let handle = try? FileHandle(forWritingTo: url) {
                try? handle.truncate(atOffset: UInt64(before))
                try? handle.close()
            }
        }

        let exception = NSException(
            name: .invalidArgumentException,
            reason: "Invalid parameter not satisfying: a test reason",
            userInfo: nil)
        ExceptionLog.record(exception)

        guard let written = try? String(contentsOf: url, encoding: .utf8) else {
            throw Failure(description: "nothing was written to \(url.path)")
        }
        try expect(written.count > before, "the record did not append")
        let entry = String(written.dropFirst(before))
        try expect(entry.contains("NSInvalidArgumentException"),
                   "the exception name was not recorded: \(entry)")
        try expect(entry.contains("a test reason"),
                   "the reason — the only part a crash report drops — was not recorded")
        try expect(entry.contains("screens:") && entry.contains("windows:"),
                   "the display context was not recorded, which is what these arrive during")

        // Raised off the main thread, the handler runs there too. The reason
        // and the stack are still written; AppKit is not asked, since asking
        // it from there can deadlock or throw again inside the handler.
        let offMainStart = (try? Data(contentsOf: url).count) ?? 0
        let written2 = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            ExceptionLog.record(NSException(name: .invalidArgumentException,
                                            reason: "raised off the main thread in a test",
                                            userInfo: nil))
            written2.signal()
        }
        guard written2.wait(timeout: .now() + 5) == .success else {
            throw Failure(description: "recording off the main thread never finished")
        }
        let offMain = String(((try? String(contentsOf: url, encoding: .utf8)) ?? "")
                                .dropFirst(offMainStart))
        try expect(offMain.contains("raised off the main thread in a test"),
                   "an exception raised off the main thread lost its reason")
        try expect(offMain.contains("not read") && !offMain.contains("screens: "),
                   "the handler asked AppKit from a background thread: \(offMain)")
    }

    private static func testProjectTitleStrip() throws {
        let root = try temporaryDirectory("project-title")
        defer { try? FileManager.default.removeItem(at: root) }
        try expect(GitService.run(["init", "-q", "-b", "trunk"], in: root).code == 0,
                   "git init failed")
        _ = GitService.run(["config", "user.name", "Gift Test"], in: root)
        _ = GitService.run(["config", "user.email", "gift@example.invalid"], in: root)
        try Data("fixture\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        // An unborn branch has no name to report yet; commit so `trunk` exists.
        try expect(GitService.commit("fixture", in: root).code == 0, "fixture commit failed")

        let workspace = WorkspaceWindowController()
        defer { workspace.window?.close() }
        workspace.openProject(root)
        workspace.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))

        let title = workspace.sidebar.projectTitle
        // The project name shows immediately; the branch arrives with Git.
        try expect(title.titleForTesting.project == root.lastPathComponent,
                   "the titlebar strip did not show the project name")
        let deadline = Date().addingTimeInterval(5)
        while title.titleForTesting.branch.isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        try expect(title.titleForTesting.branch == "trunk",
                   "the titlebar strip did not pick up the branch: "
                    + "\(title.titleForTesting.branch)")

        // The row in the Projects panel carries the same branch, and after it,
        // a gap further along, how many files the project has changed but not
        // committed — the count the Git button shows, on the project it
        // belongs to. Nothing at all while the project is clean.
        let projectsPanel = workspace.sidebar.projectsPanel
        _ = projectsPanel.view
        // Name, branch, and who commits here — the repository's own user.name,
        // which is whose name the next commit from this row will carry.
        try expect(projectsPanel.rowsForTesting.first?.titleForTesting
                    == "\(root.lastPathComponent)  trunk  Gift Test",
                   "a clean project's row does not read as name, branch and user: "
                     + "\(String(describing: projectsPanel.rowsForTesting.first?.titleForTesting))")
        try expect(projectsPanel.changes.rowCountForTesting == 0,
                   "a clean project's changes column is not empty")
        try Data("new\n".utf8).write(to: root.appendingPathComponent("changed.txt"))
        workspace.refreshGit(requireFollowUp: true)
        let wanted = "\(root.lastPathComponent)  trunk  Gift Test  1"
        let countDeadline = Date().addingTimeInterval(5)
        while projectsPanel.rowsForTesting.first?.titleForTesting != wanted,
              Date() < countDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        try expect(projectsPanel.rowsForTesting.first?.titleForTesting == wanted,
                   "the row does not carry the change count: "
                     + "\(String(describing: projectsPanel.rowsForTesting.first?.titleForTesting))")
        // Drawn in the round badge a count takes everywhere else in the
        // sidebar, not as loose digits after the branch.
        let badge = projectsPanel.rowsForTesting.first?.badgeImageForTesting
        try expect(badge != nil,
                   "the count is plain text rather than the sidebar's badge")
        try expect(badge.map { $0.size.width == $0.size.height
                                && $0.size.width >= SidebarCellDrawing.Badge.minimumDiameter }
                    == true,
                   "the badge is not the round mark the sidebar draws a count in: "
                     + "\(String(describing: badge?.size))")

        // The branch follows the name, and the name never takes more than
        // half the row: the branch, who commits and the count need the rest.
        let row = projectsPanel.rowsForTesting[0]
        row.frame = NSRect(x: 0, y: 0, width: 300, height: ProjectRowView.height)
        try expect(row.columnDividerForTesting <= 150,
                   "the name takes more than half the row: \(row.columnDividerForTesting)")
        try expect(row.branchRectForTesting.minX >= row.columnDividerForTesting,
                   "the branch is drawn over the name: "
                     + "\(row.branchRectForTesting)")
        let shortName = ProjectRowView()
        shortName.configure(name: "app", branch: "trunk", user: "", changes: 0,
                            path: "/tmp/app", isActive: false)
        shortName.frame = NSRect(x: 0, y: 0, width: 400, height: ProjectRowView.height)
        try expect(shortName.columnDividerForTesting < 100,
                   "a short name still pushes the branch to the middle of the row: "
                     + "\(shortName.columnDividerForTesting)")

        // The project being shown carries a band; the row under the pointer
        // does not — a wash that follows the mouse across the headings read as
        // a third list laid over the two they head.
        //
        // A row of its own: the panel's real ones belong to its stack, and
        // taking one out to look at it would leave the panel a row short.
        let sample = ProjectRowView()
        sample.configure(name: "project", branch: "trunk", user: "Ada",
                         changes: 2, path: "/tmp/project", isActive: true)
        let backdrop = FlatView(frame: NSRect(x: 0, y: 0, width: 300,
                                              height: ProjectRowView.height))
        backdrop.fillColor = Theme.panelBackground
        backdrop.addSubview(sample)
        sample.frame = backdrop.bounds
        func rowPixel() throws -> NSColor {
            backdrop.displayIfNeeded()
            guard let rep = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds)
            else { throw Failure(description: "the row would not render") }
            backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / max(1, backdrop.bounds.width)
            // Clear of the glyphs and of both marks: the very top of the row,
            // in the left column.
            guard let colour = rep.colorAt(x: Int(100 * scale),
                                           y: Int(1 * scale)) else {
                throw Failure(description: "no pixel to read")
            }
            return colour.usingColorSpace(.sRGB) ?? colour
        }
        /// A rendered pixel comes back through a colour-space conversion, so it
        /// lands a shade off the value that was asked for. The washes this is
        /// looking for are half a channel apart, not a thousandth.
        func matches(_ colour: NSColor, _ wanted: NSColor) -> Bool {
            guard let wanted = wanted.usingColorSpace(.sRGB) else { return false }
            return abs(colour.redComponent - wanted.redComponent) < 0.02
                && abs(colour.greenComponent - wanted.greenComponent) < 0.02
                && abs(colour.blueComponent - wanted.blueComponent) < 0.02
        }
        let selectedPixel = try rowPixel()
        try expect(matches(selectedPixel, Theme.selectedControl),
                   "the project being shown carries no band: \(selectedPixel)")
        sample.configure(name: "project", branch: "trunk", user: "Ada",
                         changes: 2, path: "/tmp/project", isActive: false)
        sample.hoverForTesting(at: NSPoint(x: 100, y: ProjectRowView.height / 2))
        let hoveredPixel = try rowPixel()
        try expect(matches(hoveredPixel, Theme.panelBackground),
                   "the row under the pointer is washed with a background: "
                     + "\(hoveredPixel)")

        // Each heading carries a mark saying what it is: the folder for the
        // project, Git's own for the branch. The two are set alike, so this is
        // what tells them apart at a glance.
        let marks = row.columnIconsForTesting
        try expect(marks.name.0 == "folder-base" && marks.branch.0 == "git",
                   "the headings are not marked as the folder and Git: "
                     + "\(marks.name.0) / \(marks.branch.0)")
        try expect(marks.name.1.maxX <= row.columnDividerForTesting
                    && marks.branch.1.minX >= row.columnDividerForTesting,
                   "a heading's mark is not beside its own heading: "
                     + "\(marks.name.1) / \(marks.branch.1)")
        try expect(row.branchRectForTesting.minX >= marks.branch.1.maxX,
                   "the branch is drawn over its own mark")

        // The branch is set like the project's name: same size, same ink, so
        // the row reads as two headings rather than a name with a note after it.
        let nameRun = row.nameLabelForTesting
        let branchRun = row.labelForTesting
        try expect(nameRun.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                    == branchRun.attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
                   "the branch is not set in the project name's font: "
                     + "\(String(describing: branchRun.attribute(.font, at: 0, effectiveRange: nil)))")
        try expect(sameColor(
                    nameRun.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                    branchRun.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor),
                   "the branch is not drawn in the project name's colour")

        // Under the expanded row: the changes over the history, and no note
        // saying it is not a repository.
        workspace.window?.contentView?.layoutSubtreeIfNeeded()
        try expect(projectsPanel.gitListsVisibleForTesting
                    && !projectsPanel.notRepositoryVisibleForTesting,
                   "a repository was not given its Git lists")
        // A 1pt border inside each region, one hue each: what has changed, and
        // what has been committed. Drawn inside, so a region's own content is
        // inset by the width rather than running under its edge.
        try expect(sameColor(projectsPanel.gitColumnForTesting.firstBorder,
                             ProjectColumnsView.regionBorder(Theme.orange))
                    && sameColor(projectsPanel.gitColumnForTesting.secondBorder,
                                 ProjectColumnsView.regionBorder(Theme.purple)),
                   "the two regions do not carry orange and purple")
        try expect(ProjectColumnsView.borderWidth == 1,
                   "the region borders are \(ProjectColumnsView.borderWidth)pt, not 1")
        // Taken down from the hue itself: saturated frames are the loudest
        // thing in a panel whose palette is two steps off black.
        try expect(ProjectColumnsView.regionBorder(Theme.orange).alphaComponent < 0.6,
                   "the region borders are drawn at full strength")

        // The changes list what the project has changed, and a click on one
        // asks for that file's diff.
        try expect(projectsPanel.changes.rowCountForTesting == 1
                    && projectsPanel.changes.rowNameForTesting(0) == "changed.txt",
                   "the changes column does not list the change: "
                     + "\(projectsPanel.changes.entriesForTesting.map(\.path))")
        // The commit line starts directly under the project's row, and the
        // list directly under the line. A table left on the system's own style
        // insets its first row, which set the list ten points lower still.
        let barTop = projectsPanel.changes.commitBarTopInsetInWindowForTesting
        let changesTop = projectsPanel.changes.firstRowTopInsetInWindowForTesting
        let rowBottom: CGFloat? = workspace.window.map { window in
            window.frame.height - row.convert(row.bounds, to: nil).minY
        }
        try expect(barTop != nil && rowBottom != nil
                    && abs(barTop! - rowBottom! - ProjectColumnsView.borderWidth) <= 0.5,
                   "the commit line does not start under the project's row: "
                     + "\(String(describing: barTop)) vs \(String(describing: rowBottom))")
        try expect(changesTop != nil && barTop != nil
                    && abs(changesTop! - (barTop! + ProjectCommitBar.height)) <= 0.5,
                   "the changes list does not start under the commit line: "
                     + "\(String(describing: changesTop)) vs \(String(describing: barTop))")
        var openedDiff: String?
        let realDiffHandler = workspace.sidebar.onGitDiff
        workspace.sidebar.onGitDiff = { entry, _ in openedDiff = entry.path }
        projectsPanel.changes.clickRowForTesting(0)
        workspace.sidebar.onGitDiff = realDiffHandler
        try expect(openedDiff == "changed.txt",
                   "clicking a change did not ask for its diff: "
                     + "\(String(describing: openedDiff))")
        try expect(realDiffHandler != nil,
                   "the window does not answer for a diff asked for by the panel")

        // Under the changes, the branch's commits — one line per commit, its
        // files under it when it is opened.
        let gitColumn = projectsPanel.gitColumnForTesting
        try expect(gitColumn.first === projectsPanel.changes.view
                    && gitColumn.second === projectsPanel.history.view,
                   "the Git column is not the changes over the history")
        projectsPanel.history.settleForTesting()
        try expect(projectsPanel.history.commitSubjectsForTesting == ["fixture"],
                   "the history does not list the project's commits: "
                     + "\(projectsPanel.history.commitSubjectsForTesting)")
        try expect(projectsPanel.history.rowSubjectForTesting(0) == "fixture",
                   "a history row does not draw its commit's subject")
        // Opening a commit lists its files; clicking one asks for that commit's
        // diff of it.
        projectsPanel.history.clickRowForTesting(0)
        let filesDeadline = Date().addingTimeInterval(5)
        while projectsPanel.history.fileRowsForTesting.isEmpty, Date() < filesDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        try expect(projectsPanel.history.fileRowsForTesting == ["file.txt"],
                   "opening a commit did not list its files: "
                     + "\(projectsPanel.history.fileRowsForTesting)")
        var openedCommitFile: String?
        let realCommitDiff = workspace.sidebar.onGitCommitDiff
        workspace.sidebar.onGitCommitDiff = { _, file, _ in openedCommitFile = file.path }
        projectsPanel.history.clickRowForTesting(1)
        workspace.sidebar.onGitCommitDiff = realCommitDiff
        try expect(openedCommitFile == "file.txt",
                   "clicking a commit's file did not ask for its diff: "
                     + "\(String(describing: openedCommitFile))")
        try expect(realCommitDiff != nil,
                   "the window does not answer for a commit diff from the panel")
        projectsPanel.history.clickRowForTesting(0)
        try expect(projectsPanel.history.fileRowsForTesting.isEmpty,
                   "clicking an open commit did not close it again")

        // Neither list carries a strip of its own: both start at their first
        // row, under the headings the project's row already gives them.
        try expect(projectsPanel.history.view.subviews.allSatisfy { $0 is NSScrollView },
                   "the history list took a heading row back")

        // A commit moves HEAD and the list follows without being asked: the
        // window's own status refresh carries the commit it is on, and the log
        // is re-read exactly when that moves — not on every save.
        try Data("more\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        try expect(GitService.commit("Second", in: root).code == 0,
                   "the fixture could not commit again")
        workspace.refreshGit(requireFollowUp: true)
        let historyDeadline = Date().addingTimeInterval(5)
        while !projectsPanel.history.commitSubjectsForTesting.contains("Second"),
              Date() < historyDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        try expect(projectsPanel.history.commitSubjectsForTesting == ["Second", "fixture"],
                   "the history did not follow the new commit: "
                     + "\(projectsPanel.history.commitSubjectsForTesting)")

        // A push moves the upstream, not HEAD. A list that watched HEAD alone
        // went on drawing the ↑ over commits that were already pushed, until
        // the project was left and come back to.
        func settleHistory(_ what: String, until done: @escaping () -> Bool) throws {
            let deadline = Date().addingTimeInterval(5)
            while !done(), Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            try expect(done(), what)
        }
        let remote = try temporaryDirectory("project-title-remote")
        defer { try? FileManager.default.removeItem(at: remote) }
        try expect(GitService.run(["init", "-q", "--bare"], in: remote).code == 0,
                   "the fixture remote was not created")
        _ = GitService.run(["remote", "add", "origin", remote.path], in: root)
        try expect(GitService.run(["push", "-q", "-u", "origin", "trunk"], in: root).code == 0,
                   "the fixture could not push")
        workspace.refreshGit(requireFollowUp: true)
        try settleHistory("everything is pushed, but the history still marks commits "
                            + "unpushed: \(projectsPanel.history.unpushedSubjectsForTesting)") {
            projectsPanel.history.unpushedSubjectsForTesting.isEmpty
        }
        try Data("later\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        try expect(GitService.commit("Third", in: root).code == 0,
                   "the fixture could not commit a third time")
        workspace.refreshGit(requireFollowUp: true)
        try settleHistory("a commit that is not pushed is not marked: "
                            + "\(projectsPanel.history.unpushedSubjectsForTesting)") {
            projectsPanel.history.unpushedSubjectsForTesting == ["Third"]
        }
        try expect(GitService.run(["push", "-q", "origin", "trunk"], in: root).code == 0,
                   "the fixture could not push again")
        workspace.refreshGit(requireFollowUp: true)
        try settleHistory("the ↑ outlived the push: "
                            + "\(projectsPanel.history.unpushedSubjectsForTesting)") {
            projectsPanel.history.unpushedSubjectsForTesting.isEmpty
        }

        // Everything behind HEAD is listed, including commits made on another
        // branch and merged in.
        _ = GitService.run(["checkout", "-q", "-b", "side"], in: root)
        try Data("side\n".utf8).write(to: root.appendingPathComponent("side.txt"))
        try expect(GitService.commit("Side work", in: root).code == 0,
                   "the fixture could not commit on the side branch")
        _ = GitService.run(["checkout", "-q", "trunk"], in: root)
        try expect(GitService.run(["merge", "--no-ff", "-q", "-m", "Merge side", "side"],
                                  in: root).code == 0,
                   "the fixture could not merge the side branch")
        workspace.refreshGit(requireFollowUp: true)
        try settleHistory("the merge and the commit behind it are missing from the "
                            + "list: \(projectsPanel.history.commitSubjectsForTesting)") {
            let listed = projectsPanel.history.commitSubjectsForTesting
            return listed.contains("Merge side") && listed.contains("Side work")
        }
        let sideRow = projectsPanel.history.commitSubjectsForTesting
            .firstIndex(of: "Side work")
        try expect(GitCommitCell.columnGap == 10,
                   "the history columns are \(GitCommitCell.columnGap)pt apart, not 10")
        // One line per commit: exact refs, commit ID, message, author and time.
        // Refs are names pointing at this commit, not a guessed branch owner.
        guard let sideIndex = sideRow,
              let sideCell = projectsPanel.history.rowCellForTesting(sideIndex) else {
            throw Failure(description: "the side commit built no cell")
        }
        let rowHeight = GitCommitCell.height
        try expect(rowHeight == Theme.treeRowHeight(),
                   "a commit row is \(rowHeight)pt, not one list row")
        try expect(projectsPanel.history.rowHeightForTesting(sideIndex) == rowHeight,
                   "the list does not give a commit one line")
        func drawn(_ cell: GitCommitCell, width: CGFloat) -> [NSRect] {
            cell.frame = NSRect(x: 0, y: 0, width: width, height: rowHeight)
            if let rep = cell.bitmapImageRepForCachingDisplay(in: cell.bounds) {
                cell.cacheDisplay(in: cell.bounds, to: rep)
            }
            return [cell.drawnHashRectForTesting, cell.drawnSubjectRectForTesting,
                    cell.drawnAuthorRectForTesting, cell.drawnDateRectForTesting]
        }
        let wideColumns = drawn(sideCell, width: 640)
        try expect(wideColumns.allSatisfy { $0.width > 0 },
                   "a column was not drawn: \(wideColumns)")
        for (left, right) in zip(wideColumns, wideColumns.dropFirst()) {
            try expect(abs(right.minX - left.maxX - GitCommitCell.columnGap) <= 0.5,
                       "the columns are not \(GitCommitCell.columnGap)pt apart: \(wideColumns)")
        }
        try expect(Set(wideColumns.map(\.midY)).count == 1, "the columns are not on one line")
        // The time is the commit's own, written out, at the trailing edge.
        try expect(sideCell.dateForTesting.range(
                    of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$"#, options: .regularExpression) != nil,
                   "the row's time is not absolute: \(sideCell.dateForTesting)")
        // The graph opens the row; commit metadata follows in aligned columns.
        try expect(sideCell.graphWidthForTesting > 0
                    && sideCell.graphRowForTesting != nil,
                   "the history row has no leading graph column")
        let refBoxes = sideCell.drawnRefRectsForTesting
        try expect(sideCell.refLabelsForTesting == ["side"] && refBoxes.count == 1,
                   "the exact branch ref is not shown: \(sideCell.refLabelsForTesting)")
        try expect(abs(refBoxes[0].minX - 8 - sideCell.graphWidthForTesting) <= 0.5,
                   "the refs overlap the graph column: \(refBoxes)")
        try expect(sideCell.drawnGraphRectForTesting.width > 0
                    && abs(refBoxes[0].minX - sideCell.drawnGraphRectForTesting.maxX
                           - GitCommitCell.columnGap) <= 0.5,
                   "the graph has no clear gap before the refs")
        try expect(abs(wideColumns[0].minX - refBoxes[0].maxX
                       - GitCommitCell.columnGap) <= 0.5,
                   "the inline refs have no clear gap before the commit ID")
        try expect(abs(wideColumns[3].maxX - (640 - 8)) <= 0.5,
                   "the time does not end at the row's edge: \(wideColumns[3])")
        try expect(sideCell.authorForTesting.hasSuffix("Gift Test"),
                   "the author column reads \(sideCell.authorForTesting)")
        try expect((sideCell.accessibilityLabel() ?? "").contains("Refs side"),
                   "the ref is missing from accessibility")
        // Every other column keeps its width: whatever the row gains or loses
        // is the message's.
        let narrowColumns = drawn(sideCell, width: 520)
        for index in [0, 2, 3] {
            try expect(narrowColumns[index].width == wideColumns[index].width,
                       "column \(index) changed width with the row: "
                         + "\(wideColumns[index]) → \(narrowColumns[index])")
        }
        try expect(abs((wideColumns[1].width - narrowColumns[1].width) - 120) <= 0.5,
                   "the message did not take the 120pt the row lost: "
                     + "\(wideColumns[1].width) → \(narrowColumns[1].width)")
        // No bubble following the pointer down the list: the row carries
        // everything it has to say.
        try expect(sideCell.toolTip == nil,
                   "a commit row still carries a tip: "
                     + "\(String(describing: sideCell.toolTip))")
        // Refs are row-local, not a blank fixed-width column. A row without a
        // ref begins its commit ID immediately after the graph; a decorated
        // row moves only by the labels it actually draws.
        var sawUndecoratedRow = false
        for index in 0..<projectsPanel.history.commitSubjectsForTesting.count {
            guard let cell = projectsPanel.history.rowCellForTesting(index) else { continue }
            let boxes = drawn(cell, width: 640)
            let refs = cell.drawnRefRectsForTesting
            if let last = refs.last {
                try expect(abs(boxes[0].minX - last.maxX - GitCommitCell.columnGap) <= 0.5,
                           "a decorated row reserved more than its inline refs")
            } else {
                sawUndecoratedRow = true
                try expect(abs(boxes[0].minX - 8 - cell.graphWidthForTesting) <= 0.5,
                           "an undecorated row kept an empty refs column")
            }
        }
        try expect(sawUndecoratedRow, "the fixture had no undecorated row to verify")
        // Expanding a merge inserts file rows between its split and the next
        // commit. Both live branches must continue through every inserted row.
        guard let mergeIndex = projectsPanel.history.commitSubjectsForTesting.firstIndex(of: "Merge side"),
              let mergeCell = projectsPanel.history.rowCellForTesting(mergeIndex),
              let mergeGraph = mergeCell.graphRowForTesting else {
            throw Failure(description: "the merge built no graph row")
        }
        try expect(mergeGraph.bottomLanes.count == 2, "the merge did not split into two lanes")
        projectsPanel.history.clickRowForTesting(mergeIndex)
        try settleHistory("the expanded merge did not list its files") {
            !projectsPanel.history.fileRowsForTesting.isEmpty
        }
        let fileCount = projectsPanel.history.fileRowsForTesting.count
        for offset in 1...fileCount {
            guard let fileCell = projectsPanel.history.fileCellForTesting(mergeIndex + offset) else {
                throw Failure(description: "the expanded merge built no file cell")
            }
            try expect(fileCell.graphLanesForTesting == mergeGraph.bottomLanes
                        && fileCell.graphWidthForTesting == mergeCell.graphWidthForTesting,
                       "expanded files interrupt or shift the merge's graph lanes")
        }
        try expect(projectsPanel.history.rowCellForTesting(mergeIndex + fileCount + 1)?
                    .graphRowForTesting?.topLanes == mergeGraph.bottomLanes,
                   "the next commit does not reconnect after the expanded file rows")
        projectsPanel.history.clickRowForTesting(mergeIndex)
        // Too narrow for every column, the author gives way before the message
        // goes below its minimum.
        let squeezed = GitCommitCell.layout(
            .init(commitID: 50, author: 120, date: 90),
            in: NSRect(x: 0, y: 0, width: 260, height: rowHeight))
        try expect(squeezed.subject.width >= GitCommitCell.minimumSubjectWidth - 0.5
                    && squeezed.author.width < 120 && squeezed.date.width == 90
                    && squeezed.commitID.width == 50,
                   "a narrow row squeezed the wrong columns: \(squeezed)")

        // A pane is placed by hand and everything inside it by constraints, so
        // the list has to be settled in the same pass: a clip view still the
        // size it was before the pane moved scrolls by the wrong amount, or
        // reports nothing to scroll at all.
        let gitPane = projectsPanel.gitColumnForTesting
        gitPane.setFrameSize(NSSize(width: gitPane.frame.width,
                                    height: gitPane.frame.height + 90))
        gitPane.layout()
        let historyPane = projectsPanel.history.view
        guard let historyScroll = historyPane.subviews
                .compactMap({ $0 as? NSScrollView }).first else {
            throw Failure(description: "the history list has no scroll view")
        }
        try expect(historyScroll.frame.height == historyPane.bounds.height
                    && historyScroll.contentView.bounds.height == historyPane.bounds.height,
                   "the list did not follow its pane: pane \(historyPane.bounds), "
                     + "list \(historyScroll.frame), clip \(historyScroll.contentView.bounds)")

        // The list is read in pages, and asks for another when the end of one
        // comes into view — forty commits with no way to say there are more is
        // not a history.
        try expect(ProjectHistoryViewController.pageSize >= 200,
                   "the history reads \(ProjectHistoryViewController.pageSize) commits a page")
        try expect(projectsPanel.history.limitForTesting
                    == ProjectHistoryViewController.pageSize,
                   "the list did not start at one page")
        projectsPanel.history.scrollToEndForTesting()
        try expect(projectsPanel.history.limitForTesting
                    == ProjectHistoryViewController.pageSize,
                   "a history shorter than a page asked for another one")
        // With more commits than a page holds, reaching the end reads deeper.
        // Measured on a page of two, so the fixture needs no two hundred
        // commits to prove it.
        // Scoped: `defer` runs when its scope ends, and the whole test is a
        // long scope — every later project switch here would read two
        // commits a page.
        do {
            ProjectHistoryViewController.pageSize = 2
            defer { ProjectHistoryViewController.pageSize = 200 }
            let deep = ProjectHistoryViewController()
            _ = deep.view
            deep.view.frame = NSRect(x: 0, y: 0, width: 300, height: 80)
            deep.view.layoutSubtreeIfNeeded()
            deep.setSource(directory: root, state: .init(head: "deep"))
            deep.settleForTesting()
            try expect(deep.limitForTesting == 2 && deep.rowCountForTesting == 2,
                       "the first page is not one page deep: \(deep.limitForTesting) / "
                         + "\(deep.rowCountForTesting)")
            deep.scrollToEndForTesting()
            deep.settleForTesting()
            try expect(deep.limitForTesting > 2 && deep.rowCountForTesting > 2,
                       "reaching the end did not read deeper: \(deep.limitForTesting) / "
                         + "\(deep.rowCountForTesting)")
            // A narrow viewport scrolls the full graph and readable metadata;
            // it must not squeeze branches into the commit ID or message.
            deep.view.setFrameSize(NSSize(width: 120, height: 80))
            deep.view.layoutSubtreeIfNeeded()
            guard let deepScroll = deep.view.subviews.compactMap({ $0 as? NSScrollView }).first,
                  let deepTable = deepScroll.documentView as? NSTableView,
                  let deepColumn = deepTable.tableColumns.first,
                  let deepCell = deep.rowCellForTesting(0) else {
                throw Failure(description: "the narrow history has no table or graph cell")
            }
            try expect(deepScroll.hasHorizontalScroller
                        && deepColumn.minWidth > deepScroll.contentView.bounds.width
                        && deepColumn.width >= deepColumn.minWidth
                        && deepTable.bounds.width >= deepColumn.minWidth,
                       "a narrow viewport clipped the history instead of allowing horizontal scrolling")
            let minimumColumns = drawn(deepCell, width: deepColumn.minWidth)
            try expect(minimumColumns[1].width >= GitCommitCell.minimumSubjectWidth - 0.5
                        && minimumColumns[0].minX >= deepCell.drawnGraphRectForTesting.maxX
                            + GitCommitCell.columnGap - 0.5,
                       "the minimum table width does not preserve graph and readable message columns")
        }

        // Both dragged lines are remembered; a test writes that somewhere of
        // its own rather than into the user's defaults.
        let scratchDefaults = UserDefaults(suiteName: "gift-divider-\(UUID())")!
        projectsPanel.dividerDefaults = scratchDefaults

        // That line is dragged too, and keeps a couple of rows on each side.
        gitColumn.layoutSubtreeIfNeeded()
        let gitHeight = gitColumn.bounds.height
        projectsPanel.dragGitDividerForTesting(to: gitHeight * 0.3)
        gitColumn.layoutSubtreeIfNeeded()
        try expect(abs(gitColumn.divider - gitHeight * 0.3) <= 1,
                   "the Git column's line did not follow the drag: "
                     + "\(gitColumn.divider) of \(gitHeight)")
        // Clear of each other, with each region's own border between them.
        try expect(projectsPanel.changes.view.frame.minY
                    > projectsPanel.history.view.frame.maxY,
                   "the changes and the history overlap: "
                     + "\(projectsPanel.changes.view.frame) / "
                     + "\(projectsPanel.history.view.frame)")
        projectsPanel.dragGitDividerForTesting(to: -400)
        try expect(gitColumn.divider >= ProjectColumnsView.minimumRow,
                   "the changes were squeezed to \(gitColumn.divider)")
        projectsPanel.dragGitDividerForTesting(to: gitHeight + 400)
        try expect(gitHeight - gitColumn.divider >= ProjectColumnsView.minimumRow,
                   "the history was squeezed to \(gitHeight - gitColumn.divider)")
        projectsPanel.dragGitDividerForTesting(to: gitHeight / 2)

        // And it is where the next window will find it.
        try expect(scratchDefaults.object(forKey: "projects_panel_git_divider") != nil,
                   "the line's place was not remembered")

        // The branch is its own target; the name beside it is a label.
        // Measured with a short name, since a temporary directory's is long
        // enough to consume the whole strip.
        title.configure(project: "Gift", branch: "main")
        title.layoutSubtreeIfNeeded()
        let zones = title.zonesForTesting
        try expect(zones.project.width > 0 && zones.branch.width > 0,
                   "the strip did not lay out both halves: \(zones)")
        try expect(zones.branch.minX >= zones.project.maxX,
                   "the halves overlap: \(zones)")
        let inBranch = NSPoint(x: zones.branch.midX, y: zones.branch.midY)
        try expect(title.zoneNameForTesting(at: inBranch) == "branch",
                   "the branch name is not its own click target")
        try expect(title.zoneNameForTesting(
                    at: NSPoint(x: zones.branch.maxX + 40, y: zones.branch.midY)) == nil,
                   "empty space past the branch still counted as a click")

        // The branch drops the menu of branches to switch to, anchored under
        // the name.
        var shownMenu: (menu: NSMenu, origin: NSPoint, anchor: NSView)?
        workspace.presentBranchMenu = { shownMenu = ($0, $1, $2) }
        title.clickForTesting(at: inBranch)
        let menuDeadline = Date().addingTimeInterval(5)
        while shownMenu == nil, Date() < menuDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        try expect(shownMenu != nil, "clicking the branch dropped no menu")
        try expect(shownMenu?.anchor === title
                    && shownMenu?.origin == NSPoint(x: zones.branch.minX,
                                                    y: zones.branch.maxY),
                   "the menu is not anchored under the branch name: "
                     + "\(String(describing: shownMenu?.origin))")
        // A branch's item reads over two lines; its name is the first.
        let listed = (shownMenu?.menu.items ?? []).map {
            ($0.title.components(separatedBy: "\n")[0], $0.state)
        }
        try expect(listed.contains { $0.0 == "trunk" && $0.1 == .on },
                   "the menu does not list the checked-out branch, ticked: "
                     + "\(listed.map(\.0))")

        // At the end of the band: the button that opens another project, and
        // past it the one that opens this project in a terminal.
        let addButton = workspace.sidebar.addProjectButtonForTesting
        let terminalButton = workspace.sidebar.terminalButtonForTesting
        workspace.window?.contentView?.layoutSubtreeIfNeeded()
        try expect(addButton.toolTip?.isEmpty == false && addButton.image != nil,
                   "the add-project button says nothing about what it does")
        try expect(addButton.frame.minX >= title.frame.maxX,
                   "the add-project button overlaps the title: \(addButton.frame)")
        try expect(terminalButton.toolTip?.isEmpty == false && terminalButton.image != nil,
                   "the terminal button says nothing about what it does")
        // Drawn here rather than taken from SF Symbols, whose `terminal` puts a
        // window frame around the prompt. A template image so the band tints it
        // like everything else in it.
        try expect(terminalButton.image?.isTemplate == true
                    && terminalButton.image?.size == NSSize(width: 14, height: 14),
                   "the terminal mark is not the band's own 14pt template: "
                     + "\(String(describing: terminalButton.image?.size))")
        try expect(terminalButton.frame.minX >= addButton.frame.maxX
                    && terminalButton.frame.maxX <= workspace.sidebar.view.bounds.maxX,
                   "the terminal button is not past the add-project button: "
                     + "\(terminalButton.frame) vs \(addButton.frame)")
        try expect(workspace.sidebar.onOpenTerminal != nil,
                   "nothing answers the terminal button")
        var openedTerminal = false
        let realTerminal = workspace.sidebar.onOpenTerminal
        workspace.sidebar.onOpenTerminal = { openedTerminal = true }
        terminalButton.performClick(nil)
        workspace.sidebar.onOpenTerminal = realTerminal
        try expect(openedTerminal, "the terminal button did nothing")

        // The window controller must have claimed the click handler, and the
        // transparent titlebar sitting over this band must not swallow it.
        try expect(title.hasClickHandlerForTesting,
                   "nothing handles a click on the project/branch strip")
        workspace.window?.contentView?.layoutSubtreeIfNeeded()
        let center = title.convert(NSPoint(x: title.bounds.midX, y: title.bounds.midY),
                                   to: nil)
        let hit = workspace.window?.contentView?.superview?.hitTest(center)
        try expect(hit === title,
                   "clicks on the project strip land on \(String(describing: hit)) instead")

        // It sits clear of the traffic lights, inside the band the panel leaves
        // above the projects.
        workspace.window?.contentView?.layoutSubtreeIfNeeded()
        guard let closeButton = workspace.window?.standardWindowButton(.closeButton),
              let zoomButton = workspace.window?.standardWindowButton(.zoomButton) else {
            throw Failure(description: "window has no traffic lights")
        }
        let lightsRight = zoomButton.convert(zoomButton.bounds, to: nil).maxX
        let stripInWindow = title.convert(title.bounds, to: nil)
        let band = workspace.sidebar.panelTopInsetForTesting
        try expect(stripInWindow.minX > lightsRight,
                   "the project strip overlaps the traffic lights "
                    + "(\(stripInWindow.minX) vs \(lightsRight))")
        let panelTop = workspace.sidebar.view.convert(
            workspace.sidebar.view.bounds, to: nil).maxY
        try expect(stripInWindow.maxY <= panelTop + 0.5
                    && stripInWindow.minY >= panelTop - band - 0.5,
                   "the project strip escaped the titlebar band")
        // Its text has to sit on the traffic lights' centre line.
        let buttonInWindow = closeButton.convert(closeButton.bounds, to: nil)
        try expect(abs(stripInWindow.midY - buttonInWindow.midY) <= 0.5,
                   "the project strip is centred at \(stripInWindow.midY) against the "
                    + "traffic lights' \(buttonInWindow.midY)")
        try expect(abs(stripInWindow.height - band) <= 0.5,
                   "the project strip is \(stripInWindow.height)pt tall against the "
                    + "\(band)pt tab row")

        // The traffic-light band is closed off by a 1pt line, sitting exactly
        // on the boundary with the projects.
        let separator = workspace.sidebar.titleSeparatorForTesting
        try expect(sameColor(separator.fillColor, Theme.border),
                   "the title band's line is not the shared border colour")
        try expect(abs(separator.frame.height - 1) < 0.5,
                   "the title band's line is \(separator.frame.height)pt tall")
        // The panel view is not flipped, so the band's lower edge is that far
        // down from the top of the panel.
        let bandEdge = workspace.sidebar.view.bounds.height - band
        try expect(abs(separator.frame.minY - bandEdge) < 0.5
                    && separator.frame.width == workspace.sidebar.view.bounds.width,
                   "the title band's line does not span the boundary: \(separator.frame), "
                    + "band edge at \(bandEdge)")

        // A narrow panel truncates the strip instead of pushing it off-window.
        try expect(title.frame.maxX <= workspace.sidebar.view.bounds.width - 8 + 0.5,
                   "the project strip overflowed the panel")

        // Coming back to the window re-reads every project, not only the one
        // on screen: a commit made in another project's own terminal shows in
        // its row and nowhere else.
        let sibling = try temporaryDirectory("project-title-sibling")
        defer { try? FileManager.default.removeItem(at: sibling) }
        _ = GitService.run(["init", "-q", "-b", "side"], in: sibling)
        _ = GitService.run(["config", "user.name", "Gift Test"], in: sibling)
        _ = GitService.run(["config", "user.email", "gift@example.invalid"], in: sibling)
        try Data("one\n".utf8).write(to: sibling.appendingPathComponent("a.txt"))
        try expect(GitService.commit("start", in: sibling).code == 0,
                   "the sibling project could not commit")
        workspace.openProject(sibling)
        projectsPanel.history.settleForTesting()
        // A switch reads the history once — when the new project's refresh
        // says where it stands. It read once more for the placeholder state it
        // was handed first.
        let readsBefore = projectsPanel.history.loadCountForTesting
        workspace.activateProject(root)
        let switchDeadline = Date().addingTimeInterval(5)
        while projectsPanel.history.loadCountForTesting == readsBefore,
              Date() < switchDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        projectsPanel.history.settleForTesting()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        try expect(projectsPanel.history.loadCountForTesting == readsBefore + 1,
                   "switching projects read the history "
                     + "\(projectsPanel.history.loadCountForTesting - readsBefore) times")
        func siblingRow() -> String? {
            projectsPanel.rowsForTesting
                .first { $0.titleForTesting.hasPrefix(sibling.lastPathComponent) }?
                .titleForTesting
        }
        try settleHistory("the sibling project's row never read its branch: "
                            + "\(String(describing: siblingRow()))") {
            siblingRow()?.contains("side") == true
        }
        try expect(siblingRow()?.hasSuffix("1") == false,
                   "the sibling started with a change: \(String(describing: siblingRow()))")
        // Changed from outside the app, in a project that is not on screen.
        try Data("two\n".utf8).write(to: sibling.appendingPathComponent("b.txt"))
        // The window becoming key is not the app coming back: that happens
        // after every alert and sheet, and each sweep walks every repository.
        let sweepsBefore = workspace.summarySweepCountForTesting
        workspace.windowDidBecomeKey(
            Notification(name: NSWindow.didBecomeKeyNotification))
        try expect(workspace.summarySweepCountForTesting == sweepsBefore,
                   "the window becoming key swept every project")
        workspace.applicationDidBecomeActive()
        try settleHistory("the row did not follow a change made while the app was "
                            + "away: \(String(describing: siblingRow()))") {
            siblingRow()?.hasSuffix("1") == true
        }
        try expect(workspace.summarySweepCountForTesting == sweepsBefore + 1,
                   "coming back did not sweep the other projects")
        // And every time: a second commit in the terminal, and straight back,
        // is exactly when the row has to follow again.
        try Data("three\n".utf8).write(to: sibling.appendingPathComponent("c.txt"))
        workspace.applicationDidBecomeActive()
        try settleHistory("coming straight back again did not re-read the other "
                            + "projects: \(String(describing: siblingRow()))") {
            siblingRow()?.hasSuffix("2") == true
        }

        // A sweep that read the project now on screen does not replace what
        // that project's own refresh said — the snapshot is older.
        let rootRow = { projectsPanel.rowsForTesting
            .first { $0.titleForTesting.hasPrefix(root.lastPathComponent) }?.titleForTesting }
        let rootBefore = rootRow()
        workspace.applySummaryForTesting(branch: "stale-branch", changes: 99, for: root)
        try expect(rootRow() == rootBefore,
                   "a sweep's snapshot replaced the project on screen: "
                     + "\(String(describing: rootRow()))")

        // Leaving every project leaves no subtitle naming one of them.
        try expect(workspace.window?.subtitle.isEmpty == false,
                   "a repository project gave the window no subtitle")
        workspace.deactivateProject()
        try expect(workspace.window?.subtitle == "",
                   "the subtitle outlived the project: "
                     + "\(String(describing: workspace.window?.subtitle))")

        // Collapsed and opened again while a refresh is still out — a save, a
        // return to the window. That refresh is thrown away on arrival, and the
        // one the reopening asked for used to be dropped as its duplicate: the
        // project came back with no history, no changes and no branch.
        workspace.activateProject(root)
        projectsPanel.history.settleForTesting()
        workspace.refreshGit()
        workspace.deactivateProject()
        workspace.activateProject(root)
        let reopenDeadline = Date().addingTimeInterval(5)
        while (projectsPanel.history.commitSubjectsForTesting.isEmpty
                || title.titleForTesting.branch.isEmpty), Date() < reopenDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        try expect(!projectsPanel.history.commitSubjectsForTesting.isEmpty,
                   "a project reopened during a refresh came back with no history")
        try expect(title.titleForTesting.branch == "trunk",
                   "a project reopened during a refresh came back with no branch: "
                     + "\(title.titleForTesting.branch)")
    }

    private static func testProjectCommitLine() throws {
        func key(_ flags: NSEvent.ModifierFlags, keyCode: UInt16 = 36,
                 characters: String = "\r", windowNumber: Int = 0) -> NSEvent {
            // Only fails for an event type that is not a key event.
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode)!
        }
        func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            return condition()
        }

        // One reading of the keys for both boxes: ⌘↩ commits, ⇧⌘↩ pushes,
        // whether the Return is the main one or the keypad's, and whatever
        // Caps Lock is doing. Anything else held down is not the shortcut.
        try expect(CommitShortcut(key([.command])) == .commit
                    && CommitShortcut(key([.command, .shift])) == .push,
                   "⌘↩ and ⇧⌘↩ are not commit and push")
        try expect(CommitShortcut(key([.command, .capsLock])) == .commit
                    && CommitShortcut(key([.command, .numericPad], keyCode: 76)) == .commit,
                   "Caps Lock or the keypad's Enter stops ⌘↩ committing")
        try expect(CommitShortcut(key([])) == nil
                    && CommitShortcut(key([.command, .option])) == nil
                    && CommitShortcut(key([.command], keyCode: 0, characters: "a")) == nil,
                   "a key that is not ⌘↩ or ⇧⌘↩ reads as one")

        // A repository with a remote to push to.
        let root = try temporaryDirectory("commit-line")
        let remote = try temporaryDirectory("commit-line-remote")
        let other = try temporaryDirectory("commit-line-other")
        defer {
            for url in [root, remote, other] { try? FileManager.default.removeItem(at: url) }
        }
        func git(_ args: [String], in directory: URL) -> String {
            GitService.run(args, in: directory).out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = git(["init", "-q", "--bare", "-b", "main"], in: remote)
        _ = git(["init", "-q", "-b", "main"], in: root)
        _ = git(["config", "user.name", "Gift Test"], in: root)
        _ = git(["config", "user.email", "gift@example.invalid"], in: root)
        try Data("one\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        try expect(GitService.commit("fixture", in: root).code == 0, "fixture commit failed")
        _ = git(["remote", "add", "origin", remote.path], in: root)
        try expect(GitService.run(["push", "-q", "-u", "origin", "main"], in: root).code == 0,
                   "the fixture could not push to its remote")
        try Data("two\n".utf8).write(to: root.appendingPathComponent("changed.txt"))

        let changes = ProjectChangesViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 260),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = changes
        window.setContentSize(NSSize(width: 360, height: 260))
        defer { window.close() }
        var changedIn: [URL] = []
        func show(_ directory: URL) {
            let status = GitService.status(in: directory)
            changes.setEntries(status.entries, in: directory,
                               ahead: status.ahead, hasUpstream: status.hasUpstream)
        }
        changes.onChanged = { directory in
            changedIn.append(directory)
            show(directory)
        }
        show(root)
        window.contentView?.layoutSubtreeIfNeeded()
        let bar = changes.commitBarForTesting
        bar.layoutSubtreeIfNeeded()

        // A line at the top of the column: the message, then Commit, then Push
        // at the edge, all on one centre line, and the list under it.
        try expect(bar.frame.height == ProjectCommitBar.height
                    && bar.frame.maxY == changes.view.bounds.height,
                   "the commit line is not a \(ProjectCommitBar.height)pt strip at the top: "
                     + "\(bar.frame) in \(changes.view.bounds)")
        let box = bar.messageBoxFrameForTesting
        let commitFrame = bar.commitButton.frame
        let pushFrame = bar.pushButton.frame
        try expect(box.maxX + ProjectCommitBar.gap == commitFrame.minX
                    && commitFrame.maxX + ProjectCommitBar.gap == pushFrame.minX
                    && pushFrame.maxX == bar.bounds.width - ProjectCommitBar.inset,
                   "the line is not message, Commit, Push: \(box) \(commitFrame) \(pushFrame)")
        // The message is the Git panel's box in one line: out to the region's
        // left edge and its full height, set apart by its fill and nothing
        // drawn around it.
        try expect(box.minX == 0 && box.minY == 0 && box.height == bar.bounds.height,
                   "the message box does not run to the region's edges: \(box) in "
                     + "\(bar.bounds)")
        try expect(box.midY == commitFrame.midY && commitFrame.midY == pushFrame.midY,
                   "the line's parts are not on one centre line")
        // One ground for the whole line — the message, the gaps and both
        // buttons — and no shape round either button while it is not lit.
        func drawn(_ view: NSView) throws -> NSBitmapImageRep {
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw Failure(description: "\(type(of: view)) could not be drawn")
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep
        }
        /// A pixel of a flipped view, by its point.
        func pixel(_ rep: NSBitmapImageRep, of view: NSView, at point: NSPoint) -> NSColor? {
            let scale = CGFloat(rep.pixelsWide) / max(1, view.bounds.width)
            return rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))
        }
        /// A colour as this same window draws it, to compare like with like:
        /// off the window, the same colour comes back in another space.
        func asDrawn(_ colour: NSColor) throws -> NSColor? {
            let reference = FlatView(frame: NSRect(x: 0, y: 0, width: 4, height: 4))
            reference.fillColor = colour
            changes.view.addSubview(reference)
            defer { reference.removeFromSuperview() }
            return pixel(try drawn(reference), of: reference, at: NSPoint(x: 2, y: 2))
        }
        func same(_ a: NSColor?, _ b: NSColor?) -> Bool {
            guard let a, let b else { return false }
            return abs(a.redComponent - b.redComponent) < 0.01
                && abs(a.greenComponent - b.greenComponent) < 0.01
                && abs(a.blueComponent - b.blueComponent) < 0.01
        }
        let ground = try asDrawn(Theme.activeTab)
        let lit = try asDrawn(Theme.activeRow)
        func ungrounded(_ rep: NSBitmapImageRep, _ points: [NSPoint]) -> [NSPoint] {
            points.filter { !same(pixel(rep, of: bar, at: $0), ground) }
        }
        func buttonEdges(_ frame: NSRect) -> [NSPoint] {
            [NSPoint(x: frame.minX + 1, y: frame.minY + 1),
             NSPoint(x: frame.maxX - 1, y: frame.maxY - 1),
             NSPoint(x: frame.minX + 1, y: frame.midY),
             NSPoint(x: frame.midX, y: frame.minY + 1),
             NSPoint(x: frame.minX + 3, y: frame.minY + 3)]
        }
        let rowPoints = [NSPoint(x: 1, y: 1), NSPoint(x: 1, y: bar.bounds.height - 1),
                         NSPoint(x: box.maxX - 1, y: 1),
                         NSPoint(x: box.midX, y: bar.bounds.height - 1),
                         NSPoint(x: box.maxX + ProjectCommitBar.gap / 2, y: bar.bounds.midY),
                         NSPoint(x: commitFrame.midX, y: 1),
                         NSPoint(x: pushFrame.midX, y: bar.bounds.height - 1),
                         NSPoint(x: bar.bounds.width - 1, y: bar.bounds.midY)]
            + buttonEdges(commitFrame) + buttonEdges(pushFrame)
        let off = ungrounded(try drawn(bar), rowPoints)
        try expect(off.isEmpty,
                   "the line is not one ground, or a button draws a shape at rest: \(off)")
        // A disabled button never lights, pointer or not.
        bar.commitButton.setHoveredForTesting(true)
        let disabledHover = try drawn(bar)
        try expect(!bar.commitButton.isEnabled && !bar.commitButton.isLitForTesting
                    && ungrounded(disabledHover, buttonEdges(commitFrame)).isEmpty,
                   "a disabled Commit lights up under the pointer")
        bar.commitButton.setHoveredForTesting(false)
        // A badge button is framed by default; the line's buttons go plain.
        try expect(BadgeButton().style == .bordered
                    && bar.commitButton.style == .plain && bar.pushButton.style == .plain,
                   "the line's buttons are not plain")

        // Its text starts as far in as the Git panel's does.
        let panelTextX: CGFloat = 4 + 5
        try expect(bar.field.frame.minX + 2 == panelTextX,
                   "the message starts \(bar.field.frame.minX + 2)pt in, not \(panelTextX)")
        try expect(bar.pushButton.title == "Push" && bar.commitButton.title == "Commit",
                   "the buttons are not Commit and Push")
        try expect(changes.rowCountForTesting == 1
                    && changes.rowNameForTesting(0) == "changed.txt",
                   "the list under the line lost the change")

        // The Git panel's rules and words: no message, no commit; nothing
        // ahead of the remote, no push.
        try expect(!bar.commitButton.isEnabled
                    && bar.commitButton.toolTip == ProjectChangesViewController.commitHint(
                        possible: false, hasChanges: true),
                   "Commit is live, or explains itself differently, with no message")
        try expect(!bar.pushButton.isEnabled && bar.pushButton.badge.isEmpty
                    && bar.pushButton.toolTip == ProjectChangesViewController.pushHint(ahead: 0),
                   "Push is live with nothing to push")
        let headBefore = git(["rev-parse", "HEAD"], in: root)
        window.makeFirstResponder(bar.field)
        try expect(bar.field.currentEditor() != nil, "the message field could not be typed in")
        try expect(bar.field.drawsPlaceholderForTesting,
                   "the empty field shows no hint while it is being typed in")
        try expect(window.performKeyEquivalent(with: key([.command])),
                   "⌘↩ in the message field was not taken")
        try expect(!changes.isBusyForTesting && git(["rev-parse", "HEAD"], in: root) == headBefore,
                   "⌘↩ committed with no message")

        // Typed, the message is enough.
        bar.field.currentEditor()?.insertText("from the line")
        try expect(!bar.field.drawsPlaceholderForTesting,
                   "the hint stays under the typed message")
        // The message sits on the same line typed and at rest. AppKit's own
        // drawing at rest ignores the centred line and set a draft left in
        // the field at the top of the strip.
        func inkRows(_ rep: NSBitmapImageRep) -> ClosedRange<Int>? {
            let scale = CGFloat(rep.pixelsWide) / max(1, bar.bounds.width)
            var rows: [Int] = []
            for y in 0..<rep.pixelsHigh {
                for x in Int(22 * scale)..<Int(57 * scale) {
                    if let c = rep.colorAt(x: x, y: y), c.brightnessComponent > 0.5 {
                        rows.append(y)
                        break
                    }
                }
            }
            guard let top = rows.min(), let bottom = rows.max() else { return nil }
            return top...bottom
        }
        let typedRows = inkRows(try drawn(bar))
        window.makeFirstResponder(nil)
        let restingRows = inkRows(try drawn(bar))
        try expect(typedRows != nil && typedRows == restingRows,
                   "the message moves when the field is left: typed \(String(describing: typedRows)), "
                     + "at rest \(String(describing: restingRows))")
        window.makeFirstResponder(bar.field)
        try expect(bar.commitButton.isEnabled
                    && bar.commitButton.toolTip == ProjectChangesViewController.commitHint(
                        possible: true, hasChanges: true),
                   "typing a message did not make Commit live")
        try expect(bar.commitButton.toolTip?.contains("⌘↩") == true
                    && bar.pushButton.toolTip?.contains("⇧⌘↩") == true,
                   "the buttons do not name the Git panel's shortcuts")
        // Live, it shows as live: its label in the text colour, and under the
        // pointer, the area a click lands in.
        bar.commitButton.setHoveredForTesting(true)
        let hovered = try drawn(bar)
        // Inside the rounded corners, clear of the label.
        let litPoints = [NSPoint(x: commitFrame.minX + 2, y: commitFrame.midY),
                         NSPoint(x: commitFrame.maxX - 2, y: commitFrame.midY),
                         NSPoint(x: commitFrame.midX, y: commitFrame.minY + 2),
                         NSPoint(x: commitFrame.midX, y: commitFrame.maxY - 2)]
        try expect(bar.commitButton.isLitForTesting
                    && litPoints.allSatisfy {
                        same(pixel(hovered, of: bar, at: $0), lit) },
                   "hovering a live Commit does not light the area it answers to")
        try expect(ungrounded(hovered, buttonEdges(pushFrame)).isEmpty,
                   "hovering Commit lit Push as well")
        bar.commitButton.setHoveredForTesting(false)
        let left = try drawn(bar)
        try expect(ungrounded(left, buttonEdges(commitFrame)).isEmpty,
                   "Commit stays lit after the pointer leaves")
        // Only the field being typed in answers ⌘↩: out of it, the key
        // belongs to whatever else is focused.
        window.makeFirstResponder(nil)
        try expect(!window.performKeyEquivalent(with: key([.command])),
                   "⌘↩ was taken by a message field nobody is typing in")
        try expect(!changes.isBusyForTesting, "⌘↩ committed from outside the field")

        window.makeFirstResponder(bar.field)
        try expect(window.performKeyEquivalent(with: key([.command])),
                   "⌘↩ in the message field was not taken")
        try expect(changes.isBusyForTesting && !bar.commitButton.isEnabled
                    && !bar.pushButton.isEnabled && !bar.field.isEditable,
                   "a running commit left the line live")
        try expect(waitUntil { !changes.isBusyForTesting }, "the commit never finished")
        try expect(git(["log", "-1", "--format=%s"], in: root) == "from the line",
                   "⌘↩ did not commit the message: "
                     + git(["log", "-1", "--format=%s"], in: root))
        try expect(bar.field.stringValue.isEmpty && bar.field.isEditable,
                   "the used message stayed in the field: '\(bar.field.stringValue)'")
        try expect(changedIn == [root],
                   "the commit was not reported for its repository: \(changedIn)")
        try expect(changes.rowCountForTesting == 0, "the committed change is still listed")

        // One commit ahead: Push counts it, as the Git panel's does.
        try expect(bar.pushButton.isEnabled && bar.pushButton.badge == "1"
                    && bar.pushButton.toolTip == ProjectChangesViewController.pushHint(ahead: 1),
                   "Push does not offer the commit just made: "
                     + "\(bar.pushButton.isEnabled) '\(bar.pushButton.badge)'")
        // ⇧⌘↩ through the real event path, typed into the field. A window
        // off screen is sent no keys at all, so this one is put up; whether
        // it is key or not, the shortcut must arrive.
        window.orderFront(nil)
        window.makeFirstResponder(bar.field)
        let push = key([.command, .shift], windowNumber: window.windowNumber)
        NSApp.postEvent(push, atStart: false)
        let pushDeadline = Date().addingTimeInterval(10)
        while changedIn.count < 2 && Date() < pushDeadline {
            if let event = NSApp.nextEvent(matching: .any,
                                           until: Date().addingTimeInterval(0.02),
                                           inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
        try expect(waitUntil { changedIn.count == 2 && !changes.isBusyForTesting },
                   "⇧⌘↩ did not push: \(changedIn)")
        try expect(git(["rev-parse", "main"], in: remote) == git(["rev-parse", "HEAD"], in: root),
                   "the remote did not receive the commit")
        try expect(!bar.pushButton.isEnabled && bar.pushButton.badge.isEmpty,
                   "Push still offers what it has just pushed")
        let remoteHead = git(["rev-parse", "main"], in: remote)
        window.makeFirstResponder(bar.field)
        try expect(window.performKeyEquivalent(with: key([.command, .shift]))
                    && !changes.isBusyForTesting,
                   "⇧⌘↩ pushed with nothing to push")
        try expect(git(["rev-parse", "main"], in: remote) == remoteHead,
                   "the remote moved on a push that had nothing to send")

        // A message belongs to its project. Half-typed and left for another
        // project, it is not there to be committed with that project's
        // changes; back again, it is.
        _ = git(["init", "-q", "-b", "main"], in: other)
        try Data("three\n".utf8).write(to: root.appendingPathComponent("again.txt"))
        show(root)
        window.makeFirstResponder(bar.field)
        bar.field.currentEditor()?.insertText("half written")
        show(other)
        try expect(bar.field.stringValue.isEmpty && bar.field.currentEditor() == nil,
                   "the message followed the switch to another project: "
                     + "'\(bar.field.stringValue)'")
        show(root)
        try expect(bar.field.stringValue == "half written",
                   "the draft did not come back with its project: '\(bar.field.stringValue)'")

        // A commit still running when the user moves on finishes in its own
        // project: the message there is used up, the one now showing is not.
        bar.field.stringValue = "committed while away"
        try expect(bar.commitButton.clickForTesting(), "Commit is not live with a message")
        changes.setEntries([], in: other)
        bar.field.stringValue = "other draft"
        try expect(waitUntil { !changes.isBusyForTesting }, "the commit never finished")
        try expect(git(["log", "-1", "--format=%s"], in: root) == "committed while away",
                   "the commit started before the switch did not land in its project")
        try expect(changedIn.last == root,
                   "the commit was reported for the project on screen, not its own")
        changes.setEntries([], in: other)
        try expect(bar.field.stringValue == "other draft",
                   "a commit finishing elsewhere cleared this project's message")
        show(root)
        try expect(bar.field.stringValue.isEmpty,
                   "the message a commit used came back as a draft")

        // Where the branch stands is not known until the refresh says: Push
        // waits for it instead of guessing there is no upstream.
        changes.setEntries([], in: other)
        try expect(!bar.pushButton.isEnabled,
                   "Push is live before anything is known about the remote")

        // Dragged narrower than its buttons, the line gives up the message
        // box rather than a constraint.
        window.setContentSize(NSSize(width: 90, height: 260))
        window.contentView?.layoutSubtreeIfNeeded()
        bar.layoutSubtreeIfNeeded()
        try expect(bar.messageBoxFrameForTesting.width == 0
                    && bar.messageBoxFrameForTesting.minX == 0,
                   "a narrow line lays its message box out at "
                     + "\(bar.messageBoxFrameForTesting)")

        // In the window: a commit from the line moves everything that reads
        // the repository; one finishing in a project left behind moves that
        // project's row.
        let first = try temporaryDirectory("commit-line-first")
        let second = try temporaryDirectory("commit-line-second")
        defer {
            for url in [first, second] { try? FileManager.default.removeItem(at: url) }
        }
        for directory in [first, second] {
            _ = git(["init", "-q", "-b", "main"], in: directory)
            _ = git(["config", "user.name", "Gift Test"], in: directory)
            _ = git(["config", "user.email", "gift@example.invalid"], in: directory)
            try Data("one\n".utf8).write(to: directory.appendingPathComponent("file.txt"))
            try expect(GitService.commit("fixture", in: directory).code == 0,
                       "fixture commit failed")
            try Data("two\n".utf8).write(to: directory.appendingPathComponent("changed.txt"))
        }
        let workspace = WorkspaceWindowController()
        defer { workspace.window?.close() }
        workspace.openProject(second)
        workspace.openProject(first)
        let projectsPanel = workspace.sidebar.projectsPanel
        _ = projectsPanel.view
        func row(_ directory: URL) -> String? {
            let path = directory.standardizedFileURL.resolvingSymlinksInPath().path
            return projectsPanel.rowsForTesting.first { $0.pathForTesting == path }?.titleForTesting
        }
        try expect(waitUntil { projectsPanel.changes.rowCountForTesting == 1
                                && row(second)?.hasSuffix("  1") == true },
                   "the fixture's changes never showed: "
                     + "\(String(describing: row(first))) / \(String(describing: row(second)))")
        let line = projectsPanel.changes.commitBarForTesting
        // No upstream yet: Push is live to set one up, from the state the
        // window's own refresh hands down.
        try expect(line.pushButton.isEnabled,
                   "the line's Push is not live with no upstream")
        // What the line reports is taken in at once — not left to the watcher
        // on .git, which gets there later or, for a change it cannot see, not
        // at all.
        let windowReads = workspace.gitRefreshRequestCountForTesting
        workspace.sidebar.onProjectGitChanged?(first.standardizedFileURL.resolvingSymlinksInPath())
        try expect(workspace.gitRefreshRequestCountForTesting == windowReads + 1,
                   "a commit from the line did not have the window re-read")
        line.field.stringValue = "from the project row"
        try expect(line.commitButton.clickForTesting(), "Commit is not live in the window")
        try expect(waitUntil {
                        projectsPanel.changes.rowCountForTesting == 0
                            && row(first)?.hasSuffix("  1") == false
                            && projectsPanel.history.commitSubjectsForTesting.first
                                == "from the project row"
                   }, "the window did not take in the commit: "
                        + "\(String(describing: row(first))) / "
                        + "\(projectsPanel.history.commitSubjectsForTesting)")
        try expect(GitService.commit("elsewhere", in: second).code == 0,
                   "the second project's commit failed")
        workspace.sidebar.onProjectGitChanged?(second.standardizedFileURL.resolvingSymlinksInPath())
        try expect(waitUntil { row(second)?.hasSuffix("  1") == false },
                   "the row of a project left behind still counts what was committed: "
                     + "\(String(describing: row(second)))")
    }

    private static func testStripedGitLists() throws {
        let root = try temporaryDirectory("striped-lists")
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) -> String {
            GitService.run(args, in: root).out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = git(["init", "-q", "-b", "main"])
        _ = git(["config", "user.name", "Gift Test"])
        _ = git(["config", "user.email", "gift@example.invalid"])
        for index in 1...5 {
            try Data("\(index)\n".utf8).write(to: root.appendingPathComponent("f\(index).txt"))
            try expect(GitService.commit("commit \(index)", in: root).code == 0,
                       "fixture commit \(index) failed")
        }
        for branch in ["alpha", "beta", "gamma"] { _ = git(["branch", branch]) }
        for name in ["new-one.txt", "new-two.txt"] {
            try Data("new\n".utf8).write(to: root.appendingPathComponent(name))
        }
        func waitUntil(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            return condition()
        }

        let panel = ProjectChangesViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = panel
        window.setContentSize(NSSize(width: 380, height: 420))
        defer { window.close() }

        /// The colour a row is drawn in, from a corner no text reaches.
        func ground(_ row: GitRowView?) throws -> NSColor? {
            guard let row else { return nil }
            row.layoutSubtreeIfNeeded()
            guard let rep = row.bitmapImageRepForCachingDisplay(in: row.bounds) else {
                throw Failure(description: "a row could not be drawn")
            }
            row.cacheDisplay(in: row.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / max(1, row.bounds.width)
            return rep.colorAt(x: Int(scale), y: Int(scale))
        }
        /// A colour as the same window draws it, to compare like with like.
        func asDrawn(_ colour: NSColor, in host: NSView) throws -> NSColor? {
            let swatch = FlatView(frame: NSRect(x: 0, y: 0, width: 4, height: 4))
            swatch.fillColor = colour
            host.addSubview(swatch)
            defer { swatch.removeFromSuperview() }
            guard let rep = swatch.bitmapImageRepForCachingDisplay(in: swatch.bounds) else {
                throw Failure(description: "a swatch could not be drawn")
            }
            swatch.cacheDisplay(in: swatch.bounds, to: rep)
            return rep.colorAt(x: 2, y: 2)
        }
        func same(_ a: NSColor?, _ b: NSColor?) -> Bool {
            guard let a, let b else { return false }
            return abs(a.redComponent - b.redComponent) < 0.01
                && abs(a.greenComponent - b.greenComponent) < 0.01
                && abs(a.blueComponent - b.blueComponent) < 0.01
        }
        let plain = try asDrawn(Theme.panelBackground, in: panel.view)
        let stripe = try asDrawn(Theme.stripedRow, in: panel.view)
        let hover = try asDrawn(Theme.hover, in: panel.view)
        // Three colours, none of which passes for another: the two grounds a
        // list alternates between, and the row under the pointer.
        try expect(!same(plain, stripe) && !same(stripe, hover) && !same(plain, hover),
                   "the stripe, the plain row and the hovered row are not three colours")

        /// What the first rows are drawn in, as plain / stripe / hover.
        func pattern(_ count: Int, _ rowView: (Int) -> GitRowView?) throws -> [String] {
            try (0..<count).map { index in
                let colour = try ground(rowView(index))
                if same(colour, plain) { return "plain" }
                if same(colour, stripe) { return "stripe" }
                if same(colour, hover) { return "hover" }
                return "other"
            }
        }

        // Changes stays a plain list.
        panel.setEntries(GitService.status(in: root).entries, in: root)
        try expect(waitUntil { panel.rowCountForTesting == 2 }, "the changes never listed")
        let changes = try pattern(2) { panel.rowViewForTesting($0) }
        try expect(changes == ["plain", "plain"],
                   "the Changes list is striped: \(changes)")

        // The history alternates, and the row under the pointer is its own
        // colour whichever of the two it sits on — and gives it back when it
        // goes.
        let history2 = ProjectHistoryViewController()
        let window2 = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
                               styleMask: [.titled], backing: .buffered, defer: false)
        window2.contentViewController = history2
        window2.setContentSize(NSSize(width: 380, height: 420))
        defer { window2.close() }
        history2.setSource(directory: root,
                           state: .init(head: git(["rev-parse", "HEAD"]), ahead: 0,
                                        hasUpstream: false))
        history2.settleForTesting()
        let projectRows = try pattern(4) { history2.rowViewForTesting($0) }
        try expect(projectRows == ["plain", "stripe", "plain", "stripe"],
                   "the project's history does not alternate: \(projectRows)")
        history2.setHoveredRowForTesting(1)
        let projectHover = try pattern(3) { history2.rowViewForTesting($0) }
        try expect(projectHover == ["plain", "hover", "plain"],
                   "hovering a commit in the project's history: \(projectHover)")
        history2.setHoveredRowForTesting(-1)
        // Opening a commit puts its files between the commits: every row
        // below takes the colour of its new place, not the one it had.
        history2.clickRowForTesting(0)
        try expect(waitUntil { history2.rowCountForTesting > 5 },
                   "the first commit did not open")
        let opened = try pattern(4) { history2.rowViewForTesting($0) }
        try expect(opened == ["plain", "stripe", "plain", "stripe"],
                   "rows kept the colours of their old places: \(opened)")
    }

    /// Git keeps a branch in one working tree at a time. A branch another
    /// tree holds is listed as such and cannot be chosen, rather than being
    /// offered and answered with Git's fatal.
    private static func testBranchesHeldByAnotherWorktree() throws {
        let root = try temporaryDirectory("worktrees")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        func git(_ args: [String]) -> String {
            GitService.run(args, in: repository).out
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = git(["init", "-q", "-b", "main"])
        _ = git(["config", "user.name", "Gift Test"])
        _ = git(["config", "user.email", "gift@example.invalid"])
        try Data("one\n".utf8).write(to: repository.appendingPathComponent("file.txt"))
        try expect(GitService.commit("fixture", in: repository).code == 0,
                   "fixture commit failed")
        _ = git(["branch", "side"])
        // A second working tree, as `git worktree add` leaves one.
        let elsewhere = root.appendingPathComponent("side-tree", isDirectory: true)
        try expect(GitService.run(["worktree", "add", "-q", elsewhere.path, "side"],
                                  in: repository).code == 0,
                   "the fixture worktree was not created")

        let branches = GitService.branches(in: repository)
        guard let side = branches.first(where: { $0.name == "side" }),
              let main = branches.first(where: { $0.name == "main" }) else {
            throw Failure(description: "the fixture's branches are missing: "
                            + "\(branches.map(\.name))")
        }
        try expect(side.heldByWorktree.map { $0.hasSuffix("side-tree") } == true,
                   "the branch in the other tree does not say where it is: "
                     + "\(String(describing: side.heldByWorktree))")
        // The branch this window is on is held by this tree, which is not
        // something to warn about.
        try expect(main.isCurrent && main.heldByWorktree == nil,
                   "the checked-out branch was reported as held elsewhere")

        // Choosing it is refused before Git is asked, and the refusal says
        // where to look.
        guard case .unavailable(let reason) =
                WorkspaceWindowController.branchSwitch(to: side, from: "main") else {
            throw Failure(description: "a branch held by another tree was offered as switchable")
        }
        try expect(reason.contains("side-tree") && reason.contains("working tree"),
                   "the refusal does not say where the branch is: \(reason)")

        // And the menu shows it dimmed, with the tree it is in, rather than
        // offering it.
        let workspace = WorkspaceWindowController()
        defer { workspace.window?.close() }
        let menu = workspace.branchMenu(branches, in: repository)
        guard let item = menu.items.first(where: {
            $0.title.components(separatedBy: "\n")[0] == "side"
        }) else {
            throw Failure(description: "the menu does not list the branch: "
                            + "\(menu.items.map(\.title))")
        }
        try expect(!item.isEnabled, "a branch held by another tree can still be chosen")
        try expect(item.title.contains("in use by side-tree"),
                   "the item does not say which tree holds it: \(item.title)")
        // Deleting it is not offered either, for the same reason Git refuses.
        let deletable = menu.items.first { $0.title == "Delete Branch" }?
            .submenu?.items.map { $0.title.components(separatedBy: "\n")[0] } ?? []
        try expect(!deletable.contains("side"),
                   "deleting a branch another tree holds is still offered: \(deletable)")

        _ = GitService.run(["worktree", "remove", "--force", elsewhere.path], in: repository)
        let freed = GitService.branches(in: repository)
        try expect(freed.first(where: { $0.name == "side" })?.heldByWorktree == nil,
                   "the branch is still held after its tree was removed")
    }

    private static func testTerminalLaunchScripts() throws {
        // It opens the folder in iTerm, with Terminal as the fallback where
        // iTerm is not installed.
        let iTerm = URL(fileURLWithPath: "/Applications/iTerm.app")
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let installed: [String: URL] = ["com.googlecode.iterm2": iTerm,
                                        "com.apple.Terminal": terminal]
        try expect(TerminalLauncher.terminalApplication { installed[$0] } == iTerm,
                   "iTerm is installed but was not preferred")
        try expect(TerminalLauncher.terminalApplication {
                       $0 == "com.apple.Terminal" ? terminal : nil
                   } == terminal,
                   "without iTerm the click did not fall back to Terminal")
        try expect(TerminalLauncher.terminalApplication { _ in nil } == nil,
                   "a machine with neither terminal still resolved one")

        // Launching iTerm opens a window by itself, so the script must not add
        // a second one — that was two windows per click.
        let cold = TerminalLauncher.iTermScript(command: "cd /tmp", reusingLaunchWindow: true)
        try expect(cold.contains("count of windows") && cold.contains("current window"),
                   "the cold-start script does not wait for the launch window")
        let warm = TerminalLauncher.iTermScript(command: "cd /tmp", reusingLaunchWindow: false)
        try expect(!warm.contains("count of windows"),
                   "the warm script waits for a window that already exists")
        try expect(warm.components(separatedBy: "create window").count == 2
                    && cold.components(separatedBy: "create window").count == 2,
                   "a script does not create exactly one window as its last resort")
        try expect(cold.contains("cd /tmp") && warm.contains("cd /tmp"),
                   "the script does not carry the command")

        // The terminal command is quoted, so a space or a quote in the path
        // cannot run as shell syntax.
        let quoted = TerminalLauncher.shellQuoted("/tmp/my project's code")
        try expect(quoted == "'/tmp/my project'\\''s code'",
                   "the path was not shell-quoted: \(quoted)")
        let escaped = TerminalLauncher.appleScriptQuoted("say \"hi\" \\ now")
        try expect(escaped == "say \\\"hi\\\" \\\\ now",
                   "the AppleScript literal was not escaped: \(escaped)")
    }

    private static func testBranchMenu() throws {
        func branch(_ name: String, _ author: String, _ date: String,
                    _ stamp: Int64, current: Bool = false,
                    remote: Bool = false) -> GitService.Branch {
            GitService.Branch(name: name, author: author, createdAt: date,
                              createdTimestamp: stamp, isCurrent: current,
                              isRemote: remote,
                              upstreamRemote: remote ? "origin" : nil,
                              upstreamBranch: remote ? name : nil)
        }
        // Most recent first is how GitService hands them over; the menu puts the
        // checked-out branch at the top regardless. With no Git panel to send
        // the rest to, every branch is listed.
        var branches = (0..<15).map {
            branch("topic-\($0)", "Author \($0)", "2026-08-\(10 + $0) 09:00", Int64(1000 - $0))
        }
        branches.insert(branch("main", "tyxu", "2026-07-01 12:00", 1, current: true), at: 7)
        let entries = WorkspaceWindowController.branchMenuEntries(branches)
        try expect(entries.count == branches.count,
                   "the menu listed \(entries.count) of \(branches.count) branches")
        try expect(entries.first?.name == "main",
                   "the current branch is not first: \(entries.map(\.name))")
        try expect(entries.dropFirst().map(\.name) == (0..<15).map { "topic-\($0)" },
                   "the rest lost their recency order: \(entries.map(\.name))")

        // Each row carries the branch, its author and its date.
        let title = WorkspaceWindowController.branchMenuTitle(
            branch("release", "Ada", "2026-08-20 18:30", 900)).string
        try expect(title.contains("release") && title.contains("Ada")
                    && title.contains("2026-08-20 18:30"),
                   "a menu row is missing branch, author or date: \(title.debugDescription)")
        try expect(title.contains("\n"),
                   "the row is not two lines: \(title.debugDescription)")

        // What a click decides, before any alert is on screen: refuse with a
        // reason, or confirm naming both ends.
        let main = branch("main", "tyxu", "2026-07-01 12:00", 1, current: true)
        let topic = branch("topic", "Ada", "2026-08-20 18:30", 900)
        let danglingRemote = GitService.Branch(
            name: "origin/HEAD", author: "Ada", createdAt: "2026-08-20 18:30",
            createdTimestamp: 900, isCurrent: false, isRemote: true,
            upstreamRemote: "origin", upstreamBranch: nil)

        try expect(WorkspaceWindowController.branchSwitch(to: main, from: "main")
                    == .alreadyCurrent,
                   "switching to the checked-out branch was not refused")
        try expect(WorkspaceWindowController.branchSwitch(to: topic, from: "topic")
                    == .alreadyCurrent,
                   "a branch matching HEAD by name was not treated as current")
        if case .unavailable(let reason) = WorkspaceWindowController.branchSwitch(
            to: danglingRemote, from: "main") {
            try expect(!reason.isEmpty, "the refusal did not say why")
        } else {
            throw Failure(description: "a remote ref with no local name was offered as switchable")
        }
        try expect(WorkspaceWindowController.branchSwitch(to: topic, from: "main")
                    == .confirm(from: "main", to: "topic"),
                   "the confirmation did not name both ends")
        // With no branch known yet the prompt still reads sensibly.
        try expect(WorkspaceWindowController.branchSwitch(to: topic, from: nil)
                    == .confirm(from: "the current branch", to: "topic"),
                   "an unknown current branch produced an empty prompt")

        // The menu itself: local branches to switch to, remote ones in a
        // submenu, then creating and deleting.
        let workspace = WorkspaceWindowController()
        defer { workspace.window?.close() }
        let directory = URL(fileURLWithPath: "/tmp/branch-menu")
        let remoteMain = branch("origin/main", "tyxu", "2026-07-01 12:00", 1, remote: true)
        let menu = workspace.branchMenu([main, topic, remoteMain], in: directory)
        // A branch's item reads over two lines; its name is the first.
        let titles = menu.items.map { $0.title.components(separatedBy: "\n")[0] }
        try expect(titles.prefix(2) == ["main", "topic"],
                   "the local branches do not open the menu: \(titles)")
        try expect(menu.items.first?.state == .on && menu.items[1].state == .off,
                   "only the checked-out branch should be ticked")
        try expect(menu.items.first { $0.title == "Remote Branches" }?.submenu?.items
                    .map { $0.title.components(separatedBy: "\n")[0] } == ["origin/main"],
                   "the remote branches are not in their own submenu: \(titles)")
        try expect(titles.contains("New Branch…"), "the menu offers no new branch: \(titles)")
        let delete = menu.items.first { $0.title == "Delete Branch" }
        try expect(delete?.isEnabled == true
                    && delete?.submenu?.items.map(\.title) == ["topic"],
                   "deleting is not offered for exactly the branches not checked out: "
                     + "\(String(describing: delete?.submenu?.items.map(\.title)))")
        let onlyMain = workspace.branchMenu([main], in: directory)
        try expect(onlyMain.items.first { $0.title == "Delete Branch" }?.isEnabled == false,
                   "a repository with one branch offers to delete one")
    }

    /// The branch menu's three actions, run against a real repository.
    private static func testBranchMenuActions() throws {
        let root = try temporaryDirectory("branch-actions")
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) -> String {
            GitService.run(args, in: root).out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = git(["init", "-q", "-b", "main"])
        _ = git(["config", "user.name", "Gift Test"])
        _ = git(["config", "user.email", "gift@example.invalid"])
        try Data("one\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        try expect(GitService.commit("fixture", in: root).code == 0, "fixture commit failed")
        func waitUntil(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            return condition()
        }

        let workspace = WorkspaceWindowController()
        defer { workspace.window?.close() }
        var alerts: [String] = []
        workspace.presentAlert = { alerts.append($0.messageText) }
        var confirmations: [String] = []
        workspace.confirmAlert = { confirmations.append($0.messageText); return true }
        workspace.openProject(root)
        let title = workspace.sidebar.projectTitle
        try expect(waitUntil { title.titleForTesting.branch == "main" },
                   "the fixture's branch never showed")
        func run(_ path: [String]) throws {
            let menu = workspace.branchMenu(GitService.branches(in: root), in: root)
            var items = menu.items
            var item: NSMenuItem?
            for (index, title) in path.enumerated() {
                item = items.first { $0.title.components(separatedBy: "\n")[0] == title }
                if index < path.count - 1 { items = item?.submenu?.items ?? [] }
            }
            guard let item, let action = item.action else {
                throw Failure(description: "the menu has no \(path.joined(separator: " > "))")
            }
            let finished = workspace.branchOperationsFinishedForTesting
            NSApp.sendAction(action, to: item.target, from: item)
            try expect(waitUntil { workspace.branchOperationsFinishedForTesting > finished },
                       "\(path.joined(separator: " > ")) never finished")
        }

        // New Branch… creates the branch from the chosen base and checks it out.
        workspace.createBranchPrompt = { _, name, base in
            name.stringValue = "feature/one"
            return base.titleOfSelectedItem == "main"
        }
        try run(["New Branch…"])
        try expect(alerts.isEmpty, "creating the branch failed: \(alerts)")
        try expect(git(["branch", "--show-current"]) == "feature/one",
                   "the new branch was not checked out: \(git(["branch", "--show-current"]))")
        try expect(waitUntil { title.titleForTesting.branch == "feature/one" },
                   "the title did not follow the new branch: \(title.titleForTesting.branch)")

        // Choosing a branch switches to it, after saying so.
        try run(["main"])
        try expect(confirmations.last?.contains("to “main”") == true,
                   "the switch was not confirmed naming its target: \(confirmations)")
        try expect(git(["branch", "--show-current"]) == "main",
                   "choosing main did not switch to it")
        try expect(waitUntil { title.titleForTesting.branch == "main" },
                   "the title did not follow the switch")

        // Delete Branch removes a merged branch, again after asking.
        try run(["Delete Branch", "feature/one"])
        try expect(confirmations.last?.contains("feature/one") == true,
                   "the delete was not confirmed: \(confirmations)")
        try expect(!git(["branch", "--list", "feature/one"]).contains("feature/one"),
                   "the branch is still there after deleting it")

        // An unmerged branch is refused by Git, and its words reach the user.
        _ = git(["checkout", "-q", "-b", "unmerged"])
        try Data("two\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        try expect(GitService.commit("only here", in: root).code == 0, "fixture commit failed")
        _ = git(["checkout", "-q", "main"])
        workspace.refreshExternalGitState()
        try expect(waitUntil { title.titleForTesting.branch == "main" }, "back on main")
        try run(["Delete Branch", "unmerged"])
        try expect(alerts.last?.contains("unmerged") == true,
                   "a refused delete said nothing: \(alerts)")
        try expect(git(["branch", "--list", "unmerged"]).contains("unmerged"),
                   "an unmerged branch was deleted")
    }

    private static func testSplitterAndRowGestures() throws {
        // A pane that passes a scroll it cannot use up the responder chain, the
        // way a list shorter than its pane does.
        final class BubblingPane: NSView {
            var received = 0
            override func scrollWheel(with event: NSEvent) {
                received += 1
                // A recursion stops here rather than taking the suite down.
                guard received < 20 else { return }
                nextResponder?.scrollWheel(with: event)
            }
        }
        let splitter = ProjectColumnsView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let left = BubblingPane()
        let right = BubblingPane()
        splitter.first = left
        splitter.second = right
        splitter.addSubview(left)
        splitter.addSubview(right)
        splitter.layout()
        guard let wheelSource = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                        wheelCount: 1, wheel1: -10, wheel2: 0, wheel3: 0),
              let wheel = NSEvent(cgEvent: wheelSource) else {
            throw Failure(description: "could not make a scroll event")
        }
        // A scroll that climbed out of a pane is not sent back down into it:
        // that went round and round until the stack ran out.
        splitter.handleScroll(wheel, at: NSPoint(x: 50, y: 150))
        try expect(left.received == 0,
                   "a scroll that came up out of a pane was sent back down into it: "
                     + "\(left.received)")
        // One that landed on the band reaches the list under it, once.
        splitter.handleScroll(wheel, at: NSPoint(x: splitter.divider - 1, y: 150))
        try expect(left.received == 1,
                   "a scroll on the band did not reach the list under it just once: "
                     + "\(left.received)")

        // A press on a pane's border lands on the splitter — there is no
        // subview there — but only a press on the band moves the line.
        splitter.firstBorder = Theme.red
        splitter.layout()
        let fraction = splitter.fraction
        try expect(!splitter.pressForTesting(at: NSPoint(x: 0.5, y: 150),
                                            draggingTo: NSPoint(x: 120, y: 150)),
                   "a press on a pane's border took hold of the divider")
        try expect(splitter.fraction == fraction, "a press on a border moved the divider")
        try expect(splitter.pressForTesting(at: NSPoint(x: splitter.divider, y: 150),
                                           draggingTo: NSPoint(x: 260, y: 150)),
                   "a press on the divider did not take hold of it")
        try expect(abs(splitter.divider - 260) <= 1,
                   "dragging the divider did not move it: \(splitter.divider)")

        // A bordered pane that has not been given any room yet gets an empty
        // frame, not the null rect: that one's origin is infinite, and every
        // constraint inside the pane was asked for an infinite constant.
        let unsized = ProjectColumnsView(frame: .zero)
        let unsizedPane = NSView()
        unsized.first = unsizedPane
        unsized.addSubview(unsizedPane)
        unsized.firstBorder = Theme.red
        unsized.layout()
        // AppKit clamps the null rect's infinite origin to a huge finite one,
        // so the check is that the pane sits where the splitter is.
        try expect(unsizedPane.frame.origin.x <= ProjectColumnsView.borderWidth
                    && unsizedPane.frame.origin.y <= ProjectColumnsView.borderWidth
                    && unsizedPane.frame.width >= 0 && unsizedPane.frame.height >= 0,
                   "a pane with no room was given a null frame: \(unsizedPane.frame)")

        // A refresh that lands while a row is being carried waits for it to be
        // put down: rearranging then put the row back where it started, and
        // rebuilding the rows left the drag holding one that was no longer in
        // the list.
        let panel = ProjectsPanelViewController()
        _ = panel.view
        panel.view.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
        typealias Listed = (name: String, branch: String, user: String, changes: Int,
                            path: String)
        let listed: [Listed] = ["a", "b", "c"].map {
            (name: $0, branch: "", user: "", changes: 0, path: "/\($0)")
        }
        panel.configure(projects: listed, active: nil)
        var reordered: (Int, Int)?
        panel.onReorder = { reordered = ($0, $1) }
        let rowsBefore = panel.rowsForTesting
        try expect(panel.beginDragForTesting(0), "the fixture row could not be picked up")
        panel.moveDragForTesting(0, by: ProjectRowView.height)
        let preview = panel.visualOrderForTesting
        // New branches change the rows' identity, which rebuilds them.
        let refreshed: [Listed] = listed.map {
            (name: $0.name, branch: "main", user: $0.user, changes: $0.changes, path: $0.path)
        }
        panel.configure(projects: refreshed, active: nil)
        try expect(panel.visualOrderForTesting == preview,
                   "a refresh in the middle of a drag put the row back")
        try expect(panel.rowsForTesting.count == rowsBefore.count
                    && zip(panel.rowsForTesting, rowsBefore).allSatisfy { $0 === $1 },
                   "a refresh in the middle of a drag rebuilt the rows under it")
        panel.endDragForTesting()
        try expect(reordered?.0 == 0 && reordered?.1 == 1,
                   "the drop was lost to the refresh: \(String(describing: reordered))")
        // A drag that ends where it began still delivers the refresh it held.
        reordered = nil
        panel.configure(projects: listed, active: nil)
        try expect(panel.beginDragForTesting(1), "the fixture row could not be picked up again")
        panel.configure(projects: refreshed, active: nil)
        panel.endDragForTesting()
        try expect(reordered == nil
                    && panel.rowsForTesting.allSatisfy { $0.titleForTesting.hasSuffix("main") },
                   "the refresh held during a drag was never applied: "
                     + "\(panel.rowsForTesting.map(\.titleForTesting))")

        // A tinted symbol is made once and kept: every visible tree row draws
        // its chevron on every redraw.
        guard let chevron = Theme.symbol("chevron.down", pointSize: 12) else {
            throw Failure(description: "no chevron symbol")
        }
        try expect(SidebarCellDrawing.tintedImageIsReusedForTesting(
                    chevron, Theme.dimText, size: NSSize(width: 12, height: 12)),
                   "a tinted symbol was rebuilt on a second draw")
    }

    private static func testMaterialFileIcons() throws {
        // The test binary runs outside an app bundle, so build the same icon
        // resources build.sh bundles and point the provider at them.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let generator = root.appendingPathComponent("Tools/generate-file-icons.py")
        guard FileManager.default.fileExists(
                atPath: root.appendingPathComponent("vendor/material-icon-theme").path) else {
            FileHandle.standardError.write(Data(
                "gift: skipping icon test — run vendor/fetch.sh first\n".utf8))
            return
        }
        let resources = try temporaryDirectory("icons")
        defer {
            FileIcons.useResources(at: nil)
            try? FileManager.default.removeItem(at: resources)
        }
        let python = Process()
        python.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        python.arguments = ["python3", generator.path, resources.path]
        python.standardOutput = FileHandle.nullDevice
        try python.run()
        python.waitUntilExit()
        try expect(python.terminationStatus == 0, "the icon generator failed")

        FileIcons.useResources(at: resources)
        // Whole names beat extensions, and an unknown extension still gets the
        // generic file icon rather than nothing.
        try expect(FileIcons.fileIconName(for: "package.json") == "nodejs",
                   "package.json did not get its own icon")
        try expect(FileIcons.fileIconName(for: "Main.swift") == "swift",
                   "a .swift file did not get the Swift icon")
        try expect(FileIcons.fileIconName(for: "Dockerfile") == "docker",
                   "Dockerfile did not get the Docker icon")
        try expect(FileIcons.fileIconName(for: "notes.qqq") == "file",
                   "an unknown extension did not fall back to the generic icon")
        try expect(FileIcons.folderIconName(for: "Sources", expanded: false) == "folder-src",
                   "the source folder did not get its own icon")
        // A tinted symbol keeps its shape. `sourceAtop` paints wherever the
        // *destination* is opaque, so tinting straight onto a filled cell
        // turned every chevron in the sidebar into a solid block.
        let box = NSRect(x: 8, y: 8, width: 16, height: 16)
        let canvas = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            Theme.panelBackground.setFill()
            rect.fill()
            SidebarCellDrawing.image(Theme.symbol("chevron.down", pointSize: 12),
                                     tint: Theme.red, in: box)
            return true
        }
        guard let tiff = canvas.tiffRepresentation,
              let drawn = NSBitmapImageRep(data: tiff) else {
            throw Failure(description: "the symbol would not render")
        }
        let scale = CGFloat(drawn.pixelsWide) / 32
        // The ground is near black; anything carrying the tint reads far above
        // it in red.
        var inked = 0
        var clear = 0
        for x in Int(box.minX * scale)..<Int(box.maxX * scale) {
            for y in Int(box.minY * scale)..<Int(box.maxY * scale) {
                guard let colour = drawn.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                else { continue }
                if colour.redComponent > 0.5 { inked += 1 } else { clear += 1 }
            }
        }
        try expect(inked > 0, "the tinted symbol drew nothing")
        try expect(clear > inked,
                   "the tint filled the symbol's whole box: \(inked) inked, \(clear) clear")

        // The two marks the Projects panel heads its columns with have to be
        // among the icons that ship, or a column loses the one thing that says
        // which of the two it is.
        for mark in ProjectRowView.columnIconNamesForTesting {
            try expect(FileIcons.image(named: mark, dark: true) != nil,
                       "the panel's \(mark) mark is not among the shipped icons")
        }

        // The decoded-image cache is bounded: each icon keeps its parsed SVG
        // alive, so browsing a tree with many file types must not accumulate
        // them forever.
        FileIcons.releaseTransientMemory()
        FileIcons.maxCachedImages = 20
        defer {
            FileIcons.maxCachedImages = 160
            FileIcons.releaseTransientMemory()
        }
        let names = ["swift", "typescript", "javascript", "python", "rust", "go",
                     "json", "yaml", "markdown", "html", "css", "docker", "git",
                     "image", "audio", "video", "pdf", "zip", "lock", "license",
                     "readme", "database", "console", "java", "ruby", "php",
                     "lua", "vue", "svelte", "sql"]
        for name in names { _ = FileIcons.image(named: name, dark: true) }
        try expect(FileIcons.cachedImageCountForTesting <= 20,
                   "the icon cache grew to \(FileIcons.cachedImageCountForTesting) past its cap")
        try expect(FileIcons.cachedImageCountForTesting > 0,
                   "the icon cache evicted everything instead of the oldest entries")
        // An evicted icon still resolves — eviction is a cache, not a loss.
        try expect(FileIcons.image(named: "swift", dark: true) != nil,
                   "an evicted icon could not be reloaded")
        FileIcons.releaseTransientMemory()
        try expect(FileIcons.cachedImageCountForTesting == 0,
                   "releasing transient memory left icons behind")

        try expect(FileIcons.folderIconName(for: "whatever", expanded: true) == "folder-open",
                   "a plain folder did not use the open folder icon")

        // The icons themselves must decode — a bundled SVG that AppKit cannot
        // read would silently leave the tree blank.
        try expect(FileIcons.image(named: "swift", dark: true) != nil,
                   "the Swift icon did not decode")
        let row = SidebarIcon.file(URL(fileURLWithPath: "/tmp/app.tsx"))
        guard case .material(let name) = row else {
            throw Failure(description: "a file row did not use a Material icon")
        }
        try expect(name == "react_ts", "app.tsx drew \(name)")

        // Without resources every row falls back to its SF Symbol.
        FileIcons.useResources(at: nil)
        guard case .symbol = SidebarIcon.file(URL(fileURLWithPath: "/tmp/app.tsx")) else {
            throw Failure(description: "rows did not fall back to SF Symbols")
        }
    }

    /// The scrollbar knob comes from the theme: AppKit's dark-mode grey is the
    /// brightest thing on a window this dark.
    private static func testScrollersFollowTheTheme() throws {
        func luminance(_ color: NSColor) -> CGFloat {
            guard let c = color.usingColorSpace(.sRGB) else { return 0 }
            return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        }

        let knob = luminance(Theme.scrollerKnob)
        let editor = luminance(Theme.diffBackground)
        try expect(knob > editor + 0.02,
                   "the knob does not separate from the surface behind it")
        try expect(knob < 0.25,
                   "the knob is brighter than anything else on the window: \(knob)")
        try expect(luminance(Theme.foreground) - knob > 0.3,
                   "the knob competes with the text for attention")

        // The capsule must survive the inset: an overlay knob is 6pt across,
        // and taking 3pt off each side left nothing to see.
        let overlayKnob = NSRect(x: 8, y: 14.5, width: 6, height: 26)
        let painted = GiftScroller.knobPaintRect(for: overlayKnob, vertical: true)
        try expect(painted.width >= 4 && painted.height == overlayKnob.height,
                   "the knob collapsed under its inset: \(painted)")
        try expect(GiftScroller.knobPaintRect(for: .zero, vertical: true).isEmpty,
                   "an empty knob rect produced something to draw")
        let horizontal = GiftScroller.knobPaintRect(
            for: NSRect(x: 4, y: 8, width: 40, height: 6), vertical: false)
        try expect(horizontal.height >= 4 && horizontal.width == 40,
                   "a horizontal knob collapsed: \(horizontal)")

        // It is actually what gets painted, not just a colour nobody reads.
        guard let paintedColour = GiftScroller.knobColourForTesting() else {
            throw Failure(description: "the scroller drew nothing")
        }
        try expect(abs(luminance(paintedColour) - knob) < 0.08,
                   "the knob painted \(luminance(paintedColour)) against the theme's \(knob)")

        // Overlay scrollers are what every window here uses; a scroller that
        // opts out of them is silently replaced by AppKit's own.
        try expect(GiftScroller.isCompatibleWithOverlayScrollers,
                   "the themed scroller would be dropped for overlay style")

        // The panel does not narrow past what its rows need.
        try expect(RootViewController.minimumSidebarWidth == 300,
                   "the sidebar floor moved: \(RootViewController.minimumSidebarWidth)")
        let root = RootViewController(sidebar: SidebarViewController(),
                                      diffs: DiffPaneViewController())
        _ = root.view
        root.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
        root.view.layoutSubtreeIfNeeded()
        root.resizeSidebarForTesting(to: 80)
        root.view.layoutSubtreeIfNeeded()
        try expect(root.sidebarWidthForTesting >= RootViewController.minimumSidebarWidth,
                   "dragging the divider went below the floor: \(root.sidebarWidthForTesting)")

        // It opens at two fifths of the window, leaving the rest to the diff.
        try expect(RootViewController.openingSidebarWidth(forWindowWidth: 1500) == 600,
                   "a 1500pt window opens its panel at "
                     + "\(RootViewController.openingSidebarWidth(forWindowWidth: 1500))pt")

        // Every scroll view in the app gets one.
        let diff = DiffView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        try expect(diff.verticalScrollerForTesting is GiftScroller,
                   "the diff kept AppKit's scroller")
    }

    /// One palette, fixed: nothing follows the system appearance and no setting
    /// selects anything else, so the tokens can be asserted outright.
    private static func testAyuDarkTheme() throws {
        // A colour is one value, not an appearance-dependent one: views cache
        // what they are built with, and a dynamic colour would resolve against
        // whatever appearance happened to be current when they drew.
        for colour in [Theme.diffBackground, Theme.foreground, Theme.selectedControl] {
            try expect(colour.usingColorSpace(.sRGB) != nil,
                       "a palette colour does not resolve on its own: \(colour)")
        }
        // The diff is the panel's surface, so the two sides read as one.
        try expect(sameColor(Theme.diffBackground, Theme.panelBackground),
                   "the diff does not match the panel")
        // The active tab is the one surface that must stay distinct: the tab
        // strip already uses the panel colour.
        try expect(!sameColor(Theme.activeTab, Theme.barBackground),
                   "the active tab vanished into the tab strip")
        // Every panel boundary is the same 1pt line.
        try expect(sameColor(GiftSplitView().dividerColor, Theme.border),
                   "the panel/diff divider is not the shared border line")
        try expect(sameColor(Theme.foreground, hexColor(0xbfbdb6)),
                   "the foreground is not Ayu's")
        // Added and removed lines are Ayu's markup colours, each over a ground
        // of its own that stays darker than the text drawn on it.
        try expect(sameColor(Theme.diffAddedText, hexColor(0x70bf56))
                    && sameColor(Theme.diffRemovedText, hexColor(0xf26d78)),
                   "the diff colours are not Ayu's")
        // The panel/diff split takes the colour directly…
        try expect(sameColor(GiftSplitView().dividerColor, Theme.border),
                   "the split did not take its divider colour from the theme")
        // …and the window's sidebar divider is painted over AppKit's hairline by
        // the drag handle, whose line must cover exactly that hairline.
        let handle = SplitDividerHandleView(
            frame: NSRect(x: 0, y: 0, width: SplitDividerHandleView.hitWidth, height: 100))
        handle.dividerThickness = 1
        try expect(handle.paintedDividerRectForTesting
                    == NSRect(x: SplitDividerHandleView.hitWidth / 2, y: 0,
                              width: 1, height: 100),
                   "the divider overlay does not sit on the split position: "
                    + "\(handle.paintedDividerRectForTesting)")
    }

    private static func hexColor(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255,
                green: CGFloat((value >> 8) & 0xff) / 255,
                blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }

    private static func testDiffHeaderStepsThroughChanges() throws {
        let diff = """
        diff --git a/Sources/App.swift b/Sources/App.swift
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -10,4 +10,4 @@
         context ten
        -removed eleven
        +added eleven
         context twelve
        @@ -40,3 +40,3 @@
         context forty
        -gone forty-one
        +back forty-one
        """
        let pane = DiffPaneViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.contentViewController = pane
        defer { window.close() }
        let directory = URL(fileURLWithPath: "/tmp/repo")
        pane.hasProject = true
        try expect(pane.hintVisibleForTesting && !pane.welcomeVisibleForTesting,
                   "an open project with no diff does not say what to click")
        pane.open(.init(directory: directory, path: "Sources/App.swift",
                        source: .workingTree, diff: diff))
        pane.view.layoutSubtreeIfNeeded()
        try expect(!pane.hintVisibleForTesting,
                   "the hint stayed over an open diff")

        let header = pane.headerForTesting
        try expect(header.pathForTesting == "Sources/App.swift",
                   "the header showed \(header.pathForTesting)")
        // Touching +/- lines are one change, so this diff holds two.
        try expect(pane.diffViewForTesting.changeCount == 2,
                   "the diff counted \(pane.diffViewForTesting.changeCount) changes, not 2")
        try expect(header.summaryForTesting == "2 changes",
                   "the header summarised \(header.summaryForTesting)")
        try expect(header.stepControlsEnabledForTesting,
                   "the step controls were disabled on a diff that has changes")

        // Unified: every line in Git's order, the file headers left to the
        // strip above. Removed lines keep their old number, added ones take
        // the new.
        let rows = pane.diffViewForTesting.rowsForTesting
        try expect(rows.count == 9 && rows[0].kind == .hunk,
                   "the unified rows are \(rows.count), starting \(String(describing: rows.first))")
        try expect(rows[2] == .change(left: (11, "removed eleven"), right: nil)
                    && rows[3] == .change(left: nil, right: (11, "added eleven")),
                   "a removed and an added line are not their own rows: \(rows[2]) / \(rows[3])")

        // Stepping forward lands on each change in turn and then wraps.
        let view = pane.diffViewForTesting
        header.clickNextForTesting()
        try expect(view.currentRowForTesting == 2,
                   "the first step landed on row \(String(describing: view.currentRowForTesting))")
        header.clickNextForTesting()
        try expect(view.currentRowForTesting == 7,
                   "the second step landed on row \(String(describing: view.currentRowForTesting))")
        header.clickNextForTesting()
        try expect(view.currentRowForTesting == 2, "stepping past the last change did not wrap")
        header.clickPreviousForTesting()
        try expect(view.currentRowForTesting == 7, "stepping back from the first change did not wrap")

        // A diff too long to model stops at the budget and says how much it
        // left out, rather than ending without a word.
        var long = "@@ -1,400 +1,400 @@\n"
        for index in 1...400 { long += "+line \(index)\n" }
        DiffRows.lineBudget = 50
        defer { DiffRows.lineBudget = 50_000 }
        pane.open(.init(directory: directory, path: "big.txt",
                        source: .workingTree, diff: long))
        try expect(pane.diffViewForTesting.rowsForTesting.count <= 50,
                   "the budget modelled \(pane.diffViewForTesting.rowsForTesting.count) rows")
        try expect(pane.diffViewForTesting.omittedLines == 351,
                   "the diff left out \(pane.diffViewForTesting.omittedLines) lines, not 351")
        try expect(pane.headerForTesting.summaryForTesting.contains("351 more lines not shown"),
                   "the strip does not say what was left out: "
                     + pane.headerForTesting.summaryForTesting)
        // A diff inside the budget says nothing of the sort.
        pane.open(.init(directory: directory, path: "Sources/App.swift",
                        source: .workingTree, diff: diff))
        try expect(pane.diffViewForTesting.omittedLines == 0
                    && !pane.headerForTesting.summaryForTesting.contains("not shown"),
                   "a whole diff claims to be truncated: "
                     + pane.headerForTesting.summaryForTesting)

        // The note under an empty diff is one line, and is not built at all
        // while there are rows to draw.
        try expect(pane.diffViewForTesting.noteFieldIsEmptyForTesting,
                   "a drawn diff still filled the note field")

        // A diff with no text to show says why instead of drawing nothing.
        pane.open(.init(directory: directory, path: "logo.png", source: .commit("abc123"),
                        diff: "diff --git a/logo.png b/logo.png\nBinary files a/logo.png and b/logo.png differ\n"))
        try expect(pane.diffViewForTesting.noteForTesting == "Binary file — no text to compare",
                   "a binary diff shows \(String(describing: pane.diffViewForTesting.noteForTesting))")
        // Git's own words, when that is all there is, are quoted rather than
        // reprinted whole.
        let wordy = String(repeating: "git said something long. ", count: 200)
        pane.open(.init(directory: directory, path: "odd.txt", source: .workingTree,
                        diff: wordy))
        try expect((pane.diffViewForTesting.noteForTesting?.count ?? 0)
                    <= DiffView.noteLimit + 1,
                   "the note reprinted \(pane.diffViewForTesting.noteForTesting?.count ?? 0) characters")
        try expect(!header.stepControlsEnabledForTesting,
                   "a diff with no changes left the step controls live")
    }

    /// Views cache the colours they are built with, so a pane has to be painted
    /// in the palette whatever order the app started in.
    private static func testThemeIsReadyBeforeAnyView() throws {
        // The hunk headers sit on a band lighter than the diff behind them.
        func luminance(_ color: NSColor) -> CGFloat {
            guard let c = color.usingColorSpace(.sRGB) else { return 0 }
            return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        }
        try expect(luminance(Theme.lineHighlight) > luminance(Theme.diffBackground),
                   "the hunk band is darker than the diff, so they read as swapped")

        // The delegate sets the dark appearance before any window: openFiles:
        // arrives first when Finder or `gift` starts the app with a project.
        NSApp.appearance = nil
        let delegate = AppDelegate()
        delegate.applicationWillFinishLaunching(
            Notification(name: NSApplication.willFinishLaunchingNotification))
        try expect(NSApp.appearance?.name == .darkAqua,
                   "the appearance is not set before the first window can be built")
    }

    /// A changed file's actions are a right-click away: the row itself is just
    /// the file, and clicking it shows the diff.
    private static func testChangesContextMenu() throws {
        let root = try temporaryDirectory("changes-menu")
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) -> String {
            GitService.run(args, in: root).out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = git(["init", "-q", "-b", "main"])
        _ = git(["config", "user.name", "Gift Test"])
        _ = git(["config", "user.email", "gift@example.invalid"])
        let tracked = root.appendingPathComponent("tracked.txt")
        let other = root.appendingPathComponent("other.txt")
        try Data("one\n".utf8).write(to: tracked)
        try Data("two\n".utf8).write(to: other)
        try expect(GitService.commit("fixture", in: root).code == 0, "fixture commit failed")
        try Data("one edited\n".utf8).write(to: tracked)
        try Data("two edited\n".utf8).write(to: other)
        let fresh = root.appendingPathComponent("fresh.txt")
        func contents(_ url: URL) -> String {
            (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        try Data("new\n".utf8).write(to: fresh)

        let changes = ProjectChangesViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = changes
        defer { window.close() }
        var changedIn: [URL] = []
        changes.onChanged = { changedIn.append($0) }
        var asked: [String] = []
        changes.confirmDiscard = { asked.append($0.messageText); return true }
        func reload() { changes.setEntries(GitService.status(in: root).entries, in: root) }
        reload()
        let paths = changes.entriesForTesting.map(\.path)
        try expect(Set(paths) == ["tracked.txt", "other.txt", "fresh.txt"],
                   "the fixture's changes: \(paths)")

        guard let menu = changes.contextMenuForTesting(row: 0) else {
            throw Failure(description: "a changed file has no context menu")
        }
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        try expect(titles == ["Show Changes", "Copy Path", "Reveal in Finder",
                              "Discard Changes…", "Discard All 3 Changes…"],
                   "the row menu reads \(titles)")

        // Show Changes is the same errand as a click on the row.
        var shown: String?
        changes.onOpenDiff = { entry, _ in shown = entry.path }
        try expect(changes.runMenuItemForTesting("Show Changes", row: 0), "Show Changes is off")
        try expect(shown == changes.entriesForTesting[0].path,
                   "Show Changes asked for \(String(describing: shown))")

        // Copy Path puts the repository-relative path on the pasteboard.
        try expect(changes.runMenuItemForTesting("Copy Path", row: 0), "Copy Path is off")
        try expect(NSPasteboard.general.string(forType: .string)
                    == changes.entriesForTesting[0].path,
                   "Copy Path copied \(String(describing: NSPasteboard.general.string(forType: .string)))")

        // Discard puts one tracked file back as HEAD has it, after asking.
        guard let trackedRow = changes.entriesForTesting.firstIndex(where: { $0.path == "tracked.txt" })
        else { throw Failure(description: "tracked.txt is not listed") }
        try expect(changes.runMenuItemForTesting("Discard Changes…", row: trackedRow),
                   "Discard Changes is off")
        // The question is prepared off the main thread: asking Git which files
        // it can restore is a subprocess each, and a few hundred of them froze
        // the window before the alert was even on screen.
        try expect(asked.isEmpty && changes.isBusyForTesting,
                   "the confirmation was prepared on the main thread")
        changes.settleForTesting()
        try expect(asked.last?.contains("tracked.txt") == true,
                   "the discard was not confirmed naming the file: \(asked)")
        try expect(contents(tracked) == "one\n",
                   "the discard did not restore HEAD's version")
        try expect(changedIn == [root], "the discard was not reported: \(changedIn)")
        reload()
        try expect(Set(changes.entriesForTesting.map(\.path)) == ["other.txt", "fresh.txt"],
                   "the list after one discard: \(changes.entriesForTesting.map(\.path))")

        // Discard All takes the rest, the new file to the Trash — and the
        // alert says so.
        try expect(changes.runMenuItemForTesting("Discard All 2 Changes…", row: 0),
                   "Discard All is off")
        changes.settleForTesting()
        try expect(asked.last == "Discard all 2 changes in this project?",
                   "Discard All asked \(String(describing: asked.last))")
        try expect(contents(other) == "two\n"
                    && !FileManager.default.fileExists(atPath: fresh.path),
                   "Discard All left changes behind")
        try expect(GitService.status(in: root).entries.isEmpty,
                   "the repository still has changes: "
                     + "\(GitService.status(in: root).entries.map(\.path))")

        // Refused, nothing happens.
        try Data("again\n".utf8).write(to: tracked)
        reload()
        changes.confirmDiscard = { _ in false }
        try expect(changes.runMenuItemForTesting("Discard Changes…", row: 0), "Discard is off")
        changes.settleForTesting()
        try expect(contents(tracked) == "again\n",
                   "a refused discard still discarded")

        // Every row is one list row, and the row under the pointer lights up.
        try expect(changes.rowViewForTesting(0) != nil, "the list drew no row")
    }

    /// The strips that show a selection say it loudly enough.
    private static func testSelectedControlsAgree() throws {
        func luminance(_ colour: NSColor) -> CGFloat {
            guard let c = colour.usingColorSpace(.sRGB) else { return 0 }
            return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        }

        do {
            let tabs = DiffTabBar.selectedColoursForTesting
            try expect(sameColor(tabs.surface, Theme.selectedControl)
                        && sameColor(tabs.ink, Theme.selectedControlText),
                       "the diff tabs do not use the shared selection colours")
            let surface = luminance(Theme.selectedControl)
            // Against the bar it sits on. `activeTab` was two percent away,
            // which read as nothing at all.
            try expect(abs(surface - luminance(Theme.barBackground)) > 0.05,
                       "the selected surface barely differs from its bar")
            try expect(abs(surface - luminance(Theme.panelBackground)) > 0.05,
                       "the selected surface barely differs from the panel")
            try expect(abs(surface - luminance(Theme.activeTab)) > 0.02,
                       "selection fell back to the old, subtler surface")
            try expect(abs(luminance(Theme.selectedControlText) - surface) > 0.35,
                       "the selected label is not readable on its surface")
            // Quiet enough to belong to the same family as the tree's selection
            // rather than glowing above everything else in the window.
            try expect(surface <= luminance(Theme.activeRow) + 0.02,
                       "selection is brighter than the tree's own")
        }

        // A window opens with the panel at two fifths of its width, within the
        // same floor and ceiling a drag is held to.
        try expect(RootViewController.defaultSidebarFraction == 0.4,
                   "the sidebar no longer opens at two fifths of the window")
        try expect(RootViewController.openingSidebarWidth(forWindowWidth: 1600) == 640,
                   "a 1600pt window does not open with a 640pt panel")
        try expect(RootViewController.openingSidebarWidth(forWindowWidth: 500)
                    == RootViewController.minimumSidebarWidth,
                   "a narrow window opened its panel below the floor")
        let opening = RootViewController(sidebar: SidebarViewController(),
                                         diffs: DiffPaneViewController())
        _ = opening.view
        opening.view.frame = NSRect(x: 0, y: 0, width: 1400, height: 700)
        opening.view.layoutSubtreeIfNeeded()
        try expect(opening.sidebarWidthForTesting == 560,
                   "a 1400pt window opened its panel at \(opening.sidebarWidthForTesting)")
        // Before it is on screen the window's width is still being decided —
        // a restored frame, a requested one — and the panel follows it.
        opening.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        opening.view.layoutSubtreeIfNeeded()
        try expect(opening.sidebarWidthForTesting == 400,
                   "the panel kept its share of a width the window had already left: "
                     + "\(opening.sidebarWidthForTesting)")
        // Settled once: a dragged width survives the window being resized.
        opening.resizeSidebarForTesting(to: 420)
        opening.view.frame = NSRect(x: 0, y: 0, width: 1800, height: 700)
        opening.view.layoutSubtreeIfNeeded()
        try expect(opening.sidebarWidthForTesting == 420,
                   "resizing the window replaced the dragged panel width: "
                     + "\(opening.sidebarWidthForTesting)")
    }

    /// The log carries what History needs to render and what its rows say in
    /// their tooltips: parents (so a merge is recognisable), and the branch or
    /// tag names pointing at a commit.
    private static func testHistoryLogDetails() throws {
        let root = try temporaryDirectory("graph")
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) { _ = GitService.run(args, in: root) }
        git(["init", "-q", "-b", "main"])
        git(["config", "user.name", "T"])
        git(["config", "user.email", "t@e.invalid"])
        func commit(_ message: String, file: String = "main.txt") throws {
            try Data("\(message)\n".utf8).write(to: root.appendingPathComponent(file))
            git(["add", "-A"])
            git(["commit", "-q", "-m", message])
        }
        try commit("first")
        try commit("second")
        git(["checkout", "-q", "-b", "feature"])
        try commit("feature work", file: "feature.txt")
        git(["checkout", "-q", "main"])
        try commit("main moves on")
        git(["merge", "-q", "--no-ff", "feature", "-m", "merge feature"])
        try commit("after the merge")

        let log = GitService.log(in: root, limit: 40)
        try expect(log.count == 6, "the log did not come back whole: \(log.map(\.subject))")
        guard log.contains(where: { $0.parents.count == 2 }) else {
            throw Failure(description: "no merge commit carried two parents: "
                            + "\(log.map { ($0.subject, $0.parents) })")
        }
        try expect(log.first?.refLabels == ["main"],
                   "the branch label was not read from the log: \(log.first?.refs ?? "-")")
        _ = GitService.run(["remote", "add", "origin", root.path], in: root)
        _ = GitService.run(["update-ref", "refs/remotes/origin/main", "HEAD"], in: root)
        _ = GitService.run(["symbolic-ref", "refs/remotes/origin/HEAD",
                            "refs/remotes/origin/main"], in: root)
        _ = GitService.run(["tag", "v1"], in: root)
        let decorated = GitService.log(in: root, limit: 1)[0]
        try expect(decorated.refLabels == ["main", "origin/main", "v1"],
                   "local, remote and tag refs were not classified: \(decorated.refs)")
        let decoratedCell = GitCommitCell()
        decoratedCell.configure(commit: decorated, pending: false)
        decoratedCell.frame = NSRect(x: 0, y: 0, width: 640,
                                     height: GitCommitCell.height)
        if let rep = decoratedCell.bitmapImageRepForCachingDisplay(in: decoratedCell.bounds) {
            decoratedCell.cacheDisplay(in: decoratedCell.bounds, to: rep)
        }
        try expect(decoratedCell.drawnRefRectsForTesting.count == 3
                    && (decoratedCell.accessibilityLabel() ?? "")
                        .contains("Refs main, origin/main, v1"),
                   "the row did not draw or expose all exact refs")
        try expect(log.last?.parents.isEmpty == true,
                   "the root commit was given a parent: \(log.last?.parents ?? [])")

    }

    /// A project opened inside a larger repository still needs a connected
    /// graph. Hidden sibling-only commits must be skipped in parent links,
    /// and loading another page must not reinterpret already-visible rows.
    private static func testScopedHistoryGraphParents() throws {
        let root = try temporaryDirectory("scoped-graph")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        @discardableResult
        func git(_ args: [String]) throws -> String {
            let result = GitService.run(args, in: root)
            try expect(result.code == 0, "graph fixture failed: \(args): \(result.err)")
            return result.out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func datedGit(_ args: [String], day: Int) throws {
            let date = String(format: "2024-01-%02dT12:00:00+0000", day)
            let result = GitService.runProcess(
                executable: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["GIT_AUTHOR_DATE=\(date)", "GIT_COMMITTER_DATE=\(date)", "git"] + args,
                in: root)
            try expect(result.code == 0,
                       "dated graph fixture failed: \(String(decoding: result.stderr, as: UTF8.self))")
        }
        func commit(_ subject: String, file: String, day: Int) throws -> String {
            try Data("\(subject)\n".utf8).write(to: root.appendingPathComponent(file))
            try git(["add", "-A"])
            try datedGit(["commit", "-q", "-m", subject], day: day)
            return try git(["rev-parse", "HEAD"])
        }
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.name", "Graph Test"])
        try git(["config", "user.email", "graph@example.invalid"])
        try git(["config", "core.abbrev", "4"])
        _ = try commit("outside root", file: "outside.txt", day: 1)
        let base = try commit("project root", file: "project/main.txt", day: 10)
        try git(["checkout", "-q", "-b", "feature"])
        _ = try commit("outside feature", file: "outside-feature.txt", day: 1)
        let feature = try commit("feature one", file: "project/feature.txt", day: 7)
        let featureTip = try commit("feature two", file: "project/feature.txt", day: 2)
        try git(["checkout", "-q", "main"])
        _ = try commit("outside main", file: "outside.txt", day: 3)
        let main = try commit("main work", file: "project/main.txt", day: 9)
        try datedGit(["merge", "-q", "--no-ff", "feature", "-m", "merge feature"], day: 4)
        let merge = try git(["rev-parse", "HEAD"])
        _ = try commit("outside after merge", file: "outside.txt", day: 5)
        let tip = try commit("project tip", file: "project/main.txt", day: 6)

        let log = GitService.log(in: project, limit: 100)
        let expectedParents = [tip: [merge], merge: [main, featureTip],
                               main: [base], featureTip: [feature], feature: [base], base: []]
        try expect(Set(log.map(\.graphID)) == Set(expectedParents.keys),
                   "scoped history lost project work or included sibling-only work: \(log.map(\.subject))")
        for (index, commit) in log.enumerated() {
            try expect(commit.fullHash == commit.graphID && commit.shortHash.count < commit.fullHash.count,
                       "a graph node uses its configurable display abbreviation as identity")
            try expect(commit.parents == expectedParents[commit.graphID],
                       "\(commit.subject) does not connect to its visible ancestors: \(commit.parents)")
            for parent in commit.parents {
                try expect(log.firstIndex(where: { $0.graphID == parent }).map { $0 > index } == true,
                           "a timestamp-skewed parent appeared above its child")
            }
        }
        let branchRows = log.enumerated().filter { [feature, featureTip].contains($0.element.graphID) }
        try expect(branchRows.count == 2 && branchRows[1].offset == branchRows[0].offset + 1,
                   "topological history interleaved another branch between consecutive feature commits")
        for limit in [1, 2, 4] {
            let page = GitService.log(in: project, limit: limit)
            try expect(page.map(\.graphID) == Array(log.prefix(limit)).map(\.graphID)
                        && page.map(\.parents) == Array(log.prefix(limit)).map(\.parents),
                       "loading more commits changed a previous page's graph at limit \(limit)")
        }
    }

    private static func testHistoryGraphLayout() throws {
        func commit(_ id: String, _ parents: [String] = [], refs: String = "") -> GitService.Commit {
            GitService.Commit(shortHash: id, subject: id, author: "T", absoluteDate: "",
                              email: "", parents: parents, refs: refs)
        }
        let commits = [commit("merge", ["main", "nested"], refs: "HEAD -> main"),
                       commit("main", ["base"]), commit("nested", ["left", "right"]),
                       commit("left", ["base"]), commit("right", ["base"]),
                       commit("base", ["root"]), commit("root")]
        let graph = GitHistoryGraph(commits: commits)
        try expect(graph.rows.count == commits.count && graph.laneCount == 3,
                   "nested merge history has missing nodes or extra lanes")
        try expect(graph.rows.map(\.nodeLane) == [0, 0, 1, 1, 2, 0, 0],
                   "split branches did not keep stable lanes until convergence")
        try expect(graph.rows[3].nodeLane != graph.rows[4].nodeLane
                    && graph.rows[4].topLanes.contains {
                        $0.targetHash == "right" && $0.lane == 2
                    },
                   "finishing the left branch moved the right branch into its lane")
        try expect(graph.rows[0].isHead && graph.rows.filter(\.isHead).count == 1,
                   "HEAD decoration is attached to the wrong graph node")
        try expect(graph.rows.enumerated().filter { $0.element.isMerge }.map(\.offset) == [0, 2],
                   "merge nodes were confused with ordinary branch commits")
        try expect(graph.rows[0].colorIndex == graph.rows[1].colorIndex
                    && graph.rows[0].colorIndex == graph.rows[5].colorIndex,
                   "the first-parent branch changed color")
        try expect(Set(graph.rows[2].bottomLanes.map(\.colorIndex)).count == 3,
                   "concurrent branches do not have distinct colors")
        try expect(graph.rows.last?.bottomLanes.isEmpty == true,
                   "lanes continue after every root has been reached")

        for (index, row) in graph.rows.enumerated() {
            if index > 0 {
                try expect(row.topLanes == graph.rows[index - 1].bottomLanes,
                           "a branch jumps at the boundary above commit \(commits[index].shortHash)")
            }
            try expect(Set(row.bottomLanes.map(\.targetHash)).count == row.bottomLanes.count,
                       "a shared ancestor was allocated more than one lane")
            for parent in commits[index].parents {
                guard let lane = row.bottomLanes.first(where: { $0.targetHash == parent }) else {
                    throw Failure(description: "a parent has no outgoing lane")
                }
                try expect(row.segments.contains {
                    $0.fromY == 0.5 && $0.toY == 1
                        && $0.fromLane == row.nodeLane && $0.toLane == lane.lane
                }, "a commit has no edge to its parent \(parent)")
            }
            for lane in row.topLanes {
                try expect(row.segments.contains { $0.fromY == 0 && $0.fromLane == lane.lane },
                           "an incoming branch is not connected to the previous row")
            }
        }
        for limit in 1..<commits.count {
            let page = GitHistoryGraph(commits: Array(commits.prefix(limit)))
            try expect(page.rows == Array(graph.rows.prefix(limit)),
                       "pagination moved or recolored visible history at limit \(limit)")
        }
        // A side branch can reach a shared ancestor before the first-parent
        // chain does. That reservation must not steal the trunk's lane/color.
        let convergenceCommits = [commit("M", ["P", "docs"]), commit("P", ["Q"]),
                                  commit("docs", ["B"]), commit("Q", ["B"]),
                                  commit("B", ["root"]), commit("root")]
        let convergence = GitHistoryGraph(commits: convergenceCommits)
        let trunkRows = [0, 1, 3, 4, 5].map { convergence.rows[$0] }
        try expect(trunkRows.allSatisfy { $0.nodeLane == 0 }
                    && Set(trunkRows.map(\.colorIndex)).count == 1,
                   "a side branch's early ancestor reservation displaced or recolored the mainline")
        try expect(convergence.rows[2].bottomLanes.map(\.targetHash) == ["Q", "B"]
                    && convergence.rows[3].bottomLanes.map(\.targetHash) == ["B"],
                   "the side branch did not converge into the surviving mainline")
        for index in 1..<convergence.rows.count {
            try expect(convergence.rows[index].topLanes == convergence.rows[index - 1].bottomLanes,
                       "mainline promotion broke a graph boundary")
            let prefix = GitHistoryGraph(commits: Array(convergenceCommits.prefix(index)))
            try expect(prefix.rows == Array(convergence.rows.prefix(index)),
                       "mainline convergence changed a previous page")
        }
        // Even when the trunk has not moved since a feature branch was cut,
        // the feature owns a side lane and bends into the trunk at its tip.
        // A purely topological layout would paint all four commits in lane 0.
        let branchBoundaryCommits = [
            commit("feature-two", ["feature-one"], refs: "HEAD -> feature"),
            commit("feature-one", ["main-tip"]),
            commit("main-tip", ["root"], refs: "main, origin/main, origin/HEAD"),
            commit("root")
        ]
        let branchBoundary = GitHistoryGraph(commits: branchBoundaryCommits,
                                             preferredTrunkID: "main-tip")
        try expect(branchBoundary.rows.map(\.nodeLane) == [1, 1, 0, 0]
                    && branchBoundary.laneCount == 2,
                   "a feature cut from an unchanged trunk reused the trunk lane")
        try expect(branchBoundary.rows[0].colorIndex == branchBoundary.rows[1].colorIndex
                    && branchBoundary.rows[1].colorIndex != branchBoundary.rows[2].colorIndex,
                   "the feature and trunk did not retain distinct colors at their boundary")
        for limit in 1..<branchBoundaryCommits.count {
            let prefix = GitHistoryGraph(commits: Array(branchBoundaryCommits.prefix(limit)),
                                         preferredTrunkID: "main-tip")
            try expect(prefix.rows == Array(branchBoundary.rows.prefix(limit)),
                       "a later trunk tip moved an already-visible feature lane")
        }
        let octopus = GitHistoryGraph(commits: [commit("octopus", ["a", "b", "c", "d"]),
                                                commit("a", ["root"]), commit("b", ["root"]),
                                                commit("c", ["root"]), commit("d", ["root"]),
                                                commit("root")])
        try expect(octopus.laneCount == 4 && octopus.rows[0].isMerge
                    && octopus.rows[0].bottomLanes.count == 4
                    && octopus.rows.last?.bottomLanes.isEmpty == true,
                   "an octopus merge lost a parent or left a phantom lane")
        let disconnected = GitHistoryGraph(commits: [commit("tip", ["root"]),
                                                     commit("independent"), commit("root")])
        try expect(disconnected.rows[1].nodeLane == 1
                    && disconnected.rows[1].bottomLanes == disconnected.rows[0].bottomLanes,
                   "an independent root interrupted another branch")
        try expect(GitHistoryGraph(commits: []).laneCount == 0
                    && GitHistoryGraph(commits: []).rows.isEmpty,
                   "empty history created a graph lane")
    }

    /// History must seed the graph with every branch tip. Otherwise two
    /// unmerged branches are loaded one at a time as if each were the only
    /// branch, and their commits are painted on the same lane.
    private static func testAllBranchesHistoryGraph() throws {
        let root = try temporaryDirectory("all-branches-graph")
        defer { try? FileManager.default.removeItem(at: root) }
        @discardableResult
        func git(_ args: [String]) throws -> String {
            let result = GitService.run(args, in: root)
            try expect(result.code == 0, "branch graph fixture failed: \(args): \(result.err)")
            return result.out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func commit(_ subject: String, file: String) throws -> String {
            try Data("\(subject)\n".utf8).write(to: root.appendingPathComponent(file))
            try git(["add", "-A"])
            try git(["commit", "-q", "-m", subject])
            return try git(["rev-parse", "HEAD"])
        }

        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.name", "Graph Test"])
        try git(["config", "user.email", "graph@example.invalid"])
        let base = try commit("base", file: "base.txt")
        try git(["checkout", "-q", "-b", "feature"])
        let featureOne = try commit("feature one", file: "feature.txt")
        let featureTwo = try commit("feature two", file: "feature.txt")
        try git(["checkout", "-q", "main"])
        let mainOne = try commit("main one", file: "main.txt")
        let mainTwo = try commit("main two", file: "main.txt")

        let log = GitService.log(in: root, limit: 40)
        try expect(Set(log.map(\.graphID)) == Set([base, featureOne, featureTwo,
                                                   mainOne, mainTwo]),
                   "History omitted commits reachable only from another branch")
        let trunk = GitService.historyGraphTrunk(in: root)
        try expect(trunk == mainTwo, "the main tip was not selected as the graph trunk")
        let graph = GitHistoryGraph(commits: log, preferredTrunkID: trunk)
        let rows = Dictionary(uniqueKeysWithValues:
            zip(log, graph.rows).map { ($0.graphID, $1) })
        guard let featureOneRow = rows[featureOne], let featureTwoRow = rows[featureTwo],
              let mainOneRow = rows[mainOne], let mainTwoRow = rows[mainTwo] else {
            throw Failure(description: "branch tips did not receive graph rows")
        }
        try expect(featureOneRow.nodeLane == featureTwoRow.nodeLane
                    && mainOneRow.nodeLane == mainTwoRow.nodeLane,
                   "commits from one branch did not retain their lane")
        try expect(mainTwoRow.nodeLane == 0 && featureTwoRow.nodeLane == 1,
                   "the feature branch did not keep a side lane beside main")
        try expect(featureTwoRow.colorIndex != mainTwoRow.colorIndex,
                   "two unmerged branches reused the same graph color")
    }

    /// Who the next commit will be authored by is resolved once per project and
    /// reused — a status refresh costs one subprocess, not several. It still
    /// has to notice `git config` run in a terminal, which touches nothing the
    /// app would otherwise look at.
    private static func testCommitIdentityFollowsGitConfig() throws {
        let root = try temporaryDirectory("identity")
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) { _ = GitService.run(args, in: root) }
        git(["init", "-q", "-b", "main"])
        git(["config", "user.name", "First Name"])
        git(["config", "user.email", "first@example.invalid"])
        try Data("one\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        git(["add", "-A"])
        git(["commit", "-q", "-m", "base"])

        GitService.forgetRepositoryInfo()
        try expect(GitService.status(in: root).userName == "First Name",
                   "the configured name did not reach the status")

        // Changed from outside, exactly as a terminal would.
        git(["config", "user.name", "Second Name"])
        try expect(GitService.status(in: root).userName == "First Name",
                   "the name is not being cached at all, so a status refresh "
                    + "pays for it every time")
        // What the repository monitor and window activation both do.
        GitService.forgetRepositoryInfo()
        let refreshed = GitService.status(in: root)
        try expect(refreshed.userName == "Second Name",
                   "the new name was not picked up: \(refreshed.userName)")

    }

    /// Commit needs both halves: something changed, and something said about
    /// it. The button used to accept the click either way and answer with an
    /// alert, or commit nothing at all.
    private static func testCommitNeedsChangesAndAMessage() throws {
        let root = try temporaryDirectory("commit-enabled")
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) { _ = GitService.run(args, in: root) }
        git(["init", "-q", "-b", "main"])
        git(["config", "user.name", "T"])
        git(["config", "user.email", "t@e.invalid"])
        try Data("one\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        git(["add", "-A"])
        git(["commit", "-q", "-m", "base"])

        let changes = ProjectChangesViewController()
        let bar = changes.commitBarForTesting
        func type(_ message: String) {
            bar.field.stringValue = message
            bar.field.onTextChange?()
        }
        try expect(!bar.commitButton.isEnabled,
                   "Commit was live before a repository was even loaded")

        // A clean repository with a message typed into it still has nothing to
        // commit.
        changes.setEntries([], in: root, ahead: 0, hasUpstream: true)
        type("a message")
        try expect(!bar.commitButton.isEnabled,
                   "Commit was available with nothing changed")

        // Changes with no message: still not a commit.
        let entry = GitService.Status.Entry(code: " M", path: "file.txt", originalPath: nil)
        type("")
        changes.setEntries([entry], in: root, ahead: 0, hasUpstream: true)
        try expect(!bar.commitButton.isEnabled,
                   "Commit was available with no message")
        type("   \n  ")
        try expect(!bar.commitButton.isEnabled,
                   "whitespace counted as a commit message")

        // Both halves present.
        type("real message")
        try expect(bar.commitButton.isEnabled,
                   "Commit stayed unavailable with changes and a message")
        // Hovering a button is where its shortcut is explained; the message box
        // is for the message.
        try expect(bar.commitButton.toolTip?.contains("⌘↩") == true,
                   "Commit does not name its shortcut: \(bar.commitButton.toolTip ?? "nil")")
        try expect(bar.pushButton.toolTip?.contains("⇧⌘↩") == true,
                   "Push does not name its shortcut: \(bar.pushButton.toolTip ?? "nil")")

        // And it goes back as soon as either half is taken away.
        changes.setEntries([], in: root, ahead: 0, hasUpstream: true)
        try expect(!bar.commitButton.isEnabled,
                   "Commit stayed live after the changes were committed away")
    }

    private static func testStatusMatchesPorcelainV1() throws {
        let root = try temporaryDirectory("status-v2")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = GitService.run(["init", "-q", "-b", "main"], in: root)
        _ = GitService.run(["config", "user.name", "Gift Test"], in: root)
        _ = GitService.run(["config", "user.email", "t@e.invalid"], in: root)
        for name in ["kept.txt", "edited.txt", "staged.txt", "gone.txt", "moved.txt"] {
            try Data("\(name)\n".utf8).write(to: root.appendingPathComponent(name))
        }
        _ = GitService.run(["add", "-A"], in: root)
        _ = GitService.run(["commit", "-q", "-m", "base"], in: root)

        // One of every shape the panel has to render.
        try Data("changed\n".utf8).write(to: root.appendingPathComponent("edited.txt"))
        try Data("changed\n".utf8).write(to: root.appendingPathComponent("staged.txt"))
        _ = GitService.run(["add", "--", "staged.txt"], in: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("gone.txt"))
        _ = GitService.run(["mv", "moved.txt", "renamed.txt"], in: root)
        try Data("new\n".utf8).write(to: root.appendingPathComponent("fresh.txt"))
        // A name that would break naive splitting.
        let awkward = "two words -> and \"quotes\".txt"
        try Data("odd\n".utf8).write(to: root.appendingPathComponent(awkward))

        // The reference: what the previous implementation read.
        let v1 = GitService.run(["status", "--porcelain=v1", "-z",
                                 "--untracked-files=all", "--", "."], in: root)
        var expected: [String: String] = [:]     // path -> code
        let records = v1.out.split(separator: "\0", omittingEmptySubsequences: true)
        var index = 0
        while index < records.count {
            let raw = String(records[index])
            index += 1
            guard raw.count > 3 else { continue }
            let code = String(raw.prefix(2))
            expected[String(raw.dropFirst(3))] = code
            if code.contains("R") || code.contains("C") { index += 1 }   // the old path
        }

        let status = GitService.status(in: root)
        try expect(status.isRepo && status.branch == "main",
                   "the branch did not come from the status call: \(status.branch)")
        try expect(status.userName == "Gift Test",
                   "the user name was lost: \(status.userName)")
        let actual = Dictionary(uniqueKeysWithValues: status.entries.map { ($0.path, $0.code) })
        try expect(actual == expected,
                   "porcelain v2 disagrees with v1:\n  v1: \(expected.sorted { $0.key < $1.key })"
                    + "\n  v2: \(actual.sorted { $0.key < $1.key })")
        guard let rename = status.entries.first(where: { $0.code.contains("R") }) else {
            throw Failure(description: "the rename was not reported: \(status.entries)")
        }
        try expect(rename.path == "renamed.txt" && rename.originalPath == "moved.txt",
                   "the rename lost a side: \(rename)")
        try expect(status.entries.contains { $0.path == awkward && $0.isUntracked },
                   "a name with spaces and quotes was dropped: \(status.entries.map(\.path))")

        // Ahead/behind rides along on the same call.
        try expect(status.hasUpstream == false && status.ahead == 0,
                   "a branch with no upstream reported one")
        let remote = root.appendingPathComponent("origin.git")
        _ = GitService.run(["init", "-q", "--bare", remote.path], in: root)
        _ = GitService.run(["remote", "add", "origin", remote.path], in: root)
        _ = GitService.run(["push", "-q", "-u", "origin", "main"], in: root)
        try Data("later\n".utf8).write(to: root.appendingPathComponent("kept.txt"))
        _ = GitService.run(["commit", "-qam", "ahead"], in: root)
        let pushable = GitService.status(in: root)
        try expect(pushable.hasUpstream && pushable.ahead == 1,
                   "ahead/behind did not come from the branch header: "
                    + "\(pushable.hasUpstream) \(pushable.ahead)")
    }

    private static func testSideBySideDiff() throws {
        let diff = """
        diff --git a/Sources/App.swift b/Sources/App.swift
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -10,4 +10,5 @@ func f() {
         context ten
        -removed eleven
        +added eleven
        +added twelve
         context twelve
        @@ -40,2 +40,1 @@
         context forty
        -gone forty-one
        """
        let rows = DiffRows.sideBySide(from: diff).rows
        // Hunk header, context, the paired change block, context, hunk, …
        try expect(rows.first?.kind == .hunk,
                   "the first row is not the hunk header: \(String(describing: rows.first))")
        let firstContext = rows[1]
        try expect(firstContext.leftNumber == 10 && firstContext.rightNumber == 10
                    && firstContext.leftText == "context ten",
                   "context lines are not numbered on both sides: \(firstContext)")

        // One removed against two added: the pair lines up, the extra addition
        // gets an empty left side rather than shifting everything down.
        let changes = rows.filter { $0.isChange }
        try expect(changes.count == 3, "expected three changed rows, got \(changes.count)")
        try expect(changes[0].leftText == "removed eleven"
                    && changes[0].rightText == "added eleven",
                   "the rewritten line is not opposite its replacement: \(changes[0])")
        try expect(changes[1].leftText == nil && changes[1].rightText == "added twelve",
                   "the extra addition did not get an empty left side: \(changes[1])")
        try expect(changes[2].leftText == "gone forty-one" && changes[2].rightText == nil,
                   "a deletion did not get an empty right side: \(changes[2])")
        // Numbering follows each side independently.
        try expect(changes[0].leftNumber == 11 && changes[0].rightNumber == 11
                    && changes[1].rightNumber == 12,
                   "the two sides do not count their own lines: \(changes.map { $0.rightNumber })")
        // The step buttons see the same two blocks the unified view does.
        try expect(DiffRows.changeBlockStarts(rows).count == 2,
                   "change blocks: \(DiffRows.changeBlockStarts(rows))")

        // The three controls are comfortable targets, not glyph-sized ones, and
        // they do not overlap.
        let sized = DiffHeaderView()
        sized.frame = NSRect(x: 0, y: 0, width: 420, height: DiffHeaderView.height)
        sized.layoutSubtreeIfNeeded()
        let frames = sized.buttonFramesForTesting
        try expect(frames.allSatisfy { $0.width >= 28 && $0.height >= 20 },
                   "the header buttons are too small to hit: \(frames)")
        try expect(zip(frames, frames.dropFirst()).allSatisfy { $0.maxX <= $1.minX },
                   "the header buttons overlap: \(frames)")
        try expect(frames.allSatisfy { $0.maxX <= sized.bounds.width },
                   "a header button hangs off the strip: \(frames)")

        // Hovering one gives it a background of its own.
        let button = DiffHeaderButton()
        try expect(!button.isHoveredForTesting, "a button starts out hovered")
        button.setHoveredForTesting(true)
        try expect(button.isHoveredForTesting, "hover state is not tracked")

        // The header offers the other mode, and says which one that is.
        let header = DiffHeaderView()
        try expect(header.modeForTesting == .unified, "diffs do not start unified")
        var toggles = 0
        header.onToggleMode = { toggles += 1 }
        header.toggleModeForTesting()
        try expect(toggles == 1, "the mode button is not wired")
        header.setMode(.sideBySide)
        try expect(header.modeLabelForTesting == "Show as one file",
                   "the button does not name what it switches to: "
                    + "\(String(describing: header.modeLabelForTesting))")

        // In the pane, switching redraws the same diff in two columns and
        // keeps the change count, then steps through the same blocks.
        let pane = DiffPaneViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = pane
        defer { window.close() }
        let directory = URL(fileURLWithPath: "/tmp/repo")
        pane.open(.init(directory: directory, path: "Sources/App.swift",
                        source: .workingTree, diff: diff))
        pane.view.layoutSubtreeIfNeeded()
        let view = pane.diffViewForTesting
        try expect(view.mode == .unified,
                   "a diff opened side by side without being asked")

        pane.toggleModeForTesting()
        defer { if view.mode == .sideBySide { pane.toggleModeForTesting() } }
        pane.view.layoutSubtreeIfNeeded()
        try expect(view.mode == .sideBySide && pane.headerForTesting.modeForTesting == .sideBySide,
                   "the mode button did not bring up the two-column view")
        try expect(view.cellForTesting(1)?.modeForTesting == .sideBySide,
                   "the rows are not drawn in two columns")
        try expect(pane.headerForTesting.summaryForTesting == "2 changes",
                   "the header lost its count in side-by-side: "
                    + pane.headerForTesting.summaryForTesting)
        // A fresh diff starts at its first line: a clip view left alone keeps
        // its origin at the bottom, which opened every diff on its last row.
        let geometry = view.geometryForTesting
        try expect(geometry.rows == rows.count,
                   "the view shows \(geometry.rows) of \(rows.count) parsed rows")
        try expect(geometry.contentHeight >= CGFloat(rows.count) * Theme.diffRowHeight() - 1,
                   "the table is shorter than its rows: \(geometry)")
        try expect(geometry.scrollOffset == 0,
                   "the diff opened scrolled to \(geometry.scrollOffset)")
        pane.headerForTesting.clickNextForTesting()
        try expect(view.currentBlockForTesting == 0,
                   "stepping did not move to the first change")

        // A diff taller than the view must actually scroll when stepping, not
        // merely move an index.
        var long = "@@ -1,200 +1,200 @@\n"
        for index in 1...120 { long += " context line \(index)\n" }
        long += "-old tail\n+new tail\n"
        for index in 1...40 { long += " trailing \(index)\n" }
        pane.open(.init(directory: directory, path: "Sources/App.swift",
                        source: .workingTree, diff: long))
        pane.view.layoutSubtreeIfNeeded()
        try expect(pane.tabTitlesForTesting == ["App.swift"],
                   "opening the same file again added a tab: \(pane.tabTitlesForTesting)")
        let before = view.geometryForTesting.scrollOffset
        pane.headerForTesting.clickNextForTesting()
        pane.view.layoutSubtreeIfNeeded()
        let after = view.geometryForTesting.scrollOffset
        try expect(after > before,
                   "stepping did not scroll: \(before) -> \(after)")
        try expect(view.currentRowForTesting != nil,
                   "the change it stepped to is not marked")
        pane.headerForTesting.clickNextForTesting()
        try expect(view.currentBlockForTesting == 0,
                   "stepping past the last change did not wrap")

        // A working-tree diff read again keeps the reader's place.
        let id = DiffPaneViewController.Tab(directory: directory, path: "Sources/App.swift",
                                            source: .workingTree, diff: "").id
        let placed = view.geometryForTesting.scrollOffset
        pane.update(id: id, diff: long + " one more\n")
        try expect(abs(view.geometryForTesting.scrollOffset - placed) < 1,
                   "a refreshed diff jumped from \(placed) to "
                     + "\(view.geometryForTesting.scrollOffset)")

        pane.toggleModeForTesting()
        pane.view.layoutSubtreeIfNeeded()
        try expect(view.mode == .unified,
                   "switching back did not restore the single-file view")
    }

    /// Diff tabs: one per file and source, closing and reopening as a browser's
    /// do, and a project's tabs going with it.
    /// Saves during a build arrive faster than diffs can be read. One batch
    /// runs, one waits, and the rest are the same request.
    private static func testOpenDiffRefreshesCoalesce() throws {
        let root = try temporaryDirectory("diff-refresh")
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) -> String {
            GitService.run(args, in: root).out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = git(["init", "-q", "-b", "main"])
        _ = git(["config", "user.name", "Gift Test"])
        _ = git(["config", "user.email", "gift@example.invalid"])
        let file = root.appendingPathComponent("file.txt")
        try Data("one\n".utf8).write(to: file)
        try expect(GitService.commit("fixture", in: root).code == 0, "fixture commit failed")
        try Data("two\n".utf8).write(to: file)
        func waitUntil(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            return condition()
        }

        let workspace = WorkspaceWindowController()
        defer { workspace.window?.close() }
        workspace.openProject(root)
        try expect(waitUntil { workspace.diffs.hasProject }, "the project never opened")
        workspace.showDiff(for: GitService.Status.Entry(code: " M", path: "file.txt",
                                                        originalPath: nil), in: root)
        try expect(waitUntil { workspace.diffs.tabs.count == 1 }, "the diff never opened")
        let batchesBefore = workspace.diffRefreshBatchesForTesting

        // Hold the read queue, so every refresh below lands while one batch
        // is in flight.
        let held = DispatchSemaphore(value: 0)
        GitService.workQueue.async { held.wait() }
        for index in 0..<30 {
            try Data("edit \(index)\n".utf8).write(to: file)
            workspace.refreshGit(requireFollowUp: true)
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        let started = workspace.diffRefreshBatchesForTesting - batchesBefore
        try expect(started == 1,
                   "30 refreshes started \(started) batches of diff reads, not one")
        held.signal()
        // What waited behind it is one more batch, not thirty.
        try expect(waitUntil {
            workspace.diffRefreshBatchesForTesting - batchesBefore >= 2
        }, "the refreshes that arrived while reading never ran")
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        // A handful — the one that waited, and the watcher's own refreshes
        // for the same writes — rather than one batch per refresh.
        let total = workspace.diffRefreshBatchesForTesting - batchesBefore
        try expect(total <= 8, "the queue kept growing: \(total) batches for 30 refreshes")
        // And the tab ends up showing the file as it is now.
        try expect(waitUntil { workspace.diffs.activeTab?.diff.contains("edit 29") == true },
                   "the diff did not end up current: "
                     + (workspace.diffs.activeTab?.diff ?? "nil"))
    }

    /// Open tabs were never capped and each kept its whole diff, so a history
    /// browsed file by file kept every diff it had shown. A commit's diff is
    /// never refreshed, so nothing else would ever let those bodies go.
    private static func testTabBodiesStayWithinBudget() throws {
        let budget = DiffPaneViewController.bodyByteBudget
        defer { DiffPaneViewController.bodyByteBudget = budget }
        DiffPaneViewController.bodyByteBudget = 1_000

        let pane = DiffPaneViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = pane
        defer { window.close() }
        let directory = URL(fileURLWithPath: "/tmp/budget")
        // About 400 bytes each: three of them are over the budget.
        let body = "@@ -1 +1 @@\n" + String(repeating: "-old line\n+new line\n", count: 20)
        func tab(_ path: String) -> DiffPaneViewController.Tab {
            .init(directory: directory, path: path, source: .commit("abc1234"), diff: body)
        }
        var readAgain: [String] = []
        pane.onReadAgain = { _, path, _ in
            readAgain.append(path)
            pane.open(tab(path))
        }
        for name in ["1.txt", "2.txt", "3.txt", "4.txt", "5.txt"] { pane.open(tab(name)) }

        try expect(pane.tabs.count == 5, "the budget closed a tab")
        try expect(pane.heldDiffBytesForTesting <= DiffPaneViewController.bodyByteBudget,
                   "five tabs hold \(pane.heldDiffBytesForTesting) bytes against a 1,000 budget")
        try expect(pane.activeTab?.path == "5.txt" && pane.activeTab?.diff.isEmpty == false,
                   "the tab on screen lost its body")
        try expect(pane.tabs[0].diff.isEmpty && pane.tabs[0].needsReread,
                   "the tab shown longest ago kept its body")
        try expect(readAgain.isEmpty, "keeping the budget read a diff back")

        // Shown again, it is read again, and something older goes instead.
        pane.select(0)
        try expect(readAgain == ["1.txt"], "the released tab was not read again: \(readAgain)")
        try expect(pane.activeTab?.path == "1.txt" && pane.activeTab?.diff == body,
                   "the released tab came back without its diff")
        try expect(pane.heldDiffBytesForTesting <= DiffPaneViewController.bodyByteBudget,
                   "reading one back broke the budget: \(pane.heldDiffBytesForTesting)")
    }

    /// Every refresh used to read every open working-tree tab: a `git diff` per
    /// tab on every save, and each body that memory pressure had released put
    /// straight back. Now only the tab on screen is read; the rest are read
    /// when shown — and must then show the file as it is.
    private static func testRefreshReadsOnlyTheTabOnScreen() throws {
        let root = try temporaryDirectory("refresh-on-screen")
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) { _ = GitService.run(args, in: root) }
        git(["init", "-q", "-b", "main"])
        git(["config", "user.name", "Gift Test"])
        git(["config", "user.email", "gift@example.invalid"])
        let a = root.appendingPathComponent("a.txt")
        let b = root.appendingPathComponent("b.txt")
        try Data("a\n".utf8).write(to: a)
        try Data("b\n".utf8).write(to: b)
        try expect(GitService.commit("fixture", in: root).code == 0, "fixture commit failed")
        try Data("a first edit\n".utf8).write(to: a)
        try Data("b first edit\n".utf8).write(to: b)
        func waitUntil(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            return condition()
        }

        let workspace = WorkspaceWindowController()
        defer { workspace.window?.close() }
        workspace.openProject(root)
        try expect(waitUntil { workspace.diffs.hasProject }, "the project never opened")
        workspace.showDiff(forPath: "a.txt", in: root)
        try expect(waitUntil { workspace.diffs.tabs.count == 1 }, "a.txt never opened")
        workspace.showDiff(forPath: "b.txt", in: root)
        try expect(waitUntil { workspace.diffs.activeTab?.path == "b.txt" }, "b.txt never opened")

        try Data("a second edit\n".utf8).write(to: a)
        try Data("b second edit\n".utf8).write(to: b)
        workspace.refreshGit(requireFollowUp: true)
        try expect(waitUntil { workspace.diffs.activeTab?.diff.contains("b second edit") == true },
                   "the tab on screen was not read again")
        guard let background = workspace.diffs.tabs.first(where: { $0.path == "a.txt" }) else {
            throw Failure(description: "a.txt's tab went away")
        }
        try expect(background.diff.isEmpty && background.needsReread,
                   "the tab in the background was read on refresh instead of when shown")

        // Shown, it is read — and it shows the file as it is now.
        workspace.diffs.select(0)
        try expect(waitUntil { workspace.diffs.activeTab?.diff.contains("a second edit") == true },
                   "the background tab, shown, did not show the file as it is: "
                     + (workspace.diffs.activeTab?.diff ?? "nil"))
    }

    private static func testDiffTabs() throws {
        let pane = DiffPaneViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = pane
        defer { window.close() }
        let one = URL(fileURLWithPath: "/tmp/one")
        let two = URL(fileURLWithPath: "/tmp/two")
        func tab(_ path: String, _ source: DiffPaneViewController.Tab.Source = .workingTree,
                 in directory: URL = one) -> DiffPaneViewController.Tab {
            .init(directory: directory, path: path, source: source,
                  diff: "@@ -1 +1 @@\n-a\n+b\n")
        }
        // Reading a diff is the window controller's errand; here it is this.
        var readAgain: [String] = []
        pane.onReadAgain = { directory, path, source in
            readAgain.append(path)
            pane.open(tab(path, source, in: directory))
        }
        pane.open(tab("a.txt"))
        pane.open(tab("a.txt", .commit("abc1234")))
        pane.open(tab("b.txt"))
        try expect(pane.tabTitlesForTesting == ["a.txt", "a.txt @ abc1234", "b.txt"],
                   "a file's change and a commit's are not separate tabs: "
                     + "\(pane.tabTitlesForTesting)")
        try expect(pane.activeTab?.path == "b.txt", "the newest tab is not the one shown")
        // A new tab opens beside the one being read.
        pane.select(0)
        pane.open(tab("c.txt"))
        try expect(pane.tabTitlesForTesting == ["a.txt", "c.txt", "a.txt @ abc1234", "b.txt"],
                   "a new tab did not open beside the one being read: "
                     + "\(pane.tabTitlesForTesting)")
        // ⌘W closes the one shown, and the next one takes its place.
        try expect(pane.closeActive(), "⌘W had nothing to close")
        try expect(pane.activeTab?.title == "a.txt @ abc1234",
                   "closing a tab did not show the next: \(String(describing: pane.activeTab?.title))")
        // ⇧⌘T brings it back — by reading the diff again, not from a copy
        // kept aside: what it showed when it was closed may not be true now.
        try expect(pane.reopenLastClosed() && pane.activeTab?.path == "c.txt",
                   "the closed tab did not come back")
        try expect(readAgain == ["c.txt"],
                   "reopening did not read the diff again: \(readAgain)")
        // Stepping wraps round.
        pane.select(3)
        pane.step(by: 1)
        try expect(pane.activeIndex == 0, "stepping past the last tab did not wrap")
        pane.closeOthers(keeping: 0)
        try expect(pane.tabTitlesForTesting == ["a.txt"], "Close Others kept \(pane.tabTitlesForTesting)")
        // Closing a project takes only its own tabs.
        pane.open(tab("x.txt", in: two))
        pane.closeTabs(in: one)
        try expect(pane.tabs.map(\.directory) == [two],
                   "closing a project took other tabs, or left its own")
        // ⌘C copies the diff being read, wherever the focus is: the rows are
        // drawn, so the editing commands have no selection to work from. The
        // window controller answers it, not the view that happens to be first
        // responder.
        NSPasteboard.general.clearContents()
        try expect(pane.copyActiveDiff(), "there was no diff to copy")
        try expect(NSPasteboard.general.string(forType: .string) == pane.activeTab?.diff,
                   "⌘C did not copy the diff as Git wrote it")
        try expect(WorkspaceWindowController.instancesRespond(to: #selector(NSText.copy(_:))),
                   "the window does not answer ⌘C, so it depends on what is focused")

        // Closed tabs cost a path each, not a diff: twenty 8 MiB diffs kept
        // "in case" outweigh reading one back.
        pane.closeAll()
        try expect(pane.tabs.isEmpty && !pane.closeActive(),
                   "tabs survived closing them all")
        try expect(!pane.copyActiveDiff(), "⌘C copied something with no diff open")
        try expect(pane.heldDiffBytesForTesting == 0 && pane.closedCountForTesting > 0,
                   "closing every tab still holds \(pane.heldDiffBytesForTesting) bytes of diff")

        // Under memory pressure the tabs stay and their bodies go; the one
        // being read is left alone, and the others are read again when shown.
        readAgain = []
        pane.open(tab("p.txt"))
        pane.open(tab("q.txt"))
        let held = pane.heldDiffBytesForTesting
        try expect(held > 0, "the fixture holds no diff")
        pane.releaseInactiveBodies()
        try expect(pane.tabs.count == 2, "releasing bodies closed a tab")
        try expect(pane.heldDiffBytesForTesting < held,
                   "releasing kept every body: \(pane.heldDiffBytesForTesting) of \(held)")
        try expect(pane.activeTab?.diff.isEmpty == false,
                   "the tab being read lost its body")
        try expect(readAgain.isEmpty, "releasing read a diff back immediately")
        pane.select(0)
        try expect(readAgain == ["p.txt"],
                   "showing a released tab did not read it again: \(readAgain)")
        try expect(pane.activeTab?.diff.isEmpty == false,
                   "the released tab came back empty")
        try expect(pane.heldDiffBytesForTesting == held,
                   "the re-read tab did not restore what was released")
    }

    private static func testFoldersRouteToTheirProjectWindow() throws {
        let root = try temporaryDirectory("open-routing")
        defer { try? FileManager.default.removeItem(at: root) }
        let outer = root.appendingPathComponent("outer", isDirectory: true)
        let inner = outer.appendingPathComponent("nested", isDirectory: true)
        let other = root.appendingPathComponent("other", isDirectory: true)
        for directory in [outer, inner, other] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let file = inner.appendingPathComponent("deep.swift")
        try Data("let x = 1\n".utf8).write(to: file)

        // Re-opening a folder raises the window already showing it, symlinked
        // temporary paths (/var → /private/var) included.
        let roots: [[URL]] = [[], [other], [outer, inner]]
        try expect(AppDelegate.projectIndex(matching: outer, in: roots)?.window == 2,
                   "re-opening a project did not find its window")
        try expect(AppDelegate.projectIndex(
                    matching: URL(fileURLWithPath: "/private" + outer.path), in: roots)?.window == 2,
                   "the same project through a symlinked path was treated as new")
        try expect(AppDelegate.projectIndex(matching: root, in: roots) == nil,
                   "an unopened folder matched an existing window")

        // Exercise the folder-picker callback itself, not just path matching.
        // A callback that unconditionally calls makeWindow passes the checks
        // above while still opening duplicate workspaces in the actual app.
        let app = AppDelegate()
        defer { app.windowsForTesting.forEach { $0.window?.close() } }
        try expect(app.openURLs([outer]), "could not open the initial project")
        guard let outerWindow = app.window(showingProject: outer) else {
            throw Failure(description: "initial project window was not registered")
        }
        // A window is a project, and says so wherever macOS shows window names
        // — Mission Control, the Dock's window list, the Window menu.
        try expect(outerWindow.windowTitleForTesting == "outer - Gift",
                   "the window is called \(outerWindow.windowTitleForTesting), not its "
                     + "project and the app")
        try expect(WorkspaceWindowController.windowTitle(forProject: nil) == "Gift"
                    && WorkspaceWindowController.windowTitle(forProject: "") == "Gift",
                   "a window with no project is not called after the app")
        // Collapsing the project leaves the app's own name behind.
        outerWindow.deactivateProject()
        try expect(outerWindow.windowTitleForTesting == "Gift",
                   "a collapsed window is still called "
                     + outerWindow.windowTitleForTesting)
        outerWindow.activateProject(outer)

        outerWindow.openSelection([outer])
        try expect(app.windowsForTesting.count == 1 && outerWindow.projects.count == 1,
                   "reselecting an open folder created a duplicate window or row")
        // A file stands for the folder it is in: dropped on the Dock icon, it
        // opens that folder as a project.
        outerWindow.openSelection([file])
        try expect(app.windowsForTesting.count == 1
                    && outerWindow.projectURL == inner.resolvingSymlinksInPath(),
                   "a file did not open the folder it is in")

        // With no window asking — Finder, `gift` — a new project gets a window
        // of its own.
        app.openURLs([other])
        guard let otherWindow = app.window(showingProject: other) else {
            throw Failure(description: "could not open a second independent project")
        }
        try expect(otherWindow !== outerWindow && app.windowsForTesting.count == 2,
                   "a project opened from outside did not get its own window")
        // Asked for from another window, a project already open is raised
        // where it is rather than opened twice.
        otherWindow.openSelection([outer])
        try expect(app.windowsForTesting.count == 2 && otherWindow.projects.count == 1
                    && outerWindow.projectURL == outer.resolvingSymlinksInPath(),
                   "opening an existing project from another window duplicated it")
        let alias = root.appendingPathComponent("outer-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outer)
        otherWindow.openSelection([alias])
        try expect(app.windowsForTesting.count == 2 && otherWindow.projects.count == 1,
                   "a symlinked folder duplicated its project")
        outerWindow.closeProject(inner)
        otherWindow.window?.close()

        // The title band still offers to open another project; listing the ones
        // already open is the Projects panel's job.
        try expect(outerWindow.sidebar.addProjectButtonForTesting.toolTip?.isEmpty == false,
                   "the title band's button does not say what it does")

        // One window, several projects: the Projects panel lists them down the
        // side and switching loads the chosen one from scratch. Nothing of the
        // project being left is kept — its diff tabs close, which is the design.
        let host = outerWindow
        host.activateProject(outer)
        host.diffs.open(.init(directory: outer.resolvingSymlinksInPath(), path: "a.txt",
                              source: .workingTree, diff: ""))
        host.openProject(other)
        try expect(host.projects.count == 2 && host.projectURL == other.resolvingSymlinksInPath(),
                   "the second project did not become this window's active one")
        try expect(host.diffs.tabs.isEmpty,
                   "the previous project's diffs survived the switch")

        let panel = host.sidebar.projectsPanel
        _ = panel.view
        let rows = panel.rowsForTesting
        try expect(rows.count == 2,
                   "the panel lists \(rows.count) projects, not 2")
        try expect(rows.map(\.titleForTesting).contains { $0.hasPrefix("outer") }
                    && rows.map(\.titleForTesting).contains { $0.hasPrefix("other") },
                   "the rows do not name the projects: \(rows.map(\.titleForTesting))")
        try expect(rows[1].isActiveForTesting && !rows[0].isActiveForTesting,
                   "the panel does not mark the project being shown")
        // The lists are expanded directly under the row that is selected.
        try expect(panel.detailPositionForTesting == 2,
                   "the lists sit at \(String(describing: panel.detailPositionForTesting)), "
                     + "not under the selected project")
        try expect(ProjectRowView.height == 32,
                   "a project row is \(ProjectRowView.height)pt, not 32")
        // Lines between the rows, but none between a project and the lists that
        // belong to it.
        try expect(!rows[0].showsDivider && rows[1].showsDivider,
                   "the rows are not separated: \(rows.map(\.showsDivider))")
        // A band down the leading edge of the project being shown, and only it.
        rows.forEach { $0.frame = NSRect(x: 0, y: 0, width: 300,
                                         height: ProjectRowView.height) }
        try expect(rows[1].markerRectForTesting?.width == 5
                    && rows[0].markerRectForTesting == nil,
                   "the selected project is not banded: "
                     + "\(rows.map { $0.markerRectForTesting?.width })")

        rows[0].clickForTesting()
        try expect(host.projectURL == outer.resolvingSymlinksInPath(),
                   "clicking a project row did not switch to it")
        // The rows below the chosen project travel the height of the whole
        // lists. They slide there rather than jumping, or the list reads as
        // having been rebuilt rather than as one project opening.
        try expect(panel.lastLayoutDurationForTesting.map { $0 > 0 } == true,
                   "switching projects moved the rows without a transition: "
                     + "\(String(describing: panel.lastLayoutDurationForTesting))")
        // But a window opening finds its project already there.
        let freshPanel = ProjectsPanelViewController()
        _ = freshPanel.view
        freshPanel.configure(projects: [(name: "a", branch: "", user: "",
                                         changes: 0, path: "/a")], active: 0)
        try expect(freshPanel.lastLayoutDurationForTesting == 0,
                   "the first fill slid into place instead of being there: "
                     + "\(String(describing: freshPanel.lastLayoutDurationForTesting))")
        // A plain folder is not a repository: once Git has said so, the space
        // says that instead of framing two empty lists.
        let settled = Date().addingTimeInterval(5)
        while !panel.notRepositoryVisibleForTesting, Date() < settled {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        try expect(panel.notRepositoryVisibleForTesting && !panel.gitListsVisibleForTesting,
                   "a folder that is not a repository was given Git lists")

        // Clicking the project already showing folds it away: the lists go,
        // the start page comes back, and the row stays for coming back to.
        rows[0].clickForTesting()
        try expect(host.projectURL == nil && host.projects.count == 2,
                   "re-clicking the open project did not collapse it")
        try expect(!host.diffs.hasProject && host.diffs.tabs.isEmpty
                    && host.diffs.welcomeVisibleForTesting,
                   "the collapsed window still claims a project")
        try expect(panel.rowsForTesting.allSatisfy { !$0.isActiveForTesting },
                   "a project is still marked as showing after collapsing")
        // Under a list of collapsed projects the space is left blank.
        try expect(!panel.gitListsVisibleForTesting && !panel.notRepositoryVisibleForTesting,
                   "collapsed projects leave something under their rows")
        rows[0].clickForTesting()
        try expect(host.projectURL == outer.resolvingSymlinksInPath(),
                   "the collapsed project could not be opened again")
        try expect(panel.detailPositionForTesting == 1,
                   "the lists did not move under the newly selected project")

        // Reordering is offered only with every project collapsed: with one
        // expanded its lists sit between the rows, and "where will it land"
        // has no honest answer. A drag then means nothing — and a press let go
        // away from the row is not a click either: selecting then closed every
        // tab of the project being left, for a press already abandoned.
        host.window?.contentView?.layoutSubtreeIfNeeded()
        let grip = NSPoint(x: 200, y: ProjectRowView.height / 2)
        let travel = [NSPoint(x: 200, y: grip.y + ProjectRowView.height),
                      NSPoint(x: 200, y: grip.y + ProjectRowView.height * 1.5)]
        let expandedOrder = host.projects.map(\.lastPathComponent)
        let expandedProject = host.projectURL
        rows[0].pressForTesting(at: grip, draggingThrough: travel)
        try expect(host.projects.map(\.lastPathComponent) == expandedOrder,
                   "a row was dragged while a project was expanded")
        try expect(host.projectURL == expandedProject && expandedProject != nil,
                   "a press released away from the row still counted as a click")
        // Let go on the row itself, it is the click it started out as.
        rows[0].pressForTesting(at: grip, draggingThrough: [
            NSPoint(x: grip.x + 30, y: grip.y + 2),
        ])
        try expect(host.projectURL == nil,
                   "a press released on the row did not land as a click")

        // Everything collapsed, the row travels. What is on screen during the
        // drag is what gets committed: the rows change places as it goes
        // rather than snapping at the drop.
        host.window?.contentView?.layoutSubtreeIfNeeded()
        let before = panel.visualOrderForTesting
        var whileMoving: [[String]] = []
        panel.rowsForTesting[0].pressForTesting(at: grip, draggingThrough: travel) {
            whileMoving.append(panel.visualOrderForTesting)
        }
        try expect(host.projects.map(\.lastPathComponent) == ["other", "outer"],
                   "dragging did not reorder: \(host.projects.map(\.lastPathComponent))")
        try expect(whileMoving.contains { $0 != before },
                   "the list did not preview the new order while the row was moving: "
                     + "\(whileMoving)")
        // A press that turns into a drag is carrying the row, not clicking it.
        // Selecting on the press expanded the project the drag started from,
        // which then took reordering away in the middle of the gesture.
        try expect(host.projectURL == nil,
                   "dragging a row into place also selected its project")

        // And it travels the other way just as well: a stack lays its rows out
        // top-down but counts its own coordinates bottom-up, and measuring the
        // drop against the stack's origin let a row move only downwards.
        host.window?.contentView?.layoutSubtreeIfNeeded()
        panel.rowsForTesting[1].pressForTesting(at: grip, draggingThrough: [
            NSPoint(x: 200, y: grip.y - ProjectRowView.height),
            NSPoint(x: 200, y: grip.y - ProjectRowView.height * 1.5),
        ])
        try expect(host.projects.map(\.lastPathComponent) == ["outer", "other"],
                   "a row could not be dragged upwards: "
                     + "\(host.projects.map(\.lastPathComponent))")

        // The same press without the travel is an ordinary click.
        host.window?.contentView?.layoutSubtreeIfNeeded()
        panel.rowsForTesting[0].pressForTesting(at: grip)
        try expect(host.projectURL == host.projects[0],
                   "releasing a press that never moved did not select the project")
        panel.rowsForTesting[0].clickForTesting()
        try expect(host.projectURL == nil, "the fixture did not collapse")

        // The branch name is a label, not a target: nothing marks it under
        // the pointer, and a click on it is a click on the row.
        host.sidebar.setProjects(host.projects.map {
            (name: $0.lastPathComponent, branch: "main", user: "", changes: 0,
             path: $0.path)
        }, active: nil)
        let branchRow = panel.rowsForTesting[0]
        branchRow.frame = NSRect(x: 0, y: 0, width: 300, height: ProjectRowView.height)
        let branchBox = branchRow.branchRectForTesting
        try expect(branchBox.width > 0 && branchBox.minX > ProjectRowView.markerWidth
                    && branchBox.maxX < branchRow.closeRectForTesting.minX,
                   "the branch name is not drawn between the name and the ✕: \(branchBox)")
        branchRow.hoverForTesting(at: NSPoint(x: branchBox.midX, y: branchBox.midY))
        let hovered = branchRow.labelForTesting
        var underlined = false
        hovered.enumerateAttribute(.underlineStyle,
                                   in: NSRange(location: 0, length: hovered.length)) {
            value, _, _ in
            if value != nil { underlined = true }
        }
        try expect(!underlined, "the branch underlines itself under the pointer")
        try expect(branchRow.toolTip == branchRow.pathForTesting,
                   "hovering the branch changed the row's tip: "
                     + "\(String(describing: branchRow.toolTip))")
        var menuShown = 0
        host.presentBranchMenu = { _, _, _ in menuShown += 1 }
        branchRow.pressForTesting(at: NSPoint(x: branchBox.midX, y: branchBox.midY))
        try expect(host.projectURL == host.projects[0],
                   "a click on the branch did not select its row")
        branchRow.pressForTesting(at: NSPoint(x: branchBox.midX, y: branchBox.midY))
        try expect(host.projectURL == nil,
                   "a second click on the branch did not collapse the row like the name does")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        try expect(menuShown == 0, "a click on a row's branch dropped the branch menu")

        // The ✕ is always there, at the row's trailing end, so the name's room
        // never changes as the pointer crosses the panel.
        let row = panel.rowsForTesting[1]
        row.frame = NSRect(x: 0, y: 0, width: 300, height: ProjectRowView.height)
        let closeBox = row.closeRectForTesting
        try expect(closeBox.width > 0 && closeBox.maxX <= row.bounds.maxX - 4
                    && closeBox.minX > row.bounds.midX,
                   "the close button is not at the row's trailing end: \(closeBox)")
        // The list has been reordered above, so this closes the second of
        // ["outer", "other"].
        row.clickCloseForTesting()
        try expect(host.projects.map(\.lastPathComponent) == ["outer"],
                   "closing did not remove the project: \(host.projects)")
        // Closing the last one empties the window rather than leaving lists
        // pointing at a project that is no longer here.
        panel.rowsForTesting[0].clickCloseForTesting()
        try expect(host.projects.isEmpty && host.projectURL == nil,
                   "the window kept a project after the last one closed")
        try expect(host.diffs.tabs.isEmpty && !host.diffs.hasProject,
                   "the emptied window still holds diffs or claims a project")

        // A project asked for from a window joins that window rather than
        // opening one of its own, which is what the band's `+` is for.
        let fresh = root.appendingPathComponent("fresh", isDirectory: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        host.openProject(other)
        let windowsBefore = app.windowsForTesting.count
        host.openSelection([fresh])
        try expect(app.windowsForTesting.count == windowsBefore,
                   "opening a project from a window created another window")
        try expect(app.window(showingProject: fresh) === host
                    && host.projectURL == fresh.resolvingSymlinksInPath(),
                   "the new project did not become the window's active one")
        try expect(host.projects.contains(other.resolvingSymlinksInPath()),
                   "switching projects dropped the one the window already held")
    }
}

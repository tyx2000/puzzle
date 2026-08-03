import AppKit
import Foundation

@main
enum RegressionTests {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func main() throws {
        _ = NSApplication.shared
        try testProcessDrain()
        try testScopedStatusAndStaging()
        try testRemoteConfigurationAndPushSelection()
        try testGitRepositoryMonitor()
        try testBranchListing()
        try testSearchMatcher()
        try testProjectSearchBackend()
        try testReadOnlyAndEncodingProtection()
        try testEditorManualSave()
        try testCommitImagePathsDoNotCollide()
        try testDefaultWindowPlacement()
        try testDocumentStoreProtectsNewBuffer()
        try testVirtualDocumentRefreshesInPlace()
        try testLargeFilesAreRejectedBeforeLoading()
        try testPreviewPayloadsAreReleased()
        try testFindMatchesAreComplete()
        try testCodeBlockAnalysisAndFolding()
        print("Regression tests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool,
                               _ message: String) throws {
        guard condition() else { throw Failure(description: message) }
    }

    private static func temporaryDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("puzzle-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// More than one pipe buffer on stderr used to make GitService wait forever
    /// while it synchronously read stdout first.
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

    private static func testScopedStatusAndStaging() throws {
        let root = try temporaryDirectory("git")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        try expect(GitService.run(["init", "-q"], in: root).code == 0, "git init failed")
        _ = GitService.run(["config", "user.name", "Puzzle Test"], in: root)
        _ = GitService.run(["config", "user.email", "puzzle@example.invalid"], in: root)

        let special = "quoted \" name\nline -> here.txt"
        try Data("inside".utf8).write(to: project.appendingPathComponent(special))
        try Data("outside".utf8).write(to: root.appendingPathComponent("outside.txt"))

        let status = GitService.status(in: project)
        try expect(status.entries.map(\.path) == [special],
                   "status was not project-relative or lossless: \(status.entries.map(\.path))")

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
        try expect(GitService.log(in: project, limit: 1).first?.subject == unusualSubject,
                   "commit metadata delimiters corrupted the history subject")
    }

    private static func testRemoteConfigurationAndPushSelection() throws {
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

        let customPush = root.appendingPathComponent("custom-push.git").path
        let saved = GitService.saveRemote(name: "backup", fetchURL: remote.path,
                                          pushURL: customPush, in: repository)
        try expect(saved.ok, "custom push URL was not saved: \(saved.message)")
        let configuredPush = GitService.run(["remote", "get-url", "--push", "backup"],
                                            in: repository).out
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try expect(configuredPush == customPush, "custom push URL was not applied")

        let reset = GitService.saveRemote(name: "backup", fetchURL: remote.path,
                                          pushURL: "", in: repository)
        try expect(reset.ok, "custom push URL was not cleared: \(reset.message)")
        let resetPush = GitService.run(["remote", "get-url", "--push", "backup"],
                                       in: repository).out
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try expect(resetPush == remote.path,
                   "cleared push URL did not fall back to fetch URL: \(resetPush)")

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
        try expect(!ambiguous.ok && ambiguous.message.contains("Push to"),
                   "push arbitrarily selected one of multiple non-origin remotes")
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

    private static func testSearchMatcher() throws {
        let sensitive = SearchOptions(caseSensitive: true, wholeWord: false, regex: false)
        try expect(SearchMatcher(query: "Run", options: sensitive)?.firstRange(in: "run") == nil,
                   "case-sensitive matching ignored case")

        let insensitive = SearchOptions(caseSensitive: false, wholeWord: false, regex: false)
        try expect(SearchMatcher(query: "Run", options: insensitive)?.firstRange(in: "run") != nil,
                   "case-insensitive matching failed")

        let whole = SearchOptions(caseSensitive: false, wholeWord: true, regex: false)
        try expect(SearchMatcher(query: "run", options: whole)?.firstRange(in: "runtime") == nil,
                   "whole-word matching accepted a partial word")
        try expect(SearchMatcher(query: "run", options: whole)?.firstRange(in: "yarn run test") != nil,
                   "whole-word matching missed a word")

        let regex = SearchOptions(caseSensitive: false, wholeWord: false, regex: true)
        try expect(SearchMatcher(query: "r.n", options: regex)?.firstRange(in: "run") != nil,
                   "regex matching failed")
        try expect(SearchMatcher(query: "[", options: regex) == nil,
                   "invalid regex should not create a matcher")
    }

    private static func testProjectSearchBackend() throws {
        let directory = try temporaryDirectory("search")
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = "colon:name\nline.txt"
        try Data("before\n  yarn run test\nafter\n".utf8)
            .write(to: directory.appendingPathComponent(name))

        let regex = SearchOptions(caseSensitive: true, wholeWord: false, regex: true)
        let groups = SearchViewController.search(query: "r.n", in: directory, options: regex)
        try expect(groups.count == 1 && groups[0].relative == name,
                   "project search lost a path containing colon/newline")
        try expect(groups[0].hits.count == 1 && groups[0].hits[0].matchRange != nil,
                   "regex project-search result was not highlighted")

        let sensitive = SearchOptions(caseSensitive: true, wholeWord: false, regex: false)
        try expect(SearchViewController.search(
            query: "RUN", in: directory, options: sensitive).isEmpty,
            "project search backend ignored case sensitivity")

        let staleURL = directory.appendingPathComponent("unsaved.txt")
        try "needle on disk\n".write(to: staleURL, atomically: true, encoding: .utf8)
        let removed = SearchViewController.search(
            query: "needle", in: directory,
            inMemoryFiles: [staleURL: "edited without the old match\n"])
        try expect(removed.allSatisfy { $0.url != staleURL },
                   "project search kept a stale disk hit for an unsaved buffer")

        let current = SearchViewController.search(
            query: "needle", in: directory,
            inMemoryFiles: [staleURL: "first line\nfresh needle in memory\n"])
        let currentHit = current.first(where: { $0.url == staleURL })?.hits.first
        try expect(currentHit?.line == 2
                   && currentHit?.preview == "fresh needle in memory",
                   "project search did not use the current unsaved buffer text")

        let store = DocumentStore.shared
        let document = store.document(for: staleURL)
        document.storage.replaceCharacters(
            in: NSRange(location: 0, length: document.storage.length),
            with: "live editor text\n")
        document.isModified = true
        let snapshot = store.modifiedTextSnapshots(in: directory)
            .first(where: { $0.url == staleURL })
        try expect(snapshot?.text == "live editor text\n",
                   "project search did not snapshot the modified editor buffer")
        document.isModified = false
        store.release(staleURL, stillOpen: false)
    }

    private static func testReadOnlyAndEncodingProtection() throws {
        let directory = try temporaryDirectory("documents")
        defer { try? FileManager.default.removeItem(at: directory) }

        let missingURL = directory.appendingPathComponent("missing.txt")
        let missing = Document(url: missingURL)
        try expect(missing.isReadOnly && missing.isUnsupported,
                   "unreadable files must be read-only")
        do {
            try missing.save()
            throw Failure(description: "saving an unreadable file unexpectedly succeeded")
        } catch let error as Failure {
            throw error
        } catch {}
        try expect(!FileManager.default.fileExists(atPath: missingURL.path),
                   "saving an unreadable document created a replacement file")

        let imageURL = directory.appendingPathComponent("pixel.png")
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        try png.write(to: imageURL)
        let image = Document(url: imageURL)
        try expect(image.isImage && image.isReadOnly, "image preview must be read-only")
        do {
            try image.save()
            throw Failure(description: "saving an image preview unexpectedly succeeded")
        } catch let error as Failure {
            throw error
        } catch {}
        let savedImage = try Data(contentsOf: imageURL)
        try expect(savedImage == png,
                   "saving an image preview changed the image")

        let corruptImageURL = directory.appendingPathComponent("corrupt.jpg")
        try Data("not really an image".utf8).write(to: corruptImageURL)
        let corruptImage = Document(url: corruptImageURL)
        try expect(corruptImage.isUnsupported && corruptImage.isReadOnly,
                   "a corrupt image fell through to the editable text decoder")

        let latinURL = directory.appendingPathComponent("latin.txt")
        let latin = Data([0x63, 0x61, 0x66, 0xE9])
        try latin.write(to: latinURL)
        let document = Document(url: latinURL)
        try expect(document.text == "café", "Latin-1 text did not decode")
        try document.save()
        let savedLatin = try Data(contentsOf: latinURL)
        try expect(savedLatin == latin,
                   "saving silently changed the original text encoding")

        document.storage.append(NSAttributedString(string: " ☕"))
        document.isModified = true
        try document.save()
        let converted = String(data: try Data(contentsOf: latinURL), encoding: .utf8)
        try expect(converted == "café ☕",
                   "unrepresentable edits did not fall back to UTF-8")
    }

    private static func testEditorManualSave() throws {
        let directory = try temporaryDirectory("auto-save")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("live.txt")
        try "before\n".write(to: url, atomically: true, encoding: .utf8)

        let pane = EditorPaneViewController()
        _ = pane.view
        pane.open(url: url)
        let store = DocumentStore.shared
        let document = store.document(for: url)
        document.storage.replaceCharacters(
            in: NSRange(location: 0, length: document.storage.length),
            with: "visible outside Puzzle\n")
        pane.textDidChange(Notification(name: NSText.didChangeNotification))
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        let notAutoSaved = try String(contentsOf: url, encoding: .utf8)
        try expect(notAutoSaved == "before\n" && document.isModified,
                   "editor changes were written without an explicit save")
        pane.save()
        let manuallySaved = try String(contentsOf: url, encoding: .utf8)
        try expect(manuallySaved == "visible outside Puzzle\n" && !document.isModified,
                   "manual editor save did not persist the buffer")

        document.storage.replaceCharacters(
            in: NSRange(location: 0, length: document.storage.length),
            with: "flushed while closing\n")
        pane.textDidChange(Notification(name: NSText.didChangeNotification))
        pane.prepareForClose()
        let preserved = try String(contentsOf: url, encoding: .utf8)
        try expect(preserved == "visible outside Puzzle\n" && document.isModified,
                   "pane close teardown silently saved or discarded the buffer")
        store.release(url, stillOpen: false)
    }

    private static func testCommitImagePathsDoNotCollide() throws {
        let firstRepository = URL(fileURLWithPath: "/tmp/first-repository")
        let secondRepository = URL(fileURLWithPath: "/tmp/second-repository")
        let first = WorkspaceWindowController.commitBlobURL(
            repository: firstRepository, commit: "abc1234", path: "assets/icon.png")
        let second = WorkspaceWindowController.commitBlobURL(
            repository: firstRepository, commit: "abc1234", path: "docs/icon.png")
        try expect(first != second, "same-named commit images share a temp URL")
        let otherRepository = WorkspaceWindowController.commitBlobURL(
            repository: secondRepository, commit: "abc1234", path: "assets/icon.png")
        try expect(first != otherRepository, "different repositories share a commit-image temp URL")
    }

    private static func testDefaultWindowPlacement() throws {
        let visible = NSRect(x: 100, y: 50, width: 1500, height: 900)
        let frame = WorkspaceWindowController.defaultWindowFrame(in: visible)
        try expect(frame == NSRect(x: 350, y: 50, width: 1000, height: 900),
                   "default window was not full-height, two-thirds width, and centered")
    }

    private static func testDocumentStoreProtectsNewBuffer() throws {
        let directory = try temporaryDirectory("document-store")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("new.txt")
        try Data("new buffer".utf8).write(to: url)

        let store = DocumentStore()
        store.maxCachedDocuments = 0
        let first = store.document(for: url)
        try expect(store.documentIsCached(url),
                   "a newly loaded document evicted itself before attachment")
        let second = store.document(for: url)
        try expect(first === second, "subsequent lookup returned a duplicate document buffer")
    }

    private static func testVirtualDocumentRefreshesInPlace() throws {
        let store = DocumentStore()
        let url = URL(string: "puzzle-diff:///preview?window=test")!
        let first = store.setVirtualDocument(url: url, text: "-old\n", displayName: "old")
        let layout = NSLayoutManager()
        first.storage.addLayoutManager(layout)
        defer { first.storage.removeLayoutManager(layout) }

        let refreshed = store.setVirtualDocument(
            url: url, text: "+new\n", displayName: "new")
        try expect(first === refreshed,
                   "refreshing a diff allocated a second document behind its layout manager")
        try expect(refreshed.text == "+new\n" && refreshed.displayName == "new",
                   "in-place diff refresh did not replace its visible content")
    }

    private static func testLargeFilesAreRejectedBeforeLoading() throws {
        let directory = try temporaryDirectory("large-file")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("generated.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(Document.maxTextFileBytes + 1))
        try handle.close()

        let document = Document(url: url)
        try expect(document.isUnsupported && document.isReadOnly,
                   "oversized text file was materialised as an editable document")
        try expect(document.storage.length < 1_000,
                   "large-file placeholder retained the oversized file contents")
        try expect(!SearchViewController.shouldLoadForNativeSearch(url),
                   "native search would read an oversized file before rejecting it")
    }

    private static func testPreviewPayloadsAreReleased() throws {
        let imagePreview = ImagePreviewView(frame: .zero)
        imagePreview.show(image: NSImage(size: NSSize(width: 100, height: 50)),
                          caption: "first")
        imagePreview.show(image: NSImage(size: NSSize(width: 50, height: 100)),
                          caption: "second")
        try expect(imagePreview.dynamicConstraintCountForTesting == 3,
                   "image preview accumulated sizing constraints")
        imagePreview.clear()
        try expect(!imagePreview.hasImageForTesting
                   && imagePreview.dynamicConstraintCountForTesting == 0,
                   "clearing an image preview retained its bitmap or constraints")

        let markdown = MarkdownPreviewView(frame: .zero)
        markdown.update(source: "# Retained preview", immediately: true)
        try expect(markdown.retainedSourceLengthForTesting > 0
                   && markdown.renderedLengthForTesting > 0,
                   "markdown preview did not render the regression fixture")
        markdown.clearContent()
        try expect(markdown.retainedSourceLengthForTesting == 0
                   && markdown.renderedLengthForTesting == 0,
                   "hidden markdown preview retained source or rendered text")
        markdown.update(source: "late delayed render")
        markdown.clearContent()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        try expect(markdown.retainedSourceLengthForTesting == 0
                   && markdown.renderedLengthForTesting == 0,
                   "cancelled markdown work repopulated a hidden preview")
    }

    private static func testFindMatchesAreComplete() throws {
        let textView = PuzzleTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        textView.string = String(repeating: "a", count: 10_250)
        let findBar = FindBarView(frame: .zero)
        findBar.attach(to: textView)
        findBar.setQuery("a")
        try expect(findBar.retainedMatchCountForTesting == textView.string.count,
                   "find-in-file did not retain every match")
        findBar.clearHighlights()
        try expect(findBar.retainedMatchCountForTesting == 0 && textView.searchMatches.isEmpty,
                   "closing find-in-file retained match ranges")
    }

    private static func testCodeBlockAnalysisAndFolding() throws {
        let swift = """
        func outer() {
            let ignored = "{ not a block }"
            // { neither is this }
            if true {
                print("nested")
            }
        }
        print("after")
        """
        let blocks = CodeBlockAnalyzer.analyze(swift, language: "swift", tabSize: 4)
        try expect(blocks.count == 2, "brace analysis included a string/comment brace")
        try expect(blocks.map(\.depth) == [0, 1], "nested block depths were not stable")
        let swiftSource = swift as NSString
        let outerOpeningLine = swiftSource.lineRange(
            for: NSRange(location: blocks[0].openerLocation, length: 0))
        let outerClosingLine = swiftSource.lineRange(
            for: NSRange(location: blocks[0].endLocation, length: 0))
        try expect(blocks[0].hiddenRange.location == NSMaxRange(outerOpeningLine)
                   && NSMaxRange(blocks[0].hiddenRange) == NSMaxRange(outerClosingLine),
                   "folding did not preserve the opener newline and hide the closing newline")

        let python = """
        if ready:
            for item in items:
                consume(item)
        finish()
        """
        let indentation = CodeBlockAnalyzer.analyze(
            python, language: "python", tabSize: 4)
        try expect(indentation.count == 2 && indentation.map(\.depth) == [0, 1],
                   "Python indentation blocks were not foldable")

        let storage = NSTextStorage(string: swift)
        storage.setAttributes(Theme.textAttributes(color: Theme.foreground),
                              range: NSRange(location: 0, length: storage.length))
        let layout = FoldingLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(
            size: NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        let textView = PuzzleTextView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            textContainer: container)
        textView.updateCodeBlocks(blocks, resetFolds: true)
        layout.ensureLayout(for: container)
        let expandedHeight = layout.usedRect(for: container).height
        textView.toggleFold(blocks[0])
        layout.ensureLayout(for: container)
        let foldedHeight = layout.usedRect(for: container).height

        try expect(foldedHeight < expandedHeight,
                   "null-glyph folding did not collapse the block's line fragments")
        try expect(storage.string == swift,
                   "visual folding changed the shared document text")
        try expect(textView.isFolded(blocks[0]), "fold state was not reflected in the gutter model")
    }
}

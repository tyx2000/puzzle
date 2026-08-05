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
        try testExternalFileLastWriteWins()
        try testBranchListing()
        try testDockRecentProjectsMenu()
        try testSearchMatcher()
        try testProjectSearchBackend()
        try testDefinitionNavigation()
        try testAbsoluteRowHeights()
        try testReadOnlyAndEncodingProtection()
        try testEditorManualSave()
        try testCommitImagePathsDoNotCollide()
        try testDefaultWindowPlacement()
        try testDocumentStoreProtectsNewBuffer()
        try testVirtualDocumentRefreshesInPlace()
        try testLargeFilesAreRejectedBeforeLoading()
        try testPreviewPayloadsAreReleased()
        try testFindMatchesAreComplete()
        try testBracketMatchingAndDeleteLine()
        try testCodeBlockAnalysisAndFolding()
        try testFileTreeContextEditing()
        try testFileHistoryTable()
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

    private static func sameColor(_ lhs: NSColor?, _ rhs: NSColor?) -> Bool {
        guard let lhs = lhs?.usingColorSpace(.sRGB),
              let rhs = rhs?.usingColorSpace(.sRGB) else { return lhs == nil && rhs == nil }
        return abs(lhs.redComponent - rhs.redComponent) < 0.002
            && abs(lhs.greenComponent - rhs.greenComponent) < 0.002
            && abs(lhs.blueComponent - rhs.blueComponent) < 0.002
            && abs(lhs.alphaComponent - rhs.alphaComponent) < 0.002
    }

    private static func testDockRecentProjectsMenu() throws {
        let directory = try temporaryDirectory("dock-recents")
        defer { try? FileManager.default.removeItem(at: directory) }

        let suiteName = "PuzzleRegressionDockRecents-\(UUID().uuidString)"
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

    private static func testAbsoluteRowHeights() throws {
        let settings = Settings.shared
        let saved = (settings.codeLineHeight, settings.treeLineHeight)
        defer {
            settings.codeLineHeight = saved.0
            settings.treeLineHeight = saved.1
            Theme.invalidateCaches()
        }

        settings.codeLineHeight = 31
        settings.treeLineHeight = 29
        Theme.invalidateCaches()

        try expect(Theme.lineMetrics().target == 31,
                   "code_line_height was treated as a multiplier instead of an exact row height")
        try expect(Theme.treeRowHeight() == 29,
                   "tree_line_height was treated as a multiplier instead of an exact row height")
    }

    private static func testExternalFileLastWriteWins() throws {
        let directory = try temporaryDirectory("external-last-write-wins")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("watched.txt")
        try Data("initial\n".utf8).write(to: url)
        let base = Date(timeIntervalSinceNow: -100)
        try FileManager.default.setAttributes([.modificationDate: base],
                                              ofItemAtPath: url.path)

        let store = DocumentStore()
        let document = store.document(for: url)
        document.storage.setAttributedString(NSAttributedString(string: "local newest\n"))
        document.markLocalEdit(at: base.addingTimeInterval(20))

        try Data("external older\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: base.addingTimeInterval(10)], ofItemAtPath: url.path)
        let ignored = store.reloadExternalChanges(
            at: [url], observedAt: base.addingTimeInterval(25))
        try expect(ignored.isEmpty && document.text == "local newest\n" && document.isModified,
                   "an older disk write replaced a newer local edit")

        try Data("external newest\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: base.addingTimeInterval(30)], ofItemAtPath: url.path)
        let applied = store.reloadExternalChanges(
            at: [url], observedAt: base.addingTimeInterval(31))
        try expect(applied == [url] && document.text == "external newest\n"
                   && !document.isModified && document.lastLocalEditAt == nil,
                   "the newest external write did not replace the editor buffer")
        store.release(url, stillOpen: false)

        var observedPaths: [URL] = []
        let monitor = WorkspaceFileMonitor(directory: directory) { paths, _ in
            observedPaths.append(contentsOf: paths)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        try Data("monitor delivery\n".utf8).write(to: url, options: .atomic)
        let deadline = Date().addingTimeInterval(3)
        while observedPaths.isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        monitor.stop()
        try expect(observedPaths.contains(where: {
            $0.standardizedFileURL == url.standardizedFileURL
                || $0.standardizedFileURL == directory.standardizedFileURL
                || $0.deletingLastPathComponent().standardizedFileURL
                    == directory.standardizedFileURL
        }), "workspace FSEvents monitor did not deliver an external file write")
    }

    private static func testBracketMatchingAndDeleteLine() throws {
        let nested = "call(\"ignored )\", [value])" as NSString
        let outer = BracketMatcher.ranges(in: nested, caret: 5)
        try expect(outer.count == 2 && outer[0].location == 4
                   && nested.substring(with: outer[1]) == ")",
                   "matching brackets did not span strings and nested brackets correctly")
        let ignored = BracketMatcher.ranges(in: "\"(not code)\"" as NSString, caret: 2)
        try expect(ignored.isEmpty, "brackets inside a string were highlighted")

        let textView = PuzzleTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        textView.string = "one\ntwo\nthree"
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        guard let deleteEvent = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.shift],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}",
            isARepeat: false, keyCode: 51) else {
            throw Failure(description: "could not construct Shift+Backspace event")
        }
        textView.keyDown(with: deleteEvent)
        try expect(textView.string == "one\nthree",
                   "Shift+Backspace did not remove the caret's complete line")
        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        try expect(textView.deleteCurrentLine() && textView.string == "one",
                   "deleting a final unterminated line left an empty line behind")

        textView.string = "(value)"
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        textView.refreshBracketMatches()
        try expect(textView.bracketMatchRanges.map(\.location) == [0, 6],
                   "the text view did not expose both matched-bracket outline ranges")
        try expect(textView.bracketScopeGeometry(
            in: NSRect(x: 0, y: 0, width: 400, height: 200))?.box != nil,
            "TextKit did not turn a same-line bracket pair into an enclosure")

        textView.string = "call(\n    value\n)"
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        textView.refreshBracketMatches()
        let laidOutMultiline = textView.bracketScopeGeometry(
            in: NSRect(x: 0, y: 0, width: 400, height: 200))
        try expect(laidOutMultiline?.box == nil
                   && laidOutMultiline?.polyline.count == 4,
                   "TextKit did not turn a multiline bracket pair into a scope contour")

        let sameLine = BracketScopeGeometry.make(
            opening: NSRect(x: 20, y: 10, width: 8, height: 14),
            closing: NSRect(x: 80, y: 10, width: 8, height: 14),
            guideX: 10, visibleRect: NSRect(x: 0, y: 0, width: 100, height: 100))
        try expect(sameLine.box != nil && sameLine.polyline.isEmpty,
                   "a same-line bracket pair did not produce a compact enclosure")

        let multiline = BracketScopeGeometry.make(
            opening: NSRect(x: 80, y: -30, width: 8, height: 14),
            closing: NSRect(x: 20, y: 130, width: 8, height: 14),
            guideX: 12, visibleRect: NSRect(x: 0, y: 0, width: 100, height: 100))
        try expect(multiline.box == nil && multiline.polyline.count == 4,
                   "a multiline bracket pair did not produce a scope contour")
        try expect(multiline.viewportCaps.count == 2,
                   "an offscreen bracket pair did not mark both viewport continuations")
        try expect(multiline.polyline[1].x == multiline.polyline[2].x,
                   "the scope contour's indentation guide was not vertical")
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
        let fileHistory = GitService.log(file: project.appendingPathComponent(renamed),
                                         in: project)
        try expect(fileHistory.first?.subject == unusualSubject
                   && fileHistory.contains(where: { $0.subject == "scoped" }),
                   "file Git history did not follow the path across its rename")

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

    private static func testDefinitionNavigation() throws {
        let root = try temporaryDirectory("definitions")
        defer { try? FileManager.default.removeItem(at: root) }
        let components = root.appendingPathComponent("components", isDirectory: true)
        try FileManager.default.createDirectory(at: components,
                                                withIntermediateDirectories: true)
        let buttonURL = components.appendingPathComponent("Button.tsx")
        let buttonText = "export function Button() { return <button /> }\n"
        try Data(buttonText.utf8).write(to: buttonURL)
        let appURL = root.appendingPathComponent("App.tsx")
        let appText = """
        import { Button } from "./components/Button"
        const handleSubmit = () => Button()
        function App() { return <Button onClick={handleSubmit} /> }
        """
        try Data(appText.utf8).write(to: appURL)

        let app = appText as NSString
        let pathClick = app.range(of: "components/Button").location + 4
        let pathDestination = DefinitionNavigator.resolve(
            text: appText, sourceURL: appURL, projectRoot: root,
            utf16Location: pathClick)
        try expect(pathDestination?.url.resolvingSymlinksInPath()
                   == buttonURL.resolvingSymlinksInPath(),
                   "Command-click did not resolve an extensionless import path")

        let usage = app.range(of: "handleSubmit", options: .backwards).location
        let localDestination = DefinitionNavigator.resolve(
            text: appText, sourceURL: appURL, projectRoot: root,
            utf16Location: usage + 2)
        try expect(localDestination?.url == appURL
                   && localDestination?.utf16Location == app.range(of: "handleSubmit").location,
                   "Command-click did not prefer the local variable declaration")

        let componentUsage = app.range(of: "Button", options: .backwards).location
        let componentDestination = DefinitionNavigator.resolve(
            text: appText, sourceURL: appURL, projectRoot: root,
            utf16Location: componentUsage + 2)
        try expect(componentDestination?.url.resolvingSymlinksInPath()
                   == buttonURL.resolvingSymlinksInPath(),
                   "Command-click did not find a component declaration in the project: \(String(describing: componentDestination))")
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
        try expect(GitService.run(["init", "-q"], in: directory).code == 0,
                   "inline-blame fixture git init failed")
        _ = GitService.run(["config", "user.name", "Puzzle Test"], in: directory)
        _ = GitService.run(["config", "user.email", "puzzle@example.invalid"], in: directory)
        try expect(GitService.commit("initial", in: directory).code == 0,
                   "inline-blame fixture commit failed")

        let pane = EditorPaneViewController()
        _ = pane.view
        pane.repositoryRoot = directory
        pane.open(url: url)
        try expect(!pane.hasActiveLineForTesting && pane.inlineBlameForTesting == nil,
                   "newly opened file activated the first line or inline blame")
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        try expect(!pane.hasActiveLineForTesting && pane.inlineBlameForTesting == nil,
                   "newly opened file activated the first line asynchronously")
        pane.jumpToLine(1)
        try expect(pane.hasActiveLineForTesting,
                   "an explicit line jump did not activate the current-line background")
        try expect(pane.currentLineHeightForTesting == Theme.lineMetrics().target,
                   "active line did not use code_line_height")
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        guard let stableBlame = pane.inlineBlameForTesting else {
            throw Failure(description: "explicitly activated line did not show inline blame")
        }
        for _ in 0..<3 {
            pane.textViewDidChangeSelection(
                Notification(name: NSTextView.didChangeSelectionNotification))
            try expect(pane.inlineBlameForTesting == stableBlame,
                       "repeated selection notification cleared inline blame")
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        try expect(pane.inlineBlameForTesting == stableBlame,
                   "same-line blame request flickered after its debounce")
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

        let sidebar = SidebarViewController()
        _ = sidebar.view
        sidebar.setFileTabHeight(72)
        try expect(sidebar.fileTreeTopInsetForTesting == 72,
                   "file tree top inset did not follow the file-tab height")

        let workspace = WorkspaceWindowController()
        workspace.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        let titlebarHeight = workspace.trafficLightTopInset * 2
            + workspace.trafficLightHeight
        try expect(workspace.sidebar.fileTreeTopInsetForTesting == titlebarHeight,
                   "file tree top inset did not follow traffic-light geometry")
        try expect(workspace.editor.activePaneForTesting?.tabBarHeight == titlebarHeight,
                   "file-tab height did not follow traffic-light geometry")

        let treeRoot = try temporaryDirectory("tree-top-inset")
        defer { try? FileManager.default.removeItem(at: treeRoot) }
        try Data("fixture".utf8).write(to: treeRoot.appendingPathComponent("file.txt"))
        workspace.sidebar.fileTree.setRoot(treeRoot)
        workspace.window?.contentView?.layoutSubtreeIfNeeded()
        let actualTop = workspace.sidebar.fileTree.firstRowTopInsetInWindowForTesting
        try expect(actualTop.map { abs($0 - titlebarHeight) <= 0.5 } == true,
                   "first file-tree row did not start at the 32pt file-tab boundary: "
                    + String(describing: actualTop))
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
        textView.string = "payload and payload"
        let clearingFindBar = FindBarView(frame: .zero)
        clearingFindBar.attach(to: textView)
        clearingFindBar.setQuery("payload")
        clearingFindBar.setQuery("p")
        try expect(textView.selectedRange().length == 1,
                   "one-character find fixture did not select its current match")
        clearingFindBar.setQuery("")
        try expect(textView.searchMatches.isEmpty && textView.currentMatchIndex == nil
                   && textView.selectedRange().length == 0,
                   "clearing find text left the final one-character selection highlighted")

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

    private static func testFileTreeContextEditing() throws {
        let directory = try temporaryDirectory("tree-context-editing")
        defer { try? FileManager.default.removeItem(at: directory) }
        let anchor = directory.appendingPathComponent("anchor.txt")
        try Data("anchor\n".utf8).write(to: anchor)

        let tree = FileTreeViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 420),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.contentViewController = tree
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        tree.setRoot(directory)
        tree.view.layoutSubtreeIfNeeded()
        try expect(!tree.automaticallyAdjustsInsetsForTesting,
                   "file-tree scroll view still applied a titlebar safe-area inset")

        let initialTrackingCount = tree.hoverTrackingAreaInstallCountForTesting
        _ = tree.hoverTrackingAreaInstallCountForTesting
        _ = tree.hoverTrackingAreaInstallCountForTesting
        try expect(initialTrackingCount == 1,
                   "file-tree installed more than one hover tracking area")
        guard let anchorRow = tree.row(for: anchor) else {
            throw Failure(description: "anchor row missing from file tree")
        }
        tree.setHoveredRowForTesting(anchorRow)
        tree.setHoveredRowForTesting(anchorRow)
        try expect(tree.hoveredRowForTesting == anchorRow,
                   "file-tree hover did not remain stable on the same row")

        func runUI(_ seconds: TimeInterval = 0.35) {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
        }

        func menuItem(_ title: String, for url: URL) throws -> NSMenuItem {
            guard let row = tree.row(for: url),
                  let item = tree.contextMenuForTesting(row: row)?.item(withTitle: title) else {
                throw Failure(description: "missing \(title) menu item for \(url.lastPathComponent)")
            }
            return item
        }

        func invoke(_ item: NSMenuItem) throws {
            guard let action = item.action,
                  NSApp.sendAction(action, to: item.target, from: item) else {
                throw Failure(description: "menu target-action was not delivered: \(item.title)")
            }
            runUI()
        }

        func enter(_ value: String) throws {
            guard let editor = window.firstResponder as? NSTextView else {
                throw Failure(description: "inline tree editor did not receive the field editor")
            }
            editor.selectAll(nil)
            editor.insertText(value, replacementRange: editor.selectedRange())
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            runUI(0.15)
        }

        let newFile = try menuItem("New File", for: anchor)
        try invoke(newFile)
        let anchorRowAfterInsert = tree.row(for: anchor)
        let pendingRowAfterInsert = tree.pendingEditRowForTesting
        try expect(pendingRowAfterInsert == (anchorRowAfterInsert ?? -2) + 1,
                   "New File did not insert an adjacent edit row "
                    + "(anchor=\(String(describing: anchorRowAfterInsert)), "
                    + "pending=\(String(describing: pendingRowAfterInsert)), "
                    + "rows=\(tree.rowCountForTesting))")
        // File monitoring and git status can both refresh immediately after a
        // context-menu action. Neither may destroy the active inline editor.
        tree.refresh()
        tree.setStatus(modified: ["anchor.txt"], untracked: [])
        runUI(0.1)
        try expect(tree.pendingEditRowForTesting == pendingRowAfterInsert,
                   "tree/git refresh removed the active New File editor")
        try expect((tree.pendingEditorVerticalCenterErrorForTesting ?? 100) <= 0.5,
                   "inline editor text/caret was not vertically centered")
        try expect(tree.pendingEditorHasIconForTesting == true,
                   "New File editor did not retain a file icon")
        try expect(sameColor(tree.pendingEditorBackgroundForTesting, .white),
                   "New File editor did not paint the whole row white")
        var openedAfterCreate: URL?
        tree.onOpenFile = { openedAfterCreate = $0 }
        try enter("created.any")
        let created = directory.appendingPathComponent("created.any")
        try expect(FileManager.default.fileExists(atPath: created.path),
                   "New File target-action did not create the entered file")
        try expect(openedAfterCreate == created,
                   "a newly created file was not opened automatically")

        try invoke(try menuItem("New Folder", for: anchor))
        try expect(tree.pendingEditorHasIconForTesting == true
                   && sameColor(tree.pendingEditorBackgroundForTesting, .white),
                   "New Folder editor did not show its icon on a white row")
        try enter("created-folder")
        var isDirectory: ObjCBool = false
        let folder = directory.appendingPathComponent("created-folder", isDirectory: true)
        try expect(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory)
                   && isDirectory.boolValue,
                   "New Folder target-action did not create a directory")

        try invoke(try menuItem("Rename", for: folder))
        try expect(tree.pendingEditorHasIconForTesting == true,
                   "Rename dropped the original folder icon")
        guard let folderRenameEditor = window.firstResponder as? NSTextView else {
            throw Failure(description: "folder rename fixture did not focus its editor")
        }
        folderRenameEditor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        runUI(0.15)

        try invoke(try menuItem("Rename", for: created))
        try expect(tree.pendingEditRowForTesting == tree.row(for: created),
                   "Rename did not replace the selected row with an editor")
        try expect(tree.pendingEditorHasIconForTesting == true
                   && sameColor(tree.pendingEditorBackgroundForTesting, .white),
                   "Rename editor dropped the original icon or white row background")
        try enter("renamed.any")
        let renamed = directory.appendingPathComponent("renamed.any")
        try expect(FileManager.default.fileExists(atPath: renamed.path)
                   && !FileManager.default.fileExists(atPath: created.path),
                   "Rename target-action did not move the file")

        try invoke(try menuItem("New File", for: renamed))
        guard let cancelEditor = window.firstResponder as? NSTextView else {
            throw Failure(description: "cancel fixture did not focus the inline editor")
        }
        cancelEditor.insertText("cancelled.txt", replacementRange: cancelEditor.selectedRange())
        cancelEditor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        runUI(0.15)
        try expect(tree.pendingEditRowForTesting == nil
                   && !FileManager.default.fileExists(
                        atPath: directory.appendingPathComponent("cancelled.txt").path),
                   "Escape did not cancel file creation")

        try invoke(try menuItem("New File", for: renamed))
        guard let blurEditor = window.firstResponder as? NSTextView else {
            throw Failure(description: "blur fixture did not focus the inline editor")
        }
        blurEditor.insertText("blurred.txt", replacementRange: blurEditor.selectedRange())
        window.makeFirstResponder(nil)
        runUI(0.15)
        try expect(tree.pendingEditRowForTesting == nil
                   && !FileManager.default.fileExists(
                        atPath: directory.appendingPathComponent("blurred.txt").path),
                   "blur did not cancel unconfirmed file creation")
    }

    private static func testFileHistoryTable() throws {
        let directory = try temporaryDirectory("file-history-table")
        defer { try? FileManager.default.removeItem(at: directory) }
        try expect(GitService.run(["init", "-q"], in: directory).code == 0,
                   "file-history git init failed")
        _ = GitService.run(["config", "user.name", "History Author"], in: directory)
        _ = GitService.run(["config", "user.email", "history@example.invalid"], in: directory)
        let file = directory.appendingPathComponent("history.txt")
        try Data("first\n".utf8).write(to: file)
        try expect(GitService.commit("first history entry", in: directory).code == 0,
                   "first file-history commit failed")
        try Data("first\nsecond\n".utf8).write(to: file)
        try expect(GitService.commit("second history entry", in: directory).code == 0,
                   "second file-history commit failed")

        let commits = GitService.log(file: file, in: directory)
        try expect(commits.count == 2, "file history did not return both commits")
        let model = FileHistoryModel(
            tabURL: URL(string: "puzzle-diff:///history-table")!,
            repository: directory,
            relativePath: "history.txt",
            displayName: "history.txt History",
            commits: commits)
        let history = FileHistoryView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        history.configure(model)
        try expect(history.columnTitlesForTesting == ["Commit", "Time", "Author", "Commit ID"],
                   "file history did not expose the required four columns")
        try expect(history.rowCountForTesting == 2,
                   "file-history table row count did not match git log")

        history.toggleRowForTesting(0)
        let deadline = Date(timeIntervalSinceNow: 3)
        while history.detailTextForTesting == "Loading…" && Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        try expect(history.expandedRowForTesting == 0,
                   "clicking a file-history row did not expand it")
        try expect(history.detailTextForTesting.contains("second"),
                   "expanded file-history row did not load its file diff")
        try expect(history.detailDiffBandCountForTesting > 0,
                   "file-history detail did not reuse Changes diff colour bands")
        history.toggleRowForTesting(0)
        try expect(history.expandedRowForTesting == nil,
                   "clicking the expanded history row did not collapse it")
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

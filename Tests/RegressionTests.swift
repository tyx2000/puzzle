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
        try testGitIgnoreRefreshReconciliation()
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
        try testMarkdownLiveEditing()
        try testFindMatchesAreComplete()
        try testBracketMatchingAndDeleteLine()
        try testCodeBlockAnalysisAndFolding()
        try testFileTreeContextEditing()
        try testFileHistoryTable()
        try testDiffGutterUsesFileLineNumbers()
        try testProjectTitleStrip()
        try testBranchMenu()
        try testMaterialFileIcons()
        try testActivityBarUsesTextLabels()
        try testAyuDarkTheme()
        try testDiffHeaderStepsThroughChanges()
        try testActiveLineSpansTheGutter()
        try testFileOpensRouteToTheirProjectWindow()
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

        // The Changes list is a file list like the tree's, so both rows must
        // measure the same — height and the spacing between rows alike.
        let tree = FileTreeViewController()
        let git = GitPanelViewController()
        let treeRow = tree.outlineView(NSOutlineView(), heightOfRowByItem: NSObject())
        let gitRow = git.tableView(NSTableView(), heightOfRow: 0)
        try expect(treeRow == 29 && gitRow == 29,
                   "git Changes rows are \(gitRow) tall against the tree's \(treeRow); "
                    + "both should follow tree_line_height")
        try expect(tree.rowPitchForTesting == git.rowPitchForTesting,
                   "git Changes rows sit at a \(git.rowPitchForTesting)pt pitch "
                    + "against the tree's \(tree.rowPitchForTesting)pt")
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
        let split = GitService.trackedAndUntracked(in: status)
        try expect(split.untracked == [special] && split.modified.isEmpty,
                   "splitting a status snapshot lost entries: \(split)")
        try expect(status.userName == "Puzzle Test",
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

    private static func testGitIgnoreRefreshReconciliation() throws {
        let directory = try temporaryDirectory("gitignore-refresh")
        defer { try? FileManager.default.removeItem(at: directory) }
        try expect(GitService.run(["init", "-q"], in: directory).code == 0,
                   "gitignore fixture git init failed")
        _ = GitService.run(["config", "user.name", "Puzzle Test"], in: directory)
        _ = GitService.run(["config", "user.email", "puzzle@example.invalid"], in: directory)

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
        let pathHoverRange = DefinitionNavigator.targetRange(
            in: appText, utf16Location: pathClick)
        try expect(pathHoverRange.map { app.substring(with: $0) } == "./components/Button",
                   "Command-hover did not identify the complete import path")
        let pathDestination = DefinitionNavigator.resolve(
            text: appText, sourceURL: appURL, projectRoot: root,
            utf16Location: pathClick)
        try expect(pathDestination?.url.resolvingSymlinksInPath()
                   == buttonURL.resolvingSymlinksInPath(),
                   "Command-click did not resolve an extensionless import path")

        let usage = app.range(of: "handleSubmit", options: .backwards).location
        let symbolHoverRange = DefinitionNavigator.targetRange(
            in: appText, utf16Location: usage + 2)
        try expect(symbolHoverRange.map { app.substring(with: $0) } == "handleSubmit",
                   "Command-hover did not identify the complete symbol")
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
                   "project search lost a path containing colon/newline: "
                    + "\(groups.map(\.relative))")
        // The temporary directory is reached through a symlink (/var → /private/var),
        // so a result whose path was built by string subtraction points nowhere.
        try expect(FileManager.default.fileExists(atPath: groups[0].url.path),
                   "search result URL does not exist: \(groups[0].url.path)")
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

    }

    private static func testMarkdownLiveEditing() throws {
        let directory = try temporaryDirectory("markdown-live-editing")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("README.md")
        let initial = "# Initial heading\n\nThis is **important** and [linked](https://example.com).\n"
        try Data(initial.utf8).write(to: url)

        let pane = EditorPaneViewController()
        _ = pane.view
        pane.repositoryRoot = directory
        pane.open(url: url)
        let document = DocumentStore.shared.document(for: url)
        try expect(document.storage.string == initial,
                   "live Markdown formatting changed the editable source")
        let headingLocation = (initial as NSString).range(of: "Initial heading").location
        let strongLocation = (initial as NSString).range(of: "important").location
        let linkLocation = (initial as NSString).range(of: "linked").location
        let headingFont = document.storage.attribute(.font, at: headingLocation,
                                                     effectiveRange: nil) as? NSFont
        let strongFont = document.storage.attribute(.font, at: strongLocation,
                                                    effectiveRange: nil) as? NSFont
        let linkColor = document.storage.attribute(.foregroundColor, at: linkLocation,
                                                   effectiveRange: nil) as? NSColor
        let markerColor = document.storage.attribute(.foregroundColor, at: 0,
                                                     effectiveRange: nil) as? NSColor
        let headingStroke = document.storage.attribute(.strokeWidth, at: headingLocation,
                                                       effectiveRange: nil) as? NSNumber
        let strongStroke = document.storage.attribute(.strokeWidth, at: strongLocation,
                                                      effectiveRange: nil) as? NSNumber
        try expect(headingFont?.pointSize ?? 0 > Theme.editorFont().pointSize
                   && (headingStroke?.doubleValue ?? 0) < 0,
                   "Markdown heading was not formatted in the editable buffer")
        try expect(strongFont != nil && (strongStroke?.doubleValue ?? 0) < 0,
                   "Markdown strong emphasis was not formatted in the editable buffer")
        try expect(sameColor(linkColor, Theme.blue),
                   "Markdown link label was not rendered as a link")
        try expect(sameColor(markerColor, Theme.dimText),
                   "Markdown source marker did not visually recede")
        let markdownLayout = FoldingLayoutManager()
        markdownLayout.updateMarkdownSyntaxRanges(document.markdownSyntaxRanges,
                                                   replacements: document.markdownGlyphReplacements,
                                                   revealing: nil)
        let linkDestination = (initial as NSString).range(of: "https://example.com").location
        try expect(markdownLayout.isCharacterHidden(at: 0)
                   && markdownLayout.isCharacterHidden(at: linkDestination)
                   && !markdownLayout.isCharacterHidden(at: headingLocation),
                   "opening Markdown did not collapse source syntax into rendered text")
        let headingLine = (initial as NSString).lineRange(
            for: NSRange(location: headingLocation, length: 0))
        markdownLayout.revealMarkdownSyntax(in: headingLine)
        try expect(!markdownLayout.isCharacterHidden(at: 0),
                   "entering a Markdown line did not reveal its editable source markers")

        let edited = """
        ## Live heading

        `payload` and *updated*

        ```swift
        let value = 1
        ```

        | Name | Value |
        | --- | --- |
        | Alpha \\| content &amp; text that must wrap onto multiple visual lines in a narrow table | 1 |

        - [ ] Pending item
        - [x] Completed item

        Setext heading
        ===============

        > Quoted text
        - Bullet item
        3. Ordered item

        ---

        ![Diagram](diagram.png)

        [Reference label][docs]
        [docs]: https://example.com/docs

            let indented = true

        Escaped \\*literal\\* and <kbd>Cmd</kbd>

        Hard break\\
        next line with <hello@example.com> and https://example.com/path.

        Entities: &amp; and &#169;.

        A note[^detail].

        [^detail]: Footnote body

        <!-- hidden note -->

        """
        document.storage.replaceCharacters(
            in: NSRange(location: 0, length: document.storage.length),
            with: edited)
        pane.textDidChange(Notification(name: NSText.didChangeNotification))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        try expect(document.storage.string == edited,
                   "editing live Markdown no longer preserved its source")
        let codeLocation = (edited as NSString).range(of: "payload").location
        let codeBackground = document.storage.attribute(.backgroundColor, at: codeLocation,
                                                        effectiveRange: nil) as? NSColor
        try expect(sameColor(codeBackground, Theme.inputBackground),
                   "Markdown edit was not formatted on the next run-loop turn")
        try expect(document.markdownCodeBlocks.count == 2
                   && document.markdownCodeBlocks[0].language == "swift",
                   "fenced/indented Markdown code was not published as rendered blocks")
        try expect(document.markdownTables.count == 1
                   && document.markdownTables[0].columnCount == 2
                   && document.markdownTables[0].rows.count == 2
                   && document.markdownTables[0].rows[1].cells[0]
                       .contains("Alpha | content & text"),
                   "Markdown table rows and columns were not parsed for rendering")
        try expect(pane.markdownDecorationCountsForTesting.codeBlocks == 2
                   && pane.markdownDecorationCountsForTesting.tables == 1,
                   "Markdown block decorations did not reach the active editor view")
        try expect(document.markdownTasks.count == 2
                   && !document.markdownTasks[0].checked
                   && document.markdownTasks[1].checked
                   && pane.markdownTaskCountForTesting == 2,
                   "Markdown task-list markers were not published as checkboxes")
        try expect(document.markdownLineMarkers.count == 4,
                   "blockquote, list and footnote markers were not rendered")
        try expect(document.markdownRules.count == 1,
                   "thematic break was not published as a rendered rule")
        try expect(document.markdownImages.count == 1
                   && document.markdownImages[0].alt == "Diagram"
                   && document.markdownImages[0].url?.lastPathComponent == "diagram.png",
                   "standalone Markdown image was not resolved for rendering")
        try expect(!pane.showsLineNumbersForTesting,
                   "Markdown editor still displayed its line-number ruler")
        try expect(!pane.hasActiveLineForTesting,
                   "Markdown editor still displayed an active-line background")
        try expect(document.markdownCollapsedLineRanges.count >= 3,
                   "Markdown fence/table separator lines were not collapsed")
        let setextLocation = (edited as NSString).range(of: "Setext heading").location
        let setextStroke = document.storage.attribute(
            .strokeWidth, at: setextLocation, effectiveRange: nil) as? NSNumber
        try expect((setextStroke?.doubleValue ?? 0) < 0,
                   "Setext heading did not receive rendered heading typography")
        let referenceDestination = (edited as NSString).range(of: "https://example.com/docs").location
        let escapedSlash = (edited as NSString).range(of: #"\*literal"#).location
        let htmlOpen = (edited as NSString).range(of: "<kbd>").location
        let hardBreak = (edited as NSString).range(of: "Hard break\\").location
            + ("Hard break" as NSString).length
        let htmlComment = (edited as NSString).range(of: "<!-- hidden note -->").location
        let bareURLLocation = (edited as NSString).range(of: "https://example.com/path").location
        let entityLocation = (edited as NSString).range(of: "Entities: &amp;").location
            + ("Entities: " as NSString).length
        let footnoteReference = (edited as NSString).range(of: "[^detail]").location
        try expect(document.markdownSyntaxRanges.contains {
            NSLocationInRange(referenceDestination, $0)
        }, "reference-link definition remained visible")
        try expect(document.markdownSyntaxRanges.contains {
            NSLocationInRange(escapedSlash, $0)
        }, "escaped Markdown punctuation retained its source backslash")
        try expect(document.markdownSyntaxRanges.contains {
            NSLocationInRange(htmlOpen, $0)
        }, "simple inline HTML tags were not collapsed")
        try expect(document.markdownSyntaxRanges.contains {
            NSLocationInRange(hardBreak, $0)
        }, "hard-break source marker remained visible")
        try expect(document.markdownSyntaxRanges.contains {
            NSLocationInRange(htmlComment, $0)
        }, "Markdown HTML comment remained visible")
        let bareURLColor = document.storage.attribute(
            .foregroundColor, at: bareURLLocation, effectiveRange: nil) as? NSColor
        try expect(sameColor(bareURLColor, Theme.blue),
                   "bare GFM URL was not rendered as a link")
        try expect(document.markdownGlyphReplacements.contains {
            $0.sourceRange.location == entityLocation && $0.character == 0x26
        }, "Markdown character entity was not decoded for rendered display")
        try expect(document.markdownSyntaxRanges.contains {
            NSLocationInRange(footnoteReference, $0)
        }, "Markdown footnote reference retained its source delimiters")

        let tableLayout = FoldingLayoutManager()
        let tableContainer = NSTextContainer(
            size: NSSize(width: 220, height: CGFloat.greatestFiniteMagnitude))
        tableContainer.widthTracksTextView = true
        tableLayout.addTextContainer(tableContainer)
        document.storage.addLayoutManager(tableLayout)
        let tableView = PuzzleTextView(
            frame: NSRect(x: 0, y: 0, width: 220, height: 300),
            textContainer: tableContainer)
        tableView.updateMarkdownDecorations(
            codeBlocks: document.markdownCodeBlocks,
            tables: document.markdownTables,
            tasks: document.markdownTasks,
            lineMarkers: document.markdownLineMarkers,
            rules: document.markdownRules,
            images: document.markdownImages,
            activeSourceRange: nil)
        tableLayout.updateMarkdownSyntaxRanges(
            document.markdownSyntaxRanges,
            collapsedLines: document.markdownCollapsedLineRanges,
            replacements: document.markdownGlyphReplacements,
            revealing: nil)
        let fenceLocation = (edited as NSString).range(of: "```swift").location
        try expect(tableLayout.isMarkdownControlLineCollapsed(at: fenceLocation),
                   "collapsed Markdown fence line would still draw a gutter number")
        let wrappedLocation = (edited as NSString).range(of: "Alpha").location
        let dynamicHeight = tableLayout.markdownTableRowHeightForTesting(
            at: wrappedLocation) ?? 0
        try expect(dynamicHeight > Theme.lineMetrics().target,
                   "wrapped Markdown table content retained the fixed code-line height")
        try expect(tableLayout.isCharacterHidden(at: wrappedLocation),
                   "rendered table source still participated in ordinary text wrapping")
        tableLayout.ensureLayout(for: tableContainer)
        let fencedBodyLocation = (edited as NSString).range(of: "let value = 1").location
        let fencedBodyGlyph = tableLayout.glyphIndexForCharacter(at: fencedBodyLocation)
        let fencedBodyFragment = tableLayout.lineFragmentRect(
            forGlyphAt: fencedBodyGlyph, effectiveRange: nil)
        try expect(fencedBodyFragment.height >= Theme.lineMetrics().target,
                   "final fenced-code content row was compressed with its closing fence")
        guard let wrappedRow = document.markdownTables[0].rows.first(where: {
            NSLocationInRange(wrappedLocation, $0.sourceRange)
        }) else { throw Failure(description: "wrapped table row metadata was missing") }
        let rowAnchor = wrappedRow.lineRange.length > wrappedRow.sourceRange.length
            ? NSMaxRange(wrappedRow.lineRange) - 1 : wrappedRow.sourceRange.location
        let wrappedGlyph = tableLayout.glyphIndexForCharacter(at: rowAnchor)
        let wrappedFragment = tableLayout.lineFragmentRect(
            forGlyphAt: wrappedGlyph, effectiveRange: nil)
        try expect(wrappedFragment.height > Theme.lineMetrics().target,
                   "TextKit did not apply the measured Markdown table row height")
        document.storage.removeLayoutManager(tableLayout)

        pane.prepareForClose()
        document.isModified = false
        DocumentStore.shared.release(url, stillOpen: false)
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

        // A file created by another process is not a cached Document. The tree
        // must still refresh immediately, and opening it must reveal/highlight
        // the row even if its FSEvent and open request arrive together.
        let external = directory.appendingPathComponent("external-created.toml")
        try Data("key = true\n".utf8).write(to: external)
        tree.selectFile(external)
        guard let externalRow = tree.row(for: external) else {
            throw Failure(description: "external open did not refresh the missing parent row")
        }
        tree.view.layoutSubtreeIfNeeded()
        let externalIsActive = tree.activeStateForTesting(at: externalRow)
        try expect(externalIsActive == true,
                   "externally opened file was not highlighted in the tree "
                    + "(activeURL=\(String(describing: tree.activeURLForTesting)), "
                    + "rowState=\(String(describing: externalIsActive)), "
                    + "highlightedRow=\(String(describing: tree.activeHighlightedRow)))")

        let monitorOnly = directory.appendingPathComponent("monitor-created.lock")
        try Data("lock\n".utf8).write(to: monitorOnly)
        tree.refresh(changedURLs: [monitorOnly])
        try expect(tree.row(for: monitorOnly) != nil,
                   "externally created file did not appear after targeted monitor refresh")

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

    private static func testActivityBarUsesTextLabels() throws {
        let bar = ActivityBarView(frame: NSRect(x: 0, y: 0, width: 320, height: 40))
        bar.layoutSubtreeIfNeeded()
        try expect(bar.buttonTitlesForTesting == ["Files", "Search", "Git", "Settings"],
                   "the activity bar reads \(bar.buttonTitlesForTesting)")

        // The Git label carries the live changed-file count in the same form as
        // the panel's own "Changes (7)" tab, a clean tree included.
        bar.setChangeCount(7)
        try expect(bar.buttonTitlesForTesting == ["Files", "Search", "Git (7)", "Settings"],
                   "the change count did not reach the Git label: "
                    + "\(bar.buttonTitlesForTesting)")
        bar.setChangeCount(0)
        try expect(bar.buttonTitlesForTesting == ["Files", "Search", "Git (0)", "Settings"],
                   "a clean tree dropped the count instead of showing (0): "
                    + "\(bar.buttonTitlesForTesting)")
        // The label is the affordance, so nothing waits for a hover to explain it.
        try expect(bar.buttonTooltipsForTesting.allSatisfy { $0 == nil },
                   "a text button still carries a tooltip")
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
                "puzzle: skipping icon test — run vendor/fetch.sh first\n".utf8))
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

    private static func testAyuDarkTheme() throws {
        let settings = Settings.shared
        let saved = settings.theme
        defer {
            settings.theme = saved
            Theme.invalidateCaches()
        }

        settings.theme = .one
        Theme.invalidateCaches()
        let oneBackground = Theme.editorBackground.usingColorSpace(.sRGB)
        try expect(Theme.isDark(NSAppearance(named: .aqua)!) == false,
                   "the default theme ignored a light system appearance")

        settings.theme = .ayuDark
        Theme.invalidateCaches()
        try expect(Theme.isDark(NSAppearance(named: .aqua)!),
                   "Ayu Dark did not report itself as a dark theme")
        // Ayu's code area is the panel's surface, and its active line is the
        // tree's active row, so the editor and the panel read as one.
        try expect(sameColor(Theme.editorBackground, Theme.panelBackground),
                   "the code area does not match the file-tree panel")
        try expect(sameColor(Theme.lineHighlight, Theme.activeRow),
                   "the active line does not match the tree's selected row")
        // The active tab is the one surface that must stay distinct: the tab
        // strip already uses the panel colour.
        try expect(!sameColor(Theme.activeTab, Theme.barBackground),
                   "the active tab vanished into the tab strip")
        // Every panel boundary is the same 1pt line.
        try expect(sameColor(PuzzleSplitView().dividerColor, Theme.border),
                   "the sidebar/editor divider is not the shared border line")
        try expect(sameColor(Theme.foreground, hexColor(0xbfbdb6)),
                   "the editor foreground is not Ayu's")
        // Types and calls swap hues between the two themes; the syntax roles
        // exist so both stay right.
        try expect(sameColor(Theme.syntaxType, hexColor(0x39bae6))
                    && sameColor(Theme.syntaxFunction, hexColor(0xffb454)),
                   "Ayu's syntax roles did not follow the theme")
        try expect(!sameColor(Theme.editorBackground, oneBackground),
                   "switching themes did not change the resolved colour")

        settings.theme = .one
        Theme.invalidateCaches()
        try expect(sameColor(Theme.editorBackground, oneBackground),
                   "switching back to One kept Ayu's background")
        // The editor panes' split view takes the colour directly…
        try expect(sameColor(PuzzleSplitView().dividerColor, Theme.border),
                   "the editor split did not take its divider colour from the theme")
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

    private static func testFileOpensRouteToTheirProjectWindow() throws {
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

        // A file lands in the window that owns it, and the deepest project wins
        // so a nested workspace keeps its own files.
        let roots: [URL?] = [nil, other, outer, inner]
        try expect(AppDelegate.projectIndex(owning: file, in: roots) == 3,
                   "a file in a nested project did not pick the nested window")
        try expect(AppDelegate.projectIndex(owning: outer.appendingPathComponent("top.swift"),
                                            in: roots) == 2,
                   "a file at the project root did not pick its window")
        try expect(AppDelegate.projectIndex(owning: root.appendingPathComponent("loose.swift"),
                                            in: roots) == nil,
                   "a file outside every project claimed a window")
        // A sibling whose name merely starts with the project's is not inside it.
        let lookalike = root.appendingPathComponent("outer-extra/file.swift")
        try expect(AppDelegate.projectIndex(owning: lookalike, in: roots) == nil,
                   "a sibling directory sharing the project's prefix matched it")

        // Re-opening a folder raises the window already showing it, symlinked
        // temporary paths (/var → /private/var) included.
        try expect(AppDelegate.projectIndex(matching: outer, in: roots) == 2,
                   "re-opening a project did not find its window")
        try expect(AppDelegate.projectIndex(
                    matching: URL(fileURLWithPath: "/private" + outer.path), in: roots) == 2,
                   "the same project through a symlinked path was treated as new")
        try expect(AppDelegate.projectIndex(matching: root, in: roots) == nil,
                   "an unopened folder matched an existing window")
    }

    private static func testActiveLineSpansTheGutter() throws {
        let directory = try temporaryDirectory("active-line")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("lines.swift")
        try Data("let a = 1\nlet b = 2\nlet c = 3\n".utf8).write(to: url)

        let pane = EditorPaneViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.contentViewController = pane
        defer { window.close() }
        pane.open(url: url)
        // The band appears once the file is actually being worked in — jumping
        // to a line is the same path a search result takes.
        pane.jumpToLine(2)
        pane.view.layoutSubtreeIfNeeded()

        guard let ruler = pane.lineNumberRulerForTesting else {
            throw Failure(description: "the editor has no line-number gutter")
        }
        guard let text = pane.currentLineBandRectForTesting,
              let gutter = ruler.currentLineBandRect() else {
            throw Failure(description: "no active-line band while a document is open")
        }
        // One row: the gutter band covers the full gutter width and lines up
        // with the band behind the code, so nothing shows through in front of
        // the line number.
        try expect(gutter.minX == 0 && gutter.width == ruler.ruleThickness,
                   "the gutter band does not span the line-number column: \(gutter)")
        try expect(abs(gutter.height - text.height) <= 0.5,
                   "the gutter band is \(gutter.height)pt against the code's \(text.height)pt")
        let expectedY = text.minY - ruler.clientViewVisibleRectForTesting.minY
        try expect(abs(gutter.minY - expectedY) <= 0.5,
                   "the gutter band sits at \(gutter.minY), the code's row at \(expectedY)")

        // Folding still hides a block's body when the document lays out on
        // demand (source files do; Markdown and diffs keep full layout because
        // their decorations measure ranges across the whole document).
        do {
            let long = directory.appendingPathComponent("folded.swift")
            var body = "import AppKit\n\nfunc outer() {\n    let a = 1\n}\n"
            let hidden = body.range(of: "let a = 1")!
            let hiddenOffset = body.distance(from: body.startIndex, to: hidden.lowerBound)
            for i in 0..<200 { body += "// filler line \(i)\n" }
            try Data(body.utf8).write(to: long)
            pane.open(url: long)
            pane.view.layoutSubtreeIfNeeded()
            try expect(!pane.isCharacterHiddenForTesting(hiddenOffset),
                       "the block body was hidden before anything was folded")
            pane.foldAllForTesting()
            pane.view.layoutSubtreeIfNeeded()
            try expect(pane.isCharacterHiddenForTesting(hiddenOffset),
                       "folding did not hide the block body under on-demand layout")
            try expect(pane.nonContiguousLayoutForTesting,
                       "a source file did not get on-demand layout")

            let notes = directory.appendingPathComponent("notes.md")
            try Data("# Title\n\n```swift\nlet x = 1\n```\n".utf8).write(to: notes)
            pane.open(url: notes)
            pane.view.layoutSubtreeIfNeeded()
            try expect(!pane.nonContiguousLayoutForTesting,
                       "Markdown lost its full layout, so its decorations would "
                        + "measure ranges that are not laid out yet")
        }

        // The undo stack is bounded, so a long session cannot accumulate every
        // edit ever made in the window.
        try expect(pane.undoLevelsForTesting == EditorPaneViewController.undoLevels,
                   "undo levels are \(String(describing: pane.undoLevelsForTesting))")

        // With a selection rather than a caret there is no band at all, in the
        // gutter or behind the code.
        pane.selectAllForTesting()
        try expect(pane.currentLineBandRectForTesting == nil
                    && ruler.currentLineBandRect() == nil,
                   "a selection still painted an active-line band")
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
        let pane = EditorPaneViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.contentViewController = pane
        defer { window.close() }

        let url = URL(string:
            "puzzle-diff:///repo/.puzzle-diff-preview?window=test&path=Sources/App.swift")!
        DocumentStore.shared.setVirtualDocument(
            url: url, text: diff, displayName: "App.swift (diff)")
        pane.open(url: url, replacingContent: true)
        pane.view.layoutSubtreeIfNeeded()

        try expect(pane.diffHeaderIsVisibleForTesting,
                   "a git diff opened without its header row")
        try expect(pane.diffHeaderForTesting.pathForTesting == "Sources/App.swift",
                   "the header showed \(pane.diffHeaderForTesting.pathForTesting)")
        // Touching +/- lines are one change, so this diff holds two.
        try expect(pane.changeBlockCountForTesting == 2,
                   "the header counted \(pane.changeBlockCountForTesting) changes, not 2")
        try expect(pane.diffHeaderForTesting.summaryForTesting == "2 changes",
                   "the header summarised \(pane.diffHeaderForTesting.summaryForTesting)")
        try expect(pane.diffHeaderForTesting.stepControlsEnabledForTesting,
                   "the step controls were disabled on a diff that has changes")

        // Stepping forward lands on each change in turn and then wraps.
        let text = diff as NSString
        func caretLine() -> Int {
            let caret = pane.caretLocationForTesting
            var line = 1
            for i in 0..<min(caret, text.length) where text.character(at: i) == 10 { line += 1 }
            return line
        }
        pane.diffHeaderForTesting.clickNextForTesting()
        try expect(caretLine() == 6, "the first step landed on line \(caretLine()), not the -/+ pair")
        pane.diffHeaderForTesting.clickNextForTesting()
        try expect(caretLine() == 11, "the second step landed on line \(caretLine())")
        pane.diffHeaderForTesting.clickNextForTesting()
        try expect(caretLine() == 6, "stepping past the last change did not wrap")
        pane.diffHeaderForTesting.clickPreviousForTesting()
        try expect(caretLine() == 11, "stepping back from the first change did not wrap")

        // An ordinary file has no header at all.
        let directory = try temporaryDirectory("diff-header")
        defer { try? FileManager.default.removeItem(at: directory) }
        let plain = directory.appendingPathComponent("plain.txt")
        try Data("just text\n".utf8).write(to: plain)
        pane.open(url: plain)
        pane.view.layoutSubtreeIfNeeded()
        try expect(!pane.diffHeaderIsVisibleForTesting,
                   "a normal file showed the diff header")
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
        // checked-out branch at the top regardless, then caps the list.
        var branches = (0..<15).map {
            branch("topic-\($0)", "Author \($0)", "2026-08-\(10 + $0) 09:00", Int64(1000 - $0))
        }
        branches.insert(branch("main", "tyxu", "2026-07-01 12:00", 1, current: true), at: 7)
        let entries = WorkspaceWindowController.branchMenuEntries(branches)
        try expect(entries.count == WorkspaceWindowController.branchMenuLimit,
                   "the menu listed \(entries.count) branches, not "
                    + "\(WorkspaceWindowController.branchMenuLimit)")
        try expect(entries.first?.name == "main",
                   "the current branch is not first: \(entries.map(\.name))")
        try expect(entries.dropFirst().map(\.name) == (0..<9).map { "topic-\($0)" },
                   "the rest lost their recency order: \(entries.map(\.name))")
        // A short list is not padded or truncated.
        try expect(WorkspaceWindowController.branchMenuEntries(Array(branches.prefix(3))).count == 3,
                   "a three-branch repo did not list all three")

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

        // Launching iTerm opens a window by itself, so the script must not add
        // a second one — that was two windows per click.
        let cold = WorkspaceWindowController.iTermScript(command: "cd /tmp",
                                                         reusingLaunchWindow: true)
        try expect(cold.contains("count of windows") && cold.contains("current window"),
                   "the cold-start script does not wait for the launch window")
        let warm = WorkspaceWindowController.iTermScript(command: "cd /tmp",
                                                         reusingLaunchWindow: false)
        try expect(!warm.contains("count of windows"),
                   "the warm script waits for a window that already exists")
        try expect(warm.components(separatedBy: "create window").count == 2,
                   "the warm script does not create exactly one window")
        // The cold path still has a create as its last resort, guarded by the
        // reuse check above it.
        try expect(cold.components(separatedBy: "create window").count == 2,
                   "the cold script lost its fallback window")
        try expect(cold.contains("cd /tmp") && warm.contains("cd /tmp"),
                   "the script does not carry the command")

        // The terminal command is quoted, so a space or a quote in the path
        // cannot run as shell syntax.
        let quoted = WorkspaceWindowController.shellQuoted("/tmp/my project's code")
        try expect(quoted == "'/tmp/my project'\\''s code'",
                   "the path was not shell-quoted: \(quoted)")
        let escaped = WorkspaceWindowController.appleScriptQuoted("say \"hi\" \\ now")
        try expect(escaped == "say \\\"hi\\\" \\\\ now",
                   "the AppleScript literal was not escaped: \(escaped)")
    }

    private static func testProjectTitleStrip() throws {
        let root = try temporaryDirectory("project-title")
        defer { try? FileManager.default.removeItem(at: root) }
        try expect(GitService.run(["init", "-q", "-b", "trunk"], in: root).code == 0,
                   "git init failed")
        _ = GitService.run(["config", "user.name", "Puzzle Test"], in: root)
        _ = GitService.run(["config", "user.email", "puzzle@example.invalid"], in: root)
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

        // The two halves are separate targets: the name opens a terminal, the
        // branch opens the branch menu. Measured with a short name, since a
        // temporary directory's is long enough to consume the whole strip.
        title.configure(project: "Puzzle", branch: "main")
        title.layoutSubtreeIfNeeded()
        let zones = title.zonesForTesting
        try expect(zones.project.width > 0 && zones.branch.width > 0,
                   "the strip did not lay out both halves: \(zones)")
        try expect(zones.branch.minX >= zones.project.maxX,
                   "the halves overlap: \(zones)")
        let inProject = NSPoint(x: zones.project.midX, y: zones.project.midY)
        let inBranch = NSPoint(x: zones.branch.midX, y: zones.branch.midY)
        try expect(title.zoneNameForTesting(at: inProject) == "project",
                   "the project name is not its own click target")
        try expect(title.zoneNameForTesting(at: inBranch) == "branch",
                   "the branch name is not its own click target")
        try expect(title.zoneNameForTesting(
                    at: NSPoint(x: zones.branch.maxX + 40, y: zones.branch.midY)) == nil,
                   "empty space past the branch still counted as a click")

        // Clicking the name opens the folder in iTerm, with Terminal as the
        // fallback where iTerm is not installed.
        let iTerm = URL(fileURLWithPath: "/Applications/iTerm.app")
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let installed: [String: URL] = ["com.googlecode.iterm2": iTerm,
                                        "com.apple.Terminal": terminal]
        try expect(WorkspaceWindowController.terminalApplication { installed[$0] } == iTerm,
                   "iTerm is installed but was not preferred")
        try expect(WorkspaceWindowController.terminalApplication {
                       $0 == "com.apple.Terminal" ? terminal : nil
                   } == terminal,
                   "without iTerm the click did not fall back to Terminal")
        try expect(WorkspaceWindowController.terminalApplication { _ in nil } == nil,
                   "a machine with neither terminal still resolved one")

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
        // above the file tree.
        workspace.window?.contentView?.layoutSubtreeIfNeeded()
        guard let closeButton = workspace.window?.standardWindowButton(.closeButton),
              let zoomButton = workspace.window?.standardWindowButton(.zoomButton) else {
            throw Failure(description: "window has no traffic lights")
        }
        let lightsRight = zoomButton.convert(zoomButton.bounds, to: nil).maxX
        let stripInWindow = title.convert(title.bounds, to: nil)
        let band = workspace.sidebar.fileTreeTopInsetForTesting
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
                    + "\(band)pt file-tab row")

        // The traffic-light band is closed off by the same 1pt line the activity
        // bar draws, sitting exactly on the boundary with the file tree.
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

        // The Git panel's own line above the commit box names the author the
        // next commit will carry, alongside the project and branch.
        let panel = GitPanelViewController()
        _ = panel.view
        panel.setDirectory(root)
        let labelDeadline = Date().addingTimeInterval(5)
        while !panel.statusLabelForTesting.contains("trunk") && Date() < labelDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let label = panel.statusLabelForTesting
        // A repo with no remote also appends "(no upstream)" after the author.
        try expect(label.hasPrefix("\(root.lastPathComponent) / trunk / Puzzle Test"),
                   "the commit header read \(label)")
    }

    private static func testDiffGutterUsesFileLineNumbers() throws {
        let diff = """
        diff --git a/a.swift b/a.swift
        index 1111111..2222222 100644
        --- a/a.swift
        +++ b/a.swift
        @@ -10,4 +10,5 @@ func f() {
         context ten
        -removed eleven
        +added eleven
        +added twelve
         context twelve
        @@ -40,2 +41,2 @@
        -gone forty
        +back forty
         context forty-one
        \\ No newline at end of file
        """
        let numbers = DiffHighlighter.lineNumbers(in: diff)
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false)
        try expect(numbers.count == lines.count,
                   "diff gutter numbering lost lines: \(numbers.count) vs \(lines.count)")
        // Headers carry no file line at all.
        try expect(numbers[0...4].allSatisfy { $0 == nil },
                   "diff headers were numbered instead of left blank")
        // Body of the first hunk: context/added follow the new file, the removed
        // line keeps the number it had in the old one.
        try expect(Array(numbers[5...9]) == [10, 11, 11, 12, 13],
                   "first hunk numbered \(numbers[5...9]) instead of the file's own lines")
        // A second hunk restarts from its own header, not from where the first left off.
        try expect(numbers[10] == nil && Array(numbers[11...13]) == [40, 41, 42],
                   "second hunk numbered \(numbers[11...13]) instead of restarting at its header")
        try expect(numbers[14] == nil,
                   "the no-newline marker was given a file line number")

        // An ordinary file keeps plain 1..n numbering — no diff map at all.
        try expect(DiffHighlighter.lineNumbers(in: "let a = 1\nlet b = 2\n") == [nil, nil, nil],
                   "non-diff text produced file line numbers")
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

import AppKit
import UniformTypeIdentifiers
import AVFoundation
import PDFKit
import Compression
import Foundation

@main
enum RegressionTests {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func main() throws {
        _ = NSApplication.shared
        try testProcessDrain()
        try testReviewFixes()
        try testQuickOpenAndGoToLine()
        try testFindAndReplace()
        try testFindSelectionNavigationAndTabIsolation()
        try testPanelAffordances()
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
        try testMediaFilesPlayInsteadOfLoading()
        try testPDFPreview()
        try testIncrementalParsing()
        try testImageDownsampling()
        try testEPUBReading()
        try testMarkdownLiveEditing()
        try testFindMatchesAreComplete()
        try testBracketMatchingAndDeleteLine()
        try testCodeBlockAnalysisAndFolding()
        try testLineIndexTracksEdits()
        try testMinifiedFilesOpenBounded()
        try testMinifiedJSONOpensFormatted()
        try testFileTreeSurvivesReentrantReload()
        try testFileTreeContextEditing()
        try testFileHistoryTable()
        try testDiffGutterUsesFileLineNumbers()
        try testProjectTitleStrip()
        try testBranchMenu()
        try testMaterialFileIcons()
        try testClosingATabWritesIt()
        try testTabKeyboardNavigation()
        try testBundleDeclaresDocumentTypes()
        try testSettingsGearLivesTopRight()
        try testActivityBarUsesTextLabels()
        try testScrollersFollowTheTheme()
        try testAyuDarkTheme()
        try testDiffHeaderStepsThroughChanges()
        try testGitLineChangeMarks()
        try testThemeIsReadyBeforeAnyView()
        try testGutterMarksUncommittedChanges()
        try testChangesRowsSurviveRefreshes()
        try testGitPanelCounters()
        try testSelectedControlsAgree()
        try testHistoryLogDetails()
        try testCommitIdentityFollowsGitConfig()
        try testSearchFieldClearAndAlignment()
        try testCommitNeedsChangesAndAMessage()
        try testOneLinePanelRows()
        try testStatusMatchesPorcelainV1()
        try testAutosaveOnFocusChange()
        try testLineEditingShortcuts()
        try testGitMarksFollowUnsavedEdits()
        try testGutterWidthFollowsLineCount()
        try testSideBySideDiff()
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

        // A newer file on disk no longer overrules unsaved edits: the buffer is
        // the only copy of what the user typed, so the write is recorded as a
        // conflict and resolved at save time instead of silently applied.
        try Data("external newest\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: base.addingTimeInterval(30)], ofItemAtPath: url.path)
        let applied = store.reloadExternalChanges(
            at: [url], observedAt: base.addingTimeInterval(31))
        try expect(applied.isEmpty && document.text == "local newest\n"
                    && document.isModified && document.hasDiskConflict,
                   "a newer external write discarded unsaved edits")

        // Once the buffer has no unsaved edits, the newer file does win.
        document.discardEditsAndReloadFromDisk()
        try expect(document.text == "external newest\n" && !document.isModified
                    && document.lastLocalEditAt == nil && !document.hasDiskConflict,
                   "taking the disk version did not replace the buffer")
        try Data("external newer still\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: base.addingTimeInterval(40)], ofItemAtPath: url.path)
        let clean = store.reloadExternalChanges(
            at: [url], observedAt: base.addingTimeInterval(41))
        try expect(clean == [url] && document.text == "external newer still\n",
                   "an unmodified buffer did not follow the file on disk")
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
    /// The six defects found in the whole-project review.
    private static func testQuickOpenAndGoToLine() throws {
        // Fuzzy ranking: initials find a long name, the file name beats the
        // directory, and a shorter path wins a tie.
        let paths = [
            "Sources/EditorPaneViewController.swift",
            "Sources/Theme.swift",
            "Tests/RegressionTests.swift",
            "vendor/tree-sitter/lib/src/parser.c",
            "Sources/deep/nested/Theme.swift",
        ]
        try expect(QuickOpen.matches(paths, query: "epvc").first
                    == "Sources/EditorPaneViewController.swift",
                   "initials did not find the long name: "
                    + "\(QuickOpen.matches(paths, query: "epvc"))")
        try expect(QuickOpen.matches(paths, query: "theme").first == "Sources/Theme.swift",
                   "the shorter path did not win: \(QuickOpen.matches(paths, query: "theme"))")
        try expect(QuickOpen.matches(paths, query: "parser.c") == ["vendor/tree-sitter/lib/src/parser.c"],
                   "an exact file name did not match alone")
        try expect(QuickOpen.matches(paths, query: "zzz").isEmpty,
                   "a query matching nothing still returned rows")
        try expect(QuickOpen.matches(paths, query: "").count == paths.count,
                   "an empty query did not list the project")
        try expect(QuickOpen.score("Sources/Theme.swift", query: "emeht") == nil,
                   "characters out of order matched")

        // The index skips the directories nobody wants in ⌘P.
        let directory = try temporaryDirectory("quick-open")
        defer { try? FileManager.default.removeItem(at: directory) }
        let nested = directory.appendingPathComponent("Sources")
        let ignored = directory.appendingPathComponent("node_modules/pkg")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ignored, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: nested.appendingPathComponent("App.swift"))
        try Data("x".utf8).write(to: ignored.appendingPathComponent("index.js"))
        let index = QuickOpen.index(in: directory)
        try expect(index == ["Sources/App.swift"],
                   "the index picked up ignored directories: \(index)")

        // Go to Line parsing.
        try expect(QuickOpen.lineTarget("42")?.line == 42
                    && QuickOpen.lineTarget("42")?.column == nil,
                   "a bare line number did not parse")
        try expect(QuickOpen.lineTarget(" 12:8 ")?.line == 12
                    && QuickOpen.lineTarget("12:8")?.column == 8,
                   "line:column did not parse")
        try expect(QuickOpen.lineTarget("0") == nil && QuickOpen.lineTarget("abc") == nil
                    && QuickOpen.lineTarget("") == nil,
                   "a non-line query was accepted")

        // The jump respects the column and clamps past the end of the line.
        let file = directory.appendingPathComponent("lines.swift")
        try Data("first line\nsecond line\n".utf8).write(to: file)
        let pane = EditorPaneViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = pane
        defer { window.close() }
        pane.open(url: file)
        pane.jumpToLine(2, column: 8)
        try expect(pane.caretLocationForTesting == "first line\n".count + 7,
                   "line:column landed at \(pane.caretLocationForTesting)")
        pane.jumpToLine(2, column: 999)
        try expect(pane.caretLocationForTesting == "first line\nsecond line".count,
                   "a column past the line did not clamp to its end")

        // A pathological query (one letter in a large file) counts every match
        // but stops retaining ranges, so the find bar's memory is bounded.
        let crowded = PuzzleTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        crowded.textStorage?.setAttributedString(NSAttributedString(
            string: String(repeating: "a\n", count: FindBarView.maxRetainedMatches + 500),
            attributes: Theme.textAttributes(color: Theme.foreground)))
        let crowdedBar = FindBarView(frame: .zero)
        crowdedBar.attach(to: crowded)
        crowdedBar.setQuery("a")
        try expect(crowdedBar.retainedMatchCountForTesting == FindBarView.maxRetainedMatches,
                   "the find bar retained \(crowdedBar.retainedMatchCountForTesting) ranges")
        try expect(crowdedBar.totalMatchCountForTesting == FindBarView.maxRetainedMatches + 500,
                   "the count stopped counting at the cap instead of reporting the truth")
        crowdedBar.clearHighlights()
        try expect(crowdedBar.retainedMatchCountForTesting == 0
                    && crowdedBar.totalMatchCountForTesting == 0,
                   "clearing left the match bookkeeping behind")

        // The panel keeps the keyboard contract: arrows move, Return accepts.
        let panel = PalettePanel()
        panel.setItems([
            PalettePanel.Item(title: "a.swift", detail: "Sources", value: file),
            PalettePanel.Item(title: "b.swift", detail: "Sources", value: file),
        ])
        try expect(panel.selectedIndexForTesting == 0, "the first row was not preselected")
        panel.moveSelectionForTesting(by: 1)
        try expect(panel.selectedIndexForTesting == 1, "down did not move the selection")
        panel.moveSelectionForTesting(by: 5)
        try expect(panel.selectedIndexForTesting == 1, "the selection ran past the last row")
        var accepted: URL?
        panel.onAccept = { accepted = $0?.value }
        panel.acceptForTesting()
        try expect(accepted == file, "Return did not hand back the highlighted row")
    }

    private static func testFindAndReplace() throws {
        let directory = try temporaryDirectory("find-replace")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sample.swift")
        try Data("let a = 1\nlet b = 2\nlet c = 3\n".utf8).write(to: file)

        let pane = EditorPaneViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = pane
        defer { window.close() }
        pane.open(url: file)

        // The replace row is out of the way until asked for, and the bar grows
        // by exactly one row when it appears.
        pane.showFindBar(seed: "let")
        let bar = pane.findBarForTesting
        try expect(!bar.isReplaceVisibleForTesting, "the replace row was showing unasked")
        let findOnly = bar.preferredHeight
        pane.showFindBar(seed: "let", replacing: true)
        try expect(bar.isReplaceVisibleForTesting, "⌥⌘F did not reveal the replace row")
        try expect(bar.preferredHeight > findOnly,
                   "the bar did not make room for the replace row")

        // Replace one: the first match changes, the rest do not.
        bar.setReplacementForTesting("var")
        bar.replaceCurrentForTesting()
        try expect(pane.textForTesting == "var a = 1\nlet b = 2\nlet c = 3\n",
                   "replace-one changed the wrong text: \(pane.textForTesting.debugDescription)")
        try expect(pane.isModifiedForTesting, "a replacement did not dirty the document")

        // Replace all: every remaining match, in one undo step. The run loop
        // turn is what a real click provides — NSTextView groups undo per pass,
        // so without it both replacements would land in the same group.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        bar.replaceAllForTesting()
        try expect(pane.textForTesting == "var a = 1\nvar b = 2\nvar c = 3\n",
                   "replace-all missed matches: \(pane.textForTesting.debugDescription)")
        pane.undoForTesting()
        try expect(pane.textForTesting == "var a = 1\nlet b = 2\nlet c = 3\n",
                   "replace-all did not undo as one step: "
                    + "\(pane.textForTesting.debugDescription)")

        // A regex replacement can reuse what it captured.
        pane.showFindBar(seed: "", replacing: true)
        var regexOptions = SearchOptions()
        regexOptions.regex = true
        bar.setOptionsForTesting(regexOptions)
        bar.setQuery("var (\\w+) = (\\d+)")
        bar.setReplacementForTesting("let $1: Int = $2")
        bar.replaceAllForTesting()
        try expect(pane.textForTesting.contains("let a: Int = 1"),
                   "a capture group was not expanded: \(pane.textForTesting.debugDescription)")
    }

    private static func testFindSelectionNavigationAndTabIsolation() throws {
        let directory = try temporaryDirectory("find-tabs")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.swift")
        let second = directory.appendingPathComponent("second.swift")
        let source = "let café = 1\nlet café = 2\nlet café = 3\n"
        try Data(source.utf8).write(to: first)
        try Data("x\ny\n".utf8).write(to: second)
        let pane = EditorPaneViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = pane
        defer { pane.prepareForClose(); window.close() }
        pane.open(url: first)
        try expect(pane.focusEditorForTesting(), "could not focus editor for selection test")
        guard let editor = window.firstResponder as? PuzzleTextView else {
            throw Failure(description: "editor was not the first responder")
        }
        // This is the word selection delivered by a double click, in UTF-16 coordinates.
        let word = (source as NSString).range(of: "café")
        editor.setSelectedRange(word)
        pane.showFindBar()
        let bar = pane.findBarForTesting
        let input = bar.queryInputForTesting
        try expect(input.stringValue == "café" && editor.searchMatches.count == 3,
                   "Cmd-F lost the selected word before searching")
        guard let firstBand = editor.currentLineBandRect() else {
            throw Failure(description: "selected search result has no current-line band")
        }
        let commandField = NSTextField()
        let commandEditor = NSTextView()
        try expect(input.control(commandField, textView: commandEditor,
                                 doCommandBy: #selector(NSResponder.insertNewline(_:))),
                   "Enter did not navigate search results")
        try expect(editor.currentMatchIndex == 1
                    && (editor.currentLineBandRect()?.minY ?? 0) > firstBand.minY,
                   "Enter did not move the current-line highlight to the next match")
        _ = input.control(commandField, textView: commandEditor,
                          doCommandBy: #selector(NSResponder.moveUp(_:)))
        try expect(editor.currentMatchIndex == 0 && editor.currentLineBandRect() == firstBand,
                   "Up did not restore the previous result's line highlight")
        _ = input.control(commandField, textView: commandEditor,
                          doCommandBy: #selector(NSResponder.moveDown(_:)))
        let savedRange = bar.state.currentRange
        bar.setOptionsForTesting(SearchOptions(caseSensitive: true, wholeWord: true, regex: false))
        _ = input.control(commandField, textView: commandEditor,
                          doCommandBy: #selector(NSResponder.moveDown(_:)))
        bar.setReplaceVisible(true)
        bar.setReplacementForTesting("name")

        // Same open + jump sequence as a result clicked in the global search panel.
        pane.open(url: second)
        pane.jumpToLine(2)
        try expect(bar.isHidden && editor.searchMatches.isEmpty
                    && editor.searchResultLineLocation == nil,
                   "global search jump carried stale underlines into another document")
        pane.showFindBar(seed: "y")
        try expect(editor.searchMatches == [NSRange(location: 2, length: 1)],
                   "the second tab did not search its own contents")
        pane.activate(index: 0)
        try expect(!bar.isHidden && bar.state.query == "café"
                    && bar.state.replacement == "name" && bar.state.isReplacing
                    && bar.state.options.caseSensitive && bar.state.options.wholeWord
                    && bar.state.currentRange == savedRange,
                   "returning to a tab lost its independent find state")
        try expect(editor.searchMatches.allSatisfy {
            (source as NSString).substring(with: $0) == "café"
        }, "restored underlines do not address actual matches")
        pane.hideFindBar()
        pane.activate(index: 1)
        try expect(!bar.isHidden && bar.state.query == "y" && !bar.state.isReplacing,
                   "closing find in one tab affected the other tab")
        pane.activate(index: 0)
        try expect(bar.isHidden && editor.searchMatches.isEmpty,
                   "a closed find bar reopened when switching tabs")
        editor.setSelectedRange(word)
        pane.showFindBar(seed: "let")
        try expect(input.stringValue == "let", "selection overwrote an explicit search seed")
        pane.close(index: 0)
        pane.open(url: first)
        try expect(bar.isHidden && editor.searchMatches.isEmpty,
                   "closing a tab retained its find state when reopened")
    }

    private static func testPanelAffordances() throws {
        // Search: the empty result area says what the panel does, and what the
        // three toggles above it mean, instead of showing a blank well.
        let search = SearchViewController()
        _ = search.view
        let idle = search.placeholderTextForTesting
        try expect(idle.contains("Search every file"),
                   "the search panel has no empty state: \(idle.debugDescription)")
        try expect(idle.contains("match case") && idle.contains("whole word")
                    && idle.contains("regular expression"),
                   "the empty state does not explain Aa / wd / .*")

        // Search rows measure like the file tree's, not their own font.
        let savedTreeHeight = Settings.shared.treeLineHeight
        defer { Settings.shared.treeLineHeight = savedTreeHeight; Theme.invalidateCaches() }
        Settings.shared.treeLineHeight = 31
        Theme.invalidateCaches()
        let outline = NSOutlineView()
        let fileRow = search.outlineView(outline, heightOfRowByItem: NSObject())
        try expect(fileRow == Theme.treeRowHeight() && fileRow == 31,
                   "a search row is \(fileRow)pt against the tree's \(Theme.treeRowHeight())pt")

        // The panel marks the match by drawing, not by an attribute on the
        // text: a background attribute would re-ink the preview.
        let cell = SearchHitCellProbe()
        try expect(cell.fillsRowHeightForTesting,
                   "the highlight is a glyph-height attribute again")

        func luma(_ color: NSColor) -> CGFloat {
            guard let c = color.usingColorSpace(.sRGB) else { return 0 }
            return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        }
        // Matches are underlined, so the only requirement on the colours is
        // that they read against the surfaces they are drawn on. Nothing is
        // painted over the text, and nothing sits behind it.
        try expect(abs(luma(Theme.matchUnderline) - luma(Theme.editorBackground)) > 0.1,
                   "the match underline does not separate from the editor")
        try expect(abs(luma(Theme.matchUnderline) - luma(Theme.panelBackground)) > 0.1,
                   "the match underline does not separate from the panel")
        guard let rule = Theme.matchUnderline.usingColorSpace(.sRGB),
              let currentRule = Theme.currentMatchUnderline.usingColorSpace(.sRGB) else {
            throw Failure(description: "match colours are not sRGB")
        }
        try expect(rule.redComponent > 0.6
                    && rule.redComponent > rule.greenComponent + 0.2
                    && rule.redComponent > rule.blueComponent + 0.2,
                   "the match underline is not red")
        try expect(currentRule.redComponent > 0.6 && currentRule.greenComponent > 0.5
                    && currentRule.blueComponent < currentRule.greenComponent - 0.2,
                   "the current-match underline is not yellow")

        let textView = PuzzleTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        // Real documents carry the theme's paragraph style, which is what makes
        // a line fragment the configured row height.
        textView.textStorage?.setAttributedString(NSAttributedString(
            string: "let value = 1\nlet other = 2\n",
            attributes: Theme.textAttributes(color: Theme.foreground)))
        let bar = FindBarView(frame: .zero)
        bar.attach(to: textView)
        bar.setQuery("let")
        // The bar starts on the match nearest the caret; clear that first, so
        // what is measured here is a plain match.
        textView.currentMatchIndex = nil
        let rects = textView.matchHighlightRectsForTesting()
        try expect(rects.count == 2, "the editor underlined \(rects.count) of 2 matches")
        try expect(rects.allSatisfy { $0.height == Theme.matchUnderlineWidth && $0.width > 0 },
                   "a match rule is \(rects.map(\.height))pt tall, not "
                     + "\(Theme.matchUnderlineWidth)pt")
        // The current match is the same rule in the accent colour: stepping
        // through matches must not move anything.
        textView.currentMatchIndex = 0
        let stepped = textView.matchHighlightRectsForTesting()
        try expect(stepped == rects,
                   "the current match is drawn at a different size or place")
        // Under the text and inside the row: a rule hanging below the fragment
        // would read as belonging to the line beneath it. Measured against the
        // fragment TextKit actually produced, since the row height is a setting.
        guard let manager = textView.layoutManager else {
            throw Failure(description: "the text view has no layout manager")
        }
        let fragment = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let rowTop = textView.textContainerInset.height + fragment.minY
        try expect(rects[0].minY > rowTop + fragment.height / 2,
                   "the rule is not under the text")
        try expect(rects[0].maxY <= rowTop + fragment.height + 0.01,
                   "the rule spilled into the line below")



        // A match can sit inside a selection — the caret is left on the one the
        // user stopped at — so both rules have to read on that surface too.
        func luminance(_ color: NSColor) -> CGFloat {
            guard let c = color.usingColorSpace(.sRGB) else { return 0 }
            return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        }
        try expect(abs(luminance(Theme.matchUnderline) - luminance(Theme.selection)) > 0.08,
                   "the match underline disappears inside a selection")
        try expect(abs(luminance(Theme.currentMatchUnderline) - luminance(Theme.selection)) > 0.08,
                   "the current-match underline disappears inside a selection")

        // The commit box explains itself and takes ⌘↩.
        let commit = CommitMessageTextView()
        commit.placeholder = "Commit message  (⌘↩ to commit)"
        var committed = 0
        commit.onCommitShortcut = { committed += 1 }
        guard let enter = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else {
            throw Failure(description: "could not synthesise ⌘↩")
        }
        commit.keyDown(with: enter)
        try expect(committed == 1, "⌘↩ did not commit")
        guard let plain = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else {
            throw Failure(description: "could not synthesise ↩")
        }
        commit.keyDown(with: plain)
        try expect(committed == 1, "a plain Return committed instead of inserting a newline")
    }

    private static func testReviewFixes() throws {
        // 1. Settings: a `//` inside a value must not swallow the real comment,
        //    which made the whole file unparseable and reverted every setting.
        let jsonc = """
        {
          // leading comment
          "ui_font_family": "Iosevka // Term",   // my font
          "tab_size": 4,
          "buffer_font_size": 13 // trailing
        }
        """
        let stripped = Settings.strippingComments(jsonc)
        guard let data = stripped.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(description: "settings with a // inside a string did not parse: "
                            + stripped.debugDescription)
        }
        try expect(parsed["ui_font_family"] as? String == "Iosevka // Term",
                   "the value lost its slashes: \(String(describing: parsed["ui_font_family"]))")
        try expect((parsed["tab_size"] as? NSNumber)?.intValue == 4, "a later key was dropped")
        try expect((parsed["buffer_font_size"] as? NSNumber)?.intValue == 13,
                   "a trailing comment was not stripped")
        // An escaped quote must not end the string early.
        let escaped = Settings.strippingComments("{\"a\": \"q\\\" // x\"} // gone")
        try expect(escaped.contains("q\\\" // x") && !escaped.contains("gone"),
                   "escape handling is wrong: \(escaped.debugDescription)")

        // 2. A case-only rename is the same file, not a name clash.
        let directory = try temporaryDirectory("review-fixes")
        defer { try? FileManager.default.removeItem(at: directory) }
        let lower = directory.appendingPathComponent("readme.md")
        try Data("hello\n".utf8).write(to: lower)
        let upper = directory.appendingPathComponent("README.md")
        let tree = FileTreeViewController()
        _ = tree.view          // setRoot drives the outline view
        tree.setRoot(directory)
        try expect(tree.renameForTesting(lower, to: "README.md"),
                   "a case-only rename was refused")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { !$0.hasPrefix(".") }
        try expect(names == ["README.md"],
                   "the case-only rename left \(names) behind")
        let renamedText = String(decoding: try Data(contentsOf: upper), as: UTF8.self)
        try expect(renamedText == "hello\n",
                   "the renamed file lost its contents: \(renamedText.debugDescription)")

        // 3. An external write never replaces unsaved edits.
        let edited = directory.appendingPathComponent("edited.txt")
        try Data("on disk\n".utf8).write(to: edited)
        let store = DocumentStore()
        let doc = store.document(for: edited)
        doc.storage.replaceCharacters(in: NSRange(location: 0, length: doc.storage.length),
                                      with: "my unsaved work\n")
        doc.markLocalEdit()
        try expect(doc.isModified, "the test edit did not mark the buffer modified")
        // Someone else writes a newer version.
        RunLoop.main.run(until: Date().addingTimeInterval(1.1))
        try Data("theirs\n".utf8).write(to: edited)
        _ = store.reloadExternalChanges(at: [edited])
        try expect(doc.text == "my unsaved work\n",
                   "an external write discarded unsaved edits: \(doc.text.debugDescription)")
        try expect(doc.hasDiskConflict, "the conflict was not recorded for the save prompt")
        // Taking the disk version is explicit, and then it does replace.
        doc.discardEditsAndReloadFromDisk()
        try expect(doc.text == "theirs\n" && !doc.hasDiskConflict,
                   "an explicit reload did not take the file on disk")

        // 4. Folds survive an edit above them.
        let manager = FoldingLayoutManager()
        let storage = NSTextStorage(string: "func a() {\n  body\n}\nfunc b() {\n  body\n}\n")
        storage.addLayoutManager(manager)
        let blocks = CodeBlockAnalyzer.analyze(storage.string, language: "swift")
        guard let second = blocks.sorted(by: { $0.openerLocation < $1.openerLocation }).last else {
            throw Failure(description: "the fixture produced no foldable blocks")
        }
        manager.updateBlocks(blocks, resetFolds: true)
        manager.toggle(second)
        try expect(manager.foldedBlockIdentities.contains(second.identity),
                   "the block did not fold")
        let inserted = "// a new line\n"
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: inserted)
        let shifted = CodeBlockAnalyzer.analyze(storage.string, language: "swift")
        manager.updateBlocks(shifted, resetFolds: false)
        try expect(manager.foldedBlockIdentities
                    == [second.identity + (inserted as NSString).length],
                   "typing above a folded block lost the fold: "
                    + "\(manager.foldedBlockIdentities)")
        storage.removeLayoutManager(manager)

        // 5. Network git calls are bounded; local ones are not.
        try expect(GitService.networkTimeout > 0,
                   "network git operations have no ceiling")
        let slow = GitService.runProcess(
            executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
            in: directory, timeout: 1)
        try expect(slow.code != 0,
                   "a process past its timeout reported success")
        try expect(String(decoding: slow.stderr, as: UTF8.self).contains("gave up"),
                   "the timeout did not say what happened")

        // 6. Repointing the icon resources resets the LRU bookkeeping with it.
        FileIcons.useResources(at: directory)
        try expect(FileIcons.cachedImageCountForTesting == 0,
                   "the icon cache survived a resource switch")
        try expect(FileIcons.lastUsedCountForTesting == 0,
                   "the LRU table kept stale keys, which would absorb evictions")
        FileIcons.useResources(at: nil)
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

        // Last, because the panel stages in the background as soon as it is
        // given a directory, and two git processes cannot hold the index at
        // once — driving Git from here afterwards would race it.
        let panel = GitPanelViewController()
        _ = panel.view
        panel.setDirectory(project)
        // Each changed file offers a way to the source, not only to its diff.
        // The row is just the file now; its actions live in the context menu.
        let cell = GitChangeCellProbe()
        cell.frame = NSRect(x: 0, y: 0, width: 260, height: Theme.treeRowHeight())
        cell.configureProbe(path: "Sources/App.swift")
        cell.layoutSubtreeIfNeeded()
        try expect(cell.nameForTesting == "App.swift",
                   "the row does not show the file name: \(cell.nameForTesting)")

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
        _ = store.reloadExternalChanges(at: [directory])
        try expect(!document.hasDiskConflict && document.isModified,
                   "a directory notification misclassified a local edit as a disk conflict")
        pane.save()
        let manuallySaved = try String(contentsOf: url, encoding: .utf8)
        try expect(manuallySaved == "visible outside Puzzle\n" && !document.isModified,
                   "manual editor save did not persist the buffer")

        // Explicit Save is authoritative for both observed conflicts and writes
        // that arrive before the file monitor has delivered its notification.
        for observed in [true, false] {
            document.storage.setAttributedString(NSAttributedString(string: "my current content\n"))
            document.markLocalEdit()
            try "external content\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)],
                                                 ofItemAtPath: url.path)
            if observed {
                _ = store.reloadExternalChanges(at: [url])
                try expect(document.hasDiskConflict, "external write was not detected")
            } else {
                try expect(document.diskChangedSinceLastSync, "unobserved disk write was not detected")
            }
            pane.autosaveIfNeeded()
            let backgroundSaved = try String(contentsOf: url, encoding: .utf8)
            try expect(backgroundSaved == "external content\n",
                       "background autosave overwrote a conflicting disk version")
            pane.save()
            let explicitlySaved = try String(contentsOf: url, encoding: .utf8)
            try expect(explicitlySaved == "my current content\n",
                       "Cmd+S did not write the current buffer over the disk version")
            try expect(!document.isModified && !document.hasDiskConflict,
                       "manual save left dirty/conflict state behind")
        }
        // A delayed event after saving must not turn the next edit into a conflict.
        document.storage.setAttributedString(NSAttributedString(string: "visible outside Puzzle\n"))
        document.markLocalEdit()
        _ = store.reloadExternalChanges(at: [directory])
        try expect(!document.hasDiskConflict, "delayed save notification created a conflict")
        pane.save()

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
        let imagePreview = ImagePreviewView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        imagePreview.show(image: NSImage(size: NSSize(width: 100, height: 50)),
                          caption: "first")
        imagePreview.show(image: NSImage(size: NSSize(width: 50, height: 100)),
                          caption: "second")
        imagePreview.layoutSubtreeIfNeeded()
        try expect(imagePreview.imageFrameForTesting.size == NSSize(width: 50, height: 100),
                   "image preview lost natural size or aspect ratio when changing images")
        imagePreview.clear()
        try expect(!imagePreview.hasImageForTesting
                   && imagePreview.imageFrameForTesting == .zero,
                   "clearing an image preview retained its bitmap or constraints")

    }

    private static func testMediaFilesPlayInsteadOfLoading() throws {
        let directory = try temporaryDirectory("media")
        defer { try? FileManager.default.removeItem(at: directory) }

        // Deliberately past the limit that governs every other document. A
        // media file is never read into a buffer, so the size gate must not
        // apply to it at all; a sparse file costs nothing to create on APFS.
        let videoURL = directory.appendingPathComponent("clip.mp4")
        FileManager.default.createFile(atPath: videoURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: videoURL)
        try handle.truncate(atOffset: UInt64(Document.maxImageFileBytes) + 1)
        try handle.close()

        let video = Document(url: videoURL)
        try expect(video.isMedia && video.isVideoMedia,
                   "a video did not open on the media path")
        try expect(!video.isUnsupported,
                   "a video was rejected by the in-memory size limit")
        try expect(video.isReadOnly && video.isPreviewOnly,
                   "a media document is not read-only")
        try expect(video.storage.length < 200,
                   "a media document read the file instead of describing it")
        do {
            try video.save()
            throw Failure(description: "saving a media document unexpectedly succeeded")
        } catch let error as Failure {
            throw error
        } catch {}

        let audioURL = directory.appendingPathComponent("tone.mp3")
        try Data([0xFF, 0xFB, 0x90, 0x00]).write(to: audioURL)
        let audio = Document(url: audioURL)
        try expect(audio.isMedia && !audio.isVideoMedia,
                   "an audio file did not open as audio")

        // Containers AVFoundation cannot decode stay on the honest
        // "unsupported binary" path instead of opening a player that fails.
        let mkvURL = directory.appendingPathComponent("clip.mkv")
        try Data([0x1A, 0x45, 0xDF, 0xA3, 0x00]).write(to: mkvURL)
        try expect(!Document(url: mkvURL).isMedia,
                   "an undecodable container was handed to the player")

        // .ts is TypeScript here, whatever the bundle's public.movie claim
        // leads Launch Services to believe.
        let typescriptURL = directory.appendingPathComponent("module.ts")
        try Data("export const value = 1\n".utf8).write(to: typescriptURL)
        let typescript = Document(url: typescriptURL)
        try expect(!typescript.isMedia && !typescript.isReadOnly,
                   "a TypeScript file was captured by the media path")

        let missingURL = directory.appendingPathComponent("gone.mp4")
        try expect(!Document(url: missingURL).isMedia,
                   "a missing file opened a player instead of reporting itself")

        let preview = MediaPreviewView(frame: NSRect(x: 0, y: 0, width: 720, height: 500))
        preview.show(url: audioURL, caption: audio.text, isVideo: false)
        try expect(preview.hasPlayerForTesting && preview.showsAudioLayoutForTesting,
                   "the media preview built no player, or used the video layout")
        try expect(!preview.usesSystemPlayerViewForTesting,
                   "audio uses the video player backdrop")
        preview.layoutSubtreeIfNeeded()
        let transportFrame = preview.transportFrameForTesting
        try expect(transportFrame.minY < 100 && transportFrame.width <= 420,
                   "the audio controls are not compact and near the bottom")
        if let bitmap = preview.bitmapImageRepForCachingDisplay(in: preview.bounds) {
            preview.cacheDisplay(in: preview.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: "/tmp/puzzle-audio-preview.png"))
            let scale = CGFloat(bitmap.pixelsWide) / preview.bounds.width
            let x = Int((transportFrame.minX + 1) * scale)
            let y = Int((preview.bounds.height - transportFrame.maxY + 1) * scale)
            try expect(sameColor(bitmap.colorAt(x: x, y: y), bitmap.colorAt(x: 10, y: 10)),
                       "the audio controller paints a rectangular background patch")
        }
        preview.show(url: videoURL, caption: video.text, isVideo: true)
        try expect(!preview.showsAudioLayoutForTesting,
                   "switching to a video kept the audio layout")
        // Switching tabs and back must not restart a file that is playing.
        let player = preview.hasPlayerForTesting
        preview.show(url: videoURL, caption: video.text, isVideo: true)
        try expect(player && preview.loadedURL == videoURL,
                   "re-activating the same tab rebuilt the player")
        preview.show(url: audioURL, caption: audio.text, isVideo: false)
        try expect(!preview.usesSystemPlayerViewForTesting,
                   "video view survived the switch back to audio")
        preview.clear()
        try expect(!preview.usesSystemPlayerViewForTesting, "cleared preview retained video view")
        try expect(!preview.hasPlayerForTesting && preview.loadedURL == nil,
                   "clearing a media preview left the player decoding")

        try expect(MediaPreviewView.formattedDuration(CMTime(seconds: 222, preferredTimescale: 1))
                    == "3:42",
                   "a duration under an hour formatted wrongly")
        try expect(MediaPreviewView.formattedDuration(CMTime(seconds: 3725, preferredTimescale: 1))
                    == "1:02:05",
                   "a duration over an hour formatted wrongly")
        try expect(MediaPreviewView.formattedDuration(.indefinite) == nil,
                   "an indefinite duration was written into the caption")
    }

    private static func testPDFPreview() throws {
        let directory = try temporaryDirectory("pdf-preview")
        let previousPositions = UserDefaults.standard.object(forKey: "PuzzlePDFPages")
        defer {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults.standard.set(previousPositions, forKey: "PuzzlePDFPages")
        }
        let url = directory.appendingPathComponent("guide.PDF")
        let pdf = PDFDocument()
        for index in 0..<2 {
            let image = NSImage(size: NSSize(width: 420, height: 594), flipped: false) { rect in
                NSColor.white.setFill()
                rect.fill()
                ("PDF preview — Page \(index + 1)" as NSString).draw(
                    at: NSPoint(x: 32, y: 510), withAttributes: [
                        .font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.black,
                    ])
                ("Scroll, select and read your documents in Puzzle." as NSString).draw(
                    at: NSPoint(x: 32, y: 465), withAttributes: [
                        .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.darkGray,
                    ])
                return true
            }
            guard let page = PDFPage(image: image) else { throw Failure(description: "PDF fixture failed") }
            pdf.insert(page, at: index)
        }
        try expect(pdf.write(to: url), "could not write PDF fixture")
        let document = Document(url: url)
        try expect(document.isPDF && document.isReadOnly && document.isPreviewOnly
                    && !document.isUnsupported && document.storage.length < 200,
                   "PDF was loaded as text or remained editable")
        do {
            try document.save()
            throw Failure(description: "PDF caption could overwrite the document")
        } catch let error as Failure { throw error } catch {}

        let pane = EditorPaneViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = pane
        defer { pane.prepareForClose(); window.close() }
        pane.open(url: url)
        window.setContentSize(NSSize(width: 800, height: 600))
        pane.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        guard var preview = pane.pdfPreviewForTesting else {
            throw Failure(description: "opening a PDF did not create the reader")
        }
        try expect(!preview.isHidden && preview.pageCountForTesting == 2
                    && preview.pageLabelForTesting == "1 / 2",
                   "PDF reader did not render the expected pages")
        try expect(preview.bounds.height > 300, "PDF preview collapsed to its header")
        try expect(preview.thumbnailSizeForTesting.width == 150
                    && preview.thumbnailSizeForTesting.height > 300,
                   "PDF thumbnail view has no space to render its pages")
        if let bitmap = pane.view.bitmapImageRepForCachingDisplay(in: pane.view.bounds) {
            pane.view.cacheDisplay(in: pane.view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: "/tmp/puzzle-pdf-preview.png"))
        }
        preview.goToNextPageForTesting()
        try expect(preview.pageIndexForTesting == 1 && preview.pageLabelForTesting == "2 / 2",
                   "PDF page navigation did not advance")
        preview.toggleThumbnailsForTesting()
        try expect(!preview.showsThumbnailsForTesting, "PDF thumbnail toggle did not hide the sidebar")
        let text = directory.appendingPathComponent("notes.txt")
        try Data("A text tab".utf8).write(to: text)
        pane.open(url: text)
        try expect(preview.isHidden && preview.pageCountForTesting == 0,
                   "leaving a PDF retained visible pages or rendering resources")
        pane.activate(index: 0)
        try expect(preview.superview == nil, "inactive PDF view remained attached")
        preview = pane.pdfPreviewForTesting!
        try expect(!preview.showsThumbnailsForTesting, "PDF sidebar preference was lost on rebuild")
        try expect(preview.pageIndexForTesting == 1, "PDF reading position was not restored")
        let invalid = directory.appendingPathComponent("invalid.pdf")
        try Data("not a PDF".utf8).write(to: invalid)
        pane.open(url: invalid)
        try expect(preview.noticeIsVisibleForTesting && preview.pageCountForTesting == 0,
                   "an invalid PDF left stale pages instead of an error notice")
        let locked = directory.appendingPathComponent("locked.pdf")
        try expect(pdf.write(to: locked, withOptions: [.ownerPasswordOption: "owner",
                                                      .userPasswordOption: "reader"]),
                   "could not write locked PDF fixture")
        pane.open(url: locked)
        try expect(preview.noticeIsVisibleForTesting && preview.pageCountForTesting == 0,
                   "a locked PDF opened an empty reader without explaining why")
        pane.activate(index: 0)
        try expect(!preview.noticeIsVisibleForTesting && preview.pageCountForTesting == 2,
                   "returning from a locked PDF did not restore readable pages")
    }

    private static func testIncrementalParsing() throws {
        let definition = LanguageDefinition(name: "json", language: tree_sitter_json()!,
            querySources: ["(string) @string (number) @number (true) @constant.builtin"],
            extensions: ["json"], display: "JSON")
        let incremental = SyntaxHighlighter(definition: definition)!
        let storage = NSTextStorage()
        let samples = ["{\"你好\": [1, 2], \"emoji\": \"😀\"}",
                       "{\"你妹\": [1, 23],\n \"emoji\": \"😁\"}",
                       "{\"你妹\": [1],\n \"emoji\": true}",
                       "{\"你妹\": [1],\n \"emoji\": true", "{}", "", "{\"值\": 9}"]
        for text in samples {
            storage.setAttributedString(NSAttributedString(string: text, attributes:
                Theme.textAttributes(color: Theme.foreground)))
            let range = NSRange(location: 0, length: storage.length)
            incremental.highlight(text: text, storage: storage, fullRange: range)
            let fresh = SyntaxHighlighter(definition: definition)!
            let expected = NSTextStorage(string: text, attributes: Theme.textAttributes(color: Theme.foreground))
            fresh.highlight(text: text, storage: expected, fullRange: range)
            try expect(incremental.treeDescriptionForTesting == fresh.treeDescriptionForTesting,
                       "incremental tree differs after Unicode/newline/deletion edits")
            try expect(storage.isEqual(to: expected), "incremental highlight differs from fresh parse")
        }
        try expect(incremental.incrementalParseCount >= 4, "edits never reused their tree")
        let count = incremental.fullParseCount + incremental.incrementalParseCount
        incremental.highlight(text: storage.string, storage: storage,
                              fullRange: NSRange(location: 0, length: storage.length))
        try expect(count == incremental.fullParseCount + incremental.incrementalParseCount,
                   "unchanged source was parsed again")
        let other = NSTextStorage(string: "[1]")
        incremental.highlight(text: other.string, storage: other,
                              fullRange: NSRange(location: 0, length: other.length))
        try expect(incremental.fullParseCount == 3, "a different buffer reused the old tree")
        incremental.discardParseTree()
        try expect(incremental.treeDescriptionForTesting == nil, "memory pressure retained a tree")
    }

    private static func testImageDownsampling() throws {
        let directory = try temporaryDirectory("image-downsampling")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("large.jpg")
        try autoreleasepool {
            let image = NSImage(size: NSSize(width: 4096, height: 2048), flipped: false) { rect in
                NSColor.systemOrange.setFill(); rect.fill(); return true
            }
            let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
            try bitmap.representation(using: .jpeg, properties: [:])!.write(to: url)
        }
        try testImageWindowResize(url: url)
        let document = Document(url: url)
        try expect(document.isImage && document.estimatedMemoryCost < 4096,
                   "image document retained decoded bitmap bytes")
        let preview = ImagePreviewView(frame: NSRect(x: 0, y: 0, width: 500, height: 350))
        preview.show(source: document.previewImage!, caption: document.text)
        preview.layoutSubtreeIfNeeded()
        let small = preview.decodedPixelsForTesting
        try expect(small > 0 && small < 2_000_000, "small viewport decoded an oversized bitmap")
        preview.setFrameSize(NSSize(width: 1400, height: 900))
        preview.needsLayout = true
        preview.layoutSubtreeIfNeeded()
        try expect(preview.decodedPixelsForTesting == small,
                   "resize decoded synchronously instead of scaling the existing frame")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        try expect(preview.decodedPixelsForTesting > small, "enlarging image did not increase detail")
        preview.setFrameSize(NSSize(width: 500, height: 350))
        preview.needsLayout = true
        preview.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        try expect(preview.decodedPixelsForTesting == small, "shrinking retained oversized bitmap")
        preview.clear()
        try expect(preview.decodedPixelsForTesting == 0, "clearing retained bitmap")

        let pane = EditorPaneViewController()
        _ = pane.view
        autoreleasepool { pane.open(url: url); pane.view.layoutSubtreeIfNeeded() }
        weak let oldPreview = pane.view.subviews.first { $0 is ImagePreviewView }
        let text = directory.appendingPathComponent("text.txt")
        try Data("text".utf8).write(to: text)
        autoreleasepool {
            pane.open(url: text)
            pane.view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        try expect(oldPreview == nil, "leaving image tab retained preview hierarchy")
        pane.prepareForClose()
    }

    private static func testImageWindowResize(url: URL) throws {
        let workspace = WorkspaceWindowController()
        let window = workspace.window!
        defer { workspace.editor.activePaneForTesting?.prepareForClose(); window.close() }
        let visible = window.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let initial = NSRect(x: visible.minX + 40, y: visible.minY + 40,
                             width: min(1000, visible.width - 80),
                             height: min(600, visible.height - 80))
        window.setFrame(initial, display: false)
        workspace.editor.open(url: url)
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        try expect(abs(window.frame.width - initial.width) < 1
                    && abs(window.frame.height - initial.height) < 1,
                   "opening an image changed the window frame: \(window.frame), expected \(initial)")
        let handles = window.contentView!.subviews.first { $0 is WindowResizeHandleView }!
        for edge: WindowResizeHandleView.Edges in [.left, .right, .top, .bottom] {
            window.setFrame(initial, display: false)
            window.contentView?.layoutSubtreeIfNeeded()
            let requested = WindowResizeHandleView.resizedFrame(initial, edges: edge,
                deltaX: edge == .left ? 80 : -80, deltaY: edge == .bottom ? 60 : -60,
                minimumSize: window.minSize)
            window.setFrame(requested, display: true)
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            try expect(abs(window.frame.width - requested.width) < 1
                        && abs(window.frame.height - requested.height) < 1
                        && abs(window.frame.minX - requested.minX) < 1
                        && abs(window.frame.minY - requested.minY) < 1,
                       "image layout overrode edge resize or moved the window: \(window.frame), expected \(requested)")
            let point = edge == .top ? NSPoint(x: handles.frame.midX, y: handles.frame.maxY - 2)
                : edge == .bottom ? NSPoint(x: handles.frame.midX, y: handles.frame.minY + 2)
                : edge == .left ? NSPoint(x: handles.frame.minX + 2, y: handles.frame.midY)
                : NSPoint(x: handles.frame.maxX - 2, y: handles.frame.midY)
            try expect(handles.hitTest(point) === handles, "image intercepted a window resize edge")
        }
    }

    // MARK: - EPUB

    /// Build a ZIP in memory so the reader's own inflate path is exercised
    /// rather than stubbed: entries marked `deflate` go through the system
    /// compressor, which is what a real book's chapters arrive as.
    private static func makeZip(_ files: [(path: String, bytes: Data, deflate: Bool)]) -> Data {
        var output = Data()
        var directory = Data()
        func append16(_ value: Int, to data: inout Data) {
            data.append(UInt8(value & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
        }
        func append32(_ value: Int, to data: inout Data) {
            for shift in [0, 8, 16, 24] { data.append(UInt8((value >> shift) & 0xFF)) }
        }
        for file in files {
            let name = Data(file.path.utf8)
            var payload = file.bytes
            var method = 0
            if file.deflate, !file.bytes.isEmpty {
                var destination = Data(count: max(64, file.bytes.count * 2))
                let written = destination.withUnsafeMutableBytes { out -> Int in
                    file.bytes.withUnsafeBytes { source -> Int in
                        compression_encode_buffer(
                            out.bindMemory(to: UInt8.self).baseAddress!, out.count,
                            source.bindMemory(to: UInt8.self).baseAddress!, file.bytes.count,
                            nil, COMPRESSION_ZLIB)
                    }
                }
                if written > 0 {
                    payload = destination.prefix(written)
                    method = 8
                }
            }
            let localOffset = output.count
            append32(0x0403_4b50, to: &output)
            append16(20, to: &output)               // version needed
            append16(0, to: &output)                // flags
            append16(method, to: &output)
            append16(0, to: &output)                // mod time
            append16(0, to: &output)                // mod date
            append32(0, to: &output)                // crc32, unchecked by the reader
            append32(payload.count, to: &output)
            append32(file.bytes.count, to: &output)
            append16(name.count, to: &output)
            append16(0, to: &output)                // extra length
            output.append(name)
            output.append(payload)

            append32(0x0201_4b50, to: &directory)
            append16(20, to: &directory)            // version made by
            append16(20, to: &directory)            // version needed
            append16(0, to: &directory)             // flags
            append16(method, to: &directory)
            append16(0, to: &directory)
            append16(0, to: &directory)
            append32(0, to: &directory)
            append32(payload.count, to: &directory)
            append32(file.bytes.count, to: &directory)
            append16(name.count, to: &directory)
            append16(0, to: &directory)             // extra
            append16(0, to: &directory)             // comment
            append16(0, to: &directory)             // disk
            append16(0, to: &directory)             // internal attributes
            append32(0, to: &directory)             // external attributes
            append32(localOffset, to: &directory)
            directory.append(name)
        }
        let directoryOffset = output.count
        output.append(directory)
        append32(0x0605_4b50, to: &output)
        append16(0, to: &output)                    // this disk
        append16(0, to: &output)                    // disk with the directory
        append16(files.count, to: &output)
        append16(files.count, to: &output)
        append32(directory.count, to: &output)
        append32(directoryOffset, to: &output)
        append16(0, to: &output)                    // comment length
        return output
    }

    private static func sampleBook() -> Data {
        let container = """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf"
            media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """
        let opf = """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>A Test Book</dc:title><dc:creator>A. Tester</dc:creator>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="c1" href="text/one.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="text/two.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
        </package>
        """
        let nav = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <body><nav epub:type="toc"><ol>
          <li><a href="text/one.xhtml">First Chapter</a>
            <ol><li><a href="text/one.xhtml#later">A Subsection</a></li></ol></li>
          <li><a href="text/two.xhtml">Second Chapter</a></li>
        </ol></nav></body></html>
        """
        let one = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>One</title>
        <style>p { color: red }</style><script>alert(1)</script></head>
        <body><h1>First Chapter</h1>
        <p>An <em>emphasised</em> word and a caf&eacute; with na&iuml;ve
           &ldquo;quotes&rdquo;.</p>
        <h2 id="later">A Subsection</h2>
        <blockquote><p>Quoted paragraph.</p></blockquote>
        <ol><li>First item</li><li>Second item</li></ol>
        </body></html>
        """
        let two = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><body>
        <h1>Second Chapter</h1><p>The end.</p></body></html>
        """
        return makeZip([
            ("mimetype", Data("application/epub+zip".utf8), false),
            ("META-INF/container.xml", Data(container.utf8), true),
            ("OEBPS/content.opf", Data(opf.utf8), true),
            ("OEBPS/nav.xhtml", Data(nav.utf8), true),
            ("OEBPS/text/one.xhtml", Data(one.utf8), true),
            ("OEBPS/text/two.xhtml", Data(two.utf8), true),
        ])
    }

    private static func testEPUBReading() throws {
        let directory = try temporaryDirectory("epub")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("book.epub")
        try sampleBook().write(to: url)

        // The archive: stored and deflated entries both come back whole.
        guard let archive = ZipArchive(url: url) else {
            throw Failure(description: "the EPUB was not recognised as a ZIP archive")
        }
        try expect(String(data: archive.data(for: "mimetype") ?? Data(), encoding: .utf8)
                    == "application/epub+zip",
                   "a stored ZIP entry did not read back")
        let chapter = archive.data(for: "OEBPS/text/one.xhtml")
        try expect(chapter != nil && chapter!.count > 200,
                   "a deflated ZIP entry did not inflate")
        try expect(archive.data(for: "OEBPS/missing.xhtml") == nil,
                   "a missing ZIP entry produced data")

        // Paths inside a package resolve against the package's own folder, and
        // `../` is what every book uses to reach its images.
        try expect(EPUBBook.resolve("../images/a.png", against: "OEBPS/text")
                    == "OEBPS/images/a.png",
                   "a relative href did not resolve out of its folder")
        try expect(EPUBBook.resolve("text/a%20b.xhtml", against: "OEBPS")
                    == "OEBPS/text/a b.xhtml",
                   "a percent-encoded href did not decode")

        guard let book = EPUBBook(url: url) else {
            throw Failure(description: "the package document did not parse")
        }
        try expect(book.title == "A Test Book" && book.author == "A. Tester",
                   "the book's metadata did not come through: \(book.title)")
        try expect(book.chapters.count == 2,
                   "the spine did not produce two chapters")
        try expect(book.chapters[0].title == "First Chapter",
                   "a spine entry was not named after its contents entry")
        try expect(book.contents.count == 3,
                   "the navigation document produced \(book.contents.count) entries, not 3")
        try expect(book.contents[1].level == 1 && book.contents[1].chapterIndex == 0,
                   "a nested contents entry lost its depth or its target")

        // Rendering: structure kept, markup and stylesheets dropped, entities
        // resolved, and words not fused to the tags beside them.
        guard let xhtml = book.data(at: book.chapters[0].path) else {
            throw Failure(description: "the first chapter is not in the archive")
        }
        let rendered = EPUBRenderer.render(xhtml: xhtml,
                                           chapterPath: book.chapters[0].path, book: book)
        let text = rendered.text.string
        try expect(text.contains("An emphasised word"),
                   "inline markup fused its words together: \(text.prefix(120))")
        try expect(text.contains("café") && text.contains("naïve")
                    && text.contains("\u{201C}quotes\u{201D}"),
                   "entities did not resolve: \(text.prefix(160))")
        try expect(!text.contains("color: red") && !text.contains("alert(1)"),
                   "a stylesheet or script was rendered as text")
        try expect(text.contains("1. First item") && text.contains("2. Second item"),
                   "an ordered list lost its numbering")
        try expect(rendered.anchors["later"] != nil,
                   "an element id was not recorded as a link target")

        // A quoted paragraph is drawn as a paragraph, so the quote's indent has
        // to reach it rather than stopping at the blockquote.
        let quoted = (text as NSString).range(of: "Quoted paragraph.")
        let style = rendered.text.attribute(.paragraphStyle, at: quoted.location,
                                            effectiveRange: nil) as? NSParagraphStyle
        try expect((style?.headIndent ?? 0) > 0,
                   "a paragraph inside a blockquote was not indented")

        // The reader itself, including moving between chapters.
        let reader = EPUBReaderView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        try expect(reader.show(url: url), "the reader refused a valid book")
        try expect(reader.chapterCountForTesting == 2
                    && reader.contentsRowCountForTesting == 3,
                   "the reader did not take the book's structure")
        try expect(reader.titleForTesting.contains("A Test Book"),
                   "the reader did not show the book's title")
        try expect(reader.chapterTextForTesting.contains("First Chapter"),
                   "the reader did not render the opening chapter")
        reader.goToNextChapterForTesting()
        try expect(reader.chapterIndexForTesting == 1
                    && reader.chapterTextForTesting.contains("The end."),
                   "stepping to the next chapter did not render it")
        reader.selectContentsRowForTesting(0)
        try expect(reader.chapterIndexForTesting == 0,
                   "clicking the contents did not go back to the chapter")
        reader.clear()
        try expect(reader.chapterTextForTesting.isEmpty && reader.chapterCountForTesting == 0,
                   "clearing the reader kept the laid-out chapter")

        // The document side: described, never read, and never writable.
        let document = Document(url: url)
        try expect(document.isEPUB && document.isReadOnly && document.isPreviewOnly,
                   "an EPUB did not open as a read-only book")
        try expect(!document.isUnsupported && document.storage.length < 200,
                   "an EPUB was read into a buffer instead of described")

        // A file named .epub that is not an archive must not open an empty
        // reader; the pane falls back to the text path for it.
        let brokenURL = directory.appendingPathComponent("broken.epub")
        try Data("not a zip".utf8).write(to: brokenURL)
        try expect(ZipArchive(url: brokenURL) == nil && EPUBBook(url: brokenURL) == nil,
                   "a file that is not an archive was accepted as a book")
        let fallbackReader = EPUBReaderView(frame: .zero)
        try expect(!fallbackReader.show(url: brokenURL),
                   "the reader claimed a file it cannot read")
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
                   "blockquote, list and footnote markers were not rendered: "
                    + "\(document.markdownLineMarkers.map { ($0.kind, $0.sourceRange) })")
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

        // Prose is set in a column, not across the whole window: Markdown is
        // read, and a full-width measure is hard to track line to line. Code
        // still fills the pane — a line means something at column 120.
        let measure = PuzzleTextView.readingColumns * Theme.characterWidth()
        let wide = NSWindow(contentRect: NSRect(x: 0, y: 0,
                                                width: measure + 400, height: 600),
                            styleMask: [.titled], backing: .buffered, defer: false)
        wide.contentViewController = pane
        defer { wide.close() }
        wide.makeKeyAndOrderFront(nil)
        wide.setContentSize(NSSize(width: measure + 400, height: 600))
        wide.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let inset = pane.textInsetForTesting
        // The column is the measure, whatever is left over is the margin.
        try expect(abs((pane.textViewWidthForTesting - inset * 2) - measure) <= 1,
                   "the Markdown column is \(pane.textViewWidthForTesting - inset * 2)pt "
                    + "wide, not the \(measure)pt measure")
        try expect(inset > 20,
                   "Markdown is not set in a centred column: \(inset)pt of margin")
        let listing = directory.appendingPathComponent("listing.swift")
        try Data("let value = 1\n".utf8).write(to: listing)
        pane.open(url: listing)
        wide.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        try expect(pane.textInsetForTesting < 20,
                   "source was indented like prose: \(pane.textInsetForTesting)pt")
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
        // Anchoring, exactly as `drawMarkdownTables` does it: a hidden row's
        // terminator belongs to the *next* fragment, so geometry has to be read
        // from the row's first character.
        func rowFragment(_ row: MarkdownTableDecoration.Row) -> NSRect {
            let glyph = tableLayout.glyphIndexForCharacter(at: row.sourceRange.location)
            return tableLayout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        let wrappedFragment = rowFragment(wrappedRow)
        try expect(wrappedFragment.height > Theme.lineMetrics().target,
                   "TextKit did not apply the measured Markdown table row height")
        guard let headerRow = document.markdownTables[0].rows.first(where: \.isHeader)
        else { throw Failure(description: "table header row metadata was missing") }
        let headerFragment = rowFragment(headerRow)
        // The header used to anchor onto the collapsed delimiter line below it,
        // a 1pt fragment, which drew the header text outside the table.
        try expect(headerFragment.height >= Theme.lineMetrics().target,
                   "Markdown table header row collapsed onto the delimiter line")
        try expect(headerFragment.maxY <= wrappedFragment.minY + 0.5,
                   "Markdown table header row was not laid out above the body rows")
        try expect(document.markdownTables[0].leadsWithBlankLine,
                   "blank line above the table was not recorded")
        try expect(headerFragment.height >= Theme.lineMetrics().target * 2,
                   "first table row did not absorb the blank line above the table")
        let trailingTerminator = NSMaxRange(document.markdownTables[0].rows.last!.sourceRange)
        let terminatorFragment = tableLayout.lineFragmentRect(
            forGlyphAt: tableLayout.glyphIndexForCharacter(at: trailingTerminator),
            effectiveRange: nil)
        try expect(terminatorFragment.height < Theme.lineMetrics().target,
                   "the table's trailing terminator drew as an extra blank line")
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
        // Stepping does not move the selection while the query field has focus:
        // AppKit paints an inactive selection over the match band, so the
        // current match would look like every other one. The band marks it, and
        // closing the bar leaves the caret there.
        try expect(textView.selectedRange().length == 0,
                   "the find bar moved the selection while the editor was unfocused")
        try expect(textView.currentMatchIndex == 0 && !textView.searchMatches.isEmpty,
                   "the current match is not marked at all")
        clearingFindBar.finish()
        try expect(textView.selectedRange().length == 1,
                   "closing the bar did not leave the caret on the match")
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

    /// The file tree must survive AppKit asking about rows the model has moved
    /// on from — the crash a file-system event caused mid-reload.
    /// The line index is kept in step with edits rather than rebuilt, so it has
    /// to agree with a rebuild after every possible edit.
    private static func testLineIndexTracksEdits() throws {
        let storage = NSTextStorage(string: "one\ntwo\nthree\nfour\n")
        var index = LineIndex(storage.string)
        var generator = SystemRandomNumberGenerator()
        let fragments = ["x", "\n", "hello\nworld", "", "\n\n", "a\nb\nc", "  ", "é\n😀\n"]

        for step in 0..<300 {
            let length = storage.length
            let location = length == 0 ? 0 : Int.random(in: 0...length, using: &generator)
            let removable = length - location
            let removed = removable == 0 ? 0 : Int.random(in: 0...min(removable, 12),
                                                          using: &generator)
            let inserted = fragments.randomElement(using: &generator)!
            let range = NSRange(location: location, length: removed)

            storage.beginEditing()
            storage.replaceCharacters(in: range, with: inserted)
            storage.endEditing()
            let insertedLength = (inserted as NSString).length
            index.apply(editedRange: NSRange(location: location, length: insertedLength),
                        delta: insertedLength - removed,
                        text: storage.mutableString)

            let rebuilt = LineIndex(storage.string)
            try expect(index.starts == rebuilt.starts,
                       "step \(step): incremental index drifted.\n"
                        + "edit at \(location) removed \(removed) inserted "
                        + "\(inserted.debugDescription)\n"
                        + "incremental \(index.starts)\nrebuilt     \(rebuilt.starts)")
            try expect(index.length == rebuilt.length,
                       "step \(step): length \(index.length) vs \(rebuilt.length)")
        }

        // The gutter reads the live index, not a copy taken when the file was
        // opened, or the numbers freeze at their state before the first edit.
        do {
            let directory = try temporaryDirectory("gutter-index")
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("lines.swift")
            try Data("let a = 1\nlet b = 2\nlet c = 3\n".utf8).write(to: file)
            let pane = EditorPaneViewController()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentViewController = pane
            defer { window.close() }
            pane.open(url: file)
            pane.view.layoutSubtreeIfNeeded()
            guard let ruler = pane.lineNumberRulerForTesting,
                  let before = ruler.lineIndexProvider?() else {
                throw Failure(description: "the gutter has no line index")
            }
            try expect(before.line(at: 10) == 2, "second line is not line 2")
            pane.setCaretForTesting(0)
            pane.insertTextForTesting("// header\n")
            guard let after = ruler.lineIndexProvider?() else {
                throw Failure(description: "the gutter lost its index after an edit")
            }
            try expect(after.line(at: 20) == 3,
                       "the gutter still numbers lines as they were before the edit")
        }

        // And the lookups it exists for.
        let text = "alpha\nbeta\n\ngamma"
        let lookup = LineIndex(text)
        try expect(lookup.line(at: 0) == 1 && lookup.line(at: 5) == 1,
                   "the first line's own newline belongs to it")
        try expect(lookup.line(at: 6) == 2 && lookup.line(at: 11) == 3
                    && lookup.line(at: 12) == 4,
                   "an empty line is still a line")
        try expect(lookup.line(at: 9_999) == lookup.lineCount,
                   "an offset past the end did not clamp to the last line")

        // A document keeps its index in step through the text storage itself.
        let directory = try temporaryDirectory("line-index-doc")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sample.txt")
        try Data("a\nb\nc\n".utf8).write(to: file)
        let document = DocumentStore().document(for: file)
        try expect(document.lineIndex.lineCount == 4, "loaded with the wrong line count")
        document.storage.beginEditing()
        document.storage.replaceCharacters(in: NSRange(location: 2, length: 0), with: "x\ny\n")
        document.storage.endEditing()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        try expect(document.lineIndex.starts == LineIndex(document.storage.string).starts,
                   "the document's index did not follow an edit to its storage")
    }

    /// A minified file (a bundle, a source map) is one line of megabytes, which
    /// TextKit lays out as a single unit — 2.5 seconds of frozen UI, measured.
    private static func testMinifiedFilesOpenBounded() throws {
        let directory = try temporaryDirectory("minified")
        defer { try? FileManager.default.removeItem(at: directory) }

        var body = "{\"version\":3,\"mappings\":\""
        body += String(repeating: "AAAA,CAAC;", count: 300_000)
        body += "\"}"
        let map = directory.appendingPathComponent("bundle.js.map")
        try Data(body.utf8).write(to: map)

        let store = DocumentStore()
        let document = store.document(for: map)
        try expect(document.isMinifiedPreview,
                   "a 3 MB single-line file was opened in full")
        try expect(document.isReadOnly,
                   "a truncated buffer is editable, so saving would destroy the file")
        try expect(document.storage.length < Document.minifiedPreviewLength + 2_000,
                   "the preview is \(document.storage.length) characters, not bounded")
        try expect(document.text.contains("minified"),
                   "the preview does not say why it is truncated")

        // A normal file, even a wide one, is untouched.
        let source = directory.appendingPathComponent("normal.swift")
        let line = String(repeating: "x", count: 300)
        let text = (1...200).map { "let value\($0) = \"\(line)\"" }.joined(separator: "\n")
        try Data(text.utf8).write(to: source)
        let normal = store.document(for: source)
        try expect(!normal.isMinifiedPreview && !normal.isReadOnly,
                   "an ordinary file was treated as minified")
        try expect(normal.text == text, "an ordinary file was altered on load")

        // The byte scan the guard relies on.
        try expect(Document.longestLineLength(in: Data("ab\ncdef\ng".utf8)) == 4,
                   "the longest line was measured wrong")
        try expect(Document.longestLineLength(in: Data("no newline".utf8)) == 10,
                   "a file without a trailing newline measured wrong")

        // Line lookups are what replaced the per-character scans.
        let index = LineIndex("one\ntwo\nthree" as NSString)
        try expect(index.lineCount == 3, "counted \(index.lineCount) lines")
        try expect(index.line(at: 0) == 1 && index.line(at: 4) == 2 && index.line(at: 12) == 3,
                   "offsets map to the wrong lines")
        try expect(index.start(ofLine: 2) == 4 && index.start(ofLine: 3) == 8,
                   "line starts are wrong: \(index.starts)")
        try expect(index.start(ofLine: 99) == index.length,
                   "a line past the end did not clamp")
        try expect(index.longestLine == 5, "longest line is \(index.longestLine)")
    }

    /// Minified JSON is laid out on the way into the buffer, the way a browser
    /// lays it out before showing it. The file on disk is not touched.
    private static func testMinifiedJSONOpensFormatted() throws {
        let directory = try temporaryDirectory("json-format")
        defer { try? FileManager.default.removeItem(at: directory) }

        let minified = """
            {"name":"puzzle","version":"2.0","private":true,\
            "scripts":{"build":"./build.sh"},"keywords":["editor","swift"],\
            "empty":{},"list":[],"numbers":[1,2.50,1e3,-0.5],"escaped":"a\\"b: {x}",\
            "nested":{"a":{"b":null}}}
            """
        let url = directory.appendingPathComponent("payload.json")
        try Data(minified.utf8).write(to: url)

        let store = DocumentStore()
        let document = store.document(for: url)
        try expect(document.isDisplayFormatted,
                   "a one-line JSON payload was left as one line")
        try expect(!document.isModified,
                   "formatting for display marked the buffer dirty, so autosave "
                     + "would rewrite a file the user never edited")
        try expect(!document.isReadOnly && !document.isMinifiedPreview,
                   "formatted JSON stayed on the read-only minified path")
        let formatted = document.text
        try expect(formatted.components(separatedBy: "\n").count > 10,
                   "the payload was not laid out over lines")
        try expect(formatted.contains("\n  \"name\": \"puzzle\","),
                   "two-space indentation is missing: \(formatted)")
        // Order, spelling and escapes survive: this re-spaces the source, it
        // does not re-encode it. JSONSerialization would sort the keys and
        // rewrite 2.50 as 2.5.
        let keys = ["name", "version", "private", "scripts", "keywords",
                    "empty", "list", "numbers", "escaped", "nested"]
        var cursor = formatted.startIndex
        for key in keys {
            guard let found = formatted.range(of: "\"\(key)\":", range: cursor..<formatted.endIndex)
            else { throw Failure(description: "key \(key) is out of order or missing") }
            cursor = found.upperBound
        }
        try expect(formatted.contains("2.50") && formatted.contains("1e3"),
                   "number literals were re-encoded rather than copied")
        try expect(formatted.contains("\"a\\\"b: {x}\""),
                   "an escaped quote or a brace inside a string broke the printer")
        try expect(formatted.contains("\"empty\": {}") && formatted.contains("\"list\": []"),
                   "empty containers were split over lines")
        // The bytes on disk are the user's, until the user edits them.
        let onDisk = String(data: try Data(contentsOf: url), encoding: .utf8)
        try expect(onDisk == minified, "opening the file rewrote it")
        // An external write of the same bytes must not paste the minified
        // source back over the formatted buffer.
        try Data(minified.utf8).write(to: url)
        _ = document.reloadFromDiskIfLatest()
        try expect(document.text == formatted,
                   "re-reading the unchanged file replaced the formatted buffer")

        // Already readable JSON is left exactly as the author wrote it, four
        // space indents and all.
        let pretty = "{\n    \"a\": 1,\n    \"b\": [2]\n}\n"
        let prettyURL = directory.appendingPathComponent("pretty.json")
        try Data(pretty.utf8).write(to: prettyURL)
        let prettyDocument = store.document(for: prettyURL)
        try expect(prettyDocument.text == pretty && !prettyDocument.isDisplayFormatted,
                   "a hand-formatted file was reformatted")

        // A single huge string value survives formatting as one huge line. The
        // file still opens: it is laid out everywhere else, and that line costs
        // TextKit milliseconds, not the seconds the preview path exists for.
        let long = "{\"note\":\"" + String(repeating: "A", count: 250_000)
            + "\",\"b\":1,\"c\":2,\"d\":[1,2,3],\"e\":{\"f\":4}}"
        let longURL = directory.appendingPathComponent("long-value.json")
        try Data(long.utf8).write(to: longURL)
        let longDocument = store.document(for: longURL)
        try expect(longDocument.isDisplayFormatted && !longDocument.isMinifiedPreview
                    && !longDocument.isReadOnly,
                   "a formatted file with one long string value opened read-only")

        // One long line inside a laid-out file is the author's formatting, not a
        // machine's, and is left alone.
        let pairs: [String] = (1...20).map { "  \"k\($0)\": \($0)" }
        let blob = "{\n  \"data\": \"" + String(repeating: "A", count: 400) + "\",\n"
            + pairs.joined(separator: ",\n") + "\n}\n"
        let blobURL = directory.appendingPathComponent("blob.json")
        try Data(blob.utf8).write(to: blobURL)
        let blobDocument = store.document(for: blobURL)
        try expect(blobDocument.text == blob && !blobDocument.isDisplayFormatted,
                   "a laid-out file with one long value was reformatted")

        // Not JSON, however long the line: nothing is guessed at.
        let broken = "{\"a\": " + String(repeating: "1", count: 300) + ",}"
        let brokenURL = directory.appendingPathComponent("broken.json")
        try Data(broken.utf8).write(to: brokenURL)
        let brokenDocument = store.document(for: brokenURL)
        try expect(brokenDocument.text == broken && !brokenDocument.isDisplayFormatted,
                   "invalid JSON was rewritten")
        try expect(JSONFormatter.pretty("[1, 2") == nil
                    && JSONFormatter.pretty("{\"a\":1} trailing") == nil
                    && JSONFormatter.pretty("") == nil,
                   "the printer accepted something that is not one JSON document")
        try expect(JSONFormatter.pretty("[[1]]") == "[\n  [\n    1\n  ]\n]\n",
                   "nested arrays are laid out wrong: "
                     + "\(JSONFormatter.pretty("[[1]]") ?? "nil")")
    }

    private static func testFileTreeSurvivesReentrantReload() throws {
        let directory = try temporaryDirectory("tree-reentrancy")
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 1...5 {
            try Data("x\n".utf8).write(to: folder.appendingPathComponent("file\(index).txt"))
        }

        let tree = FileTreeViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = tree
        defer { window.close() }
        tree.setRoot(directory)
        tree.view.layoutSubtreeIfNeeded()
        guard let folderRow = tree.row(for: folder) else {
            throw Failure(description: "the folder is missing from the tree")
        }
        tree.expandRowForTesting(folderRow)
        tree.view.layoutSubtreeIfNeeded()

        guard let node = tree.nodeForTesting(at: folderRow) else {
            throw Failure(description: "no node behind the folder row")
        }
        let children = tree.outlineView(tree.outlineViewForTesting,
                                        numberOfChildrenOfItem: node)
        try expect(children == 5, "expected five children, got \(children)")

        // Everything disappears underneath AppKit, which then asks for a child
        // it was told about a moment ago. Before, this trapped on the subscript.
        for index in 1...5 {
            try FileManager.default.removeItem(at: folder.appendingPathComponent("file\(index).txt"))
        }
        node.releaseChildrenForTesting()
        let stale = tree.outlineView(tree.outlineViewForTesting, child: 4, ofItem: node)
        try expect(!(stale is FileNode) || (stale as? FileNode) !== node,
                   "a stale child resolved to its own parent, which AppKit walks forever")

        // The expand notification must not reload inside AppKit's own reload:
        // it schedules the work instead.
        let before = tree.reloadCountForTesting
        NotificationCenter.default.post(
            name: NSOutlineView.itemDidExpandNotification,
            object: tree.outlineViewForTesting,
            userInfo: ["NSObject": node])
        try expect(tree.reloadCountForTesting == before,
                   "expanding reloaded the row from inside AppKit's notification")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        try expect(tree.reloadCountForTesting > before,
                   "the deferred reload never happened")
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

    /// Settings opens a file, not a panel, so its control is a gear with the
    /// editor's own actions at the top right — always there, whatever is open.
    /// Tabs are reachable from the keyboard, and a tab closed by mistake comes
    /// back. Before this the only way between tabs was the mouse, and a
    /// mis-hit ⌘W meant finding the file in the tree again.
    /// Closing a tab writes it, the same way leaving it does. The sheet that
    /// used to ask is gone: the answer was already known, and the same edit
    /// behaved differently depending on whether the user had clicked away
    /// first.
    private static func testClosingATabWritesIt() throws {
        let root = try temporaryDirectory("close-writes")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("notes.txt")
        try Data("original\n".utf8).write(to: file)

        let pane = EditorPaneViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = pane
        defer { window.close() }
        pane.open(url: file)
        pane.view.layoutSubtreeIfNeeded()
        pane.setCaretForTesting(0)
        pane.insertTextForTesting("EDITED ")
        try expect(pane.isModifiedForTesting, "the edit did not reach the buffer")

        // No sheet: a modal here would hang the test, so reaching the
        // assertions at all is part of what is being checked.
        pane.close(index: 0)
        try expect(pane.openURLs.isEmpty, "the tab did not close")
        let onDisk = try String(contentsOf: file, encoding: .utf8)
        try expect(onDisk == "EDITED original\n",
                   "closing did not write the buffer: \(onDisk.debugDescription)")

        // A file that changed underneath the edit is the one case still worth
        // asking about, so the close is refused rather than silently picking a
        // side. `confirmClose` reports that by returning false.
        pane.open(url: file)
        pane.view.layoutSubtreeIfNeeded()
        pane.setCaretForTesting(0)
        pane.insertTextForTesting("MINE ")
        try Data("theirs\n".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
        try expect(!pane.autosaveWritesForTesting,
                   "a conflicted buffer was written without asking")
        let afterConflict = try String(contentsOf: file, encoding: .utf8)
        try expect(afterConflict == "theirs\n",
                   "the conflicting file was overwritten: \(afterConflict.debugDescription)")
    }

    private static func testTabKeyboardNavigation() throws {
        let root = try temporaryDirectory("tab-keys")
        defer { try? FileManager.default.removeItem(at: root) }
        var files: [URL] = []
        for name in ["one.swift", "two.swift", "three.swift"] {
            let url = root.appendingPathComponent(name)
            try Data("// \(name)\n".utf8).write(to: url)
            files.append(url)
        }
        let editor = EditorViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = editor
        defer { window.close() }
        files.forEach { editor.open(url: $0) }
        editor.view.layoutSubtreeIfNeeded()
        guard let pane = editor.activePaneForTesting else {
            throw Failure(description: "no pane")
        }
        try expect(pane.openURLs.count == 3, "the files did not open as tabs")
        try expect(editor.currentURL == files[2], "the last opened file is not active")

        // Stepping wraps at both ends.
        editor.stepTab(by: 1)
        try expect(editor.currentURL == files[0], "next tab did not wrap to the first")
        editor.stepTab(by: -1)
        try expect(editor.currentURL == files[2], "previous tab did not wrap to the last")
        editor.stepTab(by: -1)
        try expect(editor.currentURL == files[1], "previous tab did not step back")

        // Closing and reopening: the most recently closed comes back first.
        pane.close(index: 1)
        try expect(!pane.openURLs.contains(files[1]), "the tab did not close")
        pane.close(index: 0)
        try expect(pane.openURLs == [files[2]], "the second close did not land")
        try expect(editor.reopenLastClosedTab() && editor.currentURL == files[0],
                   "reopen did not restore the most recently closed tab")
        try expect(editor.reopenLastClosedTab() && editor.currentURL == files[1],
                   "reopen did not walk back through the closed tabs")
        try expect(!editor.reopenLastClosedTab(),
                   "reopen invented a tab that was never closed")

        // A file deleted after it was closed is not resurrected.
        let doomed = files[0]
        pane.close(index: pane.openURLs.firstIndex(of: doomed) ?? 0)
        try FileManager.default.removeItem(at: doomed)
        try expect(!editor.reopenLastClosedTab(),
                   "reopen brought back a file that no longer exists")
    }

    /// Finder only offers apps that declare what they can open. Without a
    /// `CFBundleDocumentTypes` entry Puzzle was missing from Open With for
    /// every file type, including the ones it is for.
    private static func testBundleDeclaresDocumentTypes() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let build = try String(contentsOf: root.appendingPathComponent("build.sh"),
                               encoding: .utf8)
        guard let start = build.range(of: "<key>CFBundleDocumentTypes</key>") else {
            throw Failure(description: "the bundle declares no document types, "
                            + "so Open With hides it")
        }
        let claims = String(build[start.lowerBound...])

        // Alternate, not Owner: being offered in the list is the point; taking
        // over as the default for every source file on the machine is not.
        try expect(!claims.contains("<string>Owner</string>"),
                   "the bundle claims to own a document type")
        try expect(claims.contains("<string>Alternate</string>"),
                   "the document claims carry no handler rank")
        // Images open in a preview that cannot edit them.
        try expect(claims.contains("<string>public.image</string>")
                    && claims.contains("<string>Viewer</string>"),
                   "images are not claimed, or are claimed as editable")
        // Everything else, including files macOS cannot type at all.
        for type in ["public.text", "public.source-code", "public.json", "public.data"] {
            try expect(claims.contains("<string>\(type)</string>"),
                       "the bundle does not claim \(type)")
        }

        // Every language the app highlights has to be reachable from Finder.
        // An extension macOS types as something else (a .ts file is
        // public.mpeg-2-transport-stream, a video) or does not type at all
        // (.rs, .go get an anonymous `dyn.` type that conforms to nothing)
        // matches no UTI claim, so it has to be named outright.
        let declared = Set(
            claims.components(separatedBy: "<string>")
                .compactMap { $0.components(separatedBy: "</string>").first })
        var unreachable: [String] = []
        for spec in SyntaxHighlighter.specs {
            for ext in spec.extensions where !declared.contains(ext) {
                guard let type = UTType(filenameExtension: ext) else {
                    unreachable.append(".\(ext) (no system type)")
                    continue
                }
                guard !type.conforms(to: .text), !type.conforms(to: .sourceCode),
                      !declared.contains(type.identifier) else { continue }
                unreachable.append(".\(ext) (\(type.identifier))")
            }
        }
        try expect(unreachable.isEmpty,
                   "Finder cannot offer Puzzle for: \(unreachable.joined(separator: ", "))")
    }

    private static func testSettingsGearLivesTopRight() throws {
        try expect(!ActivityBarView.Action.allCases.contains { "\($0)" == "settings" },
                   "the activity bar still offers a Settings panel")

        let editor = EditorViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = editor
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        editor.view.layoutSubtreeIfNeeded()

        var opened = 0
        editor.onOpenSettings = { opened += 1 }
        // An empty window shows the welcome screen and no tab strip at all.
        // The gear is not part of the strip, so it is still there.
        try expect(editor.settingsGearVisibleForTesting,
                   "the gear disappeared with the tab strip")
        editor.clickSettingsGearForTesting()
        try expect(opened == 1, "the gear did not ask for settings on an empty editor")

        let root = try temporaryDirectory("settings-gear")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.swift")
        try Data("let value = 1\n".utf8).write(to: file)
        editor.open(url: file)
        editor.view.layoutSubtreeIfNeeded()
        try expect(editor.settingsGearVisibleForTesting,
                   "the gear disappeared once a file was open")
        editor.clickSettingsGearForTesting()
        try expect(opened == 2, "the gear stopped working once a file was open")

        // And it keeps clear of the tabs: the strip reserves the same width the
        // gear occupies, so a long tab title cannot run underneath it.
        try expect(EditorTabBar.actionAreaWidth >= 32,
                   "the tab strip stopped reserving room for the window's actions")
    }

    private static func testActivityBarUsesTextLabels() throws {
        let bar = ActivityBarView(frame: NSRect(x: 0, y: 0, width: 320, height: 40))
        bar.layoutSubtreeIfNeeded()
        // One button per panel. Settings is not a panel — it opens a file — so
        // it sits with the editor's actions at the top right instead.
        try expect(bar.buttonTitlesForTesting == ["Files", "Search", "Git"],
                   "the activity bar reads \(bar.buttonTitlesForTesting)")

        // The Git label carries the live changed-file count in the same form as
        // the panel's own "Changes (7)" tab. A clean tree has nothing to say, so
        // the count disappears rather than reading "(0)".
        bar.setChangeCount(7)
        try expect(bar.buttonTitlesForTesting == ["Files", "Search", "Git 7"],
                   "the change count did not reach the Git label: "
                    + "\(bar.buttonTitlesForTesting)")
        bar.setChangeCount(0)
        try expect(bar.buttonTitlesForTesting == ["Files", "Search", "Git"],
                   "a clean tree still showed a count: \(bar.buttonTitlesForTesting)")
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

    /// The scrollbar knob comes from the theme: AppKit's dark-mode grey is the
    /// brightest thing on a window this dark.
    private static func testScrollersFollowTheTheme() throws {
        func luminance(_ color: NSColor) -> CGFloat {
            guard let c = color.usingColorSpace(.sRGB) else { return 0 }
            return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        }

        let knob = luminance(Theme.scrollerKnob)
        let editor = luminance(Theme.editorBackground)
        try expect(knob > editor + 0.02,
                   "the knob does not separate from the surface behind it")
        try expect(knob < 0.25,
                   "the knob is brighter than anything else on the window: \(knob)")
        try expect(luminance(Theme.foreground) - knob > 0.3,
                   "the knob competes with the text for attention")

        // The capsule must survive the inset: an overlay knob is 6pt across,
        // and taking 3pt off each side left nothing to see.
        let overlayKnob = NSRect(x: 8, y: 14.5, width: 6, height: 26)
        let painted = PuzzleScroller.knobPaintRect(for: overlayKnob, vertical: true)
        try expect(painted.width >= 4 && painted.height == overlayKnob.height,
                   "the knob collapsed under its inset: \(painted)")
        try expect(PuzzleScroller.knobPaintRect(for: .zero, vertical: true).isEmpty,
                   "an empty knob rect produced something to draw")
        let horizontal = PuzzleScroller.knobPaintRect(
            for: NSRect(x: 4, y: 8, width: 40, height: 6), vertical: false)
        try expect(horizontal.height >= 4 && horizontal.width == 40,
                   "a horizontal knob collapsed: \(horizontal)")

        // It is actually what gets painted, not just a colour nobody reads.
        guard let paintedColour = PuzzleScroller.knobColourForTesting() else {
            throw Failure(description: "the scroller drew nothing")
        }
        try expect(abs(luminance(paintedColour) - knob) < 0.08,
                   "the knob painted \(luminance(paintedColour)) against the theme's \(knob)")

        // Overlay scrollers are what every window here uses; a scroller that
        // opts out of them is silently replaced by AppKit's own.
        try expect(PuzzleScroller.isCompatibleWithOverlayScrollers,
                   "the themed scroller would be dropped for overlay style")

        // The panel does not narrow past what its rows need.
        try expect(RootViewController.minimumSidebarWidth == 300,
                   "the sidebar floor moved: \(RootViewController.minimumSidebarWidth)")
        let root = RootViewController(sidebar: SidebarViewController(),
                                      editor: EditorViewController())
        _ = root.view
        root.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
        root.view.layoutSubtreeIfNeeded()
        root.resizeSidebarForTesting(to: 80)
        root.view.layoutSubtreeIfNeeded()
        try expect(root.sidebarWidthForTesting >= RootViewController.minimumSidebarWidth,
                   "dragging the divider went below the floor: \(root.sidebarWidthForTesting)")

        // No scroll view keeps AppKit's automatic content insets: they are for
        // lists running under a titlebar, and here they were pure dead space
        // above the first row.
        let panel = GitPanelViewController()
        _ = panel.view
        try expect(panel.listScrollInsetsForTesting.top == 0,
                   "the Git list starts \(panel.listScrollInsetsForTesting.top)pt down")
        try expect(!panel.listAdjustsInsetsForTesting,
                   "the Git list still lets AppKit inset it")
        // Nor the inset table style, whose 10pt of top padding made the gap
        // below the Branch toolbar bigger than the gap above it.
        try expect(panel.listStyleForTesting == .plain,
                   "the Git list uses an inset table style")
        panel.applyStatusForTesting(
            GitService.Status(branch: "main",
                              entries: [GitService.Status.Entry(code: " M", path: "a.swift",
                                                                originalPath: nil)],
                              isRepo: true, userName: "T", ahead: 0, hasUpstream: true),
            in: URL(fileURLWithPath: "/tmp"))
        try expect(panel.firstRowRectForTesting.minY == 0,
                   "the list starts \(panel.firstRowRectForTesting.minY)pt below its top")

        // Every scroll view in the app gets one.
        let pane = EditorPaneViewController()
        _ = pane.view
        try expect(pane.verticalScrollerForTesting is PuzzleScroller,
                   "the editor kept AppKit's scroller")
        let tree = FileTreeViewController()
        _ = tree.view
        try expect(tree.verticalScrollerForTesting is PuzzleScroller,
                   "the file tree kept AppKit's scroller")
    }

    /// One palette, fixed: nothing follows the system appearance and no setting
    /// selects anything else, so the tokens can be asserted outright.
    private static func testAyuDarkTheme() throws {
        // A colour is one value, not an appearance-dependent one: views cache
        // what they are built with, and a dynamic colour would resolve against
        // whatever appearance happened to be current when they drew.
        for colour in [Theme.editorBackground, Theme.foreground, Theme.selectedControl] {
            try expect(colour.usingColorSpace(.sRGB) != nil,
                       "a palette colour does not resolve on its own: \(colour)")
        }
        // The code area is the panel's surface, and the active line is the
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
        // Types are blue and calls yellow here, the reverse of most palettes —
        // which is why the tokens name the role and not the hue.
        try expect(sameColor(Theme.syntaxType, hexColor(0x39bae6))
                    && sameColor(Theme.syntaxFunction, hexColor(0xffb454)),
                   "the syntax roles are not Ayu's")
        // Settings no longer carry a theme, and a file that still names one is
        // rewritten without it rather than quietly keeping a dead key.
        try expect(!Settings.shared.documentedContentsForTesting.contains("\"theme\""),
                   "the settings template still offers a theme")
        // The sidebar/editor split takes the colour directly…
        try expect(sameColor(PuzzleSplitView().dividerColor, Theme.border),
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

        // Exercise the file-picker callback itself, not just path matching.
        // A callback that unconditionally calls makeWindow passes the checks
        // above while still opening duplicate workspaces in the actual app.
        let app = AppDelegate()
        defer { app.windowsForTesting.forEach { $0.window?.close() } }
        try expect(app.openURLs([outer]), "could not open the initial project")
        guard let outerWindow = app.window(showingProject: outer) else {
            throw Failure(description: "initial project window was not registered")
        }
        let sibling = outer.appendingPathComponent("sibling.swift")
        try Data("let sibling = 1\n".utf8).write(to: sibling)
        outerWindow.openSelection([file, sibling])
        try expect(app.windowsForTesting.count == 1 && outerWindow.editor.openURLs.count == 2,
                   "the file picker created another window for files inside an open project")
        outerWindow.openSelection([outer, sibling])
        try expect(app.windowsForTesting.count == 1 && outerWindow.editor.openURLs.count == 2,
                   "reselecting an open folder or file created a duplicate window/tab")

        app.openURLs([other])
        guard let otherWindow = app.window(showingProject: other) else {
            throw Failure(description: "could not open a second independent project")
        }
        otherWindow.openSelection([sibling])
        try expect(app.windowsForTesting.count == 2
                    && outerWindow.editor.currentURL == sibling.resolvingSymlinksInPath()
                    && otherWindow.editor.openURLs.isEmpty,
                   "the picker did not route a file to its existing project from another window")
        otherWindow.openSelection([outer])
        try expect(app.windowsForTesting.count == 2,
                   "opening an existing project from another window duplicated it")

        let alias = root.appendingPathComponent("outer-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outer)
        otherWindow.openSelection([alias.appendingPathComponent("sibling.swift")])
        try expect(app.windowsForTesting.count == 2 && outerWindow.editor.openURLs.count == 2,
                   "a symlinked file path duplicated its project or tab")

        app.openURLs([inner])
        otherWindow.openSelection([file])
        try expect(app.windowsForTesting.count == 3
                    && app.window(showingProject: inner)?.editor.currentURL == file.resolvingSymlinksInPath(),
                   "the picker ignored the deepest open project")

        // A mixed selection must establish the chosen root before opening its
        // nested file, even if the panel reports that file first.
        let fresh = root.appendingPathComponent("fresh", isDirectory: true)
        let child = fresh.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let freshFile = child.appendingPathComponent("sample.txt")
        try Data("sample".utf8).write(to: freshFile)
        otherWindow.openSelection([freshFile, fresh])
        try expect(app.windowsForTesting.count == 4
                    && app.window(showingProject: fresh)?.editor.openURLs.count == 1,
                   "a mixed file/folder selection created two windows for one project")
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

    /// Counts appear only where there is something to count, and Push reads as
    /// one control with two targets.
    private static func testGitPanelCounters() throws {
        let directory = try temporaryDirectory("git-counters")
        defer { try? FileManager.default.removeItem(at: directory) }
        let panel = GitPanelViewController()
        _ = panel.view
        let bar = ActivityBarView(frame: NSRect(x: 0, y: 0, width: 320, height: 40))

        func entry(_ path: String) -> GitService.Status.Entry {
            GitService.Status.Entry(code: " M", path: path, originalPath: nil)
        }
        func status(entries: [GitService.Status.Entry], ahead: Int) -> GitService.Status {
            GitService.Status(branch: "main", entries: entries, isRepo: true,
                              userName: "T", ahead: ahead, hasUpstream: true)
        }

        // Work to do: both places count it, and Push says how much is waiting.
        panel.applyStatusForTesting(status(entries: [entry("a.swift"), entry("b.swift")],
                                           ahead: 3), in: directory)
        bar.setChangeCount(2)
        // The number is a badge beside the label, not part of its text.
        try expect(panel.changesTabLabelForTesting == "Changes"
                    && panel.changesTabBadgeForTesting == "2",
                   "the tab reads \(panel.changesTabLabelForTesting) "
                    + "/ \(panel.changesTabBadgeForTesting)")
        try expect(bar.buttonTitlesForTesting[2] == "Git 2",
                   "the activity bar reads \(bar.buttonTitlesForTesting[2])")
        try expect(panel.pushLabelForTesting == "Push" && panel.pushBadgeForTesting == "3",
                   "Push reads \(panel.pushLabelForTesting) / \(panel.pushBadgeForTesting)")
        // The count belongs to Push, not to the line above the commit box.
        // (the project name is a temporary directory, so match the shapes the
        // count would take rather than the digit itself)
        try expect(!panel.statusLabelForTesting.contains("↑")
                    && !panel.statusLabelForTesting.contains("(3)"),
                   "the commit header still carries the push count: "
                    + panel.statusLabelForTesting)

        // Nothing to do: no "(0)" anywhere.
        panel.applyStatusForTesting(status(entries: [], ahead: 0), in: directory)
        bar.setChangeCount(0)
        try expect(panel.changesTabBadgeForTesting.isEmpty,
                   "the tab shows a zero badge: \(panel.changesTabBadgeForTesting)")
        try expect(bar.buttonTitlesForTesting[2] == "Git",
                   "the activity bar shows a zero: \(bar.buttonTitlesForTesting[2])")
        try expect(panel.pushBadgeForTesting.isEmpty,
                   "Push shows a zero badge: \(panel.pushBadgeForTesting)")

        // A badge is a circle on the label's own line, growing to hold its
        // digits rather than stretching into a pill.
        let labelFont = Theme.uiFont(10.5)
        let single = SidebarCellDrawing.Badge.size("3", labelFont: labelFont)
        let double = SidebarCellDrawing.Badge.size("12", labelFont: labelFont)
        let triple = SidebarCellDrawing.Badge.size("128", labelFont: labelFont)
        for (value, size) in [("3", single), ("12", double), ("128", triple)] {
            try expect(size.width == size.height,
                       "the \(value) badge is not round: \(size)")
        }
        try expect(single.width >= SidebarCellDrawing.Badge.minimumDiameter,
                   "a one-digit badge collapses: \(single)")
        try expect(triple.width > single.width,
                   "the badge does not grow with its digits: \(single) vs \(triple)")
        try expect(double.width >= single.width,
                   "a two-digit badge is smaller than a one-digit one: "
                    + "\(single) vs \(double)")
        try expect(SidebarCellDrawing.Badge.size("", labelFont: labelFont) == .zero,
                   "an empty badge still takes room")

        // Label and badge are one line of text, so they cannot drift apart:
        // the badge is an attachment, and AppKit gives it the line's baseline.
        let composed = SidebarCellDrawing.labelWithBadge(
            "Push", badge: "12", font: labelFont, colour: .white,
            badgeBackground: .gray, badgeForeground: .black)
        try expect(composed.string.hasPrefix("Push"),
                   "the label lost its text: \(composed.string.debugDescription)")
        var attachmentCount = 0
        var attachmentOffset: CGFloat = 0
        composed.enumerateAttribute(.attachment,
                                    in: NSRange(location: 0, length: composed.length)) {
            value, _, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            attachmentCount += 1
            attachmentOffset = attachment.bounds.origin.y
        }
        try expect(attachmentCount == 1, "expected one badge attachment, got \(attachmentCount)")
        // Raised so its middle sits on the cap-height, not dropped to the baseline.
        try expect(attachmentOffset < 0,
                   "the badge sits on the baseline instead of straddling the text")
        let empty = SidebarCellDrawing.labelWithBadge(
            "Push", badge: "", font: labelFont, colour: .white,
            badgeBackground: .gray, badgeForeground: .black)
        try expect(empty.string == "Push",
                   "an empty badge still added something: \(empty.string.debugDescription)")

        // The digits sit in the middle of the circle, both ways. Measured off
        // the rendered badge rather than trusted to the font metrics.
        for value in ["1", "12", "128"] {
            guard let image = SidebarCellDrawing.Badge.image(
                    value, labelFont: labelFont,
                    background: .white, foreground: .black),
                  let data = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: data) else {
                throw Failure(description: "the \(value) badge did not render")
            }
            var minX = rep.pixelsWide, maxX = -1, minY = rep.pixelsHigh, maxY = -1
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                          colour.brightnessComponent < 0.5, colour.alphaComponent > 0.5
                    else { continue }
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            try expect(maxX >= minX && maxY >= minY,
                       "the \(value) badge drew no digits")
            let inkCentre = (x: Double(minX + maxX) / 2, y: Double(minY + maxY) / 2)
            let centre = (x: Double(rep.pixelsWide - 1) / 2, y: Double(rep.pixelsHigh - 1) / 2)
            // Within a device pixel at 2x, which is half a point.
            try expect(abs(inkCentre.x - centre.x) <= 1.5,
                       "the \(value) digits are off-centre horizontally: "
                        + "\(inkCentre.x) vs \(centre.x)")
            try expect(abs(inkCentre.y - centre.y) <= 1.5,
                       "the \(value) digits are off-centre vertically: "
                        + "\(inkCentre.y) vs \(centre.y)")
        }

        // Nothing to push: the button itself is inert…
        try expect(!panel.pushEnabledForTesting,
                   "Push is still live with nothing to push")
        try expect(!panel.clickPushForTesting(),
                   "clicking a disabled Push still acted")
        // There is no menu any more: Push is the whole control.
        try expect(panel.pushBadgeForTesting.isEmpty,
                   "a count is shown with nothing to push")

        // Uncommitted work does not wake Push: those changes are not pushable
        // until they are committed.
        panel.applyStatusForTesting(status(entries: [entry("a.swift")], ahead: 0),
                                    in: directory)
        try expect(!panel.pushEnabledForTesting,
                   "Push woke up on uncommitted changes, which it cannot send")
        panel.applyStatusForTesting(status(entries: [], ahead: 0), in: directory)
        // Something to push, or a branch with no upstream to push to: live again.
        panel.applyStatusForTesting(status(entries: [], ahead: 1), in: directory)
        try expect(panel.pushEnabledForTesting, "Push is dead with a commit waiting")
        panel.applyStatusForTesting(
            GitService.Status(branch: "main", entries: [], isRepo: true, userName: "T",
                              ahead: 0, hasUpstream: false), in: directory)
        try expect(panel.pushEnabledForTesting,
                   "Push is dead on a branch that has no upstream yet, which is "
                    + "exactly when pushing sets one up")
        panel.applyStatusForTesting(status(entries: [], ahead: 0), in: directory)

        // The button sizes itself around its label and badge.
        let button = BadgeButton()
        button.title = "Push"
        let bare = button.intrinsicContentSize
        button.badge = "12"
        let badged = button.intrinsicContentSize
        try expect(badged.width > bare.width,
                   "the badge takes no room: \(bare) vs \(badged)")
        try expect(badged.height == BadgeButton.height,
                   "the button changed height for its badge: \(badged)")
        var clicks = 0
        button.onClick = { clicks += 1 }
        try expect(button.clickForTesting() && clicks == 1, "the button did not act")
        button.isEnabled = false
        try expect(!button.clickForTesting() && clicks == 1,
                   "a disabled button still acted")
    }

    /// The side-by-side diff mode behind the header's rightmost button.
    /// Uncommitted changes marked in the gutter of the file itself.
    private static func testGitLineChangeMarks() throws {
        // -U0 hunks: an addition, a modification, and a deletion.
        let diff = """
        diff --git a/App.swift b/App.swift
        --- a/App.swift
        +++ b/App.swift
        @@ -3,0 +4,2 @@ func f() {
        +added one
        +added two
        @@ -10 +11 @@
        -was this
        +is now this
        @@ -20,2 +20,0 @@
        -gone one
        -gone two
        """
        let changes = GitLineChanges.parse(diff)
        try expect(changes.count == 3, "expected three marks, got \(changes.count)")

        let inserted = changes[0]
        try expect(inserted.kind == .added && inserted.lines == 4...5,
                   "the insertion is not marked on its own lines: \(inserted)")
        let edited = changes[1]
        try expect(edited.kind == .modified && edited.lines == 11...11
                    && edited.removed == ["was this"] && edited.added == ["is now this"],
                   "the rewritten line did not keep both sides: \(edited)")
        let removedRun = changes[2]
        // Git reports a pure deletion as `+N,0`, where N is the line it came
        // *after* — verified against git itself — so the mark belongs on N+1,
        // the line that now sits where the deleted ones were.
        try expect(removedRun.kind == .deleted && removedRun.lines == 21...21
                    && removedRun.removed.count == 2 && removedRun.added.isEmpty,
                   "the deletion is not pinned to the following line: \(removedRun)")

        // Lookup is by line, which is what the gutter and the popover both use.
        try expect(GitLineChanges.change(at: 5, in: changes)?.kind == .added,
                   "the second inserted line is not covered")
        try expect(GitLineChanges.change(at: 6, in: changes) == nil,
                   "an untouched line claims a change")

        // Against a real repository, a saved edit shows up on the right line.
        let root = try temporaryDirectory("gutter-marks")
        defer { try? FileManager.default.removeItem(at: root) }
        try expect(GitService.run(["init", "-q"], in: root).code == 0, "git init failed")
        _ = GitService.run(["config", "user.name", "Puzzle Test"], in: root)
        _ = GitService.run(["config", "user.email", "puzzle@example.invalid"], in: root)
        let file = root.appendingPathComponent("App.swift")
        try Data("one\ntwo\nthree\n".utf8).write(to: file)
        _ = GitService.stageAll(in: root)
        try expect(GitService.commit("base", in: root).code == 0, "commit failed")
        try Data("one\nTWO\nthree\nfour\n".utf8).write(to: file)
        let live = GitLineChanges.changes(for: file, in: root)
        try expect(live.contains { $0.kind == .modified && $0.lines == 2...2 },
                   "the edited line is not marked: \(live)")
        try expect(live.contains { $0.kind == .added && $0.lines == 4...4 },
                   "the appended line is not marked: \(live)")
        // A file with nothing uncommitted has no marks at all.
        _ = GitService.stageAll(in: root)
        _ = GitService.commit("second", in: root)
        try expect(GitLineChanges.changes(for: file, in: root).isEmpty,
                   "a clean file still reports marks")

        // The popover says what happened, in both directions.
        let popover = GitChangePopoverController(change: edited)
        _ = popover.view
        let text = popover.contentForTesting
        try expect(text.contains("Line 11 modified") && text.contains("- was this")
                    && text.contains("+ is now this"),
                   "the popover does not explain the change: \(text.debugDescription)")

        // Clicking the gutter opens that change, and only where one exists.
        let textView = PuzzleTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let ruler = LineNumberRulerView(textView: textView)
        ruler.gitChanges = changes
        var opened: GitLineChanges.Change?
        ruler.onChangeClicked = { change, _ in opened = change }
        try expect(ruler.clickChangeForTesting(at: 11), "line 11 has no mark to click")
        try expect(opened == edited, "the click opened the wrong change")
        try expect(!ruler.clickChangeForTesting(at: 6),
                   "an unchanged line responded to a click")
    }

    /// Views cache the colours they are built with, so a pane has to be painted
    /// in the palette whatever order the app started in.
    private static func testThemeIsReadyBeforeAnyView() throws {
        let pane = EditorPaneViewController()
        _ = pane.view
        try expect(sameColor(pane.editorBackgroundForTesting, Theme.editorBackground),
                   "a pane built after the theme loaded is painted in another palette")
        try expect(sameColor(pane.editorBackgroundForTesting, Theme.panelBackground),
                   "the code area is not the panel's surface")

        // The band on the active line is the tree's active row, and it is
        // lighter than the code behind it — the two must not swap.
        func luminance(_ color: NSColor) -> CGFloat {
            guard let c = color.usingColorSpace(.sRGB) else { return 0 }
            return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        }
        try expect(sameColor(Theme.lineHighlight, Theme.activeRow),
                   "the active line is not the tree's active row")
        try expect(luminance(Theme.lineHighlight) > luminance(Theme.editorBackground),
                   "the active line is darker than the code area, so they read as swapped")

        // The delegate prepares them before any window: openFiles: arrives
        // first when Finder or `pz` starts the app with a project.
        let delegate = AppDelegate()
        delegate.applicationWillFinishLaunching(
            Notification(name: NSApplication.willFinishLaunchingNotification))
        try expect(delegate.settingsPreparedForTesting,
                   "settings are not loaded before the first window can be built")
    }

    /// Uncommitted changes are marked in the gutter, and a mark opens the diff
    /// behind it.
    private static func testGutterMarksUncommittedChanges() throws {
        let root = try temporaryDirectory("gutter-marks")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = GitService.run(["init", "-q", "-b", "main"], in: root)
        _ = GitService.run(["config", "user.name", "T"], in: root)
        _ = GitService.run(["config", "user.email", "t@e.invalid"], in: root)
        let file = root.appendingPathComponent("sample.swift")
        try Data("one\ntwo\nthree\nfour\nfive\n".utf8).write(to: file)
        _ = GitService.commit("base", in: root)
        // Line 2 modified, "four" deleted, a line added at the end. The
        // deletion is kept away from the edit: adjacent ones are a single hunk
        // to Git, and correctly report as one modification.
        try Data("one\nTWO CHANGED\nthree\nfive\nsix added\n".utf8).write(to: file)

        // Puzzle stages changes as they are made, so the marks must come from
        // a diff against HEAD — against the index they would all vanish, which
        // is exactly what happened in normal use.
        _ = GitService.stageAll(in: root)
        let changes = GitLineChanges.changes(for: file, in: root)
        let kinds = changes.map(\.kind)
        try expect(kinds.contains(.modified), "a modified line was not marked: \(changes)")
        try expect(kinds.contains(.added), "an added line was not marked: \(changes)")
        try expect(kinds.contains(.deleted), "a deletion was not marked: \(changes)")
        guard let modified = changes.first(where: { $0.kind == .modified }) else {
            throw Failure(description: "no modified change")
        }
        try expect(modified.removed == ["two"] && modified.added == ["TWO CHANGED"],
                   "the modified mark does not carry both sides: \(modified)")

        // They reach the pane and the gutter, off the main thread.
        let pane = EditorPaneViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = pane
        defer { window.close() }
        pane.repositoryRoot = root
        pane.open(url: file)
        pane.view.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(5)
        while pane.gitLineChangesForTesting.isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        try expect(pane.gitLineChangesForTesting.count == changes.count,
                   "the editor shows \(pane.gitLineChangesForTesting.count) of "
                    + "\(changes.count) marks")
        guard let ruler = pane.lineNumberRulerForTesting else {
            throw Failure(description: "the editor has no gutter")
        }
        try expect(ruler.gitChanges.count == changes.count,
                   "the gutter did not receive the marks")

        // The ribbon is on the outer edge, clear of the fold arrow's column,
        // so a changed line can still be folded.
        // The ruler only paints the fragments inside the text view's visible
        // rect, so give it a laid-out window before asking what it drew.
        window.setContentSize(NSSize(width: 700, height: 300))
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        ruler.needsDisplay = true
        ruler.displayIfNeeded()
        try expect(!ruler.changeMarkBarsForTesting.isEmpty,
                   "the gutter drew no ribbons, so the geometry below proves nothing")
        // Three targets share the gutter and none may overlap: the split
        // divider's drag handle reaches in from the left, the fold arrow owns
        // the right, and the ribbon plus the numbers sit between them.
        let arrowColumn = ruler.ruleThickness - LineNumberRulerView.foldArrowColumn
        let dividerReach = LineNumberRulerView.dividerReach
        try expect(dividerReach >= SplitDividerHandleView.hitWidth / 2,
                   "the ribbon column starts inside the divider's drag handle")
        try expect(ruler.changeMarkTargetsForTesting.allSatisfy { $0.maxX <= arrowColumn },
                   "a change target reaches into the fold arrow's column: "
                    + "\(ruler.changeMarkTargetsForTesting)")
        try expect(ruler.changeMarkTargetsForTesting.allSatisfy { $0.minX >= dividerReach },
                   "a change target reaches into the divider's drag handle: "
                    + "\(ruler.changeMarkTargetsForTesting)")
        try expect(ruler.changeMarkTargetsForTesting.allSatisfy { $0.width >= 20 },
                   "the change target is too small to hit: "
                    + "\(ruler.changeMarkTargetsForTesting.map(\.width))")
        try expect(ruler.changeMarkBarsForTesting.allSatisfy { $0.minX == dividerReach },
                   "the ribbon is not just past the divider handle: "
                    + "\(ruler.changeMarkBarsForTesting)")
        // Under the pointer the ribbon grows to the right, into the gap it was
        // given — never under the numbers.
        try expect(LineNumberRulerView.changeMarkHoverWidth
                    > LineNumberRulerView.changeMarkWidth,
                   "the ribbon does not widen on hover")
        try expect(dividerReach + LineNumberRulerView.changeMarkHoverWidth
                    <= LineNumberRulerView.numberColumn(digits: 2).start,
                   "the hovered ribbon reaches into the line numbers")
        // The width eases between the two sizes rather than jumping.
        try expect(LineNumberRulerView.markWidth(progress: 0)
                    == LineNumberRulerView.changeMarkWidth,
                   "the transition does not start at the resting width")
        try expect(LineNumberRulerView.markWidth(progress: 1)
                    == LineNumberRulerView.changeMarkHoverWidth,
                   "the transition does not end at the hovered width")
        let midpoint = LineNumberRulerView.markWidth(progress: 0.5)
        try expect(midpoint > LineNumberRulerView.changeMarkWidth
                    && midpoint < LineNumberRulerView.changeMarkHoverWidth,
                   "the midpoint is outside the two widths: \(midpoint)")
        try expect(midpoint > (LineNumberRulerView.changeMarkWidth
                                + LineNumberRulerView.changeMarkHoverWidth) / 2,
                   "the easing is not front-loaded, so the ribbon lags the pointer")
        try expect(LineNumberRulerView.markWidth(progress: -1)
                    == LineNumberRulerView.changeMarkWidth
                    && LineNumberRulerView.markWidth(progress: 2)
                        == LineNumberRulerView.changeMarkHoverWidth,
                   "progress outside 0...1 is not clamped")

        ruler.hoverChangeForTesting(at: 2)
        try expect(ruler.hoverIsAnimatingForTesting,
                   "hovering did not start the transition")
        // Let it run rather than reading a half-drawn frame.
        ruler.settleHoverForTesting()
        ruler.needsDisplay = true
        ruler.displayIfNeeded()
        let hovered = ruler.changeMarkBarsForTesting
        try expect(hovered.contains { $0.width == LineNumberRulerView.changeMarkHoverWidth },
                   "hovering a change did not widen its ribbon: \(hovered.map(\.width))")
        try expect(hovered.contains { $0.width == LineNumberRulerView.changeMarkWidth },
                   "every ribbon widened, not just the hovered one: \(hovered.map(\.width))")
        ruler.hoverChangeForTesting(at: nil)
        // Four-digit line numbers still fit between the ribbon and the arrow.
        let numbers = LineNumberRulerView.numberColumn(digits: 4)
        let digits = ("8888" as NSString).size(withAttributes: [.font: Theme.editorFont()]).width
        try expect(numbers.end - numbers.start >= digits,
                   "the number column lost too much room: "
                    + "\(numbers.end - numbers.start)pt for \(digits)pt of digits")


        // Clicking a marked line asks for its diff; an unmarked one does not.
        try expect(ruler.clickChangeForTesting(at: modified.lines.lowerBound),
                   "clicking a marked line did nothing")
        try expect(!ruler.clickChangeForTesting(at: 1),
                   "an unchanged line offered a change to open")

        // The popover shows what HEAD had and what is there now.
        let popover = GitChangePopoverController(change: modified)
        _ = popover.view
        try expect(popover.contentForTesting.contains("two")
                    && popover.contentForTesting.contains("TWO CHANGED"),
                   "the popover does not show both sides: \(popover.contentForTesting)")

        // Committing clears them.
        _ = GitService.commit("second", in: root)
        pane.refreshGitLineChanges()
        let cleared = Date().addingTimeInterval(5)
        while !pane.gitLineChangesForTesting.isEmpty && Date() < cleared {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        try expect(pane.gitLineChangesForTesting.isEmpty,
                   "the marks outlived the commit that made them history")
    }

    private static func testChangesRowsSurviveRefreshes() throws {
        let directory = try temporaryDirectory("changes-rows")
        defer { try? FileManager.default.removeItem(at: directory) }
        let panel = GitPanelViewController()
        _ = panel.view
        panel.setDirectoryForTesting(directory)

        func entry(_ path: String, _ code: String) -> GitService.Status.Entry {
            GitService.Status.Entry(code: code, path: path, originalPath: nil)
        }
        let status = GitService.Status(branch: "main",
                                       entries: [entry("a.swift", " M"), entry("b.swift", "??")],
                                       isRepo: true, userName: "T",
                                       ahead: 0, hasUpstream: true)
        panel.applyStatusForTesting(status, in: directory)
        try expect(!panel.reloadWouldRebuildForTesting,
                   "the rows were left needing a rebuild right after one")

        // The same status again — a build touching files fires these constantly.
        panel.applyStatusForTesting(status, in: directory)
        try expect(!panel.reloadWouldRebuildForTesting,
                   "an identical refresh still wanted to rebuild the rows, "
                    + "which is what swallowed clicks on the row buttons")

        // A real change still rebuilds.
        let changed = GitService.Status(branch: "main",
                                        entries: [entry("a.swift", " M")],
                                        isRepo: true, userName: "T",
                                        ahead: 0, hasUpstream: true)
        panel.applyStatusForTesting(changed, in: directory)
        try expect(panel.rowCountForTesting == 1,
                   "a changed status did not reach the table: \(panel.rowCountForTesting)")

        // Row actions are a right-click away, and the row itself is just the
        // file: no buttons to miss, and none competing with a long name.
        guard let changesMenu = panel.contextMenuForTesting(row: 0) else {
            throw Failure(description: "a changed file has no context menu")
        }
        let changeTitles = changesMenu.items.map(\.title)
        for expected in ["Show Changes", "Open File", "Copy Path", "Reveal in Finder",
                         "Discard Changes…"] {
            try expect(changeTitles.contains(expected),
                       "the row menu is missing \(expected): \(changeTitles)")
        }

        // Hovering lights the row under the pointer, as in the file tree.
        try expect(panel.hoverForTesting(row: 0),
                   "a row does not light up under the pointer")

        // Branch and History are lists to read: the commit box and its buttons
        // belong to Changes and stay there.
        try expect(panel.footerVisibleForTesting, "Changes lost its commit footer")
        panel.showHistory()
        try expect(!panel.footerVisibleForTesting,
                   "History still shows the commit box below its list")
        panel.showBranchTab()
        try expect(!panel.footerVisibleForTesting, "Branch shows the commit box")
        panel.showChangesForTesting()
        try expect(panel.footerVisibleForTesting, "Changes did not get its footer back")

        // Every row in the panel is one tree row: a changed file, a branch and
        // a commit all scan the same way down the list.
        try expect(panel.rowHeightForTesting(0) == Theme.treeRowHeight(),
                   "a file row is \(panel.rowHeightForTesting(0))pt, not one tree row")
        panel.showBranchTab()
        try expect(panel.rowHeightForTesting(0) == Theme.treeRowHeight(),
                   "a branch row is \(panel.rowHeightForTesting(0))pt, not one tree row")
        panel.showHistory()
        try expect(panel.rowHeightForTesting(0) == Theme.treeRowHeight(),
                   "a commit row is \(panel.rowHeightForTesting(0))pt, not one tree row")
        panel.showChangesForTesting()
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
        guard let mergeIndex = log.firstIndex(where: { $0.parents.count == 2 }) else {
            throw Failure(description: "no merge commit carried two parents: "
                            + "\(log.map { ($0.subject, $0.parents) })")
        }
        try expect(log.first?.refLabels == ["main"],
                   "the branch label was not read from the log: \(log.first?.refs ?? "-")")
        try expect(log.last?.parents.isEmpty == true,
                   "the root commit was given a parent: \(log.last?.parents ?? [])")

        // The panel builds one row per commit.
        let panel = GitPanelViewController()
        _ = panel.view
        panel.setDirectory(root)
        panel.showHistoryForTesting()
        let deadline = Date().addingTimeInterval(5)
        while panel.historyRowIsCommitForTesting.count < log.count && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        try expect(panel.historyRowIsCommitForTesting.allSatisfy { $0 },
                   "unexpanded history showed something other than commits")
    }

    /// `status` reads porcelain v2 and reports what v1 did, from one
    /// subprocess instead of seven.
    /// Branch and History rows are one line: the thing itself on the left, who
    /// and when on the right, and everything that no longer fits one hover
    /// away. History rows also lost their chevron — the row is the control —
    /// and the lane graph beside them.
    /// Commit needs both halves: something changed, and something said about
    /// it. The button used to accept the click either way and answer with an
    /// alert, or commit nothing at all.
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

        // And it reaches the line above the commit box.
        let panel = GitPanelViewController()
        _ = panel.view
        panel.applyStatusForTesting(refreshed, in: root)
        try expect(panel.headerLabelForTesting.contains("Second Name"),
                   "the commit header still shows the old identity: "
                    + panel.headerLabelForTesting)
    }

    private static func testSearchFieldClearAndAlignment() throws {
        let input = SearchInputView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        input.placeholder = "Search…"
        input.layoutSubtreeIfNeeded()
        try expect(!input.showsClearButtonForTesting,
                   "an empty field offers something to clear")

        var reported: [String] = []
        input.onChange = { text, _ in reported.append(text) }
        input.stringValue = "needle"
        input.layoutSubtreeIfNeeded()
        try expect(input.showsClearButtonForTesting,
                   "a field with a query has no clear button")
        input.clickClearForTesting()
        try expect(input.stringValue.isEmpty, "clearing left the query behind")
        try expect(reported == [""],
                   "clearing did not report the empty query: \(reported)")
        try expect(!input.showsClearButtonForTesting,
                   "the clear button stayed after the field was emptied")

        // At rest the ✕ is a mark like the glyphs beside it, with nothing
        // behind it; the background belongs to hover alone. A filled disc read
        // as a blob in a row of thin glyphs.
        input.stringValue = "needle"
        input.layoutSubtreeIfNeeded()
        /// `colorAt` indexes device pixels from the top-left; the caller works
        /// in the view's own points, which on this display are half of them.
        func pixel(at point: NSPoint) throws -> NSColor {
            input.displayIfNeeded()
            guard let rep = input.bitmapImageRepForCachingDisplay(in: input.bounds) else {
                throw Failure(description: "the field would not render")
            }
            input.cacheDisplay(in: input.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / max(1, input.bounds.width)
            guard let colour = rep.colorAt(x: Int(point.x * scale),
                                           y: Int((input.bounds.height - point.y) * scale)) else {
                throw Failure(description: "no pixel at \(point)")
            }
            return colour.usingColorSpace(.sRGB) ?? colour
        }
        func matches(_ a: NSColor, _ b: NSColor) -> Bool {
            abs(a.redComponent - b.redComponent) < 0.02
                && abs(a.greenComponent - b.greenComponent) < 0.02
                && abs(a.blueComponent - b.blueComponent) < 0.02
        }
        let clear = input.clearFrameForTesting
        // Inside the disc but clear of the cross, which is only 7pt across.
        let edge = NSPoint(x: clear.midX - 6, y: clear.midY)
        let background = Theme.inputBackground.usingColorSpace(.sRGB)!
        input.setClearHoveredForTesting(false)
        let atRest = try pixel(at: edge)
        try expect(matches(atRest, background),
                   "the clear button paints a background when it is not hovered")
        input.setClearHoveredForTesting(true)
        let hovered = try pixel(at: edge)
        try expect(!matches(hovered, background),
                   "hovering the clear button did not light it up")
        input.setClearHoveredForTesting(false)
        input.stringValue = ""

        // The find bar wires the same field, and its chevron lines up with it.
        let bar = FindBarView(frame: NSRect(x: 0, y: 0, width: 520, height: 42))
        let textView = PuzzleTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        textView.string = "let value = 1\n"
        bar.attach(to: textView)
        bar.setQuery("value")
        bar.layoutSubtreeIfNeeded()
        let alignment = bar.rowAlignmentForTesting
        try expect(abs(alignment.toggle.midY - alignment.input.midY) <= 0.5,
                   "the replace chevron is \(alignment.toggle.midY) against the "
                    + "field's \(alignment.input.midY)")
        try expect(bar.queryInputForTesting.showsClearButtonForTesting,
                   "the find bar's field has no clear button")
        bar.queryInputForTesting.clickClearForTesting()
        try expect(bar.retainedMatchCountForTesting == 0,
                   "clearing the find bar left its matches highlighted")
    }

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

        let panel = GitPanelViewController()
        _ = panel.view
        try expect(!panel.commitEnabledForTesting,
                   "Commit was live before a repository was even loaded")

        // A clean repository with a message typed into it still has nothing to
        // commit.
        panel.applyStatusForTesting(
            GitService.Status(branch: "main", entries: [], isRepo: true), in: root)
        panel.setCommitMessageForTesting("a message")
        try expect(!panel.commitEnabledForTesting,
                   "Commit was available with nothing changed")

        // Changes with no message: still not a commit.
        let entry = GitService.Status.Entry(code: " M", path: "file.txt", originalPath: nil)
        panel.setCommitMessageForTesting("")
        panel.applyStatusForTesting(
            GitService.Status(branch: "main", entries: [entry], isRepo: true), in: root)
        try expect(!panel.commitEnabledForTesting,
                   "Commit was available with no message")
        panel.setCommitMessageForTesting("   \n  ")
        try expect(!panel.commitEnabledForTesting,
                   "whitespace counted as a commit message")

        // Both halves present.
        panel.setCommitMessageForTesting("real message")
        try expect(panel.commitEnabledForTesting,
                   "Commit stayed unavailable with changes and a message")

        // And it goes back as soon as either half is taken away.
        panel.applyStatusForTesting(
            GitService.Status(branch: "main", entries: [], isRepo: true), in: root)
        try expect(!panel.commitEnabledForTesting,
                   "Commit stayed live after the changes were committed away")
    }

    private static func testOneLinePanelRows() throws {
        let root = try temporaryDirectory("one-line-rows")
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) { _ = GitService.run(args, in: root) }
        git(["init", "-q", "-b", "main"])
        git(["config", "user.name", "Ada Lovelace"])
        git(["config", "user.email", "ada@example.invalid"])
        try Data("one\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        git(["add", "-A"])
        git(["commit", "-q", "-m", "the subject line"])

        let panel = GitPanelViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = panel
        defer { window.close() }
        panel.setDirectory(root)
        panel.showHistory()
        let deadline = Date().addingTimeInterval(5)
        while panel.rowCountForTesting == 0 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        try expect(panel.rowCountForTesting == 1,
                   "history shows \(panel.rowCountForTesting) rows for one commit")
        let commitRow = panel.rowTextForTesting(0)
        try expect(commitRow.leading == "the subject line",
                   "the commit message is not the left of the row: \(commitRow.leading)")
        try expect(commitRow.trailing.contains("Ada Lovelace"),
                   "the author is not on the right: \(commitRow.trailing)")
        try expect(!commitRow.trailing.isEmpty
                    && commitRow.trailing != "Ada Lovelace",
                   "the time is missing from the right: \(commitRow.trailing)")
        let hash = GitService.run(["rev-parse", "--short", "HEAD"], in: root)
            .out.trimmingCharacters(in: .whitespacesAndNewlines)
        for detail in [hash, "main", "the subject line", "Ada Lovelace"] {
            try expect(commitRow.hover.contains(detail),
                       "hovering a commit does not reveal \(detail): \(commitRow.hover)")
        }

        // Clicking the row is what expands it, so its files appear underneath.
        panel.expandCommit(at: 0)
        let expanded = Date().addingTimeInterval(5)
        while panel.rowCountForTesting < 2 && Date() < expanded {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        try expect(panel.rowCountForTesting == 2,
                   "clicking a commit did not open its files: \(panel.rowCountForTesting)")
        panel.expandCommit(at: 0)
        try expect(panel.rowCountForTesting == 1, "clicking again did not close it")

        panel.showBranchTab()
        let branched = Date().addingTimeInterval(5)
        while panel.rowCountForTesting == 0 && Date() < branched {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let branchRow = panel.rowTextForTesting(0)
        try expect(branchRow.leading.hasPrefix("main"),
                   "the branch name is not the left of the row: \(branchRow.leading)")
        try expect(branchRow.trailing.contains("Ada Lovelace"),
                   "the branch row does not carry its author: \(branchRow.trailing)")
    }

    private static func testStatusMatchesPorcelainV1() throws {
        let root = try temporaryDirectory("status-v2")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = GitService.run(["init", "-q", "-b", "main"], in: root)
        _ = GitService.run(["config", "user.name", "Puzzle Test"], in: root)
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
        try expect(status.userName == "Puzzle Test",
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

    /// Leaving a buffer writes it: switching tabs, switching panes, clicking
    /// out of the editor, or leaving the window. Saving used to be entirely on
    /// the user, so an edit survived only if they remembered ⌘S.
    private static func testAutosaveOnFocusChange() throws {
        let root = try temporaryDirectory("autosave")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.txt")
        let second = root.appendingPathComponent("second.txt")
        try Data("first\n".utf8).write(to: first)
        try Data("second\n".utf8).write(to: second)

        let editor = EditorViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = editor
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        editor.open(url: first)
        editor.open(url: second)
        guard let pane = editor.activePaneForTesting else {
            throw Failure(description: "the editor has no pane")
        }
        pane.activate(index: 0)
        pane.setCaretForTesting(0)
        pane.insertTextForTesting("EDIT ")
        try expect(pane.isModifiedForTesting, "the edit did not reach the buffer")

        // Switching tabs saves what is being left behind.
        pane.activate(index: 1)
        var onDisk = try String(contentsOf: first, encoding: .utf8)
        try expect(onDisk == "EDIT first\n",
                   "switching tabs did not save the file: \(onDisk.debugDescription)")

        // Clicking out of the editor saves too, one main-queue hop later.
        pane.activate(index: 1)
        pane.setCaretForTesting(0)
        pane.insertTextForTesting("AGAIN ")
        try expect(pane.focusEditorForTesting(), "the editor could not take focus")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        onDisk = try String(contentsOf: second, encoding: .utf8)
        try expect(onDisk == "AGAIN second\n",
                   "losing focus did not save the file: \(onDisk.debugDescription)")
        field.removeFromSuperview()

        // Leaving the window writes every pane's buffer — what
        // `windowDidResignKey` calls when the user clicks another window or
        // switches apps.
        pane.activate(index: 1)
        pane.setCaretForTesting(0)
        pane.insertTextForTesting("LEFT ")
        editor.autosaveAll()
        onDisk = try String(contentsOf: second, encoding: .utf8)
        try expect(onDisk == "LEFT AGAIN second\n",
                   "leaving the window did not save: \(onDisk.debugDescription)")

        // A file that changed underneath the edit is never overwritten in
        // silence: the buffer stays dirty and waits to be asked about.
        pane.activate(index: 0)
        pane.setCaretForTesting(0)
        pane.insertTextForTesting("MINE ")
        try Data("theirs\n".utf8).write(to: first)
        // The modification date has one-second resolution on some volumes.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: first.path)
        pane.autosaveIfNeeded()
        onDisk = try String(contentsOf: first, encoding: .utf8)
        try expect(onDisk == "theirs\n",
                   "autosave overwrote a file that changed on disk: \(onDisk.debugDescription)")
        try expect(pane.isModifiedForTesting,
                   "the buffer was marked saved even though nothing was written")
    }

    /// Return carries the indent, Shift-Return opens an indented line below
    /// from anywhere on the current one, and Command-D copies the line.
    private static func testLineEditingShortcuts() throws {
        let textView = PuzzleTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags,
                 _ characters: String) throws -> NSEvent {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code) else {
                throw Failure(description: "could not construct a key event")
            }
            return event
        }

        // Return at the end of an indented line starts the next one under it.
        textView.string = "func f() {\n    let value = 1\n}"
        textView.setSelectedRange(NSRange(location: 28, length: 0))   // end of line 2
        textView.insertNewline(nil)
        try expect(textView.string == "func f() {\n    let value = 1\n    \n}",
                   "Return did not carry the indentation: \(textView.string.debugDescription)")
        try expect(textView.selectedRange().location == 33,
                   "the caret did not land after the carried indent")

        // Returning from inside an indent carries only the part before the
        // caret, so the text below keeps the indentation it already had rather
        // than gaining a second copy of it.
        textView.string = "    value"
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        textView.insertNewline(nil)
        try expect(textView.string == "  \n    value",
                   "Return inside the indent duplicated it: \(textView.string.debugDescription)")

        // Shift-Return works from the middle of the line, and from its start.
        textView.string = "\tfirst\nsecond"
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        textView.keyDown(with: try key(36, [.shift], "\r"))
        try expect(textView.string == "\tfirst\n\t\nsecond",
                   "Shift-Return did not open an indented line below: "
                    + "\(textView.string.debugDescription)")
        try expect(textView.selectedRange().location == 8,
                   "the caret is not on the new line: \(textView.selectedRange())")

        // Including on a last line that has no terminator of its own.
        textView.string = "  last"
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        try expect(textView.insertLineBelow() && textView.string == "  last\n  ",
                   "Shift-Return on an unterminated final line: "
                    + "\(textView.string.debugDescription)")

        // Command-D copies the caret's line and keeps the caret's column.
        textView.string = "one\n    two\nthree"
        textView.setSelectedRange(NSRange(location: 8, length: 0))    // inside "two"
        textView.keyDown(with: try key(2, [.command], "d"))
        try expect(textView.string == "one\n    two\n    two\nthree",
                   "Command-D did not copy the line: \(textView.string.debugDescription)")
        try expect(textView.selectedRange().location == 16,
                   "the caret did not follow the copy: \(textView.selectedRange())")

        // A selection spanning lines copies all of them, once.
        textView.string = "a\nb\nc"
        textView.setSelectedRange(NSRange(location: 0, length: 3))
        try expect(textView.duplicateCurrentLine() && textView.string == "a\nb\na\nb\nc",
                   "Command-D over a selection: \(textView.string.debugDescription)")
    }

    /// The gutter marks the buffer, not the file on disk. They used to appear
    /// only after a save, which is exactly when they stop being useful.
    private static func testGitMarksFollowUnsavedEdits() throws {
        let root = try temporaryDirectory("live-marks")
        _ = GitService.run(["init", "-q", "-b", "main"], in: root)
        _ = GitService.run(["config", "user.name", "T"], in: root)
        _ = GitService.run(["config", "user.email", "t@e.invalid"], in: root)
        let file = root.appendingPathComponent("live.swift")
        try Data("one\ntwo\nthree\nfour\n".utf8).write(to: file)
        _ = GitService.stageAll(in: root)
        _ = GitService.commit("base", in: root)

        // The in-process diff has to agree with the one Git prints, or the
        // marks would move under the user the moment they saved.
        let baseline = GitLineChanges.baseline(for: file, in: root)
        try expect(baseline == ["one", "two", "three", "four"],
                   "HEAD's copy did not come back: \(String(describing: baseline))")
        for edited in ["one\nTWO\nthree\nfour\n",
                       "one\ntwo\nthree\nfour\nfive\n",
                       "one\nfour\n",
                       "added\none\ntwo\nthree\nfour\n",
                       "one\ntwo\nthree\n"] {
            try Data(edited.utf8).write(to: file)
            _ = GitService.stageAll(in: root)
            let fromGit = GitLineChanges.changes(for: file, in: root)
            let inProcess = GitLineChanges.changes(from: baseline ?? [],
                                                   to: GitLineChanges.lines(of: edited))
            try expect(fromGit == inProcess,
                       "the in-process diff disagrees with git for "
                        + "\(edited.debugDescription):\n  git: \(fromGit)\n  ours: \(inProcess)")
        }
        try Data("one\ntwo\nthree\nfour\n".utf8).write(to: file)
        _ = GitService.stageAll(in: root)

        // And end to end: type into an open buffer, save nothing, get marks.
        let pane = EditorPaneViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = pane
        defer { window.close() }
        pane.repositoryRoot = root
        pane.open(url: file)
        pane.view.layoutSubtreeIfNeeded()
        let settled = Date().addingTimeInterval(5)
        while !pane.gitLineChangesForTesting.isEmpty && Date() < settled {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        try expect(pane.gitLineChangesForTesting.isEmpty,
                   "an unedited file is marked: \(pane.gitLineChangesForTesting)")

        pane.setCaretForTesting(4)
        pane.insertTextForTesting("EDITED ")
        try expect(pane.isModifiedForTesting, "the edit did not reach the document")
        let deadline = Date().addingTimeInterval(5)
        while pane.gitLineChangesForTesting.isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let marks = pane.gitLineChangesForTesting
        try expect(marks.count == 1 && marks[0].kind == .modified && marks[0].lines == 2...2,
                   "an unsaved edit was not marked on its own line: \(marks)")
        try expect(!pane.isModifiedForTesting == false, "the buffer was saved behind our back")
        let onDisk = try String(contentsOf: file, encoding: .utf8)
        try expect(onDisk == "one\ntwo\nthree\nfour\n",
                   "marking the buffer wrote to the file: \(onDisk.debugDescription)")
    }

    /// The gutter is only as wide as the numbers it has to draw. A fixed
    /// four-digit column cost every short file the same margin.
    private static func testGutterWidthFollowsLineCount() throws {
        typealias Ruler = LineNumberRulerView
        try expect(Ruler.digits(forHighestLine: 1) == Ruler.minimumDigits,
                   "a one-line file collapses the gutter below its floor")
        try expect(Ruler.digits(forHighestLine: 99) == 2, "99 asks for more than two digits")
        try expect(Ruler.digits(forHighestLine: 100) == 3, "100 still asks for two digits")
        try expect(Ruler.digits(forHighestLine: 9999) == 4, "9999 does not ask for four digits")

        let short = Ruler.gutterWidth(digits: Ruler.digits(forHighestLine: 80))
        let long = Ruler.gutterWidth(digits: Ruler.digits(forHighestLine: 4200))
        try expect(short < long - 4, "a short file gets the same gutter as a long one")

        // And the live gutter follows the file it is showing, not a constant.
        let root = try temporaryDirectory("gutter-width")
        let brief = root.appendingPathComponent("brief.txt")
        try Data(String(repeating: "x\n", count: 40).utf8).write(to: brief)
        let bulky = root.appendingPathComponent("bulky.txt")
        try Data(String(repeating: "x\n", count: 1500).utf8).write(to: bulky)

        let pane = EditorPaneViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = pane
        defer { window.close() }
        pane.open(url: brief)
        pane.view.layoutSubtreeIfNeeded()
        guard let ruler = pane.lineNumberRulerForTesting else {
            throw Failure(description: "the editor has no gutter")
        }
        ruler.displayIfNeeded()
        let briefWidth = ruler.ruleThickness
        pane.open(url: bulky)
        pane.view.layoutSubtreeIfNeeded()
        ruler.displayIfNeeded()
        let bulkyWidth = ruler.ruleThickness
        try expect(briefWidth < bulkyWidth,
                   "the gutter is \(briefWidth)pt for 40 lines and \(bulkyWidth)pt for 1500")
        try expect(briefWidth == Ruler.gutterWidth(digits: 2),
                   "a 40-line file does not get the two-digit gutter: \(briefWidth)pt")
        try expect(bulkyWidth == Ruler.gutterWidth(digits: 4),
                   "a 1500-line file does not get the four-digit gutter: \(bulkyWidth)pt")

        // Whatever the width, the numbers keep a column of their own between
        // the ribbon and the fold arrow.
        for line in [1, 9, 10, 99, 100, 1000, 99999] {
            let digits = Ruler.digits(forHighestLine: line)
            let column = Ruler.numberColumn(digits: digits)
            try expect(column.start >= Ruler.dividerReach + Ruler.changeMarkHoverWidth,
                       "line numbers run under the change ribbon at \(line) lines")
            try expect(column.end > column.start,
                       "the number column is empty at \(line) lines")
            let value = "\(line)" as NSString
            let drawn = value.size(withAttributes: [.font: Theme.editorFont()]).width
            try expect(column.end - column.start >= drawn - 0.5,
                       "line \(line) does not fit its own column")
        }
    }

    /// The three strips that show a selection — the activity bar, the Git
    /// panel's tabs, the file tabs — say it the same way, and loudly enough.
    private static func testSelectedControlsAgree() throws {
        func luminance(_ colour: NSColor) -> CGFloat {
            guard let c = colour.usingColorSpace(.sRGB) else { return 0 }
            return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        }

        do {
            let strips = [ActivityBarView.selectedColoursForTesting,
                          EditorTabBar.selectedColoursForTesting,
                          GitPanelViewController.selectedTabColoursForTesting]
            for strip in strips.dropFirst() {
                try expect(sameColor(strip.surface, strips[0].surface)
                            && sameColor(strip.ink, strips[0].ink),
                           "the strips disagree about selection")
            }
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

        // A window opens with room for the Git panel's rows.
        try expect(RootViewController.defaultSidebarWidth == 500,
                   "the sidebar no longer opens at 500pt")
        try expect(RootViewController.defaultSidebarWidth
                    >= RootViewController.minimumSidebarWidth,
                   "the default sidebar width is below its own floor")
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
        let rows = SideBySideDiff.rows(from: diff)
        // Hunk header, context, the paired change block, context, hunk, …
        try expect(rows.first?.kind == .hunk,
                   "the first row is not the hunk header: \(String(describing: rows.first))")
        let firstContext = rows[1]
        try expect(firstContext.leftNumber == 10 && firstContext.rightNumber == 10
                    && firstContext.leftText == "context ten",
                   "context lines are not numbered on both sides: \(firstContext)")

        // One removed against two added: the pair lines up, the extra addition
        // gets an empty left side rather than shifting everything down.
        let changes = rows.filter(\.isChange)
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
                   "the two sides do not count their own lines: \(changes.map(\.rightNumber))")
        // The step buttons see the same two blocks the unified view does.
        try expect(SideBySideDiff.changeBlockStarts(rows).count == 2,
                   "change blocks: \(SideBySideDiff.changeBlockStarts(rows))")

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

        // In the pane, switching swaps which view is on screen and keeps the
        // change count, then steps through the same blocks.
        let directory = try temporaryDirectory("side-by-side")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pane = EditorPaneViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = pane
        defer { window.close() }
        let url = URL(string:
            "puzzle-diff:///repo/.puzzle-diff-preview?window=sbs&path=Sources/App.swift")!
        DocumentStore.shared.setVirtualDocument(url: url, text: diff,
                                                displayName: "App.swift (diff)")
        pane.open(url: url, replacingContent: true)
        pane.view.layoutSubtreeIfNeeded()
        try expect(!pane.sideBySideVisibleForTesting,
                   "a diff opened side by side without being asked")

        pane.toggleDiffModeForTesting()
        pane.view.layoutSubtreeIfNeeded()
        try expect(pane.sideBySideVisibleForTesting,
                   "the mode button did not bring up the two-column view")
        try expect(pane.diffHeaderForTesting.summaryForTesting == "2 changes",
                   "the header lost its count in side-by-side: "
                    + pane.diffHeaderForTesting.summaryForTesting)
        // A fresh diff starts at its first line: a clip view left alone keeps
        // its origin at the bottom, which opened every diff on its last row.
        guard let geometry = pane.sideBySideGeometryForTesting else {
            throw Failure(description: "the side-by-side view reported no geometry")
        }
        try expect(geometry.rows == rows.count,
                   "the view shows \(geometry.rows) of \(rows.count) parsed rows")
        try expect(geometry.contentHeight >= CGFloat(rows.count) * Theme.lineMetrics().target - 1,
                   "the table is shorter than its rows: \(geometry)")
        try expect(geometry.scrollOffset == 0,
                   "the diff opened scrolled to \(geometry.scrollOffset)")
        pane.diffHeaderForTesting.clickNextForTesting()
        try expect(pane.sideBySideBlockForTesting == 0,
                   "stepping did not move to the first change")

        // A diff taller than the view must actually scroll when stepping, not
        // merely move an index.
        var long = "@@ -1,200 +1,200 @@\n"
        for index in 1...120 { long += " context line \(index)\n" }
        long += "-old tail\n+new tail\n"
        for index in 1...40 { long += " trailing \(index)\n" }
        DocumentStore.shared.setVirtualDocument(url: url, text: long,
                                                displayName: "App.swift (diff)")
        pane.open(url: url, replacingContent: true)
        pane.view.layoutSubtreeIfNeeded()
        let before = pane.sideBySideGeometryForTesting?.scrollOffset ?? -1
        pane.diffHeaderForTesting.clickNextForTesting()
        pane.view.layoutSubtreeIfNeeded()
        let after = pane.sideBySideGeometryForTesting?.scrollOffset ?? -1
        try expect(after > before,
                   "stepping in side-by-side did not scroll: \(before) -> \(after)")
        try expect(pane.sideBySideCurrentRowForTesting != nil,
                   "the change it stepped to is not marked")
        pane.diffHeaderForTesting.clickNextForTesting()
        pane.diffHeaderForTesting.clickNextForTesting()
        try expect(pane.sideBySideBlockForTesting == 0,
                   "stepping past the last change did not wrap")

        pane.toggleDiffModeForTesting()
        pane.view.layoutSubtreeIfNeeded()
        try expect(!pane.sideBySideVisibleForTesting,
                   "switching back did not restore the single-file view")
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

        // Searching inside a folded block opens it. Marking the result where it
        // lay would have drawn a rule across the whole collapsed line: folded
        // text has no glyph run of its own to underline.
        let hiddenMatch = swiftSource.range(of: "nested")
        try expect(NSIntersectionRange(hiddenMatch, blocks[0].hiddenRange).length > 0,
                   "the fixture's match is not inside the folded block")
        let bar = FindBarView(frame: .zero)
        bar.attach(to: textView)
        bar.setQuery("nested")
        try expect(!textView.isFolded(blocks[0]),
                   "a search result inside a fold left the block collapsed")
        layout.ensureLayout(for: container)
        try expect(!layout.isCharacterHidden(at: hiddenMatch.location),
                   "the result stayed hidden after its fold was opened")
        let rules = textView.matchHighlightRectsForTesting()
        try expect(rules.count == 1, "\(rules.count) rules for one visible result")
        try expect(rules[0].width < container.size.width / 2,
                   "the rule is \(rules[0].width)pt wide: it spans the line, not the match")

        // A fold with no result in it is left alone.
        textView.toggleFold(blocks[1])
        bar.setQuery("after")
        try expect(textView.isFolded(blocks[1]),
                   "searching opened a fold that held no result")
    }
}

import AppKit

/// Records why an Objective-C exception took the process down.
///
/// A crash report names the frames but not the exception: AppKit's own layout
/// and display passes throw from inside frameworks, and what reaches the report
/// is `abort() called` with no reason and, when the throw is entirely inside
/// AppKit, no frame of ours to read either. The reason string is the one thing
/// that would say which invariant was violated, and it is thrown away.
///
/// This keeps it. It cannot make the app survive — an uncaught exception is
/// already fatal by the time the handler runs — it only leaves something to
/// read afterwards.
///
/// It does not cover every crash: AppKit reacts to an exception thrown during
/// *view* layout by calling `+[NSApplication _crashOnException:]`, which traps
/// before any handler of ours is consulted. What it does cover is the shape
/// this was written for — an uncaught exception unwinding to `abort()`.
enum ExceptionLog {
    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Puzzle/exceptions.log")
    }

    static func install() {
        NSSetUncaughtExceptionHandler { exception in
            ExceptionLog.record(exception)
        }
    }

    /// Separate from the handler so it can be exercised without raising.
    static func record(_ exception: NSException, at date: Date = Date()) {
        var entry = """

        ── \(ISO8601DateFormatter().string(from: date)) ─────────────────────
        \(exception.name.rawValue)
        \(exception.reason ?? "(no reason given)")

        """
        // The screen layout and the window sizes, because the exceptions worth
        // reading here arrive during a display pass — a wake, a resolution
        // change, a display coming or going.
        entry += "screens: "
            + NSScreen.screens.map { NSStringFromRect($0.frame) }.joined(separator: " ")
            + "\n"
        entry += "windows: "
            + NSApp.windows.map { NSStringFromRect($0.frame) }.joined(separator: " ")
            + "\n"
        entry += exception.callStackSymbols.joined(separator: "\n") + "\n"
        append(entry)
    }

    private static func append(_ text: String) {
        let url = fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}

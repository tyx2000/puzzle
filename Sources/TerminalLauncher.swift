import AppKit

/// Opens a project folder in a terminal: iTerm in a window of its own when it
/// is installed, Terminal otherwise.
enum TerminalLauncher {
    /// Terminals tried, in order.
    static let terminalBundleIDs = ["com.googlecode.iterm2", "com.apple.Terminal"]

    /// The first of those that is installed. Injectable so the preference order
    /// stays testable on a machine with or without iTerm.
    static func terminalApplication(
        lookup: (String) -> URL? = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }
    ) -> URL? {
        terminalBundleIDs.lazy.compactMap(lookup).first
    }

    /// Open a terminal window at `directory`. Opening a folder through
    /// `NSWorkspace` lets iTerm reuse whatever window it already has, so it is
    /// asked for a new one by script, with the plain open as the fallback (no
    /// iTerm, or automation not permitted).
    static func open(at directory: URL) {
        let command = "cd " + shellQuoted(directory.path)
        // Launching iTerm already opens a window; asking for another on top of
        // that is what produced two. Only create one when it was running.
        let reuseLaunchWindow = !isITermRunning
        DispatchQueue.global(qos: .userInitiated).async {
            guard !runITermScript(command: command,
                                  reusingLaunchWindow: reuseLaunchWindow) else { return }
            DispatchQueue.main.async {
                guard let terminal = terminalApplication() else { return }
                NSWorkspace.shared.open([directory], withApplicationAt: terminal,
                                        configuration: NSWorkspace.OpenConfiguration(),
                                        completionHandler: nil)
            }
        }
    }

    static var isITermRunning: Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.googlecode.iterm2").isEmpty
    }

    /// Runs off the main thread: the reuse path waits for the launch window, and
    /// AppleScript execution blocks its caller.
    @discardableResult
    static func runITermScript(command: String, reusingLaunchWindow: Bool) -> Bool {
        guard NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.googlecode.iterm2") != nil else { return false }
        var error: NSDictionary?
        NSAppleScript(source: iTermScript(command: command,
                                          reusingLaunchWindow: reusingLaunchWindow))?
            .executeAndReturnError(&error)
        return error == nil
    }

    /// `reusingLaunchWindow` means iTerm is not running yet: the window its
    /// launch opens is the one to use, so wait for it instead of adding a second.
    static func iTermScript(command: String, reusingLaunchWindow: Bool) -> String {
        let reuse = """
              repeat 50 times
                if (count of windows) > 0 then exit repeat
                delay 0.1
              end repeat
              if (count of windows) > 0 then set targetWindow to current window
            """
        return """
            tell application "iTerm"
              activate
              set targetWindow to missing value
            \(reusingLaunchWindow ? reuse : "")
              if targetWindow is missing value then
                set targetWindow to (create window with default profile)
              end if
              tell current session of targetWindow
                write text "\(appleScriptQuoted(command))"
              end tell
            end tell
            """
    }

    /// Single-quote for the shell: everything inside is literal, and an embedded
    /// quote is closed, escaped and reopened.
    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escape for an AppleScript string literal.
    static func appleScriptQuoted(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

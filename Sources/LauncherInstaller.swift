import Foundation
import Darwin

/// Keeps the `pz` terminal launcher available after a normal Finder/DMG app
/// installation, where Tools/install.sh is never executed.
enum LauncherInstaller {
    private static let marker = "PUZZLE_PZ_LAUNCHER=1"

    /// Installation can briefly start the user's login shell, so never hold up
    /// window creation. Re-running this on every launch also refreshes `pz`
    /// automatically when Puzzle itself is updated.
    static func installIfNeeded() {
        DispatchQueue.global(qos: .utility).async {
            _ = installBundledLauncher()
        }
    }

    @discardableResult
    static func installBundledLauncher() -> URL? {
        guard let source = Bundle.main.url(forResource: "pz", withExtension: nil,
                                           subdirectory: "bin"),
              let launcher = try? Data(contentsOf: source) else { return nil }

        let directories = candidateDirectories()

        // Prefer updating a launcher Puzzle already owns, even if the user's
        // PATH order has changed since it was installed.
        let existing = directories.first { directory in
            let target = directory.appendingPathComponent("pz")
            return FileManager.default.fileExists(atPath: target.path)
                && isPuzzleLauncher(at: target)
                && FileManager.default.isWritableFile(atPath: target.path)
        }

        let directory = existing ?? directories.first(where: writableDirectory)
        guard let directory else { return nil }

        let target = directory.appendingPathComponent("pz")
        if FileManager.default.fileExists(atPath: target.path) {
            // Never silently replace a command belonging to another tool.
            guard isPuzzleLauncher(at: target) else { return nil }
            if (try? Data(contentsOf: target)) == launcher { return target }
        }

        do {
            try launcher.write(to: target, options: .atomic)
            guard chmod(target.path, 0o755) == 0 else { return nil }
            return target
        } catch {
            return nil
        }
    }

    private static func isPuzzleLauncher(at url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        // The second clause recognizes launchers installed by older Puzzle
        // builds, before the explicit ownership marker was added.
        return text.contains(marker)
            || (text.contains("# pz — open a folder") && text.contains("Puzzle.app"))
    }

    private static func writableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && FileManager.default.isWritableFile(atPath: url.path)
            && !FileManager.default.fileExists(atPath: url.appendingPathComponent("pz").path)
    }

    /// Finder-launched apps inherit a minimal PATH, so ask a clean login shell
    /// rather than trusting ProcessInfo.environment.
    private static func candidateDirectories() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let preferred = [
            "/opt/homebrew/bin", "/usr/local/bin",
            "\(home)/.local/bin", "\(home)/bin", "\(home)/go/bin",
        ]
        let loginPath = loginPathDirectories()
        let loginSet = Set(loginPath)

        // Prefer the conventional command locations when they are actually on
        // PATH, then consider every other writable login-PATH directory.
        var ordered = preferred.filter { loginSet.contains($0) } + loginPath
        var seen = Set<String>()
        ordered = ordered.filter { seen.insert($0).inserted }
        return ordered.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private static func loginPathDirectories() -> [String] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", "printf %s \"$PATH\""]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let path = String(data: data, encoding: .utf8) else { return [] }
            return path.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        } catch {
            return []
        }
    }
}

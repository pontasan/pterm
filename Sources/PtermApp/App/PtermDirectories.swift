import Foundation

/// Manages the pterm profile directory structure.
///
/// The default profile root is ~/.pterm, but tests and alternate launch modes can
/// override the root directory so all config/state files resolve beneath a different
/// profile path. Ensures all required directories exist with proper permissions (0700).
enum PtermDirectories {
    private static let overrideLock = NSLock()
    private static var overriddenBaseDirectory: URL?
    private static var cachedTestBaseDirectory: URL?

    /// Base directory: ~/.pterm/ unless explicitly overridden.
    static var base: URL {
        overrideLock.lock()
        let overridden = overriddenBaseDirectory
        overrideLock.unlock()
        return (overridden ?? defaultBaseDirectory()).standardizedFileURL
    }

    /// Config file: ~/.pterm/config.json
    static var config: URL { base.appendingPathComponent("config.json") }

    /// Lock file: ~/.pterm/lock
    static var lock: URL { base.appendingPathComponent("lock") }

    /// Clipboard files: ~/.pterm/files/
    static var files: URL { base.appendingPathComponent("files") }

    /// Session data: ~/.pterm/sessions/
    static var sessions: URL { base.appendingPathComponent("sessions") }
    static var sessionScrollback: URL { sessions.appendingPathComponent("scrollback") }

    /// Audit logs: ~/.pterm/audit/
    static var audit: URL { base.appendingPathComponent("audit") }

    /// Workspace data: ~/.pterm/workspaces/
    static var workspaces: URL { base.appendingPathComponent("workspaces") }

    static var isUsingOverriddenBaseDirectory: Bool {
        overrideLock.lock()
        let overridden = overriddenBaseDirectory != nil
        overrideLock.unlock()
        return overridden
    }

    static func setBaseDirectory(_ directory: URL?) {
        overrideLock.lock()
        overriddenBaseDirectory = directory?.standardizedFileURL
        overrideLock.unlock()
    }

    static func withBaseDirectory<T>(_ directory: URL, _ body: () throws -> T) rethrows -> T {
        overrideLock.lock()
        let previous = overriddenBaseDirectory
        overriddenBaseDirectory = directory.standardizedFileURL
        overrideLock.unlock()
        defer {
            overrideLock.lock()
            overriddenBaseDirectory = previous
            overrideLock.unlock()
        }
        return try body()
    }

    /// Ensure all directories exist with correct permissions.
    ///
    /// After creation, each path is verified via `lstat` (not `stat`) to confirm
    /// it is a real directory and not a symlink. This prevents a TOCTOU attack
    /// where an attacker replaces a directory with a symlink between the existence
    /// check and the use of the path.
    static func ensureDirectories() {
        let fm = FileManager.default
        let dirs = [base, files, sessions, sessionScrollback, audit, workspaces]

        for dir in dirs {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
            } catch {
                fatalError("Failed to create directory \(dir.path): \(error)")
            }

            // Use lstat (not stat) to avoid following symlinks. If the path is
            // a symlink pointing to a directory, stat would report S_IFDIR but
            // lstat correctly reports S_IFLNK, letting us detect the attack.
            var sb = stat()
            guard lstat(dir.path, &sb) == 0 else {
                fatalError("Failed to lstat directory \(dir.path): \(String(cString: strerror(errno)))")
            }
            guard (sb.st_mode & S_IFMT) == S_IFDIR else {
                fatalError("Security violation: \(dir.path) is not a directory (mode=0o\(String(sb.st_mode, radix: 8))). Possible symlink attack.")
            }

            // Enforce 0700 permissions
            let currentPerms = sb.st_mode & 0o7777
            if currentPerms != 0o700 {
                do {
                    try fm.setAttributes([.posixPermissions: 0o700],
                                        ofItemAtPath: dir.path)
                } catch {
                    fatalError("Failed to set permissions on \(dir.path): \(error)")
                }
            }
        }
    }

    private static func defaultBaseDirectory() -> URL {
        if let testBaseDirectory = ProcessInfo.processInfo.environment["PTERM_TEST_BASE_DIR"],
           !testBaseDirectory.isEmpty {
            return URL(fileURLWithPath: testBaseDirectory, isDirectory: true)
        }
        if NSClassFromString("XCTestCase") != nil {
            return prepareTestProcessBaseDirectory()
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pterm", isDirectory: true)
    }

    private static func prepareTestProcessBaseDirectory() -> URL {
        overrideLock.lock()
        defer { overrideLock.unlock() }

        if let cachedTestBaseDirectory {
            return cachedTestBaseDirectory
        }

        let fm = FileManager.default
        let rootDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(".pterm-tests-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let configURL = rootDirectory.appendingPathComponent("config.json")
        if !fm.fileExists(atPath: configURL.path) {
            try? "{}".write(to: configURL, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        }

        cachedTestBaseDirectory = rootDirectory.standardizedFileURL
        return cachedTestBaseDirectory!
    }
}

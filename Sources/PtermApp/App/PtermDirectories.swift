import Foundation

/// Manages the pterm profile directory structure.
///
/// The default profile root is ~/.pterm, but tests and alternate launch modes can
/// override the root directory so all config/state files resolve beneath a different
/// profile path. Ensures all required directories exist with proper permissions (0700).
enum PtermDirectories {
    private static let overrideLock = NSLock()
    private static var overriddenBaseDirectory: URL?

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
    static func ensureDirectories() {
        let fm = FileManager.default
        let dirs = [base, files, sessions, sessionScrollback, audit, workspaces]

        for dir in dirs {
            if !fm.fileExists(atPath: dir.path) {
                do {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                          attributes: [.posixPermissions: 0o700])
                } catch {
                    fatalError("Failed to create directory \(dir.path): \(error)")
                }
            }
        }

        // Verify and enforce 0700 permissions on all directories
        for dir in dirs {
            do {
                let attrs = try fm.attributesOfItem(atPath: dir.path)
                if let perms = attrs[.posixPermissions] as? Int, perms != 0o700 {
                    try fm.setAttributes([.posixPermissions: 0o700],
                                        ofItemAtPath: dir.path)
                }
            } catch {
                // Non-fatal: permissions may already be correct
            }
        }
    }

    private static func defaultBaseDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pterm", isDirectory: true)
    }
}

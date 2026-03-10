import Foundation

/// Manages the ~/.pterm/ directory structure.
///
/// Ensures all required directories exist with proper permissions (0700).
enum PtermDirectories {
    /// Base directory: ~/.pterm/
    static var base: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pterm")
    }

    /// Config file: ~/.pterm/config.json
    static var config: URL { base.appendingPathComponent("config.json") }

    /// Lock file: ~/.pterm/lock
    static var lock: URL { base.appendingPathComponent("lock") }

    /// Clipboard files: ~/.pterm/files/
    static var files: URL { base.appendingPathComponent("files") }

    /// Session data: ~/.pterm/sessions/
    static var sessions: URL { base.appendingPathComponent("sessions") }

    /// Audit logs: ~/.pterm/audit/
    static var audit: URL { base.appendingPathComponent("audit") }

    /// Workspace data: ~/.pterm/workspaces/
    static var workspaces: URL { base.appendingPathComponent("workspaces") }

    /// Ensure all directories exist with correct permissions.
    static func ensureDirectories() {
        let fm = FileManager.default
        let dirs = [base, files, sessions, audit, workspaces]

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
}

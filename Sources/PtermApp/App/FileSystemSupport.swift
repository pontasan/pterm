import Foundation

enum AtomicFileWriter {
    static func write(_ data: Data, to destination: URL, permissions: Int = 0o600) throws {
        let fm = FileManager.default
        let directory = destination.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])

        let tempURL = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        let created = fm.createFile(atPath: tempURL.path, contents: data,
                                    attributes: [.posixPermissions: permissions])
        guard created else {
            throw CocoaError(.fileWriteUnknown)
        }

        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: tempURL)
        } else {
            try fm.moveItem(at: tempURL, to: destination)
        }
        try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: destination.path)
    }
}

enum FileNameSanitizer {
    static func sanitize(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = trimmed.map { character -> Character in
            if character == "/" || character == ":" || character.isNewline {
                return "_"
            }
            return character
        }
        let result = String(sanitized).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? fallback : result
    }
}

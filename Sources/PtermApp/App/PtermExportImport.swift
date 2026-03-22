import AppKit
import Foundation

enum PtermExportImportError: Error {
    case invalidArchive
    case unsafeArchiveEntry(String)
    case commandFailed(String)
}

final class PtermExportImportManager {
    struct ImportPreview {
        let includedItems: [String]
        let overwrittenItems: [String]
    }

    private enum TransferFile {
        static let note = "note.txt"
    }

    private let noteStore: AppNoteStore
    private let fileManager: FileManager
    private let configURL: URL
    private let sessionsURL: URL
    private let workspacesURL: URL
    private let auditURL: URL

    init(noteStore: AppNoteStore,
         fileManager: FileManager = .default,
         configURL: URL = PtermDirectories.config,
         sessionsURL: URL = PtermDirectories.sessions,
         workspacesURL: URL = PtermDirectories.workspaces,
         auditURL: URL = PtermDirectories.audit) {
        self.noteStore = noteStore
        self.fileManager = fileManager
        self.configURL = configURL
        self.sessionsURL = sessionsURL
        self.workspacesURL = workspacesURL
        self.auditURL = auditURL
    }

    func defaultExportURL() -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let name = "pterm-export-\(formatter.string(from: Date())).zip"
        return fileManager.homeDirectoryForCurrentUser.appendingPathComponent(name)
    }

    func exportArchive(to destination: URL) throws {
        let staging = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        try copyIfExists(configURL, to: staging.appendingPathComponent("config.json"))
        try copyDirectoryIfExists(sessionsURL, to: staging.appendingPathComponent("sessions"))
        try copyDirectoryIfExists(workspacesURL, to: staging.appendingPathComponent("workspaces"))
        try copyDirectoryIfExists(auditURL, to: staging.appendingPathComponent("audit"))
        if let note = try noteStore.exportNoteForTransfer() {
            try AtomicFileWriter.write(
                Data(note.utf8),
                to: staging.appendingPathComponent(TransferFile.note),
                permissions: 0o600
            )
        }

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", staging.path, destination.path])
    }

    func importArchive(from archiveURL: URL) throws {
        let extractionRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let backupRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: extractionRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: extractionRoot)
            try? fileManager.removeItem(at: backupRoot)
        }

        try run("/usr/bin/ditto", ["-x", "-k", archiveURL.path, extractionRoot.path])
        guard let extractedRoot = try firstDirectory(in: extractionRoot) else {
            throw PtermExportImportError.invalidArchive
        }
        try validateExtractedArchive(root: extractedRoot)
        let importedNote = try plaintextNote(in: extractedRoot)

        let replacements: [(source: URL, destination: URL)] = [
            (extractedRoot.appendingPathComponent("config.json"), configURL),
            (extractedRoot.appendingPathComponent("sessions"), sessionsURL),
            (extractedRoot.appendingPathComponent("workspaces"), workspacesURL),
            (extractedRoot.appendingPathComponent("audit"), auditURL)
        ]

        var backups: [(original: URL, backup: URL)] = []
        var createdDestinations: [URL] = []
        do {
            for item in replacements where fileManager.fileExists(atPath: item.source.path) {
                let backup = backupRoot.appendingPathComponent(item.destination.lastPathComponent)
                let destinationExisted = fileManager.fileExists(atPath: item.destination.path)
                if fileManager.fileExists(atPath: item.destination.path) {
                    try fileManager.moveItem(at: item.destination, to: backup)
                    backups.append((item.destination, backup))
                }
                try copyReplacing(item.source, to: item.destination)
                if !destinationExisted {
                    createdDestinations.append(item.destination)
                }
            }
            try normalizeImportedPermissions(for: replacements.map(\.destination))
            if let importedNote {
                try noteStore.importTransferredNote(importedNote)
            }
        } catch {
            for created in createdDestinations.reversed() {
                try? fileManager.removeItem(at: created)
            }
            for pair in backups.reversed() {
                try? fileManager.removeItem(at: pair.original)
                try? fileManager.moveItem(at: pair.backup, to: pair.original)
            }
            throw error
        }
    }

    func inspectArchive(_ archiveURL: URL) throws -> ImportPreview {
        let extractionRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: extractionRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: extractionRoot) }

        try run("/usr/bin/ditto", ["-x", "-k", archiveURL.path, extractionRoot.path])
        guard let extractedRoot = try firstDirectory(in: extractionRoot) else {
            throw PtermExportImportError.invalidArchive
        }
        try validateExtractedArchive(root: extractedRoot)

        let candidates: [(label: String, archived: URL, destination: URL)] = [
            ("config.json", extractedRoot.appendingPathComponent("config.json"), configURL),
            ("sessions/", extractedRoot.appendingPathComponent("sessions"), sessionsURL),
            ("workspaces/", extractedRoot.appendingPathComponent("workspaces"), workspacesURL),
            ("audit/", extractedRoot.appendingPathComponent("audit"), auditURL)
        ]

        var included: [String] = candidates.compactMap { candidate -> String? in
            fileManager.fileExists(atPath: candidate.archived.path) ? candidate.label : nil
        }
        var overwritten: [String] = candidates.compactMap { candidate -> String? in
            guard fileManager.fileExists(atPath: candidate.archived.path),
                  fileManager.fileExists(atPath: candidate.destination.path) else {
                return nil
            }
            return candidate.label
        }
        let archivedNoteURL = extractedRoot.appendingPathComponent(TransferFile.note)
        if fileManager.fileExists(atPath: archivedNoteURL.path) {
            included.append(TransferFile.note)
            if noteStore.hasStoredNote() {
                overwritten.append(TransferFile.note)
            }
        }

        return ImportPreview(includedItems: included, overwrittenItems: overwritten)
    }

    private func copyIfExists(_ source: URL, to destination: URL) throws {
        guard fileManager.fileExists(atPath: source.path) else { return }
        try copyReplacing(source, to: destination)
    }

    private func copyDirectoryIfExists(_ source: URL, to destination: URL) throws {
        guard fileManager.fileExists(atPath: source.path) else { return }
        try copyReplacing(source, to: destination)
    }

    private func copyReplacing(_ source: URL, to destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    func normalizeImportedPermissions(for destinations: [URL]) throws {
        for destination in destinations where fileManager.fileExists(atPath: destination.path) {
            try normalizePermissionsRecursively(at: destination)
        }
    }

    func normalizePermissionsRecursively(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            let children = try fileManager.contentsOfDirectory(at: url,
                                                               includingPropertiesForKeys: [.isDirectoryKey],
                                                               options: [])
            for child in children {
                try normalizePermissionsRecursively(at: child)
            }
            return
        }

        let permissions: Int
        if url.lastPathComponent == ".key" {
            permissions = 0o400
        } else {
            permissions = 0o600
        }
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    private func firstDirectory(in root: URL) throws -> URL? {
        let contents = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                           options: [.skipsHiddenFiles])
        return contents.first(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true })
    }

    private func validateExtractedArchive(root: URL) throws {
        let rootPath = root.standardizedFileURL.path
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .linkCountKey]
        guard let enumerator = fileManager.enumerator(at: root,
                                                      includingPropertiesForKeys: Array(keys),
                                                      options: [.skipsHiddenFiles]) else {
            throw PtermExportImportError.invalidArchive
        }

        for case let entry as URL in enumerator {
            let values = try entry.resourceValues(forKeys: keys)
            let standardized = entry.standardizedFileURL.path
            let relative = String(standardized.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let entryLabel = relative.isEmpty ? entry.lastPathComponent : relative

            if values.isSymbolicLink == true {
                throw PtermExportImportError.unsafeArchiveEntry(entryLabel)
            }

            // Reject hardlinked files (link count > 1 for non-directories)
            if values.isDirectory != true, let linkCount = values.linkCount, linkCount > 1 {
                throw PtermExportImportError.unsafeArchiveEntry(entryLabel)
            }
        }
    }

    private func plaintextNote(in root: URL) throws -> String? {
        let noteURL = root.appendingPathComponent(TransferFile.note)
        guard fileManager.fileExists(atPath: noteURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: noteURL)
        guard let note = String(data: data, encoding: .utf8) else {
            throw PtermExportImportError.invalidArchive
        }
        return note
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: errorData, as: UTF8.self)
            throw PtermExportImportError.commandFailed(message)
        }
    }
}

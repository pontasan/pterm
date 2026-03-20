import AppKit
import Foundation
import UniformTypeIdentifiers

struct ClipboardPasteResult {
    let textToPaste: String
    let createdFiles: [URL]
}

final class ClipboardFileStore {
    private let rootDirectory: URL
    private let fileManager: FileManager
    private let nowProvider: () -> Date

    init(rootDirectory: URL = PtermDirectories.files,
         fileManager: FileManager = .default,
         nowProvider: @escaping () -> Date = Date.init) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
        self.nowProvider = nowProvider
    }

    func importFromPasteboard(_ pasteboard: NSPasteboard) throws -> ClipboardPasteResult? {
        try cleanupExpiredFiles()
        if let fileURLs = readFileURLs(from: pasteboard), !fileURLs.isEmpty {
            return try importFileURLs(fileURLs)
        }

        if let storedImage = try importImageData(from: pasteboard) {
            return ClipboardPasteResult(
                textToPaste: shellQuotedPath(storedImage.path),
                createdFiles: [storedImage]
            )
        }

        if let storedData = try importGenericBinaryData(from: pasteboard) {
            return ClipboardPasteResult(
                textToPaste: shellQuotedPath(storedData.path),
                createdFiles: [storedData]
            )
        }

        return nil
    }

    func importFileURLs(_ fileURLs: [URL]) throws -> ClipboardPasteResult? {
        try cleanupExpiredFiles()
        guard !fileURLs.isEmpty else { return nil }

        let storedFiles = try fileURLs.map(copyExternalFile)
        return ClipboardPasteResult(
            textToPaste: storedFiles.map { shellQuotedPath($0.path) }.joined(separator: " "),
            createdFiles: storedFiles
        )
    }

    func cleanupExpiredFiles() throws {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let expirationDate = nowProvider().addingTimeInterval(-24 * 60 * 60)
        let urls = try fileManager.contentsOfDirectory(at: rootDirectory,
                                                       includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles])
        for url in urls {
            // Use FileManager.attributesOfItem instead of URL.resourceValues
            // to avoid stale cached modification dates.
            let attrs = try fileManager.attributesOfItem(atPath: url.path)
            let modified = attrs[.modificationDate] as? Date ?? .distantPast
            if modified < expirationDate {
                try unlinkFile(at: url)
            }
        }
    }

    func deleteStoredFile(at url: URL) throws {
        guard url.deletingLastPathComponent().path == rootDirectory.path else {
            throw CocoaError(.fileNoSuchFile)
        }
        try unlinkFile(at: url)
    }

    func deleteAllStoredFiles() throws {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let urls = try fileManager.contentsOfDirectory(at: rootDirectory,
                                                       includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles])
        for url in urls {
            try unlinkFile(at: url)
        }
    }

    func shellQuotedPath(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func readFileURLs(from pasteboard: NSPasteboard) -> [URL]? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
    }

    private func importImageData(from pasteboard: NSPasteboard) throws -> URL? {
        guard let item = pasteboard.pasteboardItems?.first else { return nil }

        for type in item.types {
            guard let utType = UTType(type.rawValue), utType.conforms(to: .image),
                  let data = item.data(forType: type) else {
                continue
            }
            let ext = utType.preferredFilenameExtension ?? "bin"
            return try writeUniqueFile(data: data, preferredExtension: ext)
        }
        return nil
    }

    private func importGenericBinaryData(from pasteboard: NSPasteboard) throws -> URL? {
        guard let item = pasteboard.pasteboardItems?.first else { return nil }

        for type in item.types {
            guard let data = item.data(forType: type), !data.isEmpty else {
                continue
            }

            if type == .string || type == .fileURL {
                continue
            }

            if let utType = UTType(type.rawValue),
               utType.conforms(to: .text) {
                continue
            }

            let ext = UTType(type.rawValue)?.preferredFilenameExtension ?? "bin"
            return try writeUniqueFile(data: data, preferredExtension: ext)
        }

        return nil
    }

    private func copyExternalFile(from sourceURL: URL) throws -> URL {
        let ext = sourceURL.pathExtension
        let destination = try uniqueDestinationURL(preferredExtension: ext)
        try fileManager.copyItem(at: sourceURL, to: destination)
        // Touch mtime so the 24-hour expiry counts from import time,
        // not from the source file's original modification date.
        try fileManager.setAttributes([
            .posixPermissions: 0o600,
            .modificationDate: nowProvider()
        ], ofItemAtPath: destination.path)
        return destination
    }

    private func writeUniqueFile(data: Data, preferredExtension: String) throws -> URL {
        let destination = try uniqueDestinationURL(preferredExtension: preferredExtension)
        try AtomicFileWriter.write(data, to: destination, permissions: 0o600)
        return destination
    }

    private func uniqueDestinationURL(preferredExtension: String) throws -> URL {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let ext = preferredExtension.isEmpty ? "" : ".\(preferredExtension)"
        return rootDirectory.appendingPathComponent(UUID().uuidString + ext)
    }

    private func unlinkFile(at url: URL) throws {
        let result = unlink(url.path)
        if result != 0 && errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

import AppKit
import CommonCrypto
import Foundation

enum PtermExportImportError: Error {
    case passwordRequired
    case invalidArchive
    case unsafeArchiveEntry(String)
    case commandFailed(String)
    case invalidKeyEnvelope
}

final class PtermExportImportManager {
    struct ImportPreview {
        let includedItems: [String]
        let overwrittenItems: [String]
    }

    private enum KeyEnvelope {
        static let magic = "PTE1".data(using: .utf8)!
        static let saltLength = 16
        static let ivLength = kCCBlockSizeAES128
        static let keyLength = 32
        static let rounds: UInt32 = 100_000
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

    func exportArchive(to destination: URL, password: String) throws {
        guard !password.isEmpty else { throw PtermExportImportError.passwordRequired }

        let staging = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        try copyIfExists(configURL, to: staging.appendingPathComponent("config.json"))
        try copyDirectoryIfExists(sessionsURL, to: staging.appendingPathComponent("sessions"))
        try copyDirectoryIfExists(workspacesURL, to: staging.appendingPathComponent("workspaces"))
        try copyDirectoryIfExists(auditURL, to: staging.appendingPathComponent("audit"))

        let noteKey = try noteStore.exportEncryptionKey()
        guard noteKey.count == KeyEnvelope.keyLength else {
            throw PtermExportImportError.invalidKeyEnvelope
        }
        let envelope = try encryptKeyEnvelope(key: noteKey, password: password)
        try AtomicFileWriter.write(envelope, to: staging.appendingPathComponent("keys.enc"), permissions: 0o600)

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", staging.path, destination.path])
    }

    func importArchive(from archiveURL: URL, password: String) throws {
        guard !password.isEmpty else { throw PtermExportImportError.passwordRequired }
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
        let envelopeURL = extractedRoot.appendingPathComponent("keys.enc")
        let envelope = try Data(contentsOf: envelopeURL)
        let noteKey = try decryptKeyEnvelope(envelope, password: password)

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
            try noteStore.importEncryptionKey(noteKey)
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
            ("audit/", extractedRoot.appendingPathComponent("audit"), auditURL),
            ("keys.enc", extractedRoot.appendingPathComponent("keys.enc"), URL(fileURLWithPath: "/dev/null"))
        ]

        let included: [String] = candidates.compactMap { candidate -> String? in
            fileManager.fileExists(atPath: candidate.archived.path) ? candidate.label : nil
        }
        let overwritten: [String] = candidates.compactMap { candidate -> String? in
            guard candidate.label != "keys.enc",
                  fileManager.fileExists(atPath: candidate.archived.path),
                  fileManager.fileExists(atPath: candidate.destination.path) else {
                return nil
            }
            return candidate.label
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
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(at: root,
                                                      includingPropertiesForKeys: Array(keys),
                                                      options: [.skipsHiddenFiles]) else {
            throw PtermExportImportError.invalidArchive
        }

        for case let entry as URL in enumerator {
            let values = try entry.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                let standardized = entry.standardizedFileURL.path
                let relative = String(standardized.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                throw PtermExportImportError.unsafeArchiveEntry(relative.isEmpty ? entry.lastPathComponent : relative)
            }
        }
    }

    private func encryptKeyEnvelope(key: Data, password: String) throws -> Data {
        var salt = Data(count: KeyEnvelope.saltLength)
        var iv = Data(count: KeyEnvelope.ivLength)
        let saltStatus = salt.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, KeyEnvelope.saltLength, $0.baseAddress!)
        }
        let ivStatus = iv.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, KeyEnvelope.ivLength, $0.baseAddress!)
        }
        guard saltStatus == errSecSuccess, ivStatus == errSecSuccess else {
            throw PtermExportImportError.invalidKeyEnvelope
        }
        let derivedKey = try deriveKey(from: password, salt: salt)
        let ciphertext = try crypt(operation: CCOperation(kCCEncrypt), input: key, key: derivedKey, iv: iv)
        return KeyEnvelope.magic + salt + iv + ciphertext
    }

    private func decryptKeyEnvelope(_ envelope: Data, password: String) throws -> Data {
        let prefix = KeyEnvelope.magic.count + KeyEnvelope.saltLength + KeyEnvelope.ivLength
        guard envelope.count >= prefix,
              envelope.prefix(KeyEnvelope.magic.count) == KeyEnvelope.magic else {
            throw PtermExportImportError.invalidKeyEnvelope
        }
        let saltStart = KeyEnvelope.magic.count
        let ivStart = saltStart + KeyEnvelope.saltLength
        let bodyStart = ivStart + KeyEnvelope.ivLength
        let salt = envelope.subdata(in: saltStart..<ivStart)
        let iv = envelope.subdata(in: ivStart..<bodyStart)
        let body = envelope.subdata(in: bodyStart..<envelope.count)
        let derivedKey = try deriveKey(from: password, salt: salt)
        let decrypted = try crypt(operation: CCOperation(kCCDecrypt), input: body, key: derivedKey, iv: iv)
        guard decrypted.count == KeyEnvelope.keyLength else {
            throw PtermExportImportError.invalidKeyEnvelope
        }
        return decrypted
    }

    private func deriveKey(from password: String, salt: Data) throws -> Data {
        var derived = Data(count: KeyEnvelope.keyLength)
        let status = derived.withUnsafeMutableBytes { derivedBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    password, password.lengthOfBytes(using: .utf8),
                    saltBytes.bindMemory(to: UInt8.self).baseAddress!, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    KeyEnvelope.rounds,
                    derivedBytes.bindMemory(to: UInt8.self).baseAddress!, KeyEnvelope.keyLength
                )
            }
        }
        guard status == kCCSuccess else {
            throw PtermExportImportError.invalidKeyEnvelope
        }
        return derived
    }

    private func crypt(operation: CCOperation, input: Data, key: Data, iv: Data) throws -> Data {
        var output = Data(count: input.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var outLength = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            inputBytes.baseAddress, input.count,
                            outputBytes.baseAddress, outputCapacity,
                            &outLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw PtermExportImportError.invalidKeyEnvelope
        }
        output.removeSubrange(outLength..<output.count)
        return output
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

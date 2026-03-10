import CommonCrypto
import Foundation
import Security

final class WorkspaceNoteStore {
    private enum Constants {
        static let service = "com.pterm.workspace-notes"
        static let account = "encryption-key"
        static let keyLength = 32
        static let ivLength = kCCBlockSizeAES128
        static let saltLength = 16
        static let magic = "PTN1".data(using: .utf8)!
    }

    private let rootDirectory: URL
    private let fileManager: FileManager

    init(rootDirectory: URL = PtermDirectories.workspaces, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    func loadNote(for workspaceName: String) throws -> String? {
        let url = noteURL(for: workspaceName)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        let key = try loadOrCreateKey()
        let plaintext = try decrypt(data, using: key)
        return String(data: plaintext, encoding: .utf8)
    }

    func saveNote(_ note: String, for workspaceName: String) throws {
        let directory = workspaceDirectory(for: workspaceName)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let key = try loadOrCreateKey()
        let ciphertext = try encrypt(Data(note.utf8), using: key)
        try AtomicFileWriter.write(ciphertext, to: noteURL(for: workspaceName), permissions: 0o600)
    }

    func renameWorkspaceData(from oldName: String, to newName: String) throws {
        let source = workspaceDirectory(for: oldName)
        let destination = workspaceDirectory(for: newName)
        guard source.path != destination.path,
              fileManager.fileExists(atPath: source.path) else {
            return
        }

        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])

        if fileManager.fileExists(atPath: destination.path) {
            let sourceNote = noteURL(for: oldName)
            if fileManager.fileExists(atPath: sourceNote.path) {
                let note = try loadNote(for: oldName) ?? ""
                try saveNote(note, for: newName)
            }
            try removeWorkspaceData(for: oldName)
            return
        }

        try fileManager.moveItem(at: source, to: destination)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
        let note = destination.appendingPathComponent("notes.enc")
        if fileManager.fileExists(atPath: note.path) {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: note.path)
        }
    }

    func removeWorkspaceData(for workspaceName: String) throws {
        let directory = workspaceDirectory(for: workspaceName)
        guard fileManager.fileExists(atPath: directory.path) else {
            return
        }
        try fileManager.removeItem(at: directory)
    }

    func exportEncryptionKey() throws -> Data {
        try loadOrCreateKey()
    }

    func importEncryptionKey(_ key: Data) throws {
        guard key.count == Constants.keyLength else {
            throw WorkspaceNoteError.invalidKeyLength
        }
        let deleteQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Constants.service,
            kSecAttrAccount: Constants.account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let add: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Constants.service,
            kSecAttrAccount: Constants.account,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData: key
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw WorkspaceNoteError.keychain(status)
        }
    }

    private func workspaceDirectory(for name: String) -> URL {
        let sanitized = FileNameSanitizer.sanitize(name, fallback: "Uncategorized")
        return rootDirectory.appendingPathComponent(sanitized)
    }

    private func noteURL(for workspaceName: String) -> URL {
        workspaceDirectory(for: workspaceName).appendingPathComponent("notes.enc")
    }

    private func loadOrCreateKey() throws -> Data {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Constants.service,
            kSecAttrAccount: Constants.account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            guard data.count == Constants.keyLength else {
                throw WorkspaceNoteError.invalidKeyLength
            }
            return data
        }
        if status != errSecItemNotFound {
            throw WorkspaceNoteError.keychain(status)
        }

        var key = Data(count: Constants.keyLength)
        let result = key.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, Constants.keyLength, bytes.baseAddress!)
        }
        guard result == errSecSuccess else {
            throw WorkspaceNoteError.randomFailure
        }

        let add: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Constants.service,
            kSecAttrAccount: Constants.account,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData: key
        ]
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw WorkspaceNoteError.keychain(addStatus)
        }
        return key
    }

    private func encrypt(_ plaintext: Data, using key: Data) throws -> Data {
        var salt = Data(count: Constants.saltLength)
        var iv = Data(count: Constants.ivLength)
        let saltStatus = salt.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, Constants.saltLength, bytes.baseAddress!)
        }
        let ivStatus = iv.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, Constants.ivLength, bytes.baseAddress!)
        }
        guard saltStatus == errSecSuccess, ivStatus == errSecSuccess else {
            throw WorkspaceNoteError.randomFailure
        }

        let crypt = try crypt(operation: CCOperation(kCCEncrypt),
                              input: plaintext, key: key, iv: iv)
        return Constants.magic + salt + iv + crypt
    }

    private func decrypt(_ ciphertext: Data, using key: Data) throws -> Data {
        let prefixLength = Constants.magic.count + Constants.saltLength + Constants.ivLength
        guard ciphertext.count >= prefixLength,
              ciphertext.prefix(Constants.magic.count) == Constants.magic else {
            throw WorkspaceNoteError.invalidFormat
        }
        let ivRange = (Constants.magic.count + Constants.saltLength)..<(Constants.magic.count + Constants.saltLength + Constants.ivLength)
        let bodyRange = (Constants.magic.count + Constants.saltLength + Constants.ivLength)..<ciphertext.count
        let iv = ciphertext.subdata(in: ivRange)
        let body = ciphertext.subdata(in: bodyRange)
        return try crypt(operation: CCOperation(kCCDecrypt),
                         input: body, key: key, iv: iv)
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
            throw WorkspaceNoteError.crypto(status)
        }
        output.removeSubrange(outLength..<output.count)
        return output
    }
}

enum WorkspaceNoteError: Error {
    case keychain(OSStatus)
    case crypto(CCCryptorStatus)
    case invalidFormat
    case invalidKeyLength
    case randomFailure
}

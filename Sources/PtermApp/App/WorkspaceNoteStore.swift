import CommonCrypto
import Foundation
import Security

/// Stores a single encrypted app-level note in ~/.pterm/note.enc.
final class AppNoteStore {
    private enum Constants {
        static let service = "com.pterm.workspace-notes"
        static let account = "encryption-key"
        static let keyLength = 32
        static let ivLength = kCCBlockSizeAES128
        static let saltLength = 16
        static let magic = "PTN1".data(using: .utf8)!
        static let noteFileName = "note.enc"
    }

    private let rootDirectory: URL
    private let fileManager: FileManager
    private var cachedKey: Data?

    init(rootDirectory: URL = PtermDirectories.base, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    func loadNote() throws -> String? {
        let url = noteURL
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        let key = try loadOrCreateKey()
        let plaintext = try decrypt(data, using: key)
        guard let note = String(data: plaintext, encoding: .utf8) else {
            throw AppNoteError.invalidFormat
        }
        return note
    }

    func saveNote(_ note: String) throws {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let key = try loadOrCreateKey()
        let ciphertext = try encrypt(Data(note.utf8), using: key)
        try AtomicFileWriter.write(ciphertext, to: noteURL, permissions: 0o600)
    }

    func exportEncryptionKey() throws -> Data {
        try loadOrCreateKey()
    }

    func importEncryptionKey(_ key: Data) throws {
        guard key.count == Constants.keyLength else {
            throw AppNoteError.invalidKeyLength
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
            throw AppNoteError.keychain(status)
        }
        cachedKey = key
    }

    private var noteURL: URL {
        rootDirectory.appendingPathComponent(Constants.noteFileName)
    }

    private func loadOrCreateKey() throws -> Data {
        if let cachedKey {
            return cachedKey
        }

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
                throw AppNoteError.invalidKeyLength
            }
            cachedKey = data
            return data
        }
        if status != errSecItemNotFound {
            throw AppNoteError.keychain(status)
        }

        var key = Data(count: Constants.keyLength)
        let result = key.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, Constants.keyLength, bytes.baseAddress!)
        }
        guard result == errSecSuccess else {
            throw AppNoteError.randomFailure
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
            throw AppNoteError.keychain(addStatus)
        }
        cachedKey = key
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
            throw AppNoteError.randomFailure
        }

        let crypt = try crypt(operation: CCOperation(kCCEncrypt),
                              input: plaintext, key: key, iv: iv)
        return Constants.magic + salt + iv + crypt
    }

    private func decrypt(_ ciphertext: Data, using key: Data) throws -> Data {
        let prefixLength = Constants.magic.count + Constants.saltLength + Constants.ivLength
        guard ciphertext.count >= prefixLength,
              ciphertext.prefix(Constants.magic.count) == Constants.magic else {
            throw AppNoteError.invalidFormat
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
            throw AppNoteError.crypto(status)
        }
        output.removeSubrange(outLength..<output.count)
        return output
    }
}

enum AppNoteError: Error {
    case keychain(OSStatus)
    case crypto(CCCryptorStatus)
    case invalidFormat
    case invalidKeyLength
    case randomFailure
}

import CommonCrypto
import CryptoKit
import Foundation
import Security

struct AuditConfiguration: Equatable {
    var enabled: Bool
    var retentionDays: Int?
    var encryption: Bool

    static let disabled = AuditConfiguration(enabled: false, retentionDays: nil, encryption: false)
}

final class TerminalAuditLogger {
    private enum WriteBuffer {
        static let flushThreshold = 16 * 1024
    }

    private enum EncryptionFrame {
        static let magic = "PTAE1".data(using: .utf8)!
        static let ivLength = kCCBlockSizeAES128
        static let headerLength = magic.count + ivLength + MemoryLayout<UInt32>.size
    }

    private struct Header: Encodable {
        let version: Int
        let width: Int
        let height: Int
        let timestamp: Int64
        let timezone: String
        let env: [String: String]
        let workspace: String
        let terminal: String
        let session_id: String
        let host: String
        let user: String
    }

    private let rootDirectory: URL
    private let sessionID: UUID
    private let timeZoneIdentifier: String
    private let termEnv: String
    private let workspaceNameProvider: () -> String
    private let terminalNameProvider: () -> String
    private let sizeProvider: () -> (cols: Int, rows: Int)
    private let keyProvider: () throws -> SymmetricKey
    private let nowProvider: () -> Date
    private let encryptionEnabled: Bool
    private var startDate: Date
    private var currentDayKey: String?
    private var fileHandle: FileHandle?
    private var pendingWriteBuffer = Data()
    private var headerWritten = false
    private var eventCount = 0
    private var hmacAccumulator = Data()
    private let queue = DispatchQueue(label: "pterm.audit.logger")

    init(rootDirectory: URL = PtermDirectories.audit,
         sessionID: UUID,
         timeZoneIdentifier: String = TimeZone.current.identifier,
         termEnv: String,
         encryptionEnabled: Bool = false,
         workspaceNameProvider: @escaping () -> String,
         terminalNameProvider: @escaping () -> String,
         sizeProvider: @escaping () -> (cols: Int, rows: Int),
         keyProvider: @escaping () throws -> SymmetricKey = { try AuditKeyStore.loadOrCreateKey() },
         nowProvider: @escaping () -> Date = Date.init) {
        self.rootDirectory = rootDirectory
        self.sessionID = sessionID
        self.timeZoneIdentifier = timeZoneIdentifier
        self.termEnv = termEnv
        self.encryptionEnabled = encryptionEnabled
        self.workspaceNameProvider = workspaceNameProvider
        self.terminalNameProvider = terminalNameProvider
        self.sizeProvider = sizeProvider
        self.keyProvider = keyProvider
        self.nowProvider = nowProvider
        self.startDate = nowProvider()
    }

    deinit {
        close()
    }

    func recordInput(_ data: Data) {
        recordEvent(type: "i", data: data)
    }

    func recordOutput(_ data: Data) {
        recordEvent(type: "o", data: data)
    }

    func close() {
        queue.sync {
            try? flushPendingBuffer()
            try? fileHandle?.synchronize()
            try? fileHandle?.close()
            fileHandle = nil
        }
    }

    func cleanupExpiredLogs(retentionDays: Int?) throws {
        guard let retentionDays else { return }
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let calendar = Calendar(identifier: .gregorian)
        let cutoff = calendar.startOfDay(for: nowProvider().addingTimeInterval(TimeInterval(-retentionDays * 24 * 60 * 60)))
        let dayDirs = try FileManager.default.contentsOfDirectory(at: rootDirectory,
                                                                  includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        for dir in dayDirs {
            guard let date = formatter.date(from: dir.lastPathComponent), date < cutoff else {
                continue
            }
            try FileManager.default.removeItem(at: dir)
        }
    }

    private func recordEvent(type: String, data: Data) {
        queue.async {
            do {
                try self.rotateIfNeeded()
                try self.writeHeaderIfNeeded()
                let elapsed = self.nowProvider().timeIntervalSince(self.startDate)
                let payload = [AuditJSON.number(elapsed), .string(type), .string(Self.rawJSONString(from: data))]
                let line = try AuditJSON.encodeArray(payload)
                try self.append(line)
                self.hmacAccumulator.append(line)
                self.eventCount += 1
                if self.eventCount.isMultiple(of: 100) {
                    try self.appendHMACLine(elapsed: elapsed)
                }
            } catch {
                fatalError("Audit logging failed: \(error)")
            }
        }
    }

    private static func rawJSONString(from data: Data) -> String {
        String(data: data, encoding: .isoLatin1) ?? ""
    }

    private func rotateIfNeeded() throws {
        let dayKey = AuditPathBuilder.dayString(for: nowProvider(), timeZoneIdentifier: timeZoneIdentifier)
        if currentDayKey == dayKey {
            return
        }

        try flushPendingBuffer()
        try fileHandle?.synchronize()
        try fileHandle?.close()
        fileHandle = nil
        pendingWriteBuffer.removeAll(keepingCapacity: true)
        headerWritten = false
        eventCount = 0
        hmacAccumulator.removeAll(keepingCapacity: true)
        startDate = nowProvider()
        currentDayKey = dayKey

        let workspace = FileNameSanitizer.sanitize(workspaceNameProvider(), fallback: "Uncategorized")
        let terminal = FileNameSanitizer.sanitize(terminalNameProvider(), fallback: "terminal")
        let fileName = "\(terminal)_\(sessionID.uuidString.prefix(6)).cast"
        let directory = rootDirectory
            .appendingPathComponent(dayKey)
            .appendingPathComponent(workspace)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fileURL = directory.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil,
                                           attributes: [.posixPermissions: 0o600])
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        fileHandle = try FileHandle(forWritingTo: fileURL)
        try fileHandle?.seekToEnd()
    }

    private func writeHeaderIfNeeded() throws {
        guard !headerWritten else { return }
        let size = sizeProvider()
        let header = Header(
            version: 2,
            width: size.cols,
            height: size.rows,
            timestamp: Int64(startDate.timeIntervalSince1970),
            timezone: timeZoneIdentifier,
            env: ["TERM": termEnv],
            workspace: workspaceNameProvider(),
            terminal: terminalNameProvider(),
            session_id: sessionID.uuidString,
            host: ProcessInfo.processInfo.hostName,
            user: NSUserName()
        )
        let headerData = try JSONEncoder().encode(header) + Data([0x0A])
        try append(headerData)
        headerWritten = true
    }

    private func appendHMACLine(elapsed: TimeInterval) throws {
        let key = try keyProvider()
        let digest = HMAC<SHA256>.authenticationCode(for: hmacAccumulator, using: key)
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        let line = try AuditJSON.encodeArray([.number(elapsed), .string("h"), .string("hmac-sha256:\(hash)")])
        try append(line)
        hmacAccumulator.removeAll(keepingCapacity: true)
    }

    private func append(_ data: Data) throws {
        let payload = encryptionEnabled ? try encryptFrame(data) : data
        pendingWriteBuffer.append(payload)
        if pendingWriteBuffer.count >= WriteBuffer.flushThreshold {
            try flushPendingBuffer()
        }
    }

    private func flushPendingBuffer() throws {
        guard !pendingWriteBuffer.isEmpty else { return }
        try fileHandle?.write(contentsOf: pendingWriteBuffer)
        pendingWriteBuffer.removeAll(keepingCapacity: true)
    }

    private func encryptFrame(_ plaintext: Data) throws -> Data {
        let key = try keyProvider()
        let keyData = key.withUnsafeBytes { Data($0) }
        var iv = Data(count: EncryptionFrame.ivLength)
        let randomStatus = iv.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, EncryptionFrame.ivLength, bytes.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            throw CocoaError(.fileWriteUnknown)
        }

        let ciphertext = try crypt(
            operation: CCOperation(kCCEncrypt),
            input: plaintext,
            key: keyData,
            iv: iv
        )
        var frame = Data()
        frame.reserveCapacity(EncryptionFrame.headerLength + ciphertext.count)
        frame.append(EncryptionFrame.magic)
        frame.append(iv)
        var bodyLength = UInt32(ciphertext.count).bigEndian
        withUnsafeBytes(of: &bodyLength) { frame.append(contentsOf: $0) }
        frame.append(ciphertext)
        return frame
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
            throw CocoaError(.fileWriteUnknown)
        }
        output.removeSubrange(outLength..<output.count)
        return output
    }

    static func decryptFile(_ data: Data, key: SymmetricKey) throws -> Data {
        var offset = 0
        var plaintext = Data()
        let keyData = key.withUnsafeBytes { Data($0) }

        while offset < data.count {
            let remaining = data.count - offset
            guard remaining >= EncryptionFrame.headerLength else {
                throw CocoaError(.fileReadCorruptFile)
            }

            let magicRange = offset..<(offset + EncryptionFrame.magic.count)
            guard data.subdata(in: magicRange) == EncryptionFrame.magic else {
                throw CocoaError(.fileReadCorruptFile)
            }
            offset += EncryptionFrame.magic.count

            let ivRange = offset..<(offset + EncryptionFrame.ivLength)
            let iv = data.subdata(in: ivRange)
            offset += EncryptionFrame.ivLength

            let lengthRange = offset..<(offset + MemoryLayout<UInt32>.size)
            let bodyLength = data.subdata(in: lengthRange).withUnsafeBytes {
                $0.load(as: UInt32.self).bigEndian
            }
            offset += MemoryLayout<UInt32>.size

            let bodySize = Int(bodyLength)
            guard bodySize >= 0, offset + bodySize <= data.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let bodyRange = offset..<(offset + bodySize)
            let body = data.subdata(in: bodyRange)
            offset += bodySize

            let chunk = try decryptChunk(body, key: keyData, iv: iv)
            plaintext.append(chunk)
        }

        return plaintext
    }

    private static func decryptChunk(_ input: Data, key: Data, iv: Data) throws -> Data {
        var output = Data(count: input.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var outLength = 0

        let status = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
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
            throw CocoaError(.fileReadCorruptFile)
        }
        output.removeSubrange(outLength..<output.count)
        return output
    }
}

enum AuditKeyStore {
    static func loadOrCreateKey(url: URL = PtermDirectories.audit.appendingPathComponent(".key")) throws -> SymmetricKey {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        if fm.fileExists(atPath: url.path) {
            try? fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
            let data = try Data(contentsOf: url)
            guard data.count == 32 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return SymmetricKey(data: data)
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard result == errSecSuccess else {
            throw CocoaError(.fileWriteUnknown)
        }
        let data = Data(bytes)
        try AtomicFileWriter.write(data, to: url, permissions: 0o400)
        return SymmetricKey(data: data)
    }
}

enum AuditPathBuilder {
    static func dayString(for date: Date, timeZoneIdentifier: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

private enum AuditJSON {
    case string(String)
    case number(Double)

    static func encodeArray(_ values: [AuditJSON]) throws -> Data {
        var encoded = "["
        for (index, value) in values.enumerated() {
            if index > 0 {
                encoded.append(",")
            }
            switch value {
            case .string(let string):
                let data = try JSONEncoder().encode(string)
                encoded.append(String(decoding: data, as: UTF8.self))
            case .number(let number):
                encoded.append(String(format: "%.6f", number))
            }
        }
        encoded.append("]\n")
        return Data(encoded.utf8)
    }
}

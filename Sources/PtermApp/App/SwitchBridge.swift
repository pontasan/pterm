import Foundation
import Security

/// Lets the Switch menu bar app list terminals and choose which are on show, and nothing else.
///
/// This is separate from the MCP server on purpose: MCP can type into terminals and close them,
/// and listing needs none of that. Switch can only read titles and pick a view here. It cannot
/// send input or read terminal contents, because no such request exists.
///
/// A socket in the profile directory (0700), not a port, so nothing else on the machine can
/// reach it by address. Each connection is then checked against the signature of the process on
/// the other end, as reported by the kernel, before a single byte is read from it. There is no
/// token to steal, and shells running inside pterm are refused like everything else.
final class SwitchBridge {
    enum StartError: Error, Equatable {
        case pathTooLong
        case directoryNotPrivate
        case pathInUse
        case socket(Int32)
    }

    /// Longer than any valid request. A larger one is refused unread.
    static let maximumRequestSize = 65_536
    private static let readDeadline: TimeInterval = 2

    private let socketURL: URL
    private let isAllowed: (Int32) -> Bool
    private let respond: (Data) -> Data
    private let queue = DispatchQueue(label: "com.pterm.switch-bridge")
    private var source: DispatchSourceRead?

    /// `respond` runs on the bridge's own queue, one request at a time.
    init(socketURL: URL, isAllowed: @escaping (Int32) -> Bool, respond: @escaping (Data) -> Data) {
        self.socketURL = socketURL
        self.isAllowed = isAllowed
        self.respond = respond
    }

    func start() throws {
        let path = socketURL.path
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { throw StartError.pathTooLong }

        // The directory is what keeps other users out, so it has to really be private.
        var directory = stat()
        guard lstat(socketURL.deletingLastPathComponent().path, &directory) == 0,
              directory.st_mode & S_IFMT == S_IFDIR,
              directory.st_uid == geteuid(),
              directory.st_mode & 0o077 == 0 else {
            throw StartError.directoryNotPrivate
        }

        // A socket left by a crash is replaced. The instance lock says no one else is using it.
        // Anything else at this path is not ours to delete.
        var existing = stat()
        if lstat(path, &existing) == 0 {
            guard existing.st_mode & S_IFMT == S_IFSOCK else { throw StartError.pathInUse }
            unlink(path)
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw StartError.socket(errno) }
        do {
            // Shells are spawned from this process, and must not inherit the socket.
            guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
                  fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
                throw StartError.socket(errno)
            }
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                buffer.copyBytes(from: path.utf8)
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0 else { throw StartError.socket(errno) }
            // Nothing can connect until listen, so this leaves no moment of wider access.
            guard chmod(path, 0o600) == 0, listen(descriptor, 8) == 0 else {
                let code = errno
                unlink(path)
                throw StartError.socket(code)
            }
        } catch {
            close(descriptor)
            throw error
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptWaiting(on: descriptor) }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    func stop() {
        guard let source else { return }
        self.source = nil
        source.cancel()
        unlink(socketURL.path)
    }

    private func acceptWaiting(on listener: Int32) {
        while true {
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            defer { close(connection) }
            var noSignal: Int32 = 1
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            // A connection inherits non-blocking from the listener on this platform.
            guard fcntl(connection, F_SETFD, FD_CLOEXEC) == 0,
                  fcntl(connection, F_SETFL, 0) == 0,
                  setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0,
                  setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
                  setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
                continue
            }
            guard isAllowed(connection) else {
                NSLog("pterm Switch bridge: refused a connection from an unverified process")
                continue
            }
            guard let request = Self.readRequest(from: connection) else { continue }
            var reply = respond(request)
            reply.append(0x0A)
            Self.write(reply, to: connection)
        }
    }

    /// One line, or nil when it is too long or does not arrive in time.
    private static func readRequest(from connection: Int32) -> Data? {
        let deadline = Date().addingTimeInterval(readDeadline)
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            let count = read(connection, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            request.append(contentsOf: buffer[0..<count])
            if let end = request.firstIndex(of: 0x0A) {
                return end <= maximumRequestSize ? request.prefix(upTo: end) : nil
            }
            guard request.count <= maximumRequestSize else { return nil }
        }
        return nil
    }

    private static func write(_ data: Data, to connection: Int32) {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(connection, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return }
                offset += count
            }
        }
    }
}

/// The two requests that exist, and what is said in reply.
enum SwitchBridgeProtocol {
    struct Terminal: Equatable {
        let id: UUID
        let title: String
        let workspace: String
        /// On show in the focused or split view, in a window that is not minimized.
        let isDisplayed: Bool
    }

    static func reply(to request: Data,
                      list: () -> (windowNumber: Int, terminals: [Terminal])?,
                      show: ([UUID]) -> Int?) -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: request) as? [String: Any],
              let operation = object["op"] as? String else {
            return failure("invalid request")
        }
        switch operation {
        case "list":
            guard let state = list() else { return failure("no window") }
            return encoded([
                "ok": true,
                "window_number": state.windowNumber,
                "terminals": state.terminals.map {
                    ["id": $0.id.uuidString, "title": $0.title, "workspace": $0.workspace, "displayed": $0.isDisplayed]
                }
            ])
        case "show":
            guard let raw = object["terminals"] as? [String], !raw.isEmpty else {
                return failure("invalid request")
            }
            var ids: [UUID] = []
            for text in raw {
                guard let id = UUID(uuidString: text) else { return failure("invalid request") }
                if !ids.contains(id) { ids.append(id) }
            }
            guard let windowNumber = show(ids) else { return failure("unknown terminal") }
            return encoded(["ok": true, "window_number": windowNumber])
        default:
            return failure("invalid request")
        }
    }

    private static func failure(_ reason: String) -> Data {
        encoded(["ok": false, "error": reason])
    }

    private static func encoded(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{\"ok\":false}".utf8)
    }
}

/// Decides from the code signature, as the kernel identifies the peer. Only a program signed
/// with Developer ID by the same team as this copy of pterm, under Switch's identifier, passes.
struct SwitchBridgePeerVerifier {
    static let switchIdentifier = "com.tranworks.switch"
    private static let hardenedRuntimeFlag: UInt32 = 0x10000

    let requirement: SecRequirement

    /// Nil unless this copy of pterm has a team of its own, as an ad-hoc build does not. There
    /// is then nothing to compare a peer with, and the bridge does not start.
    init?() {
        guard let team = Self.ownTeam(), Self.isPlainTeamIdentifier(team) else { return nil }
        var requirement: SecRequirement?
        let text = Self.requirementText(team: team)
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return nil }
        self.requirement = requirement
    }

    /// Developer ID, this team, Switch.
    static func requirementText(team: String) -> String {
        "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and "
            + "certificate leaf[field.1.2.840.113635.100.6.1.13] and "
            + "certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(switchIdentifier)\""
    }

    /// The team goes into the requirement's text, so it may hold nothing that could change its meaning.
    static func isPlainTeamIdentifier(_ team: String) -> Bool {
        !team.isEmpty && team.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) }
    }

    func isAllowed(connection: Int32) -> Bool {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(connection, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return false }
        let attributes = [kSecGuestAttributeAudit: withUnsafeBytes(of: &token) { Data($0) }] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return false }
        // Without the hardened runtime, a library could be loaded into a genuine copy.
        guard let flags = Self.signingInformation(of: code)?[kSecCodeInfoFlags as String] as? UInt32 else { return false }
        return flags & Self.hardenedRuntimeFlag != 0
    }

    private static func ownTeam() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        return signingInformation(of: code)?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func signingInformation(of code: SecCode) -> [String: Any]? {
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess else {
            return nil
        }
        return information as? [String: Any]
    }
}

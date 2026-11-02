import Foundation
import Security
import XCTest
@testable import PtermApp

final class SwitchBridgeTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        // Short, because a socket path has a small limit.
        directory = URL(fileURLWithPath: "/tmp/psb-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private var socketURL: URL { directory.appendingPathComponent("switch.sock") }

    private func started(isAllowed: @escaping (Int32) -> Bool = { _ in true },
                         respond: @escaping (Data) -> Data = { _ in Data("{}".utf8) }) throws -> SwitchBridge {
        let bridge = SwitchBridge(socketURL: socketURL, isAllowed: isAllowed, respond: respond)
        try bridge.start()
        addTeardownBlock { bridge.stop() }
        return bridge
    }

    /// What comes back for these bytes, until the other end closes.
    private func exchange(_ request: Data) throws -> Data {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(descriptor) }
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: socketURL.path.utf8) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        _ = request.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { return reply }
            reply.append(contentsOf: buffer[0..<count])
        }
    }

    // MARK: Socket

    func testSocketIsOwnerOnlyAndRemovedOnStop() throws {
        let bridge = try started()
        var info = stat()
        XCTAssertEqual(lstat(socketURL.path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFSOCK)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        bridge.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
    }

    func testRefusedPeerGetsNothingAndItsRequestIsNotHandled() throws {
        let handled = NSLock()
        var calls = 0
        _ = try started(isAllowed: { _ in false }, respond: { _ in
            handled.lock(); calls += 1; handled.unlock()
            return Data("{\"ok\":true}".utf8)
        })
        XCTAssertEqual(try exchange(Data("{\"op\":\"list\"}\n".utf8)), Data())
        handled.lock(); defer { handled.unlock() }
        XCTAssertEqual(calls, 0)
    }

    func testAllowedPeerGetsOneLine() throws {
        _ = try started(respond: { Data("got:".utf8) + $0 })
        XCTAssertEqual(try exchange(Data("abc\nignored".utf8)), Data("got:abc\n".utf8))
    }

    func testOversizedRequestIsRefusedUnanswered() throws {
        _ = try started(respond: { _ in Data("answered".utf8) })
        let huge = Data(repeating: 0x61, count: SwitchBridge.maximumRequestSize + 8192) + Data("\n".utf8)
        XCTAssertEqual(try exchange(huge), Data())
    }

    func testSocketIsNotInheritedByChildProcesses() throws {
        // Every descriptor pterm owns here has close-on-exec, which is what a spawned shell honours.
        _ = try started()
        let bridgeDescriptors = (0..<256).filter { descriptor in
            var address = sockaddr_un()
            var length = socklen_t(MemoryLayout<sockaddr_un>.size)
            let named = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(Int32(descriptor), $0, &length) }
            }
            guard named == 0, address.sun_family == sa_family_t(AF_UNIX) else { return false }
            let path = withUnsafeBytes(of: &address.sun_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            return path == socketURL.path
        }
        XCTAssertEqual(bridgeDescriptors.count, 1)
        XCTAssertEqual(fcntl(Int32(bridgeDescriptors[0]), F_GETFD) & FD_CLOEXEC, FD_CLOEXEC)
    }

    func testRestartReplacesALeftoverSocketButNothingElse() throws {
        let first = SwitchBridge(socketURL: socketURL, isAllowed: { _ in true }, respond: { $0 })
        try first.start()
        // As after a crash: the file stays, and no one is behind it.
        let second = SwitchBridge(socketURL: socketURL, isAllowed: { _ in true }, respond: { $0 })
        try second.start()
        second.stop()
        first.stop()

        try Data("mine".utf8).write(to: socketURL)
        let third = SwitchBridge(socketURL: socketURL, isAllowed: { _ in true }, respond: { $0 })
        XCTAssertThrowsError(try third.start()) { XCTAssertEqual($0 as? SwitchBridge.StartError, .pathInUse) }
        XCTAssertEqual(try Data(contentsOf: socketURL), Data("mine".utf8))
        try FileManager.default.removeItem(at: socketURL)

        let elsewhere = directory.appendingPathComponent("target")
        try Data("target".utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: socketURL, withDestinationURL: elsewhere)
        XCTAssertThrowsError(try third.start()) { XCTAssertEqual($0 as? SwitchBridge.StartError, .pathInUse) }
        XCTAssertEqual(try Data(contentsOf: elsewhere), Data("target".utf8))
        try FileManager.default.removeItem(at: socketURL)
    }

    func testDirectoryOthersCanEnterIsRefused() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        let bridge = SwitchBridge(socketURL: socketURL, isAllowed: { _ in true }, respond: { $0 })
        XCTAssertThrowsError(try bridge.start()) { XCTAssertEqual($0 as? SwitchBridge.StartError, .directoryNotPrivate) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
    }

    func testPathTooLongForASocketIsRefused() throws {
        let long = directory.appendingPathComponent(String(repeating: "x", count: 120))
        let bridge = SwitchBridge(socketURL: long, isAllowed: { _ in true }, respond: { $0 })
        XCTAssertThrowsError(try bridge.start()) { XCTAssertEqual($0 as? SwitchBridge.StartError, .pathTooLong) }
    }

    // MARK: Requests

    private let one = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let two = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func decoded(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func reply(_ text: String, shown: ((([UUID]) -> Void))? = nil) throws -> [String: Any] {
        try decoded(SwitchBridgeProtocol.reply(
            to: Data(text.utf8),
            list: { (7, [.init(id: self.one, title: "logs", workspace: "A", isDisplayed: true),
                         .init(id: self.two, title: "repl", workspace: "B", isDisplayed: false)]) },
            show: { ids in shown?(ids); return ids.contains(UUID(uuidString: "99999999-9999-9999-9999-999999999999")!) ? nil : 7 }))
    }

    func testListSaysTitlesAndWhatIsOnShowAndNothingElse() throws {
        let answer = try reply("{\"op\":\"list\"}")
        XCTAssertEqual(answer["ok"] as? Bool, true)
        XCTAssertEqual(answer["window_number"] as? Int, 7)
        let terminals = try XCTUnwrap(answer["terminals"] as? [[String: Any]])
        XCTAssertEqual(terminals.map { $0["title"] as? String }, ["logs", "repl"])
        XCTAssertEqual(terminals.map { $0["workspace"] as? String }, ["A", "B"])
        XCTAssertEqual(terminals.map { $0["displayed"] as? Bool }, [true, false])
        XCTAssertEqual(Set(terminals[0].keys), ["id", "title", "workspace", "displayed"])
    }

    func testShowPassesEachTerminalOnce() throws {
        var shown: [UUID] = []
        let text = "{\"op\":\"show\",\"terminals\":[\"\(two.uuidString)\",\"\(one.uuidString)\",\"\(two.uuidString)\"]}"
        let answer = try reply(text) { shown = $0 }
        XCTAssertEqual(answer["ok"] as? Bool, true)
        XCTAssertEqual(answer["window_number"] as? Int, 7)
        XCTAssertEqual(shown, [two, one])
    }

    func testAnythingElseIsRefusedWithoutActing() throws {
        var acted = false
        let refused = [
            "not json", "[]", "{}", "{\"op\":7}",
            "{\"op\":\"send_input\",\"text\":\"rm -rf /\"}",
            "{\"op\":\"close\",\"terminals\":[\"\(one.uuidString)\"]}",
            "{\"op\":\"show\"}", "{\"op\":\"show\",\"terminals\":[]}",
            "{\"op\":\"show\",\"terminals\":\"\(one.uuidString)\"}",
            "{\"op\":\"show\",\"terminals\":[\"../../etc\"]}",
            "{\"op\":\"show\",\"terminals\":[\"\(one.uuidString)\",\"bad\"]}"
        ]
        for text in refused {
            XCTAssertEqual(try reply(text) { _ in acted = true }["ok"] as? Bool, false, text)
        }
        XCTAssertFalse(acted)
    }

    func testUnknownTerminalIsAFailure() throws {
        let answer = try reply("{\"op\":\"show\",\"terminals\":[\"99999999-9999-9999-9999-999999999999\"]}")
        XCTAssertEqual(answer["ok"] as? Bool, false)
    }

    // MARK: Signature

    func testRequirementNamesDeveloperIDTeamAndSwitch() {
        let text = SwitchBridgePeerVerifier.requirementText(team: "ABCDE12345")
        XCTAssertTrue(text.contains("anchor apple generic"))
        XCTAssertTrue(text.contains("certificate leaf[subject.OU] = \"ABCDE12345\""))
        XCTAssertTrue(text.contains("identifier \"com.tranworks.switch\""))
        var requirement: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(text as CFString, [], &requirement), errSecSuccess)
    }

    func testTeamThatCouldChangeTheRequirementIsRejected() {
        XCTAssertTrue(SwitchBridgePeerVerifier.isPlainTeamIdentifier("ABCDE12345"))
        XCTAssertFalse(SwitchBridgePeerVerifier.isPlainTeamIdentifier(""))
        XCTAssertFalse(SwitchBridgePeerVerifier.isPlainTeamIdentifier("A\" or anchor apple or \"B"))
    }
}

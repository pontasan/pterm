import Darwin
import XCTest
@testable import PtermApp

final class IOHookManagerTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        // Ignore SIGPIPE globally so that EPIPE on write() doesn't kill
        // the test process.  This mirrors what the app does in main.swift.
        signal(SIGPIPE, SIG_IGN)
    }

    // MARK: - Helpers

    /// Create a minimal hook configuration with the master switch ON.
    private func makeConfig(hooks: [IOHookEntry] = [],
                            enabled: Bool = true) -> IOHookConfiguration {
        IOHookConfiguration(enabled: enabled, hooks: hooks)
    }

    /// Create a hook entry with sensible defaults.
    private func makeHook(name: String = "test-hook",
                          target: IOHookTarget = .output,
                          buffering: IOHookBufferingMode = .immediate,
                          command: String = "cat > /dev/null",
                          processMatch: String? = nil,
                          includeChildren: Bool = false) -> IOHookEntry {
        var regex: NSRegularExpression?
        if let pattern = processMatch {
            regex = try? NSRegularExpression(pattern: pattern, options: [])
        }
        return IOHookEntry(
            enabled: true,
            name: name,
            target: target,
            buffering: buffering,
            idleMs: IOHookEntry.defaultIdleMs,
            bufferSize: IOHookEntry.defaultBufferSize,
            command: command,
            processMatch: processMatch,
            processMatchRegex: regex,
            includeChildren: includeChildren
        )
    }

    // MARK: - Precondition

    func testInitRequiresMasterSwitchON() {
        // This should not crash — master switch ON.
        let config = makeConfig(hooks: [makeHook()])
        let manager = IOHookManager(config: config)
        manager.shutdown()
    }

    // MARK: - Spawn & Shutdown

    func testSpawnHookProcessAndShutdown() {
        let hook = makeHook(command: "cat > /dev/null")
        let config = makeConfig(hooks: [hook])
        let manager = IOHookManager(config: config)
        defer { manager.shutdown() }

        let pty = PTY()
        defer { pty.stop(waitForExit: true) }

        let exitExpectation = expectation(description: "pty-exit")
        var exited = false
        let lock = NSLock()
        pty.onOutput = { _ in }
        pty.onExit = {
            lock.lock()
            defer { lock.unlock() }
            guard !exited else { return }
            exited = true
            exitExpectation.fulfill()
        }

        do {
            try pty.start(rows: 24, cols: 80, initialDirectory: NSTemporaryDirectory())
        } catch {
            return XCTFail("Failed to start PTY: \(error)")
        }

        let queue = DispatchQueue(label: "test.hook-manager")
        manager.activateTerminal(id: UUID(), masterFD: pty.testMasterFD,
                                 shellPID: pty.childPID, ptyQueue: queue)

        // Give the hook process time to start.
        Thread.sleep(forTimeInterval: 0.5)

        // Should have active hooks.
        // Shutdown should clean up without crashing.
        manager.shutdown()

        pty.write("exit\n")
        wait(for: [exitExpectation], timeout: 8.0)
    }

    // MARK: - Data Dispatch

    func testDispatchRawOutputToImmediateModeHook() {
        // Use a hook command that writes to a temp file so we can verify delivery.
        let tempFile = NSTemporaryDirectory() + "pterm_hook_test_\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: tempFile) }

        let hook = makeHook(
            command: "cat >> \(tempFile)"
        )
        let config = makeConfig(hooks: [hook])
        let manager = IOHookManager(config: config)
        defer { manager.shutdown() }

        let pty = PTY()
        defer { pty.stop(waitForExit: true) }

        let exitExpectation = expectation(description: "pty-exit")
        var exited = false
        let lock = NSLock()
        pty.onOutput = { _ in }
        pty.onExit = {
            lock.lock()
            defer { lock.unlock() }
            guard !exited else { return }
            exited = true
            exitExpectation.fulfill()
        }

        do {
            try pty.start(rows: 24, cols: 80, initialDirectory: NSTemporaryDirectory())
        } catch {
            return XCTFail("Failed to start PTY: \(error)")
        }

        let termID = UUID()
        let queue = DispatchQueue(label: "test.hook-manager")
        manager.activateTerminal(id: termID, masterFD: pty.testMasterFD,
                                 shellPID: pty.childPID, ptyQueue: queue)

        // Give the hook process time to start.
        Thread.sleep(forTimeInterval: 0.5)

        // Dispatch some data.
        let testData: [UInt8] = Array("Hello, Hook!\n".utf8)
        testData.withUnsafeBufferPointer { buf in
            manager.dispatchRawOutput(buf, terminalID: termID)
        }

        // Give the delivery thread time to write.
        Thread.sleep(forTimeInterval: 1.0)

        // Shutdown to flush.
        manager.deactivateTerminal(id: termID)

        // Wait for hook process to finish writing and exit.
        Thread.sleep(forTimeInterval: 1.0)

        // Verify the temp file contains our data.
        let content = try? String(contentsOfFile: tempFile, encoding: .utf8)
        XCTAssertEqual(content, "Hello, Hook!\n",
                       "Hook should have received dispatched data")

        pty.write("exit\n")
        wait(for: [exitExpectation], timeout: 8.0)
    }

    // MARK: - EPIPE Handling

    func testEPIPEDeactivatesHook() {
        // Use a command that exits immediately, causing EPIPE on write.
        let hook = makeHook(command: "true")  // exits immediately
        let config = makeConfig(hooks: [hook])
        let manager = IOHookManager(config: config)
        defer { manager.shutdown() }

        let pty = PTY()
        defer { pty.stop(waitForExit: true) }

        let exitExpectation = expectation(description: "pty-exit")
        var exited = false
        let lock = NSLock()
        pty.onOutput = { _ in }
        pty.onExit = {
            lock.lock()
            defer { lock.unlock() }
            guard !exited else { return }
            exited = true
            exitExpectation.fulfill()
        }

        do {
            try pty.start(rows: 24, cols: 80, initialDirectory: NSTemporaryDirectory())
        } catch {
            return XCTFail("Failed to start PTY: \(error)")
        }

        let termID = UUID()
        let queue = DispatchQueue(label: "test.hook-manager")
        manager.activateTerminal(id: termID, masterFD: pty.testMasterFD,
                                 shellPID: pty.childPID, ptyQueue: queue)

        // Wait for "true" to exit.
        Thread.sleep(forTimeInterval: 1.0)

        // Try to dispatch data — should hit EPIPE and deactivate.
        let testData: [UInt8] = Array("test\n".utf8)
        testData.withUnsafeBufferPointer { buf in
            manager.dispatchRawOutput(buf, terminalID: termID)
        }

        // Give time for the delivery thread to detect EPIPE.
        Thread.sleep(forTimeInterval: 1.0)

        // Hook should no longer be active.
        XCTAssertFalse(manager.hasActiveHooks(for: termID),
                       "Hook should be deactivated after EPIPE")

        pty.write("exit\n")
        wait(for: [exitExpectation], timeout: 8.0)
    }

    // MARK: - Process Match

    func testProcessMatchFilteringWithNoMatch() {
        // Hook only matches "claude" but the shell is zsh/bash.
        let hook = makeHook(processMatch: "^claude$")
        let config = makeConfig(hooks: [hook])
        let manager = IOHookManager(config: config)
        defer { manager.shutdown() }

        let pty = PTY()
        defer { pty.stop(waitForExit: true) }

        let exitExpectation = expectation(description: "pty-exit")
        var exited = false
        let lock = NSLock()
        pty.onOutput = { _ in }
        pty.onExit = {
            lock.lock()
            defer { lock.unlock() }
            guard !exited else { return }
            exited = true
            exitExpectation.fulfill()
        }

        do {
            try pty.start(rows: 24, cols: 80, initialDirectory: NSTemporaryDirectory())
        } catch {
            return XCTFail("Failed to start PTY: \(error)")
        }

        let termID = UUID()
        let queue = DispatchQueue(label: "test.hook-manager")
        manager.activateTerminal(id: termID, masterFD: pty.testMasterFD,
                                 shellPID: pty.childPID, ptyQueue: queue)

        Thread.sleep(forTimeInterval: 0.5)

        // No hooks should be active since the shell process doesn't match "claude".
        XCTAssertFalse(manager.hasActiveHooks(for: termID),
                       "No hooks should be active when process doesn't match")

        pty.write("exit\n")
        wait(for: [exitExpectation], timeout: 8.0)
    }

    func testProcessMatchNilMatchesAll() {
        let hook = makeHook(processMatch: nil)
        let config = makeConfig(hooks: [hook])
        let manager = IOHookManager(config: config)
        defer { manager.shutdown() }

        let pty = PTY()
        defer { pty.stop(waitForExit: true) }

        let exitExpectation = expectation(description: "pty-exit")
        var exited = false
        let lock = NSLock()
        pty.onOutput = { _ in }
        pty.onExit = {
            lock.lock()
            defer { lock.unlock() }
            guard !exited else { return }
            exited = true
            exitExpectation.fulfill()
        }

        do {
            try pty.start(rows: 24, cols: 80, initialDirectory: NSTemporaryDirectory())
        } catch {
            return XCTFail("Failed to start PTY: \(error)")
        }

        let termID = UUID()
        let queue = DispatchQueue(label: "test.hook-manager")
        manager.activateTerminal(id: termID, masterFD: pty.testMasterFD,
                                 shellPID: pty.childPID, ptyQueue: queue)

        Thread.sleep(forTimeInterval: 0.5)

        // Hook with no process_match should be active for any process.
        XCTAssertTrue(manager.hasActiveHooks(for: termID),
                      "Hook with nil process_match should match all processes")

        pty.write("exit\n")
        wait(for: [exitExpectation], timeout: 8.0)
    }

    // MARK: - Recursive Prevention

    func testHookChildPIDTracking() {
        let hook = makeHook(command: "sleep 60")
        let config = makeConfig(hooks: [hook])
        let manager = IOHookManager(config: config)
        defer { manager.shutdown() }

        let pty = PTY()
        defer { pty.stop(waitForExit: true) }

        let exitExpectation = expectation(description: "pty-exit")
        var exited = false
        let lock = NSLock()
        pty.onOutput = { _ in }
        pty.onExit = {
            lock.lock()
            defer { lock.unlock() }
            guard !exited else { return }
            exited = true
            exitExpectation.fulfill()
        }

        do {
            try pty.start(rows: 24, cols: 80, initialDirectory: NSTemporaryDirectory())
        } catch {
            return XCTFail("Failed to start PTY: \(error)")
        }

        let termID = UUID()
        let queue = DispatchQueue(label: "test.hook-manager")
        manager.activateTerminal(id: termID, masterFD: pty.testMasterFD,
                                 shellPID: pty.childPID, ptyQueue: queue)

        Thread.sleep(forTimeInterval: 0.5)

        // The hook's child PID should NOT be the same as the shell PID.
        XCTAssertFalse(manager.isHookChildProcess(pty.childPID),
                       "Shell PID should not be in hook child PIDs")

        // After deactivation, hook child PIDs should be cleared.
        manager.deactivateTerminal(id: termID)
        Thread.sleep(forTimeInterval: 0.5)

        pty.write("exit\n")
        wait(for: [exitExpectation], timeout: 8.0)
    }

    // MARK: - Multi-Terminal Isolation

    func testMultipleTerminalsIndependent() {
        let hook = makeHook(command: "cat > /dev/null")
        let config = makeConfig(hooks: [hook])
        let manager = IOHookManager(config: config)
        defer { manager.shutdown() }

        let pty1 = PTY()
        let pty2 = PTY()
        defer { pty1.stop(waitForExit: true) }
        defer { pty2.stop(waitForExit: true) }

        let exit1 = expectation(description: "pty1-exit")
        let exit2 = expectation(description: "pty2-exit")
        var exited1 = false
        var exited2 = false
        let lock = NSLock()

        pty1.onOutput = { _ in }
        pty2.onOutput = { _ in }
        pty1.onExit = {
            lock.lock()
            defer { lock.unlock() }
            guard !exited1 else { return }
            exited1 = true
            exit1.fulfill()
        }
        pty2.onExit = {
            lock.lock()
            defer { lock.unlock() }
            guard !exited2 else { return }
            exited2 = true
            exit2.fulfill()
        }

        do {
            try pty1.start(rows: 24, cols: 80, initialDirectory: NSTemporaryDirectory())
            try pty2.start(rows: 24, cols: 80, initialDirectory: NSTemporaryDirectory())
        } catch {
            return XCTFail("Failed to start PTY: \(error)")
        }

        let termID1 = UUID()
        let termID2 = UUID()
        let queue = DispatchQueue(label: "test.hook-manager")

        manager.activateTerminal(id: termID1, masterFD: pty1.testMasterFD,
                                 shellPID: pty1.childPID, ptyQueue: queue)
        manager.activateTerminal(id: termID2, masterFD: pty2.testMasterFD,
                                 shellPID: pty2.childPID, ptyQueue: queue)

        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertTrue(manager.hasActiveHooks(for: termID1))
        XCTAssertTrue(manager.hasActiveHooks(for: termID2))

        // Deactivating one terminal should not affect the other.
        manager.deactivateTerminal(id: termID1)
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertFalse(manager.hasActiveHooks(for: termID1))
        XCTAssertTrue(manager.hasActiveHooks(for: termID2))

        manager.deactivateTerminal(id: termID2)

        pty1.write("exit\n")
        pty2.write("exit\n")
        wait(for: [exit1, exit2], timeout: 8.0)
    }

    // MARK: - Shutdown Idempotency

    func testShutdownIsIdempotent() {
        let hook = makeHook(command: "cat > /dev/null")
        let config = makeConfig(hooks: [hook])
        let manager = IOHookManager(config: config)

        manager.shutdown()
        manager.shutdown()  // Must not crash.
    }

    // MARK: - Stdin Hook

    func testStdinHookReceivesInput() {
        let tempFile = NSTemporaryDirectory() + "pterm_stdin_hook_\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: tempFile) }

        let hook = makeHook(
            name: "stdin-logger",
            target: .stdin,
            command: "cat >> \(tempFile)"
        )
        let config = makeConfig(hooks: [hook])
        let manager = IOHookManager(config: config)
        defer { manager.shutdown() }

        let pty = PTY()
        defer { pty.stop(waitForExit: true) }

        let exitExpectation = expectation(description: "pty-exit")
        var exited = false
        let lock = NSLock()
        pty.onOutput = { _ in }
        pty.onExit = {
            lock.lock()
            defer { lock.unlock() }
            guard !exited else { return }
            exited = true
            exitExpectation.fulfill()
        }

        do {
            try pty.start(rows: 24, cols: 80, initialDirectory: NSTemporaryDirectory())
        } catch {
            return XCTFail("Failed to start PTY: \(error)")
        }

        let termID = UUID()
        let queue = DispatchQueue(label: "test.hook-manager")
        manager.activateTerminal(id: termID, masterFD: pty.testMasterFD,
                                 shellPID: pty.childPID, ptyQueue: queue)

        Thread.sleep(forTimeInterval: 0.5)

        // Dispatch stdin data.
        let inputData = Data("ls -la\n".utf8)
        manager.dispatchRawInput(inputData, terminalID: termID)

        Thread.sleep(forTimeInterval: 1.0)
        manager.deactivateTerminal(id: termID)
        Thread.sleep(forTimeInterval: 1.0)

        let content = try? String(contentsOfFile: tempFile, encoding: .utf8)
        XCTAssertEqual(content, "ls -la\n",
                       "Stdin hook should receive input data")

        pty.write("exit\n")
        wait(for: [exitExpectation], timeout: 8.0)
    }

    // MARK: - Disabled Hook

    func testDisabledHookNotActivated() {
        var hook = makeHook(command: "cat > /dev/null")
        // Create a disabled hook entry.
        hook = IOHookEntry(
            enabled: false,
            name: hook.name,
            target: hook.target,
            buffering: hook.buffering,
            idleMs: hook.idleMs,
            bufferSize: hook.bufferSize,
            command: hook.command,
            processMatch: hook.processMatch,
            processMatchRegex: hook.processMatchRegex,
            includeChildren: hook.includeChildren
        )
        let config = makeConfig(hooks: [hook])
        let manager = IOHookManager(config: config)
        defer { manager.shutdown() }

        let pty = PTY()
        defer { pty.stop(waitForExit: true) }

        let exitExpectation = expectation(description: "pty-exit")
        var exited = false
        let lock = NSLock()
        pty.onOutput = { _ in }
        pty.onExit = {
            lock.lock()
            defer { lock.unlock() }
            guard !exited else { return }
            exited = true
            exitExpectation.fulfill()
        }

        do {
            try pty.start(rows: 24, cols: 80, initialDirectory: NSTemporaryDirectory())
        } catch {
            return XCTFail("Failed to start PTY: \(error)")
        }

        let termID = UUID()
        let queue = DispatchQueue(label: "test.hook-manager")
        manager.activateTerminal(id: termID, masterFD: pty.testMasterFD,
                                 shellPID: pty.childPID, ptyQueue: queue)

        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertFalse(manager.hasActiveHooks(for: termID),
                       "Disabled hook should not be activated")

        pty.write("exit\n")
        wait(for: [exitExpectation], timeout: 8.0)
    }

    // MARK: - needsTextCapture

    func testNeedsTextCaptureForLineModeHook() {
        let hook = makeHook(buffering: .line, command: "cat > /dev/null")
        let config = makeConfig(hooks: [hook])
        let manager = IOHookManager(config: config)
        defer { manager.shutdown() }

        let pty = PTY()
        defer { pty.stop(waitForExit: true) }

        let exitExpectation = expectation(description: "pty-exit")
        var exited = false
        let lock = NSLock()
        pty.onOutput = { _ in }
        pty.onExit = {
            lock.lock()
            defer { lock.unlock() }
            guard !exited else { return }
            exited = true
            exitExpectation.fulfill()
        }

        do {
            try pty.start(rows: 24, cols: 80, initialDirectory: NSTemporaryDirectory())
        } catch {
            return XCTFail("Failed to start PTY: \(error)")
        }

        let termID = UUID()
        let queue = DispatchQueue(label: "test.hook-manager")
        manager.activateTerminal(id: termID, masterFD: pty.testMasterFD,
                                 shellPID: pty.childPID, ptyQueue: queue)

        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertTrue(manager.needsTextCapture(for: termID),
                      "Line-mode hook should require text capture")

        pty.write("exit\n")
        wait(for: [exitExpectation], timeout: 8.0)
    }

    func testNoTextCaptureNeededForImmediateModeOnly() {
        let hook = makeHook(buffering: .immediate, command: "cat > /dev/null")
        let config = makeConfig(hooks: [hook])
        let manager = IOHookManager(config: config)
        defer { manager.shutdown() }

        let pty = PTY()
        defer { pty.stop(waitForExit: true) }

        let exitExpectation = expectation(description: "pty-exit")
        var exited = false
        let lock = NSLock()
        pty.onOutput = { _ in }
        pty.onExit = {
            lock.lock()
            defer { lock.unlock() }
            guard !exited else { return }
            exited = true
            exitExpectation.fulfill()
        }

        do {
            try pty.start(rows: 24, cols: 80, initialDirectory: NSTemporaryDirectory())
        } catch {
            return XCTFail("Failed to start PTY: \(error)")
        }

        let termID = UUID()
        let queue = DispatchQueue(label: "test.hook-manager")
        manager.activateTerminal(id: termID, masterFD: pty.testMasterFD,
                                 shellPID: pty.childPID, ptyQueue: queue)

        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertFalse(manager.needsTextCapture(for: termID),
                       "Immediate-mode-only hooks should not need text capture")

        pty.write("exit\n")
        wait(for: [exitExpectation], timeout: 8.0)
    }

    // MARK: - Line Mode Text Delivery

    func testLineModeDelivery() {
        let tempFile = NSTemporaryDirectory() + "pterm_line_hook_\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: tempFile) }

        let hook = makeHook(
            name: "line-logger",
            target: .output,
            buffering: .line,
            command: "cat >> \(tempFile)"
        )
        let config = makeConfig(hooks: [hook])
        let manager = IOHookManager(config: config)
        defer { manager.shutdown() }

        let pty = PTY()
        defer { pty.stop(waitForExit: true) }

        let exitExpectation = expectation(description: "pty-exit")
        var exited = false
        let lock = NSLock()
        pty.onOutput = { _ in }
        pty.onExit = {
            lock.lock()
            defer { lock.unlock() }
            guard !exited else { return }
            exited = true
            exitExpectation.fulfill()
        }

        do {
            try pty.start(rows: 24, cols: 80, initialDirectory: NSTemporaryDirectory())
        } catch {
            return XCTFail("Failed to start PTY: \(error)")
        }

        let termID = UUID()
        let queue = DispatchQueue(label: "test.hook-manager")
        manager.activateTerminal(id: termID, masterFD: pty.testMasterFD,
                                 shellPID: pty.childPID, ptyQueue: queue)

        Thread.sleep(forTimeInterval: 0.5)

        // Simulate VT parser emitting characters then a newline.
        for char in "Hello".unicodeScalars {
            manager.dispatchTextCharacter(char.value, terminalID: termID)
        }
        // Newline triggers flush.
        manager.dispatchTextCharacter(0x0A, terminalID: termID)

        Thread.sleep(forTimeInterval: 1.0)
        manager.deactivateTerminal(id: termID)
        Thread.sleep(forTimeInterval: 1.0)

        let content = try? String(contentsOfFile: tempFile, encoding: .utf8)
        XCTAssertEqual(content, "Hello\n",
                       "Line-mode hook should receive accumulated text on newline")

        pty.write("exit\n")
        wait(for: [exitExpectation], timeout: 8.0)
    }
}

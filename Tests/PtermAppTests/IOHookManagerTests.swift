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
                          diffOnly: Bool = IOHookEntry.defaultDiffOnly,
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
            diffOnly: diffOnly,
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
            diffOnly: hook.diffOnly,
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

    // MARK: - Line Mode CR/LF Handling

    func testLineModeDoesNotFlushOnCR() {
        // Bug regression: sending "Hello\r\n" should produce exactly one
        // "Hello\n" line, not "Hello\n" followed by a spurious "\n".
        let tempFile = NSTemporaryDirectory() + "pterm_crlf_test_\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: tempFile) }

        let hook = makeHook(
            name: "crlf-test",
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

        // Send "Hello\r\n" character by character.
        for char in "Hello".unicodeScalars {
            manager.dispatchTextCharacter(char.value, terminalID: termID)
        }
        manager.dispatchTextCharacter(0x0D, terminalID: termID)  // CR
        manager.dispatchTextCharacter(0x0A, terminalID: termID)  // LF

        Thread.sleep(forTimeInterval: 1.0)
        manager.deactivateTerminal(id: termID)
        Thread.sleep(forTimeInterval: 1.0)

        let content = try? String(contentsOfFile: tempFile, encoding: .utf8)
        XCTAssertEqual(content, "Hello\n",
                       "CR+LF should produce exactly one 'Hello\\n', not 'Hello\\n\\n'")

        pty.write("exit\n")
        wait(for: [exitExpectation], timeout: 8.0)
    }

    func testLineModeMultipleLinesWithCRLF() {
        let tempFile = NSTemporaryDirectory() + "pterm_multi_crlf_\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: tempFile) }

        let hook = makeHook(
            name: "multi-crlf",
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

        // Send "Line1\r\nLine2\r\n"
        for char in "Line1".unicodeScalars {
            manager.dispatchTextCharacter(char.value, terminalID: termID)
        }
        manager.dispatchTextCharacter(0x0D, terminalID: termID)
        manager.dispatchTextCharacter(0x0A, terminalID: termID)
        for char in "Line2".unicodeScalars {
            manager.dispatchTextCharacter(char.value, terminalID: termID)
        }
        manager.dispatchTextCharacter(0x0D, terminalID: termID)
        manager.dispatchTextCharacter(0x0A, terminalID: termID)

        Thread.sleep(forTimeInterval: 1.0)
        manager.deactivateTerminal(id: termID)
        Thread.sleep(forTimeInterval: 1.0)

        let content = try? String(contentsOfFile: tempFile, encoding: .utf8)
        XCTAssertEqual(content, "Line1\nLine2\n",
                       "Multiple CR+LF lines should produce correct output")

        pty.write("exit\n")
        wait(for: [exitExpectation], timeout: 8.0)
    }

    func testLineModeUnicodeCharacters() {
        let tempFile = NSTemporaryDirectory() + "pterm_unicode_\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: tempFile) }

        let hook = makeHook(
            name: "unicode-test",
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

        // Send Japanese text: "こんにちは" + LF
        for char in "こんにちは".unicodeScalars {
            manager.dispatchTextCharacter(char.value, terminalID: termID)
        }
        manager.dispatchTextCharacter(0x0A, terminalID: termID)

        Thread.sleep(forTimeInterval: 1.0)
        manager.deactivateTerminal(id: termID)
        Thread.sleep(forTimeInterval: 1.0)

        let content = try? String(contentsOfFile: tempFile, encoding: .utf8)
        XCTAssertEqual(content, "こんにちは\n",
                       "Line-mode should correctly handle Japanese/Unicode characters")

        pty.write("exit\n")
        wait(for: [exitExpectation], timeout: 8.0)
    }

    func testLineModeEmptyLineOnLF() {
        let tempFile = NSTemporaryDirectory() + "pterm_empty_lf_\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: tempFile) }

        let hook = makeHook(
            name: "empty-lf-test",
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

        // Send just LF — should flush an empty line (just "\n").
        manager.dispatchTextCharacter(0x0A, terminalID: termID)

        Thread.sleep(forTimeInterval: 1.0)
        manager.deactivateTerminal(id: termID)
        Thread.sleep(forTimeInterval: 1.0)

        let content = try? String(contentsOfFile: tempFile, encoding: .utf8)
        XCTAssertEqual(content, "\n",
                       "Just LF should flush an empty line")

        pty.write("exit\n")
        wait(for: [exitExpectation], timeout: 8.0)
    }

    // MARK: - forceResetAllProcesses

    func testForceResetAllProcesses() {
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

        let termID = UUID()
        let queue = DispatchQueue(label: "test.hook-manager")
        manager.activateTerminal(id: termID, masterFD: pty.testMasterFD,
                                 shellPID: pty.childPID, ptyQueue: queue)

        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(manager.hasActiveHooks(for: termID),
                      "Hook should be active before reset")

        // Force reset should kill and respawn.
        manager.forceResetAllProcesses()

        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertTrue(manager.hasActiveHooks(for: termID),
                      "Hook should be re-activated after forceResetAllProcesses")

        pty.write("exit\n")
        wait(for: [exitExpectation], timeout: 8.0)
    }

    // MARK: - activeInstanceCount

    func testActiveInstanceCount() {
        let hook = makeHook(command: "cat > /dev/null")
        let config = makeConfig(hooks: [hook])
        let manager = IOHookManager(config: config)
        defer { manager.shutdown() }

        XCTAssertEqual(manager.activeInstanceCount, 0,
                       "No instances before activation")

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
        XCTAssertEqual(manager.activeInstanceCount, 1,
                       "One hook on one terminal = 1 active instance")

        manager.deactivateTerminal(id: termID)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(manager.activeInstanceCount, 0,
                       "After deactivation, count should be 0")

        pty.write("exit\n")
        wait(for: [exitExpectation], timeout: 8.0)
    }

    // MARK: - needsIdleMode

    func testNeedsIdleModeForIdleHook() {
        let hook = makeHook(
            name: "idle-hook",
            target: .output,
            buffering: .idle,
            command: "cat > /dev/null"
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
        XCTAssertTrue(manager.needsIdleMode(for: termID),
                      "Idle-buffered hook should require idle mode")

        pty.write("exit\n")
        wait(for: [exitExpectation], timeout: 8.0)
    }

    // MARK: - Multiple Hooks on Same Terminal

    func testMultipleHooksOnSameTerminal() {
        let tempFile1 = NSTemporaryDirectory() + "pterm_multi1_\(UUID().uuidString).txt"
        let tempFile2 = NSTemporaryDirectory() + "pterm_multi2_\(UUID().uuidString).txt"
        defer {
            try? FileManager.default.removeItem(atPath: tempFile1)
            try? FileManager.default.removeItem(atPath: tempFile2)
        }

        let hook1 = makeHook(
            name: "imm-hook",
            target: .output,
            buffering: .immediate,
            command: "cat >> \(tempFile1)"
        )
        let hook2 = makeHook(
            name: "line-hook",
            target: .output,
            buffering: .line,
            command: "cat >> \(tempFile2)"
        )
        let config = makeConfig(hooks: [hook1, hook2])
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
        XCTAssertEqual(manager.activeInstanceCount, 2,
                       "Two hooks on same terminal should create 2 active instances")

        pty.write("exit\n")
        wait(for: [exitExpectation], timeout: 8.0)
    }

    // MARK: - Deactivate Cleans Up All Hooks

    func testDeactivateTerminalCleansUpAllHooks() {
        let hook1 = makeHook(name: "hook-a", command: "cat > /dev/null")
        let hook2 = makeHook(name: "hook-b", buffering: .line, command: "cat > /dev/null")
        let config = makeConfig(hooks: [hook1, hook2])
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
        XCTAssertEqual(manager.activeInstanceCount, 2)

        manager.deactivateTerminal(id: termID)
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertEqual(manager.activeInstanceCount, 0,
                       "All hooks should be cleaned up after deactivateTerminal")
        XCTAssertFalse(manager.hasActiveHooks(for: termID))
        XCTAssertFalse(manager.needsTextCapture(for: termID))

        pty.write("exit\n")
        wait(for: [exitExpectation], timeout: 8.0)
    }

    // MARK: - dispatchTextLine

    func testDispatchTextLineDelivery() {
        let tempFile = NSTemporaryDirectory() + "pterm_textline_\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: tempFile) }

        let hook = makeHook(
            name: "textline-test",
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

        // dispatchTextLine appends \n automatically.
        manager.dispatchTextLine("Hello World", terminalID: termID)

        Thread.sleep(forTimeInterval: 1.0)
        manager.deactivateTerminal(id: termID)
        Thread.sleep(forTimeInterval: 1.0)

        let content = try? String(contentsOfFile: tempFile, encoding: .utf8)
        XCTAssertEqual(content, "Hello World\n",
                       "dispatchTextLine should deliver the line with a trailing newline")

        pty.write("exit\n")
        wait(for: [exitExpectation], timeout: 8.0)
    }

    func testDispatchTextLineIgnoresEmptyString() {
        let tempFile = NSTemporaryDirectory() + "pterm_emptyline_\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: tempFile) }

        let hook = makeHook(
            name: "emptyline-test",
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

        // Empty string should be ignored.
        manager.dispatchTextLine("", terminalID: termID)
        // But non-empty should still work.
        manager.dispatchTextLine("After empty", terminalID: termID)

        Thread.sleep(forTimeInterval: 1.0)
        manager.deactivateTerminal(id: termID)
        Thread.sleep(forTimeInterval: 1.0)

        let content = try? String(contentsOfFile: tempFile, encoding: .utf8)
        XCTAssertEqual(content, "After empty\n",
                       "Empty dispatchTextLine should be silently ignored")

        pty.write("exit\n")
        wait(for: [exitExpectation], timeout: 8.0)
    }

    // MARK: - CR-only (no LF) should not flush

    func testLineModeCarriageReturnOnlyDoesNotFlush() {
        let tempFile = NSTemporaryDirectory() + "pterm_cronly_\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: tempFile) }

        let hook = makeHook(
            name: "cr-only-test",
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

        // Send "Hello" followed by CR only (no LF) - should NOT flush.
        for char in "Hello".unicodeScalars {
            manager.dispatchTextCharacter(char.value, terminalID: termID)
        }
        manager.dispatchTextCharacter(0x0D, terminalID: termID)  // CR only

        Thread.sleep(forTimeInterval: 0.5)

        // Now send "World" + LF - should flush "HelloWorld" since CR was ignored.
        for char in "World".unicodeScalars {
            manager.dispatchTextCharacter(char.value, terminalID: termID)
        }
        manager.dispatchTextCharacter(0x0A, terminalID: termID)

        Thread.sleep(forTimeInterval: 1.0)
        manager.deactivateTerminal(id: termID)
        Thread.sleep(forTimeInterval: 1.0)

        let content = try? String(contentsOfFile: tempFile, encoding: .utf8)
        XCTAssertEqual(content, "HelloWorld\n",
                       "CR alone should not flush - text continues accumulating until LF")

        pty.write("exit\n")
        wait(for: [exitExpectation], timeout: 8.0)
    }

    // MARK: - Invalid Unicode Scalar in dispatchTextCharacter

    func testLineModeHandlesInvalidUnicodeScalar() {
        let tempFile = NSTemporaryDirectory() + "pterm_invalid_unicode_\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: tempFile) }

        let hook = makeHook(
            name: "invalid-unicode-test",
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

        // Send a valid char, then an invalid surrogate half (0xD800), then LF.
        manager.dispatchTextCharacter(0x41, terminalID: termID)  // 'A'
        manager.dispatchTextCharacter(0xD800, terminalID: termID)  // Invalid surrogate
        manager.dispatchTextCharacter(0x0A, terminalID: termID)  // LF

        Thread.sleep(forTimeInterval: 1.0)
        manager.deactivateTerminal(id: termID)
        Thread.sleep(forTimeInterval: 1.0)

        let content = try? String(contentsOfFile: tempFile, encoding: .utf8)
        // Invalid scalar should be replaced with U+FFFD (replacement character).
        XCTAssertEqual(content, "A\u{FFFD}\n",
                       "Invalid unicode scalar should be replaced with U+FFFD")

        pty.write("exit\n")
        wait(for: [exitExpectation], timeout: 8.0)
    }

    // MARK: - Grid reader registration for idle mode

    func testRegisterGridReaderDoesNotCrash() {
        let hook = makeHook(
            name: "idle-grid",
            target: .output,
            buffering: .idle,
            command: "cat > /dev/null"
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

        // Register a grid reader.
        manager.registerGridReader(terminalID: termID, rows: 24, cols: 80) { row, cols in
            row < 3 ? "Line \(row)" : nil
        }

        // Update grid dimensions.
        manager.updateGridDimensions(terminalID: termID, rows: 25, cols: 80)

        // Notify dirty row.
        manager.notifyDirtyRow(0, terminalID: termID)

        // Notify resize and alternate screen changes.
        manager.notifyResize(terminalID: termID)
        manager.notifyAlternateScreenChange(terminalID: termID)

        // None of this should crash.
        Thread.sleep(forTimeInterval: 0.5)

        pty.write("exit\n")
        wait(for: [exitExpectation], timeout: 8.0)
    }

    // MARK: - Rapid dispatch stress test

    func testRapidLineModeDispatchDoesNotCrash() {
        let tempFile = NSTemporaryDirectory() + "pterm_rapid_\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: tempFile) }

        let hook = makeHook(
            name: "rapid-test",
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

        // Rapidly dispatch 100 lines.
        for i in 0..<100 {
            for char in "Line\(i)".unicodeScalars {
                manager.dispatchTextCharacter(char.value, terminalID: termID)
            }
            manager.dispatchTextCharacter(0x0A, terminalID: termID)
        }

        Thread.sleep(forTimeInterval: 2.0)
        manager.deactivateTerminal(id: termID)
        Thread.sleep(forTimeInterval: 1.0)

        // Verify the file was written (at least partially).
        let content = try? String(contentsOfFile: tempFile, encoding: .utf8)
        XCTAssertNotNil(content, "Rapid dispatch should produce output")
        if let content {
            XCTAssertTrue(content.contains("Line0\n"),
                          "First line should be present")
        }

        pty.write("exit\n")
        wait(for: [exitExpectation], timeout: 8.0)
    }

    // MARK: - forceResetAllProcesses after shutdown is safe

    func testForceResetAfterShutdownIsSafe() {
        let hook = makeHook(command: "cat > /dev/null")
        let config = makeConfig(hooks: [hook])
        let manager = IOHookManager(config: config)

        manager.shutdown()
        // This should not crash or do anything.
        manager.forceResetAllProcesses()

        XCTAssertEqual(manager.activeInstanceCount, 0)
    }

    // MARK: - isHookChildProcess returns false for unknown PID

    func testIsHookChildProcessReturnsFalseForUnknownPID() {
        let config = makeConfig(hooks: [makeHook()])
        let manager = IOHookManager(config: config)
        defer { manager.shutdown() }

        XCTAssertFalse(manager.isHookChildProcess(99999),
                       "Unknown PID should not be a hook child process")
    }

    // MARK: - needsTextCapture with idle mode

    func testNeedsTextCaptureForIdleModeHook() {
        let hook = makeHook(
            name: "idle-capture",
            target: .output,
            buffering: .idle,
            command: "cat > /dev/null"
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

        XCTAssertTrue(manager.needsTextCapture(for: termID),
                      "Idle-mode hook should also require text capture")

        pty.write("exit\n")
        wait(for: [exitExpectation], timeout: 8.0)
    }

    // MARK: - Dispatch to non-existent terminal

    func testDispatchToNonExistentTerminalDoesNotCrash() {
        let hook = makeHook(command: "cat > /dev/null")
        let config = makeConfig(hooks: [hook])
        let manager = IOHookManager(config: config)
        defer { manager.shutdown() }

        let fakeTermID = UUID()

        // These should all silently return without crashing.
        let testData: [UInt8] = Array("test\n".utf8)
        testData.withUnsafeBufferPointer { buf in
            manager.dispatchRawOutput(buf, terminalID: fakeTermID)
        }
        manager.dispatchRawInput(Data("test\n".utf8), terminalID: fakeTermID)
        manager.dispatchTextLine("test", terminalID: fakeTermID)
        manager.dispatchTextCharacter(0x41, terminalID: fakeTermID)

        // Query methods should return false/0.
        XCTAssertFalse(manager.hasActiveHooks(for: fakeTermID))
        XCTAssertFalse(manager.needsTextCapture(for: fakeTermID))
        XCTAssertFalse(manager.needsIdleMode(for: fakeTermID))
    }

    // MARK: - Operations after shutdown

    func testOperationsAfterShutdownAreSafe() {
        let hook = makeHook(command: "cat > /dev/null")
        let config = makeConfig(hooks: [hook])
        let manager = IOHookManager(config: config)

        manager.shutdown()

        let termID = UUID()

        // All operations after shutdown should be safe no-ops.
        let testData: [UInt8] = Array("test\n".utf8)
        testData.withUnsafeBufferPointer { buf in
            manager.dispatchRawOutput(buf, terminalID: termID)
        }
        manager.dispatchRawInput(Data("test\n".utf8), terminalID: termID)
        manager.dispatchTextLine("test", terminalID: termID)
        manager.dispatchTextCharacter(0x41, terminalID: termID)
        manager.deactivateTerminal(id: termID)

        XCTAssertFalse(manager.hasActiveHooks(for: termID))
        XCTAssertEqual(manager.activeInstanceCount, 0)
    }

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

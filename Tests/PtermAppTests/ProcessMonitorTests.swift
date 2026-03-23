import XCTest
@testable import PtermApp

final class ProcessMonitorTests: XCTestCase {

    // MARK: - Creation

    func testCreateWithValidMasterFDSucceeds() {
        // Use a real PTY to get a valid master fd
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

        let queue = DispatchQueue(label: "test.process-monitor")
        let monitor = ProcessMonitor(masterFD: pty.testMasterFD, shellPID: pty.childPID, queue: queue)
        XCTAssertNotNil(monitor, "ProcessMonitor should initialize with a valid PTY")
        monitor?.stop()

        pty.write("exit\n")
        wait(for: [exitExpectation], timeout: 8.0)
    }

    // MARK: - Foreground Process Change Detection

    func testDetectsForegroundProcessChange() {
        let pty = PTY()
        defer { pty.stop(waitForExit: true) }

        let exitExpectation = expectation(description: "pty-exit")
        let changeExpectation = expectation(description: "foreground-change")
        changeExpectation.assertForOverFulfill = false
        var exited = false
        let lock = NSLock()
        var detectedNames: [String?] = []

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

        let queue = DispatchQueue(label: "test.process-monitor")
        guard let monitor = ProcessMonitor(masterFD: pty.testMasterFD, shellPID: pty.childPID, queue: queue) else {
            return XCTFail("Failed to create ProcessMonitor")
        }
        defer { monitor.stop() }

        monitor.onForegroundProcessChange = { name in
            lock.lock()
            detectedNames.append(name)
            lock.unlock()
            changeExpectation.fulfill()
        }
        monitor.start()

        // Run a short-lived command to trigger a process change
        pty.write("/bin/echo hello\n")
        // Then exit
        pty.write("exit\n")

        wait(for: [changeExpectation], timeout: 5.0)
        wait(for: [exitExpectation], timeout: 8.0)

        lock.lock()
        let names = detectedNames
        lock.unlock()

        // Should have detected at least one change (echo starting or exiting)
        XCTAssertFalse(names.isEmpty, "Should detect at least one foreground process change")
    }

    // MARK: - Resource Cleanup

    func testStopCleansUpResources() {
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

        let queue = DispatchQueue(label: "test.process-monitor")
        let monitor = ProcessMonitor(masterFD: pty.testMasterFD, shellPID: pty.childPID, queue: queue)
        XCTAssertNotNil(monitor)

        monitor?.start()
        monitor?.stop()

        // Stopping twice must not crash
        monitor?.stop()

        pty.write("exit\n")
        wait(for: [exitExpectation], timeout: 8.0)
    }

    // MARK: - High Water Mark

    func testHighWaterMarkPreventsUnboundedRegistration() {
        // This test verifies the concept — we can't easily fork 256+ processes
        // in a test, but we can verify the constant is set.
        XCTAssertEqual(ProcessMonitor.maxMonitoredPIDs, 256)
    }
}

import XCTest
@preconcurrency @testable import PtermApp

final class PTYIntegrationTests: XCTestCase {
    func testPTYExecutesZshCommandAndReturnsVersionMarker() throws {
        let pty = PTY()
        defer { pty.stop(waitForExit: true) }

        let marker = "__PTERM_ZSH_\(UUID().uuidString)__"
        let outputExpectation = expectation(description: "pty-zsh-output")
        let exitExpectation = expectation(description: "pty-zsh-exit")
        let lock = NSLock()
        var collectedOutput = ""
        var matched = false
        var exited = false

        pty.onOutput = { data in
            let chunk = String(decoding: data, as: UTF8.self)
            lock.lock()
            collectedOutput += chunk
            if !matched, collectedOutput.contains(marker) {
                matched = true
                outputExpectation.fulfill()
            }
            lock.unlock()
        }
        pty.onExit = {
            lock.lock()
            defer { lock.unlock() }
            guard !exited else { return }
            exited = true
            exitExpectation.fulfill()
        }

        try pty.start(rows: 24, cols: 80, initialDirectory: NSTemporaryDirectory())
        pty.write("printf '\(marker)%s__\\n' \"$ZSH_VERSION\"\nexit\n")

        wait(for: [outputExpectation, exitExpectation], timeout: 8.0)
        XCTAssertTrue(collectedOutput.contains(marker))
    }

    func testPTYSanitizesInvalidTERMBeforeLaunchingShell() throws {
        let pty = PTY()
        defer { pty.stop(waitForExit: true) }

        let marker = "__PTERM_TERM_\(UUID().uuidString)__"
        let outputExpectation = expectation(description: "pty-term-output")
        let exitExpectation = expectation(description: "pty-term-exit")
        let lock = NSLock()
        var collectedOutput = ""
        var matched = false
        var exited = false

        pty.onOutput = { data in
            let chunk = String(decoding: data, as: UTF8.self)
            lock.lock()
            collectedOutput += chunk
            if !matched, collectedOutput.contains("\(marker)xterm-256color__") {
                matched = true
                outputExpectation.fulfill()
            }
            lock.unlock()
        }
        pty.onExit = {
            lock.lock()
            defer { lock.unlock() }
            guard !exited else { return }
            exited = true
            exitExpectation.fulfill()
        }

        try pty.start(rows: 24, cols: 80, termEnv: "bad;term", initialDirectory: NSTemporaryDirectory())
        pty.write("printf '\(marker)%s__\\n' \"$TERM\"\nexit\n")

        wait(for: [outputExpectation, exitExpectation], timeout: 8.0)
        XCTAssertTrue(collectedOutput.contains("\(marker)xterm-256color__"))
    }

    @MainActor
    func testTerminalControllerRealPTYCoalescesDisplayNotificationsAcrossManyOutputLines() throws {
        let controller = TerminalController(
            rows: 4,
            cols: 32,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13
        )
        defer { controller.stop(waitForExit: true) }

        let exitExpectation = expectation(description: "controller-exit-display-coalesce")
        var displayCount = 0
        var outputActivityCount = 0
        var stateChangeCount = 0
        var exited = false
        controller.onNeedsDisplay = { displayCount += 1 }
        controller.onOutputActivity = { outputActivityCount += 1 }
        controller.onStateChange = { stateChangeCount += 1 }
        controller.onExit = {
            guard !exited else { return }
            exited = true
            exitExpectation.fulfill()
        }

        try controller.start()
        controller.sendInput("for i in {0..199}; do print -r -- 'burst'$i; done\nexit\n")

        wait(for: [exitExpectation], timeout: 8.0)
        drainMainQueue(testCase: self)

        XCTAssertGreaterThan(displayCount, 0)
        XCTAssertEqual(displayCount, outputActivityCount)
        XCTAssertEqual(stateChangeCount, 0)
        XCTAssertLessThan(displayCount, 200)
        XCTAssertTrue(controller.allText().contains("burst199"))
    }

    @MainActor
    func testTerminalControllerRealPTYEvictsOldHistoryUnderSmallScrollbackBudget() throws {
        let controller = TerminalController(
            rows: 4,
            cols: 32,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 1024,
            scrollbackMaxCapacity: 1024,
            fontName: "Menlo",
            fontSize: 13
        )
        defer { controller.stop(waitForExit: true) }

        let exitExpectation = expectation(description: "controller-exit")
        var outputActivityCount = 0
        var exited = false
        controller.onOutputActivity = { outputActivityCount += 1 }
        controller.onExit = {
            guard !exited else { return }
            exited = true
            exitExpectation.fulfill()
        }

        try controller.start()
        controller.sendInput("for i in {0..79}; do print -r -- '__ROW__'$i; done\nexit\n")

        wait(for: [exitExpectation], timeout: 8.0)
        drainMainQueue(testCase: self)

        XCTAssertGreaterThan(outputActivityCount, 0)
        XCTAssertLessThan(controller.scrollback.rowCount, 80)
        XCTAssertTrue(controller.findMatches(for: "__ROW__79").contains { $0.absoluteRow >= 0 })
        XCTAssertTrue(controller.findMatches(for: "__ROW__0").isEmpty)
        XCTAssertTrue(controller.allText().contains("__ROW__79"))
        XCTAssertFalse(controller.allText().contains("__ROW__0"))
    }

    @MainActor
    func testTerminalControllerRealPTYRemainsResponsiveDuringConcurrentResizeAndQueries() throws {
        let controller = TerminalController(
            rows: 6,
            cols: 40,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13
        )
        defer { controller.stop(waitForExit: true) }

        let exitExpectation = expectation(description: "controller-exit-concurrent-pty")
        let workerDone = expectation(description: "controller-worker-done")
        var exited = false
        controller.onExit = {
            guard !exited else { return }
            exited = true
            exitExpectation.fulfill()
        }

        try controller.start()

        DispatchQueue.global(qos: .userInitiated).async {
            for iteration in 0..<30 {
                controller.resize(rows: 6 + (iteration % 3), cols: 40 + (iteration % 7))
                _ = controller.findMatches(for: "live")
                _ = controller.allText()
                controller.scrollToBottom()
                usleep(5_000)
            }
            workerDone.fulfill()
        }

        controller.sendInput("for i in {0..299}; do print -r -- 'live'$i' marker'; done\nsleep 0.2\nexit\n")

        wait(for: [workerDone, exitExpectation], timeout: 10.0)
        drainMainQueue(testCase: self)

        XCTAssertTrue(controller.allText().contains("live299 marker"))
        let size = controller.withModel { ($0.rows, $0.cols) }
        XCTAssertGreaterThanOrEqual(size.0, 6)
        XCTAssertGreaterThanOrEqual(size.1, 40)
    }

    @MainActor
    func testTerminalControllerRealPTYSoakWithAuditLoggingRetainsLatestOutput() throws {
        try withTemporaryDirectory { directory in
            let controller = TerminalController(
                rows: 6,
                cols: 40,
                termEnv: "xterm-256color",
                textEncoding: .utf8,
                scrollbackInitialCapacity: 2048,
                scrollbackMaxCapacity: 2048,
                fontName: "Menlo",
                fontSize: 13
            )
            controller.auditLogger = TerminalAuditLogger(
                rootDirectory: directory,
                sessionID: controller.id,
                termEnv: "xterm-256color",
                workspaceNameProvider: { controller.sessionSnapshot.workspaceName },
                terminalNameProvider: { controller.title },
                sizeProvider: { (40, 6) }
            )
            defer {
                controller.auditLogger?.close()
                controller.stop(waitForExit: true)
            }

            let exitExpectation = expectation(description: "controller-exit-audit-soak")
            var exited = false
            controller.onExit = {
                guard !exited else { return }
                exited = true
                exitExpectation.fulfill()
            }

            try controller.start()
            controller.sendInput("for i in {0..499}; do print -r -- 'audit'$i' payload'; done\nexit\n")

            wait(for: [exitExpectation], timeout: 10.0)
            controller.auditLogger?.close()
            drainMainQueue(testCase: self)

            XCTAssertTrue(controller.allText().contains("audit499 payload"))

            let castFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .flatMap { root -> [URL] in
                    (try? FileManager.default.subpathsOfDirectory(atPath: root.path).map {
                        root.appendingPathComponent($0)
                    }) ?? []
                }
                .filter { $0.pathExtension == "cast" }
            XCTAssertFalse(castFiles.isEmpty)
            let payload = try castFiles.reduce(into: Data()) { partial, url in
                partial.append(try Data(contentsOf: url))
            }
            let text = String(decoding: payload, as: UTF8.self)
            XCTAssertTrue(text.contains("audit499 payload"))
        }
    }

    @MainActor
    func testTerminalControllerRealPTYConcurrentClearRestoreDirectorySelectionAndStop() throws {
        try withTemporaryDirectory { directory in
            let persistencePath = directory.appendingPathComponent("scrollback.bin").path
            let controller = TerminalController(
                rows: 6,
                cols: 40,
                termEnv: "xterm-256color",
                textEncoding: .utf8,
                scrollbackInitialCapacity: 4096,
                scrollbackMaxCapacity: 4096,
                fontName: "Menlo",
                fontSize: 13,
                scrollbackPersistencePath: persistencePath
            )
            defer { controller.stop(waitForExit: true) }

            let exitExpectation = expectation(description: "controller-exit-concurrent-mixed")
            let workerDone = expectation(description: "controller-mixed-worker-done")
            var exited = false
            controller.onExit = {
                guard !exited else { return }
                exited = true
                exitExpectation.fulfill()
            }

            try controller.start()
            controller.sendInput("for i in {0..199}; do print -r -- 'mix'$i; done\nsleep 0.3\n")

            DispatchQueue.global(qos: .userInitiated).async {
                for index in 0..<20 {
                    controller.updateCurrentDirectory(path: "/tmp/run\(index)")
                    controller.clearScrollback()
                    controller.restorePersistedScrollbackToViewport()
                    let selection = TerminalSelection(
                        anchor: GridPosition(row: 0, col: 0),
                        active: GridPosition(row: 0, col: 3),
                        mode: .normal
                    )
                    _ = controller.selectedText(for: selection)
                    usleep(10_000)
                }
                controller.stop(waitForExit: false)
                workerDone.fulfill()
            }

            wait(for: [workerDone, exitExpectation], timeout: 10.0)
            drainMainQueue(testCase: self)

            XCTAssertFalse(controller.isAlive)
            XCTAssertTrue(controller.sessionSnapshot.currentDirectory.hasPrefix("/tmp/run"))
            XCTAssertGreaterThanOrEqual(controller.scrollback.rowCount, 0)
        }
    }
}

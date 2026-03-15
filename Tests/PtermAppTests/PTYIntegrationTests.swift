import XCTest
@preconcurrency @testable import PtermApp

final class PTYIntegrationTests: XCTestCase {
    func testResolveShellPathPrefersUserShellThenFallsBackInOrder() {
        XCTAssertEqual(
            PTY.resolveShellPath(
                launchOrder: ["/custom/shell", "/bin/zsh", "/bin/bash", "/bin/sh"],
                userShellPath: "/custom/shell",
                isExecutable: { $0 == "/custom/shell" || $0 == "/bin/zsh" || $0 == "/bin/bash" || $0 == "/bin/sh" }
            ),
            "/custom/shell"
        )
        XCTAssertEqual(
            PTY.resolveShellPath(
                launchOrder: ["/missing/shell", "/bin/zsh", "/bin/bash", "/bin/sh"],
                userShellPath: "/missing/shell",
                isExecutable: { $0 == "/bin/zsh" || $0 == "/bin/bash" || $0 == "/bin/sh" }
            ),
            "/bin/zsh"
        )
        XCTAssertEqual(
            PTY.resolveShellPath(
                launchOrder: ["/missing/shell", "/bin/bash", "/bin/sh"],
                userShellPath: nil,
                isExecutable: { $0 == "/bin/bash" || $0 == "/bin/sh" }
            ),
            "/bin/bash"
        )
        XCTAssertEqual(
            PTY.resolveShellPath(
                launchOrder: ["/missing/shell"],
                userShellPath: "/bin/sh",
                isExecutable: { $0 == "/bin/sh" }
            ),
            "/bin/sh"
        )
    }

    func testPTYExecutesResolvedShellAndExportsMatchingShellEnvironment() throws {
        let pty = PTY()
        defer { pty.stop(waitForExit: true) }

        let marker = "__PTERM_SHELL_\(UUID().uuidString)__"
        let outputExpectation = expectation(description: "pty-shell-output")
        let exitExpectation = expectation(description: "pty-shell-exit")
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
        pty.write("shell_name=${0##*/}; shell_name=${shell_name#-}; env_name=${SHELL##*/}; printf '\(marker)%s|%s|%s|%s__\\n' \"$0\" \"$SHELL\" \"$shell_name\" \"$env_name\"\nexit\n")

        wait(for: [outputExpectation, exitExpectation], timeout: 8.0)
        XCTAssertTrue(collectedOutput.contains(marker))
        guard let range = collectedOutput.range(of: "\(marker)") else {
            return XCTFail("Missing shell marker in PTY output: \(collectedOutput)")
        }
        let suffix = collectedOutput[range.upperBound...]
        guard let endRange = suffix.range(of: "__") else {
            return XCTFail("Missing shell marker terminator in PTY output: \(collectedOutput)")
        }
        let payload = String(suffix[..<endRange.lowerBound])
        let parts = payload.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(parts.count, 4)
        XCTAssertFalse(parts[1].isEmpty)
        XCTAssertEqual(parts[2], parts[3])
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
        controller.sendInput("i=0; while [ \"$i\" -le 199 ]; do printf 'burst%s\\n' \"$i\"; i=$((i+1)); done\nexit\n")

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
        controller.sendInput("i=0; while [ \"$i\" -le 79 ]; do printf '__ROW__%s\\n' \"$i\"; i=$((i+1)); done\nexit\n")

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

        controller.sendInput("i=0; while [ \"$i\" -le 299 ]; do printf 'live%s marker\\n' \"$i\"; i=$((i+1)); done\nsleep 0.2\nexit\n")

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
            controller.sendInput("i=0; while [ \"$i\" -le 499 ]; do printf 'audit%s payload\\n' \"$i\"; i=$((i+1)); done\nexit\n")

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
            controller.sendInput("i=0; while [ \"$i\" -le 199 ]; do printf 'mix%s\\n' \"$i\"; i=$((i+1)); done\nsleep 0.3\n")

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

    @MainActor
    func testTerminalControllerRealPTYInterruptStopsStreamingBeforeAllLinesRender() throws {
        let controller = TerminalController(
            rows: 6,
            cols: 48,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13
        )
        defer { controller.stop(waitForExit: true) }

        let readyToInterrupt = expectation(description: "controller-stream-threshold-visible")
        let streamQuiesced = expectation(description: "controller-stream-quiesced-after-interrupt")
        let exitExpectation = expectation(description: "controller-exit-after-interrupt")

        let marker = "__INT__"
        let totalLines = 9_999
        let interruptThreshold = 20
        let quietInterval: TimeInterval = 0.30
        let lock = NSLock()
        var thresholdReached = false
        var interruptIssued = false
        var quietSignaled = false
        var exitSignaled = false
        var highestSeen = -1
        var lastProgressAt = CACurrentMediaTime()

        controller.onOutputActivity = {
            let snapshot = controller.allText()
            let latestSeen = Self.highestStreamingMarker(in: snapshot, marker: marker)
            var shouldInterrupt = false
            var shouldSignalThreshold = false

            lock.lock()
            if latestSeen > highestSeen {
                highestSeen = latestSeen
                lastProgressAt = CACurrentMediaTime()
            }
            if !thresholdReached, latestSeen >= interruptThreshold {
                thresholdReached = true
                shouldSignalThreshold = true
            }
            if thresholdReached, !interruptIssued {
                interruptIssued = true
                shouldInterrupt = true
            }
            lock.unlock()

            if shouldSignalThreshold {
                readyToInterrupt.fulfill()
            }
            if shouldInterrupt {
                controller.performInterrupt()
                pollForQuiet()
            }
        }

        controller.onExit = {
            guard !exitSignaled else { return }
            exitSignaled = true
            exitExpectation.fulfill()
        }

        func pollForQuiet() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                let latestSeen = Self.highestStreamingMarker(in: controller.allText(), marker: marker)
                var shouldContinuePolling = false
                var shouldSignalQuiet = false

                lock.lock()
                if latestSeen > highestSeen {
                    highestSeen = latestSeen
                    lastProgressAt = CACurrentMediaTime()
                }
                if !quietSignaled {
                    if CACurrentMediaTime() - lastProgressAt >= quietInterval {
                        quietSignaled = true
                        shouldSignalQuiet = true
                    } else {
                        shouldContinuePolling = true
                    }
                }
                lock.unlock()

                if shouldSignalQuiet {
                    streamQuiesced.fulfill()
                    controller.sendInput("exit\n")
                    return
                }
                if shouldContinuePolling {
                    pollForQuiet()
                }
            }
        }

        try controller.start()
        controller.sendInput(
            """
            i=0
            while [ "$i" -le \(totalLines) ]; do
              printf '\(marker)%05d\\n' "$i"
              i=$((i+1))
              sleep 0.005
            done
            exit
            """
        )

        wait(for: [readyToInterrupt, streamQuiesced, exitExpectation], timeout: 10.0)
        drainMainQueue(testCase: self)

        let finalText = controller.allText()
        let finalHighestSeen = Self.highestStreamingMarker(in: finalText, marker: marker)
        XCTAssertGreaterThanOrEqual(finalHighestSeen, interruptThreshold)
        XCTAssertLessThan(finalHighestSeen, totalLines)
        XCTAssertFalse(finalText.contains("\(marker)\(String(format: "%05d", totalLines))"))
    }

    @MainActor
    func testTerminalControllerRealPTYResizeImmediatelyRewrapsExistingViewportContent() throws {
        try withTemporaryDirectory { directory in
            let controller = TerminalController(
                rows: 6,
                cols: 10,
                termEnv: "xterm-256color",
                textEncoding: .utf8,
                scrollbackInitialCapacity: 4096,
                scrollbackMaxCapacity: 4096,
                fontName: "Menlo",
                fontSize: 13,
                initialDirectory: directory.path
            )
            defer { controller.stop(waitForExit: true) }

            let logicalText = "ABCDEFGHIJKLMNOPQRSTUVWX"
            let marker = "__PTERM_WRAP_READY__"
            let scriptURL = directory.appendingPathComponent("paint.sh")
            try """
            printf '\\033[?1049h\\033[H\\033[2J\(logicalText)\\n\(marker)\\n'
            sleep 1.5
            """.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

            let paintedExpectation = expectation(description: "controller-wrap-marker-painted")
            var markerSeen = false

            controller.onOutputActivity = {
                guard !markerSeen else { return }
                if controller.allText().contains(marker) {
                    markerSeen = true
                    paintedExpectation.fulfill()
                }
            }

            try controller.start()
            controller.sendInput("stty -echo\n")
            let echoDisabled = expectation(description: "controller-echo-disabled")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                echoDisabled.fulfill()
            }
            wait(for: [echoDisabled], timeout: 1.0)
            controller.sendInput(". ./paint.sh\n")

            wait(for: [paintedExpectation], timeout: 8.0)
            drainMainQueue(testCase: self)

            let narrowLines = Self.visibleViewportLines(of: controller, count: 4)
            XCTAssertEqual(narrowLines[0].trimmingCharacters(in: .whitespaces), "ABCDEFGHIJ")
            XCTAssertEqual(narrowLines[1].trimmingCharacters(in: .whitespaces), "KLMNOPQRST")
            XCTAssertEqual(narrowLines[2].trimmingCharacters(in: .whitespaces), "UVWX")

            controller.resize(rows: 6, cols: 40)
            drainMainQueue(testCase: self)

            let wideLines = Self.visibleViewportLines(of: controller, count: 4)
            XCTAssertEqual(wideLines[0].trimmingCharacters(in: .whitespaces), logicalText)
            XCTAssertEqual(wideLines[1].trimmingCharacters(in: .whitespaces), marker)
            XCTAssertEqual(wideLines[2].trimmingCharacters(in: .whitespaces), "")
        }
    }

    @MainActor
    func testTerminalControllerRealPTYResizeSignalsForegroundProcessGroupWithSIGWINCH() throws {
        let controller = TerminalController(
            rows: 6,
            cols: 20,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13
        )
        defer { controller.stop(waitForExit: true) }

        let readyMarker = "__WINCH_READY__"
        let winchMarker = "__WINCH_SEEN__"
        let readyExpectation = expectation(description: "foreground-process-ready")
        let winchExpectation = expectation(description: "foreground-process-received-sigwinch")
        var readySeen = false
        var winchSeen = false

        controller.onOutputActivity = {
            let text = controller.allText()
            if !readySeen, text.contains(readyMarker) {
                readySeen = true
                readyExpectation.fulfill()
            }
            if !winchSeen, text.contains(winchMarker) {
                winchSeen = true
                winchExpectation.fulfill()
            }
        }

        try controller.start()
        controller.sendInput("stty -echo\n")
        let echoDisabled = expectation(description: "winch-echo-disabled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            echoDisabled.fulfill()
        }
        wait(for: [echoDisabled], timeout: 1.0)
        controller.sendInput(
            """
            /bin/sh -c 'trap "printf \"\(winchMarker)\\\\n\"" WINCH; printf "\(readyMarker)\\n"; while :; do sleep 1; done' &
            fg %1
            """
        )

        wait(for: [readyExpectation], timeout: 8.0)
        controller.resize(rows: 6, cols: 40)
        wait(for: [winchExpectation], timeout: 3.0)
    }

    @MainActor
    func testTerminalControllerResizeRoundTripKeepsCompletedOutput() throws {
        let controller = TerminalController(
            rows: 24,
            cols: 57,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13
        )
        defer { controller.stop(waitForExit: true) }

        try controller.start()
        controller.sendInput("i=1; while [ $i -le 10 ]; do printf '%03d\\n' \"$i\"; i=$((i+1)); done\n")

        let completedExpectation = expectation(description: "completed output available before resize round trip")
        let completionDeadline = Date().addingTimeInterval(8.0)
        func pollCompletedOutput() {
            let text = controller.allText()
            if text.contains("001"),
               text.contains("010"),
               text.contains("009"),
               text.contains("while [ $i -le 10 ]") {
                completedExpectation.fulfill()
                return
            }
            if Date() < completionDeadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: pollCompletedOutput)
            }
        }
        DispatchQueue.main.async(execute: pollCompletedOutput)
        wait(for: [completedExpectation], timeout: 8.5)
        drainMainQueue(testCase: self)

        let baseline = controller.allText()
        controller.resize(rows: 24, cols: 120)
        controller.resize(rows: 24, cols: 57)
        drainMainQueue(testCase: self)

        XCTAssertEqual(controller.allText(), baseline)
    }

    @MainActor
    func testTerminalControllerNotifyCurrentSizeChangedSignalsForegroundProcessGroupWithoutGeometryChange() throws {
        let controller = TerminalController(
            rows: 6,
            cols: 20,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13
        )
        defer { controller.stop(waitForExit: true) }

        let readyMarker = "__NOTIFY_READY__"
        let winchMarker = "__NOTIFY_WINCH__"
        let readyExpectation = expectation(description: "foreground-process-ready-notify")
        let winchExpectation = expectation(description: "foreground-process-received-notify-current-size")
        var readySeen = false
        var winchSeen = false

        controller.onOutputActivity = {
            let text = controller.allText()
            if !readySeen, text.contains(readyMarker) {
                readySeen = true
                readyExpectation.fulfill()
            }
            if !winchSeen, text.contains(winchMarker) {
                winchSeen = true
                winchExpectation.fulfill()
            }
        }

        try controller.start()
        controller.sendInput("stty -echo\n")
        let echoDisabled = expectation(description: "notify-echo-disabled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            echoDisabled.fulfill()
        }
        wait(for: [echoDisabled], timeout: 1.0)
        controller.sendInput(
            """
            /bin/sh -c 'trap "printf \"\(winchMarker)\\\\n\"" WINCH; printf "\(readyMarker)\\n"; while :; do sleep 1; done' &
            fg %1
            """
        )

        wait(for: [readyExpectation], timeout: 8.0)
        controller.notifyCurrentSizeChanged()
        wait(for: [winchExpectation], timeout: 3.0)
    }

    @MainActor
    func testTerminalControllerRepeatedNotifyCurrentSizeChangedDeliversThirdWINCHToForegroundProcessGroup() throws {
        let controller = TerminalController(
            rows: 6,
            cols: 20,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 4096,
            scrollbackMaxCapacity: 4096,
            fontName: "Menlo",
            fontSize: 13
        )
        defer { controller.stop(waitForExit: true) }

        let readyMarker = "__TRIPLE_NOTIFY_READY__"
        let winchMarker = "__TRIPLE_NOTIFY_WINCH__"
        let readyExpectation = expectation(description: "foreground-process-ready-triple-notify")
        let winchExpectation = expectation(description: "foreground-process-received-third-notify")
        var readySeen = false
        var winchSeen = false

        controller.onOutputActivity = {
            let text = controller.allText()
            if !readySeen, text.contains(readyMarker) {
                readySeen = true
                readyExpectation.fulfill()
            }
            if !winchSeen, text.contains(winchMarker) {
                winchSeen = true
                winchExpectation.fulfill()
            }
        }

        try controller.start()
        controller.sendInput("stty -echo\n")
        let echoDisabled = expectation(description: "triple-notify-echo-disabled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            echoDisabled.fulfill()
        }
        wait(for: [echoDisabled], timeout: 1.0)
        controller.sendInput(
            """
            /bin/sh -c 'count=0; trap "count=$((count + 1)); if [ \"$count\" -ge 3 ]; then printf \"\(winchMarker)\\\\n\"; fi" WINCH; printf "\(readyMarker)\\n"; while :; do sleep 1; done' &
            fg %1
            """
        )

        wait(for: [readyExpectation], timeout: 8.0)
        controller.notifyCurrentSizeChanged()
        controller.notifyCurrentSizeChanged()
        controller.notifyCurrentSizeChanged()
        wait(for: [winchExpectation], timeout: 3.0)
    }

    private static func highestStreamingMarker(in text: String, marker: String) -> Int {
        var highest = -1
        var searchStart = text.startIndex
        while let range = text.range(of: marker, range: searchStart..<text.endIndex) {
            let digitsStart = range.upperBound
            let digitsEnd = text.index(digitsStart, offsetBy: 5, limitedBy: text.endIndex) ?? text.endIndex
            if digitsEnd > digitsStart {
                let digits = text[digitsStart..<digitsEnd]
                if digits.count == 5, let value = Int(digits) {
                    highest = max(highest, value)
                }
            }
            searchStart = range.upperBound
        }
        return highest
    }

    private static func visibleViewportLines(of controller: TerminalController, count: Int) -> [String] {
        controller.withViewport { model, scrollback, scrollOffset in
            let rows = min(count, model.rows)
            let scrollbackRowCount = scrollback.rowCount
            let firstAbsolute = scrollOffset > 0 ? max(0, scrollbackRowCount - scrollOffset) : scrollbackRowCount
            return (0..<rows).map { row in
                let absoluteRow = firstAbsolute + row
                let cells: [Cell]
                if absoluteRow < scrollbackRowCount {
                    cells = scrollback.getRow(at: absoluteRow) ?? []
                } else {
                    let gridRow = absoluteRow - scrollbackRowCount
                    cells = (0..<model.cols).map { model.grid.cell(at: gridRow, col: $0) }
                }
                return viewportLineText(cells: cells, cols: model.cols)
            }
        }
    }

    private static func viewportLineText(cells: [Cell], cols: Int) -> String {
        var text = ""
        text.reserveCapacity(cols)
        for col in 0..<cols {
            let cell = col < cells.count ? cells[col] : .empty
            if cell.isWideContinuation {
                continue
            }
            guard cell.codepoint != 0, let scalar = UnicodeScalar(cell.codepoint) else {
                text.append(" ")
                continue
            }
            text.append(Character(scalar))
        }
        return text
    }
}

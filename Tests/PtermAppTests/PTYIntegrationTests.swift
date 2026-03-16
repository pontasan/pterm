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

        let text = controller.allText()
        let lateMatches = controller.findMatches(for: "__ROW__79")
        let earlyMatches = controller.findMatches(for: "__ROW__0")

        XCTAssertGreaterThan(outputActivityCount, 0)
        XCTAssertLessThan(controller.scrollback.rowCount, 80)
        XCTAssertTrue(lateMatches.contains { $0.absoluteRow >= 0 })
        XCTAssertTrue(earlyMatches.isEmpty)
        XCTAssertTrue(text.contains("__ROW__79"))
        XCTAssertFalse(text.contains("__ROW__0"))
    }

    @MainActor
    func testTerminalControllerRealPTYTimeSeq100000ProfileFixture() throws {
        let controller = TerminalController(
            rows: 24,
            cols: 80,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 16 * 1024 * 1024,
            scrollbackMaxCapacity: 16 * 1024 * 1024,
            fontName: "Menlo",
            fontSize: 13
        )
        defer { controller.stop(waitForExit: true) }

        let exitExpectation = expectation(description: "controller-exit-time-seq-100000")
        var exited = false
        controller.onExit = {
            guard !exited else { return }
            exited = true
            exitExpectation.fulfill()
        }

        try controller.start()
        controller.sendInput("TIMEFMT=$'__PTERM_TIME__ %U %S %P %E'; time seq 1 100000; exit\n")

        wait(for: [exitExpectation], timeout: 30.0)
        drainMainQueue(testCase: self)

        let text = controller.allText()
        XCTAssertTrue(text.contains("100000"), "seq output tail should remain visible")
        XCTAssertTrue(text.contains("__PTERM_TIME__"), "shell timing output should be captured")
    }

    @MainActor
    func testTerminalControllerRealPTYKittenBenchmarkCompletes() throws {
        guard let kittenPath = Self.findExecutable(named: "kitten") else {
            throw XCTSkip("kitten is not installed in this environment")
        }

        try withTemporaryDirectory { directory in
            let controller = TerminalController(
                rows: 24,
                cols: 100,
                termEnv: "xterm-256color",
                textEncoding: .utf8,
                scrollbackInitialCapacity: 16 * 1024 * 1024,
                scrollbackMaxCapacity: 16 * 1024 * 1024,
                fontName: "Menlo",
                fontSize: 13
            )
            defer { controller.stop(waitForExit: true) }

            let outputPath = directory.appendingPathComponent("kitten-benchmark.txt").path
            let doneMarker = "__PTERM_KITTEN_DONE__"
            let exitExpectation = expectation(description: "controller-exit-kitten-benchmark")
            let longEscapeExpectation = expectation(description: "controller-kitten-long-escape-visible")
            let finalizeExpectation = expectation(description: "controller-kitten-finalize-visible")
            var exited = false
            var sawLongEscape = false
            var sawFinalize = false
            controller.onExit = {
                guard !exited else { return }
                exited = true
                exitExpectation.fulfill()
            }
            controller.onOutputActivity = {
                let text = controller.allText()
                if !sawLongEscape, text.contains("Running: Long escape codes") {
                    sawLongEscape = true
                    longEscapeExpectation.fulfill()
                }
                if !sawFinalize, text.contains("Waiting for response indicating parsing finished") {
                    sawFinalize = true
                    finalizeExpectation.fulfill()
                }
            }

            try controller.start()
            controller.sendInput(
                "'\(Self.shellSingleQuoted(kittenPath))' __benchmark__ --repetitions 1 2>&1 | tee '\(Self.shellSingleQuoted(outputPath))'; "
                + "printf '\(doneMarker)\\n'; "
                + "exit\n"
            )

            wait(for: [longEscapeExpectation, finalizeExpectation, exitExpectation], timeout: 45.0)
            drainMainQueue(testCase: self)

            let terminalText = controller.allText()
            let benchmarkOutput = (try? String(contentsOfFile: outputPath, encoding: .utf8)) ?? ""
            XCTAssertTrue(
                terminalText.contains(doneMarker),
                "benchmark command should complete. terminal tail=\(String(terminalText.suffix(500)))"
            )
            XCTAssertTrue(
                benchmarkOutput.contains("Only ASCII chars"),
                "benchmark progress should include ASCII stage. file tail=\(String(benchmarkOutput.suffix(500)))"
            )
            XCTAssertTrue(
                benchmarkOutput.contains("Long escape codes"),
                "benchmark progress should include long OSC stage. file tail=\(String(benchmarkOutput.suffix(500)))"
            )
        }
    }

    @MainActor
    func testTerminalControllerRealPTYVttestTerminalReportsReplayCompletesWithoutReportFailures() throws {
        guard let vttestPath = Self.findExecutable(named: "vttest") else {
            throw XCTSkip("vttest is not installed in this environment")
        }

        try withTemporaryDirectory { directory in
            let logPath = directory.appendingPathComponent("vttest-reports.log").path

            let controller = TerminalController(
                rows: 24,
                cols: 100,
                termEnv: "xterm-256color",
                textEncoding: .utf8,
                scrollbackInitialCapacity: 16 * 1024 * 1024,
                scrollbackMaxCapacity: 16 * 1024 * 1024,
                fontName: "Menlo",
                fontSize: 13
            )
            defer { controller.stop(waitForExit: true) }

            let doneMarker = "__PTERM_VTTEST_DONE__"
            let exitExpectation = expectation(description: "controller-exit-vttest-terminal-reports")
            var exited = false
            controller.onExit = {
                guard !exited else { return }
                exited = true
                exitExpectation.fulfill()
            }

            try controller.start()
            controller.sendInput(
                "'\(Self.shellSingleQuoted(vttestPath))' -l '\(Self.shellSingleQuoted(logPath))'\n"
            )

            let pressReturn = {
                controller.sendInput("\n")
            }
            let pressEnterKey = {
                controller.sendInput(controller.newlineKeyInput())
            }

            let sendChoice: (String) -> Void = { choice in
                controller.sendInput(choice)
                pressReturn()
            }

            try Self.waitForTerminalText(
                controller,
                toContain: "Enter choice number (0 - 12):",
                timeout: 10.0
            )
            sendChoice("6")

            try Self.waitForTerminalText(
                controller,
                toContain: "Enter choice number (0 - 7):",
                timeout: 10.0
            )

            sendChoice("1")
            try Self.waitForTerminalText(controller, toContain: "Push <RETURN>", timeout: 10.0)
            XCTAssertFalse(controller.allText().localizedCaseInsensitiveContains("no answerback"), "ENQ answerback should be reported.\n\(controller.allText())")
            pressReturn()

            try Self.waitForTerminalText(
                controller,
                toContain: "Enter choice number (0 - 7):",
                timeout: 10.0
            )
            sendChoice("2")
            try Self.waitForTerminalText(controller, toContain: "NewLine mode set", timeout: 10.0)
            XCTAssertFalse(controller.allText().localizedCaseInsensitiveContains("failed"), "Linefeed/newline mode should not fail.\n\(controller.allText())")
            pressEnterKey()
            try Self.waitForTerminalText(controller, toContain: "NewLine mode reset", timeout: 10.0)
            XCTAssertTrue(controller.allText().contains("<13> <10>  -- OK"), "LNM should report CRLF while set.\n\(controller.allText())")
            pressEnterKey()
            try Self.waitForTerminalText(controller, toContain: "Push <RETURN>", timeout: 10.0)
            XCTAssertTrue(controller.allText().contains("<13>  -- OK"), "LNM should report CR after reset.\n\(controller.allText())")
            pressReturn()

            try Self.waitForTerminalText(
                controller,
                toContain: "Enter choice number (0 - 7):",
                timeout: 10.0
            )
            sendChoice("3")
            try Self.waitForTerminalText(controller, toContain: "Push <RETURN>", timeout: 10.0)
            XCTAssertFalse(controller.allText().contains("Unknown response"), "DSR screen should not report an unknown response.\n\(controller.allText())")
            pressReturn()

            try Self.waitForTerminalText(
                controller,
                toContain: "Enter choice number (0 - 7):",
                timeout: 10.0
            )
            sendChoice("4")
            try Self.waitForTerminalText(controller, toContain: "Push <RETURN>", timeout: 10.0)
            XCTAssertFalse(controller.allText().contains("Unknown response"), "Primary DA should not report an unknown response.\n\(controller.allText())")
            pressReturn()

            try Self.waitForTerminalText(
                controller,
                toContain: "Enter choice number (0 - 7):",
                timeout: 10.0
            )
            sendChoice("5")
            try Self.waitForTerminalText(controller, toContain: "Push <RETURN>", timeout: 10.0)
            XCTAssertFalse(controller.allText().contains("failed"), "Secondary DA should not fail.\n\(controller.allText())")
            pressReturn()

            try Self.waitForTerminalText(
                controller,
                toContain: "Enter choice number (0 - 7):",
                timeout: 10.0
            )
            sendChoice("7")
            try Self.waitForTerminalText(controller, toContain: "Push <RETURN>", timeout: 10.0)
            XCTAssertFalse(controller.allText().contains("Bad format"), "DECREQTPARM should not report a bad format.\n\(controller.allText())")
            pressReturn()

            try Self.waitForTerminalText(
                controller,
                toContain: "Enter choice number (0 - 7):",
                timeout: 10.0
            )
            sendChoice("0")
            try Self.waitForTerminalText(
                controller,
                toContain: "Enter choice number (0 - 12):",
                timeout: 10.0
            )
            sendChoice("0")
            try Self.waitForTerminalText(
                controller,
                toContain: "That's all, folks!",
                timeout: 10.0
            )
            controller.sendInput("printf '\(doneMarker)\\n'\nexit\n")

            wait(for: [exitExpectation], timeout: 20.0)
            drainMainQueue(testCase: self)

            let terminalText = controller.allText()
            let replayLog = try String(contentsOfFile: logPath, encoding: .utf8)

            XCTAssertTrue(
                terminalText.contains(doneMarker),
                "vttest replay should complete. tail=\(String(terminalText.suffix(500)))"
            )
            XCTAssertTrue(replayLog.contains("Device Status Report (DSR)"))
            XCTAssertTrue(replayLog.contains("Primary Device Attributes (DA)"))
            XCTAssertTrue(replayLog.contains("Secondary Device Attributes (DA)"))
            XCTAssertTrue(replayLog.contains("Request Terminal Parameters (DECREQTPARM)"))
            XCTAssertFalse(replayLog.contains("Unknown response"), "vttest replay log=\n\(replayLog)")
            XCTAssertFalse(replayLog.contains("Bad format"), "vttest replay log=\n\(replayLog)")
            XCTAssertFalse(replayLog.contains("result failed"), "vttest replay log=\n\(replayLog)")
            XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("no answerback"), "vttest replay log=\n\(replayLog)")
        }
    }

    @MainActor
    func testTerminalControllerRealPTYVttestISO6429CursorMovementReplayCompletes() throws {
        guard let vttestPath = Self.findExecutable(named: "vttest") else {
            throw XCTSkip("vttest is not installed in this environment")
        }

        try withTemporaryDirectory { directory in
            let logPath = directory.appendingPathComponent("vttest-iso6429-cursor.log").path

            let controller = TerminalController(
                rows: 24,
                cols: 100,
                termEnv: "xterm-256color",
                textEncoding: .utf8,
                scrollbackInitialCapacity: 16 * 1024 * 1024,
                scrollbackMaxCapacity: 16 * 1024 * 1024,
                fontName: "Menlo",
                fontSize: 13
            )
            defer { controller.stop(waitForExit: true) }

            let doneMarker = "__PTERM_VTTEST_ISO6429_DONE__"
            let exitExpectation = expectation(description: "controller-exit-vttest-iso6429-cursor")
            var exited = false
            controller.onExit = {
                guard !exited else { return }
                exited = true
                exitExpectation.fulfill()
            }

            try controller.start()
            controller.sendInput(
                "'\(Self.shellSingleQuoted(vttestPath))' -l '\(Self.shellSingleQuoted(logPath))'\n"
            )

            let pressReturn = {
                controller.sendInput("\n")
            }

            let sendChoice: (String) -> Void = { choice in
                controller.sendInput(choice)
                pressReturn()
            }

            try Self.waitForTerminalText(
                controller,
                toContain: "Enter choice number (0 - 12):",
                timeout: 10.0
            )
            sendChoice("11")

            try Self.waitForTerminalText(
                controller,
                toContain: "Enter choice number (0 - 8):",
                timeout: 10.0
            )
            sendChoice("5")

            try Self.waitForTerminalText(
                controller,
                toContain: "Enter choice number (0 - 9):",
                timeout: 10.0
            )

            let expectedPrompts: [(choice: String, expected: String)] = [
                ("1", "There should be a box-outline made of *'s in the middle of the screen."),
                ("2", "The tab-stops should be numbered consecutively starting at 1 in screen."),
                ("3", "There should be a box-outline made of *'s in the middle of the screen."),
                ("4", "The lines with *'s above should look the same (they wrap once)"),
                ("5", "There should be a box-outline made of *'s in the middle of the screen."),
                ("6", "There should be a box-outline made of *'s in the middle of the screen."),
                ("7", "The lines above this should be numbered in sequence, from 1."),
                ("8", "The lines above this should be numbered in sequence, from 1."),
                ("9", "There should be a box-outline made of *'s in the middle of the screen.")
            ]

            for item in expectedPrompts {
                sendChoice(item.choice)
                try Self.waitForTerminalText(controller, toContain: item.expected, timeout: 10.0)
                pressReturn()
                try Self.waitForTerminalText(
                    controller,
                    toContain: "Enter choice number (0 - 9):",
                    timeout: 10.0
                )
            }

            sendChoice("0")
            try Self.waitForTerminalText(
                controller,
                toContain: "Enter choice number (0 - 8):",
                timeout: 10.0
            )
            sendChoice("0")
            try Self.waitForTerminalText(
                controller,
                toContain: "Enter choice number (0 - 12):",
                timeout: 10.0
            )
            sendChoice("0")
            try Self.waitForTerminalText(
                controller,
                toContain: "That's all, folks!",
                timeout: 10.0
            )
            controller.sendInput("printf '\(doneMarker)\\n'\nexit\n")

            wait(for: [exitExpectation], timeout: 20.0)
            drainMainQueue(testCase: self)

            let terminalText = controller.allText()
            let replayLog = try String(contentsOfFile: logPath, encoding: .utf8)

            XCTAssertTrue(
                terminalText.contains(doneMarker),
                "vttest ISO-6429 cursor replay should complete. tail=\(String(terminalText.suffix(500)))"
            )
            XCTAssertTrue(replayLog.contains("Cursor-Back-Tab (CBT)"))
            XCTAssertTrue(replayLog.contains("Cursor-Horizontal-Index (CHT)"))
            XCTAssertTrue(replayLog.contains("Horizontal-Position-Relative (HPR)"))
            XCTAssertTrue(replayLog.contains("Vertical-Position-Relative (VPR)"))
            XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("not implemented"), "vttest replay log=\n\(replayLog)")
        }
    }

    @MainActor
    func testTerminalControllerRealPTYVttestISO6429MiscReplayCompletes() throws {
        guard let vttestPath = Self.findExecutable(named: "vttest") else {
            throw XCTSkip("vttest is not installed in this environment")
        }

        try withTemporaryDirectory { directory in
            let logPath = directory.appendingPathComponent("vttest-iso6429-misc.log").path

            let controller = TerminalController(
                rows: 24,
                cols: 100,
                termEnv: "xterm-256color",
                textEncoding: .utf8,
                scrollbackInitialCapacity: 16 * 1024 * 1024,
                scrollbackMaxCapacity: 16 * 1024 * 1024,
                fontName: "Menlo",
                fontSize: 13
            )
            defer { controller.stop(waitForExit: true) }

            let doneMarker = "__PTERM_VTTEST_ISO6429_MISC_DONE__"
            let exitExpectation = expectation(description: "controller-exit-vttest-iso6429-misc")
            var exited = false
            controller.onExit = {
                guard !exited else { return }
                exited = true
                exitExpectation.fulfill()
            }

            try controller.start()
            controller.sendInput("'\(Self.shellSingleQuoted(vttestPath))' -l '\(Self.shellSingleQuoted(logPath))'\n")

            let pressReturn = { controller.sendInput("\n") }
            let sendChoice: (String) -> Void = { choice in
                controller.sendInput(choice)
                pressReturn()
            }

            try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
            sendChoice("11")
            try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 8):", timeout: 10.0)
            sendChoice("7")
            try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 6):", timeout: 10.0)

            sendChoice("1")
            try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 2):", timeout: 10.0)
            sendChoice("2")
            try Self.waitForTerminalText(controller, toContain: "solid box made of *'s in the middle of the screen.", timeout: 10.0)
            pressReturn()
            try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 2):", timeout: 10.0)
            sendChoice("0")
            try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 6):", timeout: 10.0)

            let miscPrompts: [(choice: String, expected: String)] = [
                ("2", "There should be a diagonal of 2 +'s down to the row of *'s above this message."),
                ("3", "There should be a horizontal row of *'s above, just above the message."),
                ("4", "There should be a vertical column of *'s centered above."),
                ("5", "There should be a vertical column of *'s centered above."),
                ("6", "There should be a horizontal row of *'s above, on the top row.")
            ]

            for item in miscPrompts {
                sendChoice(item.choice)
                try Self.waitForTerminalText(controller, toContain: item.expected, timeout: 10.0)
                pressReturn()
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 6):", timeout: 10.0)
            }

            sendChoice("0")
            try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 8):", timeout: 10.0)
            sendChoice("0")
            try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
            sendChoice("0")
            try Self.waitForTerminalText(controller, toContain: "That's all, folks!", timeout: 10.0)
            controller.sendInput("printf '\(doneMarker)\\n'\nexit\n")

            wait(for: [exitExpectation], timeout: 20.0)
            drainMainQueue(testCase: self)

            let terminalText = controller.allText()
            let replayLog = try String(contentsOfFile: logPath, encoding: .utf8)

            XCTAssertTrue(terminalText.contains(doneMarker))
            XCTAssertTrue(replayLog.contains("Protected-Area Tests"))
            XCTAssertTrue(replayLog.contains("Test Repeat (REP)"))
            XCTAssertTrue(replayLog.contains("Test Scroll-Down (SD)"))
            XCTAssertTrue(replayLog.contains("Test Scroll-Left (SL)"))
            XCTAssertTrue(replayLog.contains("Test Scroll-Right (SR)"))
            XCTAssertTrue(replayLog.contains("Test Scroll-Up (SU)"))
            XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("not implemented"), "vttest replay log=\n\(replayLog)")
        }
    }

    @MainActor
    func testTerminalControllerRealPTYVttestVT220ScreenDisplayReplayCompletes() throws {
        guard let vttestPath = Self.findExecutable(named: "vttest") else {
            throw XCTSkip("vttest is not installed in this environment")
        }

        try withTemporaryDirectory { directory in
            let logPath = directory.appendingPathComponent("vttest-vt220-screen.log").path

            let controller = TerminalController(
                rows: 24,
                cols: 100,
                termEnv: "xterm-256color",
                textEncoding: .utf8,
                scrollbackInitialCapacity: 16 * 1024 * 1024,
                scrollbackMaxCapacity: 16 * 1024 * 1024,
                fontName: "Menlo",
                fontSize: 13
            )
            defer { controller.stop(waitForExit: true) }

            try controller.start()
            controller.sendInput("'\(Self.shellSingleQuoted(vttestPath))' -l '\(Self.shellSingleQuoted(logPath))'\n")

            let pressReturn = { controller.sendInput("\n") }
            let sendChoice: (String) -> Void = { choice in
                controller.sendInput(choice)
                pressReturn()
            }

            try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
            sendChoice("11")
            try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 8):", timeout: 10.0)
            sendChoice("1")
            try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 7):", timeout: 10.0)
            sendChoice("2")
            try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 4):", timeout: 10.0)

            sendChoice("2")
            try Self.waitForTerminalText(controller, toContain: "The cursor should be invisible", timeout: 10.0)
            pressReturn()
            try Self.waitForTerminalText(controller, toContain: "The cursor should be visible again", timeout: 10.0)
            pressReturn()
            try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 4):", timeout: 10.0)

            sendChoice("3")
            try Self.waitForTerminalText(controller, toContain: "ECH test: there should be E's with a gap before diagonal of **'s", timeout: 10.0)
            pressReturn()
            try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 4):", timeout: 10.0)

            sendChoice("4")
            try Self.waitForTerminalText(controller, toContain: "solid box made of *'s in the middle of the screen.", timeout: 10.0)
            pressReturn()
            try Self.waitForTerminalText(controller, toContain: "solid box made of *'s in the middle of the screen.", timeout: 10.0)
            pressReturn()
            try Self.waitForTerminalText(controller, toContain: "solid box made of *'s in the middle of the screen.", timeout: 10.0)
            controller.stop(waitForExit: true)
            drainMainQueue(testCase: self)

            let replayLog = try String(contentsOfFile: logPath, encoding: .utf8)

            XCTAssertTrue(replayLog.contains("Test screen-display functions"))
            XCTAssertTrue(replayLog.contains("Test Visible/Invisible Cursor (DECTCEM)"))
            XCTAssertTrue(replayLog.contains("Test Erase Char (ECH)"))
            XCTAssertTrue(replayLog.contains("Test Protected-Areas (DECSCA)"))
            XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("not implemented"), "vttest replay log=\n\(replayLog)")
        }
    }

    @MainActor
    func testTerminalControllerRealPTYVttestVT220ControlsReplayCompletes() throws {
        guard let vttestPath = Self.findExecutable(named: "vttest") else {
            throw XCTSkip("vttest is not installed in this environment")
        }

        try withTemporaryDirectory { directory in
            try MainActor.assumeIsolated {
            let logPath = directory.appendingPathComponent("vttest-vt220-controls.log").path

            let controller = TerminalController(
                rows: 24,
                cols: 100,
                termEnv: "xterm-256color",
                textEncoding: .utf8,
                scrollbackInitialCapacity: 16 * 1024 * 1024,
                scrollbackMaxCapacity: 16 * 1024 * 1024,
                fontName: "Menlo",
                fontSize: 13
            )
            defer { controller.stop(waitForExit: true) }

            try controller.start()
            controller.sendInput("'\(Self.shellSingleQuoted(vttestPath))' -l '\(Self.shellSingleQuoted(logPath))'\n")

            let pressReturn = { controller.sendInput("\n") }
            let sendChoice: (String) -> Void = { choice in
                controller.sendInput(choice)
                pressReturn()
            }
            let terminalTail = { String(controller.allText().suffix(1200)) }
            let waitForAnyTail: ([String], TimeInterval) throws -> String = { needles, timeout in
                let deadline = Date().addingTimeInterval(timeout)
                while Date() < deadline {
                    let text = terminalTail()
                    if let needle = needles.first(where: { text.contains($0) }) {
                        return needle
                    }
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                }
                XCTFail(
                    "Timed out waiting for terminal tail containing any of \(needles). tail=\(terminalTail())"
                )
                return needles[0]
            }
            let advancePastHoldToMenu: ([String], TimeInterval) throws -> String = { menuNeedles, timeout in
                let deadline = Date().addingTimeInterval(timeout)
                while Date() < deadline {
                    let text = terminalTail()
                    if let needle = menuNeedles.first(where: { text.contains($0) }) {
                        return needle
                    }
                    if text.contains("Push <RETURN>") {
                        pressReturn()
                    }
                    RunLoop.main.run(until: Date().addingTimeInterval(0.10))
                }
                XCTFail(
                    "Timed out advancing past hold screen. expected any of \(menuNeedles). tail=\(terminalTail())"
                )
                return menuNeedles[0]
            }

            try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
            sendChoice("11")
            _ = try waitForAnyTail(["Enter choice number (0 - 8):", "VT220 Tests"], 10.0)
            sendChoice("1")
            _ = try waitForAnyTail(["Enter choice number (0 - 7):", "VT220 Tests"], 10.0)

            sendChoice("3")
            _ = try waitForAnyTail(["Push <RETURN>"], 10.0)
            pressReturn()
            _ = try waitForAnyTail(["Enter choice number (0 - 7):", "VT220 Tests"], 10.0)

            sendChoice("6")
            _ = try waitForAnyTail(["The terminal will now soft-reset"], 10.0)
            pressReturn()
            _ = try advancePastHoldToMenu(["Enter choice number (0 - 7):", "VT220 Tests"], 10.0)

            sendChoice("0")
            _ = try waitForAnyTail(["Enter choice number (0 - 8):", "Menu 11: Non-VT100 Tests"], 10.0)
            sendChoice("0")
            _ = try waitForAnyTail(["Enter choice number (0 - 12):", "Menu 0: Main Menu"], 10.0)
            sendChoice("0")
            _ = try waitForAnyTail(["That's all, folks!"], 10.0)
            pressReturn()
            controller.sendInput("exit\n")

            let replayLog = try String(contentsOfFile: logPath, encoding: .utf8)
            XCTAssertTrue(replayLog.contains("Test 8-bit controls (S7C1T/S8C1T)"))
            XCTAssertTrue(replayLog.contains("8-bit controls enabled:"))
            XCTAssertTrue(replayLog.contains("8-bit controls disabled:"))
            XCTAssertTrue(replayLog.contains("Soft Terminal Reset (DECSTR)"))
            XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("failed"), "vttest replay log=\n\(replayLog)")
            XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("not implemented"), "vttest replay log=\n\(replayLog)")
        }
        }
    }

    @MainActor
    func testTerminalControllerRealPTYVttestVT220ReportsReplayCompletes() throws {
        guard let vttestPath = Self.findExecutable(named: "vttest") else {
            throw XCTSkip("vttest is not installed in this environment")
        }

        try withTemporaryDirectory { directory in
            try MainActor.assumeIsolated {
                let logPath = directory.appendingPathComponent("vttest-vt220-reports.log").path

                let controller = TerminalController(
                    rows: 24,
                    cols: 100,
                    termEnv: "xterm-256color",
                    textEncoding: .utf8,
                    scrollbackInitialCapacity: 16 * 1024 * 1024,
                    scrollbackMaxCapacity: 16 * 1024 * 1024,
                    fontName: "Menlo",
                    fontSize: 13
                )
                defer { controller.stop(waitForExit: true) }

                try controller.start()
                controller.sendInput("'\(Self.shellSingleQuoted(vttestPath))' -l '\(Self.shellSingleQuoted(logPath))'\n")

                let pressReturn = { controller.sendInput("\n") }
                let sendChoice: (String) -> Void = { choice in
                    controller.sendInput(choice)
                    pressReturn()
                }

                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
                sendChoice("11")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 8):", timeout: 10.0)
                sendChoice("1")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 7):", timeout: 10.0)
                sendChoice("1")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 1):", timeout: 10.0)
                sendChoice("1")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 4):", timeout: 10.0)

                sendChoice("1")
                try Self.waitForTerminalText(controller, toContain: "North American/ASCII", timeout: 10.0)
                pressReturn()
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 4):", timeout: 10.0)

                sendChoice("2")
                try Self.waitForTerminalText(controller, toContain: "Terminal is in good operating condition", timeout: 10.0)
                pressReturn()
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 4):", timeout: 10.0)

                sendChoice("3")
                try Self.waitForTerminalText(controller, toContain: "No printer", timeout: 10.0)
                pressReturn()
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 4):", timeout: 10.0)

                sendChoice("4")
                try Self.waitForTerminalText(controller, toContain: "UDKs unlocked", timeout: 10.0)
                pressReturn()
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 4):", timeout: 10.0)

                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 1):", timeout: 10.0)
                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 7):", timeout: 10.0)
                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 8):", timeout: 10.0)
                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
                sendChoice("0")
                controller.sendInput("exit\n")

                let replayLog = try String(contentsOfFile: logPath, encoding: .utf8)
                XCTAssertTrue(replayLog.contains("VT220 Device Status Reports"))
                XCTAssertTrue(replayLog.contains("North American/ASCII"))
                XCTAssertTrue(replayLog.contains("No printer"))
                XCTAssertTrue(replayLog.contains("UDKs unlocked"))
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("failed"), "vttest replay log=\n\(replayLog)")
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("not implemented"), "vttest replay log=\n\(replayLog)")
            }
        }
    }

    @MainActor
    func testTerminalControllerRealPTYVttestCharsetShiftReplayCompletes() throws {
        guard let vttestPath = Self.findExecutable(named: "vttest") else {
            throw XCTSkip("vttest is not installed in this environment")
        }

        try withTemporaryDirectory { directory in
            try MainActor.assumeIsolated {
                let logPath = directory.appendingPathComponent("vttest-charsets-shifts.log").path

                let controller = TerminalController(
                    rows: 24,
                    cols: 100,
                    termEnv: "xterm-256color",
                    textEncoding: .utf8,
                    scrollbackInitialCapacity: 16 * 1024 * 1024,
                    scrollbackMaxCapacity: 16 * 1024 * 1024,
                    fontName: "Menlo",
                    fontSize: 13
                )
                defer { controller.stop(waitForExit: true) }

                try controller.start()
                controller.sendInput("'\(Self.shellSingleQuoted(vttestPath))' -l '\(Self.shellSingleQuoted(logPath))'\n")

                let pressReturn = { controller.sendInput("\n") }
                let sendChoice: (String) -> Void = { choice in
                    controller.sendInput(choice)
                    pressReturn()
                }

                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
                sendChoice("3")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 13):", timeout: 10.0)

                sendChoice("10")
                try Self.waitForTerminalText(controller, toContain: "Push <RETURN>", timeout: 10.0)
                pressReturn()
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 13):", timeout: 10.0)

                sendChoice("11")
                try Self.waitForTerminalText(controller, toContain: "Testing single-shift G2 into GL (SS2)", timeout: 10.0)
                try Self.waitForTerminalText(controller, toContain: "Push <RETURN>", timeout: 10.0)
                pressReturn()
                try Self.waitForTerminalText(controller, toContain: "Testing single-shift G3 into GL (SS3)", timeout: 10.0)
                try Self.waitForTerminalText(controller, toContain: "Push <RETURN>", timeout: 10.0)
                pressReturn()
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 13):", timeout: 10.0)

                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
                sendChoice("0")
                controller.sendInput("exit\n")

                let replayLog = try String(contentsOfFile: logPath, encoding: .utf8)
                XCTAssertTrue(replayLog.contains("Test VT220 Locking Shifts"))
                XCTAssertTrue(replayLog.contains("Test VT220 Single Shifts"))
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("failed"), "vttest replay log=\n\(replayLog)")
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("not implemented"), "vttest replay log=\n\(replayLog)")
            }
        }
    }

    @MainActor
    func testTerminalControllerRealPTYVttestSetupDetectsVT420OperatingLevel() throws {
        guard let vttestPath = Self.findExecutable(named: "vttest") else {
            throw XCTSkip("vttest is not installed in this environment")
        }

        try withTemporaryDirectory { directory in
            try MainActor.assumeIsolated {
                let logPath = directory.appendingPathComponent("vttest-setup-levels.log").path

                let controller = TerminalController(
                    rows: 24,
                    cols: 100,
                    termEnv: "xterm-256color",
                    textEncoding: .utf8,
                    scrollbackInitialCapacity: 16 * 1024 * 1024,
                    scrollbackMaxCapacity: 16 * 1024 * 1024,
                    fontName: "Menlo",
                    fontSize: 13
                )
                defer { controller.stop(waitForExit: true) }

                try controller.start()
                controller.sendInput("'\(Self.shellSingleQuoted(vttestPath))' -l '\(Self.shellSingleQuoted(logPath))'\n")

                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
                controller.sendInput("0\nexit\n")

                let replayLog = try String(contentsOfFile: logPath, encoding: .utf8)
                XCTAssertTrue(replayLog.contains("Read: <27> [ ? 6 4 ; 1 ; 2 ; 6 ; 8 ; 9 ; 1 5 c"), replayLog)
                XCTAssertTrue(replayLog.contains("Read: <27> P 1 $ r 6 4 ; 1 \" p <27> \\"), replayLog)
                XCTAssertTrue(replayLog.contains("Read: <27> [ > 4 1 ; 0 ; 0 c"), replayLog)
            }
        }
    }

    @MainActor
    func testTerminalControllerRealPTYVttestVT320TerminalStateReportReplayCompletes() throws {
        guard let vttestPath = Self.findExecutable(named: "vttest") else {
            throw XCTSkip("vttest is not installed in this environment")
        }

        try withTemporaryDirectory { directory in
            try MainActor.assumeIsolated {
                let logPath = directory.appendingPathComponent("vttest-vt320-terminal-state.log").path

                let controller = TerminalController(
                    rows: 24,
                    cols: 100,
                    termEnv: "xterm-256color",
                    textEncoding: .utf8,
                    scrollbackInitialCapacity: 16 * 1024 * 1024,
                    scrollbackMaxCapacity: 16 * 1024 * 1024,
                    fontName: "Menlo",
                    fontSize: 13
                )
                defer { controller.stop(waitForExit: true) }

                try controller.start()
                controller.sendInput("'\(Self.shellSingleQuoted(vttestPath))' -l '\(Self.shellSingleQuoted(logPath))'\n")

                let pressReturn = { controller.sendInput("\n") }
                let sendChoice: (String) -> Void = { choice in
                    controller.sendInput(choice)
                    pressReturn()
                }

                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
                sendChoice("11")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 8):", timeout: 10.0)
                sendChoice("2")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 6):", timeout: 10.0)
                sendChoice("5")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 6):", timeout: 10.0)

                sendChoice("4")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 2):", timeout: 10.0)
                sendChoice("2")
                try Self.waitForTerminalText(controller, toContain: "Testing Terminal State Reports (DECRQTSR/DECTSR)", timeout: 10.0)
                try Self.waitForTerminalText(controller, toContain: "Push <RETURN>", timeout: 10.0)
                pressReturn()
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 2):", timeout: 10.0)
                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 6):", timeout: 10.0)
                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 6):", timeout: 10.0)
                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 8):", timeout: 10.0)
                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
                sendChoice("0")
                controller.sendInput("exit\n")

                let replayLog = try String(contentsOfFile: logPath, encoding: .utf8)
                XCTAssertTrue(replayLog.contains("Testing Terminal State Reports (DECRQTSR/DECTSR)"))
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("failed"), "vttest replay log=\n\(replayLog)")
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("not implemented"), "vttest replay log=\n\(replayLog)")
            }
        }
    }

    @MainActor
    func testTerminalControllerRealPTYVttestVT320StatusStringReportsReplayCompletes() throws {
        guard let vttestPath = Self.findExecutable(named: "vttest") else {
            throw XCTSkip("vttest is not installed in this environment")
        }

        try withTemporaryDirectory { directory in
            try MainActor.assumeIsolated {
                let logPath = directory.appendingPathComponent("vttest-vt320-decrqss.log").path

                let controller = TerminalController(
                    rows: 24,
                    cols: 100,
                    termEnv: "xterm-256color",
                    textEncoding: .utf8,
                    scrollbackInitialCapacity: 16 * 1024 * 1024,
                    scrollbackMaxCapacity: 16 * 1024 * 1024,
                    fontName: "Menlo",
                    fontSize: 13
                )
                defer { controller.stop(waitForExit: true) }

                try controller.start()
                controller.sendInput("'\(Self.shellSingleQuoted(vttestPath))' -l '\(Self.shellSingleQuoted(logPath))'\n")

                let pressReturn = { controller.sendInput("\n") }
                let sendChoice: (String) -> Void = { choice in
                    controller.sendInput(choice)
                    pressReturn()
                }

                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
                sendChoice("11")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 8):", timeout: 10.0)
                sendChoice("2")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 6):", timeout: 10.0)
                sendChoice("5")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 6):", timeout: 10.0)
                sendChoice("5")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 11):", timeout: 10.0)

                for item in 1...11 {
                    sendChoice(String(item))
                    try Self.waitForTerminalText(controller, toContain: "Push <RETURN>", timeout: 10.0)
                    pressReturn()
                    try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 11):", timeout: 10.0)
                }

                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 6):", timeout: 10.0)
                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 6):", timeout: 10.0)
                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 8):", timeout: 10.0)
                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
                sendChoice("0")
                controller.sendInput("exit\n")

                let replayLog = try String(contentsOfFile: logPath, encoding: .utf8)
                XCTAssertTrue(replayLog.contains("VT320 Status-String Reports"), replayLog)
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("failed"), "vttest replay log=\n\(replayLog)")
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("not implemented"), "vttest replay log=\n\(replayLog)")
            }
        }
    }

    @MainActor
    func testTerminalControllerRealPTYTimeSeq100000ScrollbackSizingProbe() throws {
        let initialCapacity = 16 * 1024 * 1024
        let controller = TerminalController(
            rows: 24,
            cols: 80,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: initialCapacity,
            scrollbackMaxCapacity: initialCapacity,
            fontName: "Menlo",
            fontSize: 13
        )
        defer { controller.stop(waitForExit: true) }

        let exitExpectation = expectation(description: "controller-exit-time-seq-100000-sizing-probe")
        var exited = false
        controller.onExit = {
            guard !exited else { return }
            exited = true
            exitExpectation.fulfill()
        }

        try controller.start()
        let initialRowIndexCapacity = controller.scrollback.rowIndexCapacity
        let initialDataCapacity = controller.scrollback.capacity
        controller.sendInput("TIMEFMT=$'__PTERM_TIME__ %U %S %P %E'; time seq 1 100000; exit\n")

        wait(for: [exitExpectation], timeout: 30.0)
        drainMainQueue(testCase: self)

        let scrollback = controller.scrollback
        let rowIndexBytes = scrollback.rowIndexCapacity * 12
        print(
            "SEQ100000_SCROLLBACK "
                + "initial_capacity=\(initialCapacity) "
                + "initial_data_capacity=\(initialDataCapacity) "
                + "initial_row_index_capacity=\(initialRowIndexCapacity) "
                + "data_capacity=\(scrollback.capacity) "
                + "data_bytes_used=\(scrollback.bytesUsed) "
                + "row_count=\(scrollback.rowCount) "
                + "row_index_capacity=\(scrollback.rowIndexCapacity) "
                + "row_index_bytes=\(rowIndexBytes) "
                + "serialization_buffer_capacity=\(scrollback.serializationBufferCapacity)"
        )

        let text = controller.allText()
        XCTAssertTrue(text.contains("100000"), "seq output tail should remain visible")
        XCTAssertTrue(text.contains("__PTERM_TIME__"), "shell timing output should be captured")
        XCTAssertEqual(scrollback.capacity, initialDataCapacity, "seq workload should not require data buffer growth")
        XCTAssertEqual(scrollback.rowIndexCapacity, initialRowIndexCapacity, "seq workload should not require row-index growth")
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

    private static func findExecutable(named name: String) -> String? {
        let searchPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/Applications/kitty.app/Contents/MacOS",
        ]
        for directory in searchPaths {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\"'\"'")
    }

    @MainActor
    private static func waitForTerminalText(
        _ controller: TerminalController,
        toContain needle: String,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if controller.allText().contains(needle) {
                return
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail("Timed out waiting for terminal text containing '\(needle)'. tail=\(String(controller.allText().suffix(500)))", file: file, line: line)
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

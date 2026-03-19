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

    func testResolveExecutablePathRequiresAbsoluteExecutableFile() {
        XCTAssertEqual(
            PTY.resolveExecutablePath("/bin/echo", isExecutable: { $0 == "/bin/echo" }),
            "/bin/echo"
        )
        XCTAssertNil(
            PTY.resolveExecutablePath("echo", isExecutable: { _ in true })
        )
        XCTAssertNil(
            PTY.resolveExecutablePath("/missing/echo", isExecutable: { _ in false })
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

    func testPTYCanLaunchDirectExecutableWithoutShell() throws {
        let pty = PTY()
        defer { pty.stop(waitForExit: true) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pterm-direct-exec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let outputExpectation = expectation(description: "pty-direct-exec-output")
        let exitExpectation = expectation(description: "pty-direct-exec-exit")
        let lock = NSLock()
        var collectedOutput = ""
        var exited = false

        pty.onOutput = { data in
            let chunk = String(decoding: data, as: UTF8.self)
            lock.lock()
            collectedOutput += chunk
            if collectedOutput.contains(directory.path) {
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

        try pty.start(
            rows: 24,
            cols: 80,
            initialDirectory: directory.path,
            executablePath: "/bin/pwd"
        )

        wait(for: [outputExpectation, exitExpectation], timeout: 8.0)
        XCTAssertTrue(collectedOutput.contains(directory.path))
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
                termEnv: "xterm-kitty",
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
            let completionExpectation = expectation(description: "controller-kitten-completion-visible")
            var exited = false
            var sawLongEscape = false
            var sawCompletion = false
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
                if !sawCompletion,
                   (text.contains("Results:") || text.contains(doneMarker)) {
                    sawCompletion = true
                    completionExpectation.fulfill()
                }
            }

            try controller.start()
            try Self.waitForTerminalText(
                controller,
                toContain: "%",
                timeout: 8.0
            )
            controller.sendInput(
                "'\(Self.shellSingleQuoted(kittenPath))' __benchmark__ --repetitions 1 2>&1 | tee '\(Self.shellSingleQuoted(outputPath))'; "
                + "printf '\(doneMarker)\\n'; "
                + "exit\n"
            )

            wait(for: [longEscapeExpectation, completionExpectation, exitExpectation], timeout: 45.0)
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
    func testTerminalControllerRealPTYKittenBenchmarkRepetitions100DoesNotLeakDescriptorsOrKittyPayloadFiles() throws {
        guard let kittenPath = Self.findExecutable(named: "kitten") else {
            throw XCTSkip("kitten is not installed in this environment")
        }

        let baselineDescriptorCount = try Self.openFileDescriptorCount()
        let baselinePayloadFiles = Self.currentKittyImagePayloadFilenames()

        try withTemporaryPtermConfig { _ in
            let controller = TerminalController(
                rows: 24,
                cols: 100,
                termEnv: "xterm-kitty",
                textEncoding: .utf8,
                scrollbackInitialCapacity: 16 * 1024 * 1024,
                scrollbackMaxCapacity: 16 * 1024 * 1024,
                fontName: "Menlo",
                fontSize: 13
            )

            let doneMarker = "__PTERM_KITTEN_R100_DONE__"
            let exitExpectation = expectation(description: "controller-exit-kitten-benchmark-r100")
            let completionExpectation = expectation(description: "controller-kitten-r100-completion-visible")
            var exited = false
            var sawCompletion = false

            controller.onExit = {
                guard !exited else { return }
                exited = true
                exitExpectation.fulfill()
            }
            controller.onOutputActivity = {
                let text = controller.allText()
                if !sawCompletion, (text.contains("Results:") || text.contains(doneMarker)) {
                    sawCompletion = true
                    completionExpectation.fulfill()
                }
            }

            try controller.start()
            try Self.waitForTerminalText(controller, toContain: "%", timeout: 8.0)
            controller.sendInput(
                "'\(Self.shellSingleQuoted(kittenPath))' __benchmark__ --render --repetitions 100; "
                + "printf '\(doneMarker)\\n'; "
                + "exit\n"
            )

            wait(for: [completionExpectation, exitExpectation], timeout: 180.0)
            drainMainQueue(testCase: self, timeout: 3.0)
            controller.stop(waitForExit: true)
            drainMainQueue(testCase: self, timeout: 3.0)

            try Self.waitForCondition(
                timeout: 10.0,
                pollInterval: 0.05,
                description: "file descriptor count should return to baseline after kitten benchmark"
            ) {
                try Self.openFileDescriptorCount() <= baselineDescriptorCount + 8
            }

            try Self.waitForCondition(
                timeout: 10.0,
                pollInterval: 0.05,
                description: "kitty image payload temp files should be cleaned up after kitten benchmark"
            ) {
                Self.currentKittyImagePayloadFilenames().subtracting(baselinePayloadFiles).isEmpty
            }
        }
    }

    @MainActor
    func testTerminalControllerRealPTYKittenBenchmarkNamedStagesCompleteIndividually() throws {
        guard let kittenPath = Self.findExecutable(named: "kitten") else {
            throw XCTSkip("kitten is not installed in this environment")
        }

        let stages: [(argument: String, resultLabel: String)] = [
            ("ascii", "Only ASCII chars"),
            ("unicode", "Unicode chars"),
            ("csi", "CSI codes with few chars"),
            ("long_escape_codes", "Long escape codes"),
            ("images", "Images"),
        ]

        try withTemporaryDirectory { directory in
            for stage in stages {
                let controller = TerminalController(
                    rows: 24,
                    cols: 100,
                    termEnv: "xterm-kitty",
                    textEncoding: .utf8,
                    scrollbackInitialCapacity: 16 * 1024 * 1024,
                    scrollbackMaxCapacity: 16 * 1024 * 1024,
                    fontName: "Menlo",
                    fontSize: 13
                )
                defer { controller.stop(waitForExit: true) }

                let outputPath = directory.appendingPathComponent("kitten-benchmark-\(stage.argument).txt").path
                let doneMarker = "__PTERM_KITTEN_STAGE_DONE_\(stage.argument)__"
                let exitExpectation = expectation(description: "controller-exit-kitten-\(stage.argument)")
                let completionExpectation = expectation(description: "controller-kitten-\(stage.argument)-completion-visible")
                var exited = false
                var sawCompletion = false

                controller.onExit = {
                    guard !exited else { return }
                    exited = true
                    exitExpectation.fulfill()
                }
                controller.onOutputActivity = {
                    let text = controller.allText()
                    if !sawCompletion,
                       (text.contains("Results:") || text.contains(doneMarker)) {
                        sawCompletion = true
                        completionExpectation.fulfill()
                    }
                }

                try controller.start()
                try Self.waitForTerminalText(controller, toContain: "%", timeout: 8.0)
                controller.sendInput(
                    "'\(Self.shellSingleQuoted(kittenPath))' __benchmark__ --repetitions 1 \(stage.argument) 2>&1 | tee '\(Self.shellSingleQuoted(outputPath))'; "
                    + "printf '\(doneMarker)\\n'; "
                    + "exit\n"
                )

                wait(for: [completionExpectation, exitExpectation], timeout: 30.0)
                drainMainQueue(testCase: self)

                let terminalText = controller.allText()
                let benchmarkOutput = (try? String(contentsOfFile: outputPath, encoding: .utf8)) ?? ""
                XCTAssertTrue(
                    terminalText.contains(doneMarker),
                    "benchmark stage \(stage.argument) should complete. tail=\(String(terminalText.suffix(500)))"
                )
                XCTAssertTrue(
                    benchmarkOutput.contains("Results:"),
                    "benchmark stage \(stage.argument) should emit results. file tail=\(String(benchmarkOutput.suffix(500)))"
                )
                XCTAssertTrue(
                    benchmarkOutput.contains(stage.resultLabel),
                    "benchmark stage \(stage.argument) should emit the expected results label. file tail=\(String(benchmarkOutput.suffix(500)))"
                )
            }
        }
    }

    @MainActor
    func testTerminalControllerRealPTYKittenImagesStageUsesInlineImagesWithoutPlaceholderText() throws {
        guard let kittenPath = Self.findExecutable(named: "kitten") else {
            throw XCTSkip("kitten is not installed in this environment")
        }

        try withTemporaryPtermConfig { _ in
            PastedImageRegistry.shared.reset()
            defer { PastedImageRegistry.shared.reset() }

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

            let doneMarker = "__PTERM_KITTEN_IMAGES_DONE__"
            let exitExpectation = expectation(description: "controller-exit-kitten-images")
            let imageStageExpectation = expectation(description: "controller-kitten-images-stage-visible")
            var exited = false
            var sawImagesStage = false

            controller.onExit = {
                guard !exited else { return }
                exited = true
                exitExpectation.fulfill()
            }
            controller.onOutputActivity = {
                let text = controller.allText()
                if !sawImagesStage, text.contains("Running: Images") {
                    sawImagesStage = true
                    imageStageExpectation.fulfill()
                }
            }

            try controller.start()
            try Self.waitForTerminalText(controller, toContain: "%", timeout: 8.0)
            controller.sendInput(
                "'\(Self.shellSingleQuoted(kittenPath))' __benchmark__ --repetitions 1 images; "
                + "printf '\(doneMarker)\\n'; "
                + "exit\n"
            )

            wait(for: [imageStageExpectation, exitExpectation], timeout: 30.0)
            drainMainQueue(testCase: self)

            let terminalText = controller.allText()
            XCTAssertTrue(terminalText.contains(doneMarker))
            XCTAssertFalse(terminalText.contains("[Image #"))

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
            sendChoice("6")
            try Self.waitForTerminalText(controller, toContain: "Push <RETURN>", timeout: 10.0)
            XCTAssertFalse(controller.allText().localizedCaseInsensitiveContains("failed"), "Tertiary DA should not fail.\n\(controller.allText())")
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
            XCTAssertTrue(replayLog.contains("Tertiary Device Attributes (DA)"))
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
    func testTerminalControllerRealPTYVttestScreenFeaturesReplayCompletes() throws {
        guard let vttestPath = Self.findExecutable(named: "vttest") else {
            throw XCTSkip("vttest is not installed in this environment")
        }

        try withTemporaryDirectory { directory in
            try MainActor.assumeIsolated {
                let logPath = directory.appendingPathComponent("vttest-screen-features.log").path

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

                let pressReturn = { controller.sendInput("\r") }
                let sendChoice: (String) -> Void = { choice in
                    controller.sendInput(choice)
                    pressReturn()
                }
                let terminalTail = { String(controller.allText().suffix(1600)) }
                let advancePastScreenScenario: (TimeInterval) throws -> Void = { timeout in
                    let deadline = Date().addingTimeInterval(timeout)
                    while Date() < deadline {
                        let tail = terminalTail()
                        if tail.contains("Enter choice number (0 - 12):") {
                            return
                        }
                        pressReturn()
                        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                    }
                    XCTFail("Timed out advancing screen features replay. Tail=\n\(terminalTail())")
                }

                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
                sendChoice("2")
                try advancePastScreenScenario(80.0)
                sendChoice("0")
                controller.sendInput("exit\n")

                let replayLog = try String(contentsOfFile: logPath, encoding: .utf8)
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("failed"), "vttest replay log=\n\(replayLog)")
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("not implemented"), "vttest replay log=\n\(replayLog)")
            }
        }
    }

    @MainActor
    func testTerminalControllerRealPTYVttestCursorMovementsReplayCompletes() throws {
        guard let vttestPath = Self.findExecutable(named: "vttest") else {
            throw XCTSkip("vttest is not installed in this environment")
        }

        try withTemporaryDirectory { directory in
            try MainActor.assumeIsolated {
                let logPath = directory.appendingPathComponent("vttest-cursor-movements.log").path

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
                let terminalTail = { String(controller.allText().suffix(1600)) }
                let advancePastCursorScenario: (TimeInterval) throws -> Void = { timeout in
                    let deadline = Date().addingTimeInterval(timeout)
                    while Date() < deadline {
                        let tail = terminalTail()
                        if tail.contains("Enter choice number (0 - 12):") {
                            return
                        }
                        pressReturn()
                        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                    }
                    XCTFail("Timed out advancing cursor movements replay. Tail=\n\(terminalTail())")
                }

                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
                sendChoice("1")
                try Self.waitForTerminalText(controller, toContain: "The screen should be cleared", timeout: 10.0)
                let viewportLines = Self.visibleViewportLines(of: controller, count: 24)
                let penultimateLine = viewportLines[22]
                XCTAssertEqual(
                    penultimateLine,
                    "*" + String(repeating: "+", count: 78) + "*",
                    "unexpected penultimate line:\n\(viewportLines.joined(separator: "\n"))"
                )
                try advancePastCursorScenario(80.0)
                sendChoice("0")
                controller.sendInput("exit\n")

                let replayLog = try String(contentsOfFile: logPath, encoding: .utf8)
                XCTAssertTrue(replayLog.contains("tst_movements"), "vttest replay log=\n\(replayLog)")
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("failed"), "vttest replay log=\n\(replayLog)")
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("not implemented"), "vttest replay log=\n\(replayLog)")
            }
        }
    }

    func testTerminalControllerRealPTYVttestDoubleSizedCharactersReplayCompletes() throws {
        guard let vttestPath = Self.findExecutable(named: "vttest") else {
            throw XCTSkip("vttest is not installed in this environment")
        }

        try withTemporaryDirectory { directory in
            try MainActor.assumeIsolated {
                let logPath = directory.appendingPathComponent("vttest-double-sized.log").path

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
                let terminalTail = { String(controller.allText().suffix(1600)) }
                let advancePastDoubleSizeScenario: (TimeInterval) throws -> Void = { timeout in
                    let deadline = Date().addingTimeInterval(timeout)
                    while Date() < deadline {
                        let tail = terminalTail()
                        if tail.contains("Enter choice number (0 - 12):") {
                            return
                        }
                        pressReturn()
                        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                    }
                    XCTFail("Timed out advancing double-sized replay. Tail=\n\(terminalTail())")
                }

                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
                sendChoice("4")
                try advancePastDoubleSizeScenario(60.0)
                sendChoice("0")
                controller.sendInput("exit\n")

                let replayLog = try String(contentsOfFile: logPath, encoding: .utf8)
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("failed"), "vttest replay log=\n\(replayLog)")
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("not implemented"), "vttest replay log=\n\(replayLog)")
            }
        }
    }

    @MainActor
    func testTerminalControllerRealPTYVttestResetReplayCompletes() throws {
        guard let vttestPath = Self.findExecutable(named: "vttest") else {
            throw XCTSkip("vttest is not installed in this environment")
        }

        try withTemporaryDirectory { directory in
            try MainActor.assumeIsolated {
                let logPath = directory.appendingPathComponent("vttest-reset.log").path

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
                let terminalTail = { String(controller.allText().suffix(1600)) }
                let advancePastScenario: ([String], TimeInterval) throws -> Void = { menuNeedles, timeout in
                    let deadline = Date().addingTimeInterval(timeout)
                    while Date() < deadline {
                        let tail = terminalTail()
                        if menuNeedles.contains(where: { tail.contains($0) }) {
                            return
                        }
                        pressReturn()
                        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                    }
                    XCTFail("Timed out advancing reset replay. Tail=\n\(terminalTail())")
                }

                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
                sendChoice("10")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 3):", timeout: 10.0)

                sendChoice("1")
                try Self.waitForTerminalText(controller, toContain: "The terminal will now be RESET.", timeout: 10.0)
                try advancePastScenario(["Enter choice number (0 - 3):"], 20.0)

                sendChoice("2")
                try Self.waitForTerminalText(controller, toContain: "built-in confidence test", timeout: 10.0)
                try advancePastScenario(["Enter choice number (0 - 3):"], 20.0)

                sendChoice("3")
                try Self.waitForTerminalText(controller, toContain: "The terminal will now soft-reset", timeout: 10.0)
                try advancePastScenario(["Enter choice number (0 - 3):"], 20.0)

                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
                sendChoice("0")
                controller.sendInput("exit\n")

                let replayLog = try String(contentsOfFile: logPath, encoding: .utf8)
                XCTAssertTrue(replayLog.contains("Test of reset and self-test"))
                XCTAssertTrue(replayLog.contains("Reset to Initial State (RIS)"))
                XCTAssertTrue(replayLog.contains("Invoke Terminal Test (DECTST)"))
                XCTAssertTrue(replayLog.contains("Soft Terminal Reset (DECSTR)"))
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("failed"), "vttest replay log=\n\(replayLog)")
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("not implemented"), "vttest replay log=\n\(replayLog)")
            }
        }
    }

    @MainActor
    func testTerminalControllerRealPTYVttestKeyboardLEDLightsReplayCompletes() throws {
        guard let vttestPath = Self.findExecutable(named: "vttest") else {
            throw XCTSkip("vttest is not installed in this environment")
        }

        try withTemporaryDirectory { directory in
            try MainActor.assumeIsolated {
                let logPath = directory.appendingPathComponent("vttest-keyboard-led-lights.log").path

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
                let terminalTail = { String(controller.allText().suffix(1400)) }
                let advancePastKeyboardScenario: ([String], TimeInterval) throws -> Void = { menuNeedles, timeout in
                    let deadline = Date().addingTimeInterval(timeout)
                    while Date() < deadline {
                        let tail = terminalTail()
                        if menuNeedles.contains(where: { tail.contains($0) }) {
                            return
                        }
                        if tail.contains("Push <RETURN>") {
                            pressReturn()
                        }
                        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                    }
                    XCTFail("Timed out advancing keyboard replay. Tail=\n\(terminalTail())")
                }

                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
                sendChoice("5")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 9):", timeout: 10.0)

                sendChoice("1")
                try Self.waitForTerminalText(controller, toContain: "These LEDs", timeout: 10.0)
                try advancePastKeyboardScenario(["Enter choice number (0 - 9):"], 20.0)

                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
                sendChoice("0")
                controller.sendInput("exit\n")

                let replayLog = try String(contentsOfFile: logPath, encoding: .utf8)
                XCTAssertTrue(replayLog.contains("Test of keyboard"))
                XCTAssertTrue(replayLog.contains("LED Lights"))
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("failed"), "vttest replay log=\n\(replayLog)")
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("not implemented"), "vttest replay log=\n\(replayLog)")
            }
        }
    }

    @MainActor
    func testTerminalControllerRealPTYVttestKeyboardCoreReplayCompletes() throws {
        guard let vttestPath = Self.findExecutable(named: "vttest") else {
            throw XCTSkip("vttest is not installed in this environment")
        }

        try withTemporaryDirectory { directory in
            try MainActor.assumeIsolated {
                let logPath = directory.appendingPathComponent("vttest-keyboard-core.log").path

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
                let terminalTail = { String(controller.allText().suffix(1600)) }
                let waitForKeyboardMenu: (TimeInterval) throws -> Void = { timeout in
                    let deadline = Date().addingTimeInterval(timeout)
                    while Date() < deadline {
                        let tail = terminalTail()
                        if tail.contains("Enter choice number (0 - 9):") {
                            return
                        }
                        if tail.contains("Push <RETURN>") {
                            pressReturn()
                        }
                        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                    }
                    XCTFail("Timed out returning to keyboard menu. Tail=\n\(terminalTail())")
                }
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
                sendChoice("5")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 9):", timeout: 10.0)

                sendChoice("2")
                try Self.waitForTerminalText(controller, toContain: "Auto Repeat OFF:", timeout: 10.0)
                controller.sendInput("a\r")
                try Self.waitForTerminalText(controller, toContain: "Auto Repeat ON:", timeout: 10.0)
                controller.sendInput("aa\r")
                try Self.waitForTerminalText(controller, toContain: "OK.", timeout: 10.0)
                try waitForKeyboardMenu(15.0)

                sendChoice("8")
                try Self.waitForTerminalText(controller, toContain: "Finish with a single RETURN.", timeout: 10.0)
                controller.sendInput("\r")
                try waitForKeyboardMenu(20.0)

                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
                sendChoice("0")
                controller.sendInput("exit\n")

                let replayLog = try String(contentsOfFile: logPath, encoding: .utf8)
                XCTAssertTrue(replayLog.contains("Test of keyboard"))
                XCTAssertTrue(replayLog.contains("Auto Repeat"))
                XCTAssertTrue(replayLog.contains("AnswerBack"))
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("failed"), "vttest replay log=\n\(replayLog)")
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("not implemented"), "vttest replay log=\n\(replayLog)")
            }
        }
    }

    @MainActor
    func testTerminalControllerRealPTYVttestKnownBugsReplayCompletes() throws {
        guard let vttestPath = Self.findExecutable(named: "vttest") else {
            throw XCTSkip("vttest is not installed in this environment")
        }

        try withTemporaryDirectory { directory in
            try MainActor.assumeIsolated {
                let logPath = directory.appendingPathComponent("vttest-known-bugs.log").path

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
                let terminalTail = { String(controller.allText().suffix(1600)) }
                let waitForKnownBugsMenu: (TimeInterval) throws -> Void = { timeout in
                    let deadline = Date().addingTimeInterval(timeout)
                    while Date() < deadline {
                        let tail = terminalTail()
                        if tail.contains("Enter choice number (0 - 9):") {
                            return
                        }
                        pressReturn()
                        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                    }
                    XCTFail("Timed out returning to known-bugs menu. Tail=\n\(terminalTail())")
                }

                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
                sendChoice("9")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 9):", timeout: 10.0)

                let scenarios: [(choice: String, expected: String)] = [
                    ("1", "Scroll while toggle softscroll"),
                    ("2", "Line 11 should be double-wide"),
                    ("3", "Except for this line, the screen should be blank."),
                    ("4", "Enter 0 to exit, 1 to try to invoke the bug again."),
                    ("5", "This test should put an 'X' at line 3 column 100."),
                    ("6", "Toggle origin mode, forget rest"),
                    ("7", "wrap around bug"),
                    ("8", "right half of double-width lines"),
                    ("9", "This is 20 lines of text")
                ]

                for scenario in scenarios {
                    sendChoice(scenario.choice)
                    try Self.waitForTerminalText(controller, toContain: scenario.expected, timeout: 10.0)
                    try waitForKnownBugsMenu(20.0)
                }

                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
                sendChoice("0")
                controller.sendInput("exit\n")

                let replayLog = try String(contentsOfFile: logPath, encoding: .utf8)
                XCTAssertTrue(replayLog.contains("Test of known bugs"))
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("failed"), "vttest replay log=\n\(replayLog)")
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("not implemented"), "vttest replay log=\n\(replayLog)")
            }
        }
    }

    @MainActor
    func testTerminalControllerRealPTYVttestVT52ModeReplayCompletes() throws {
        guard let vttestPath = Self.findExecutable(named: "vttest") else {
            throw XCTSkip("vttest is not installed in this environment")
        }

        try withTemporaryDirectory { directory in
            try MainActor.assumeIsolated {
                let logPath = directory.appendingPathComponent("vttest-vt52-mode.log").path

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
                let terminalTail = { String(controller.allText().suffix(1600)) }
                let advancePastVT52Scenario: (TimeInterval) throws -> Void = { timeout in
                    let deadline = Date().addingTimeInterval(timeout)
                    while Date() < deadline {
                        let tail = terminalTail()
                        if tail.contains("Enter choice number (0 - 12):") {
                            return
                        }
                        pressReturn()
                        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                    }
                    XCTFail("Timed out advancing VT52 replay. Tail=\n\(terminalTail())")
                }

                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
                sendChoice("7")
                try advancePastVT52Scenario(30.0)
                sendChoice("0")
                controller.sendInput("exit\n")

                let replayLog = try String(contentsOfFile: logPath, encoding: .utf8)
                XCTAssertFalse(replayLog.isEmpty)
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("unknown response"), "vttest replay log=\n\(replayLog)")
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("failed"), "vttest replay log=\n\(replayLog)")
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("not implemented"), "vttest replay log=\n\(replayLog)")
            }
        }
    }

    func testTerminalControllerRealPTYVttestVT102FeaturesReplayCompletes() throws {
        guard let vttestPath = Self.findExecutable(named: "vttest") else {
            throw XCTSkip("vttest is not installed in this environment")
        }

        try withTemporaryDirectory { directory in
            try MainActor.assumeIsolated {
                let logPath = directory.appendingPathComponent("vttest-vt102-features.log").path

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
                let terminalTail = { String(controller.allText().suffix(1400)) }
                let advancePastVT102Scenario: (TimeInterval) throws -> Void = { timeout in
                    let deadline = Date().addingTimeInterval(timeout)
                    while Date() < deadline {
                        let tail = terminalTail()
                        if tail.contains("Enter choice number (0 - 12):") {
                            return
                        }
                        pressReturn()
                        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                    }
                    XCTFail("Timed out advancing VT102 features replay. Tail=\n\(terminalTail())")
                }

                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
                sendChoice("8")
                try Self.waitForTerminalText(controller, toContain: "Screen accordion test", timeout: 10.0)
                try advancePastVT102Scenario(40.0)
                sendChoice("0")
                controller.sendInput("exit\n")

                let replayLog = try String(contentsOfFile: logPath, encoding: .utf8)
                XCTAssertTrue(replayLog.contains("Test of VT102 features"))
                XCTAssertTrue(replayLog.contains("Screen accordion test"))
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("failed"), "vttest replay log=\n\(replayLog)")
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("not implemented"), "vttest replay log=\n\(replayLog)")
            }
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
    func testTerminalControllerRealPTYVttestVT100CharsetReplayCompletes() throws {
        guard let vttestPath = Self.findExecutable(named: "vttest") else {
            throw XCTSkip("vttest is not installed in this environment")
        }

        try withTemporaryDirectory { directory in
            try MainActor.assumeIsolated {
                let logPath = directory.appendingPathComponent("vttest-charsets-vt100.log").path

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

                sendChoice("8")
                try Self.waitForTerminalText(controller, toContain: "These are the installed character sets.", timeout: 10.0)
                try Self.waitForTerminalText(controller, toContain: "Push <RETURN>", timeout: 10.0)
                pressReturn()
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 13):", timeout: 10.0)

                sendChoice("9")
                try Self.waitForTerminalText(controller, toContain: "These are the G0 and G1 character sets.", timeout: 10.0)
                try Self.waitForTerminalText(controller, toContain: "Push <RETURN>", timeout: 10.0)
                pressReturn()
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 13):", timeout: 10.0)

                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
                sendChoice("0")
                controller.sendInput("exit\n")

                let replayLog = try String(contentsOfFile: logPath, encoding: .utf8)
                XCTAssertTrue(replayLog.contains("Test VT100 Character Sets"))
                XCTAssertTrue(replayLog.contains("Test Shift In/Shift Out (SI/SO)"))
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("failed"), "vttest replay log=\n\(replayLog)")
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("not implemented"), "vttest replay log=\n\(replayLog)")
            }
        }
    }

    @MainActor
    func testTerminalControllerRealPTYVttestCharsetSelectionReplayCompletes() throws {
        guard let vttestPath = Self.findExecutable(named: "vttest") else {
            throw XCTSkip("vttest is not installed in this environment")
        }

        try withTemporaryDirectory { directory in
            try MainActor.assumeIsolated {
                let logPath = directory.appendingPathComponent("vttest-charsets-selection.log").path

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

                sendChoice("1")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 13):", timeout: 10.0)

                for item in ["4", "5", "6", "7"] {
                    sendChoice(item)
                    try Self.waitForTerminalText(controller, toContain: "Choose character-set:", timeout: 10.0)
                    sendChoice("1")
                    try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 13):", timeout: 10.0)
                }

                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
                sendChoice("0")
                controller.sendInput("exit\n")

                let replayLog = try String(contentsOfFile: logPath, encoding: .utf8)
                XCTAssertTrue(replayLog.contains("Character-Set Tests"))
                XCTAssertTrue(replayLog.contains("Reset (G0 ASCII, G1 Latin-1, no NRC mode)"))
                XCTAssertTrue(replayLog.contains("Specify G0"))
                XCTAssertTrue(replayLog.contains("Specify G1"))
                XCTAssertTrue(replayLog.contains("Specify G2"))
                XCTAssertTrue(replayLog.contains("Specify G3"))
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("failed"), "vttest replay log=\n\(replayLog)")
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("not implemented"), "vttest replay log=\n\(replayLog)")
            }
        }
    }

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
                XCTAssertTrue(replayLog.contains("Read: <27> [ ? 6 5 ; 4 ; 6 ; 1 8 ; 2 2 c"), replayLog)
                XCTAssertTrue(replayLog.contains("Read: <27> P 1 $ r 6 5 ; 1 \" p <27> \\"), replayLog)
                XCTAssertTrue(replayLog.contains("Read: <27> [ > 1 ; 2 7 7 ; 0 c"), replayLog)
            }
        }
    }

    @MainActor
    func testTerminalControllerRealPTYVttestSetupReplayCompletes() throws {
        guard let vttestPath = Self.findExecutable(named: "vttest") else {
            throw XCTSkip("vttest is not installed in this environment")
        }

        try withTemporaryDirectory { directory in
            try MainActor.assumeIsolated {
                let logPath = directory.appendingPathComponent("vttest-setup-replay.log").path

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

                let sendChoice: (String) -> Void = { choice in
                    controller.sendInput(choice)
                    controller.sendInput("\n")
                }
                let terminalTail = { String(controller.allText().suffix(1600)) }
                let advanceToSetupMenu: (TimeInterval) throws -> Void = { timeout in
                    let deadline = Date().addingTimeInterval(timeout)
                    while Date() < deadline {
                        let tail = terminalTail()
                        if tail.contains("Select a number to modify it:") {
                            return
                        }
                        if tail.contains("Push <RETURN>") {
                            controller.sendInput("\n")
                        }
                        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                    }
                    XCTFail("Timed out returning to setup menu. Tail=\n\(terminalTail())")
                }

                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
                sendChoice("12")
                try Self.waitForTerminalText(controller, toContain: "Select a number to modify it:", timeout: 10.0)

                for item in 1...8 {
                    sendChoice(String(item))
                    try advanceToSetupMenu(10.0)
                }

                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
                sendChoice("0")
                controller.sendInput("exit\n")

                let replayLog = try String(contentsOfFile: logPath, encoding: .utf8)
                XCTAssertTrue(replayLog.contains("Modify test-parameters"))
                XCTAssertTrue(replayLog.contains("Operating level"))
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("failed"), "vttest replay log=\n\(replayLog)")
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("not implemented"), "vttest replay log=\n\(replayLog)")
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
    func testTerminalControllerRealPTYVttestVT320DeviceStatusReplayCompletes() throws {
        guard let vttestPath = Self.findExecutable(named: "vttest") else {
            throw XCTSkip("vttest is not installed in this environment")
        }

        try withTemporaryDirectory { directory in
            try MainActor.assumeIsolated {
                let logPath = directory.appendingPathComponent("vttest-vt320-device-status.log").path

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
                let terminalTail = { String(controller.allText().suffix(1400)) }
                let advancePastHoldToMenu: ([String], TimeInterval) throws -> Void = { menuNeedles, timeout in
                    let deadline = Date().addingTimeInterval(timeout)
                    while Date() < deadline {
                        let tail = terminalTail()
                        if menuNeedles.contains(where: { tail.contains($0) }) {
                            return
                        }
                        if tail.contains("Push <RETURN>") {
                            pressReturn()
                        }
                        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                    }
                    XCTFail("Timed out advancing past hold to menu \(menuNeedles). Tail=\n\(terminalTail())")
                }

                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
                sendChoice("11")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 8):", timeout: 10.0)
                sendChoice("2")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 6):", timeout: 10.0)
                sendChoice("5")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 6):", timeout: 10.0)
                sendChoice("2")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 7):", timeout: 10.0)

                for item in ["2", "3", "4", "5", "6", "7"] {
                    sendChoice(item)
                    try Self.waitForTerminalText(controller, toContain: "Push <RETURN>", timeout: 10.0)
                    try advancePastHoldToMenu(["Enter choice number (0 - 7):"], 10.0)
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
                XCTAssertTrue(replayLog.contains("VT320 Device Status Reports (DSR)"))
                XCTAssertTrue(replayLog.contains("Test Locator Status"))
                XCTAssertTrue(replayLog.contains("Identify Locator"))
                XCTAssertTrue(replayLog.contains("Test Extended Cursor-Position (DECXCPR)"))
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
                let terminalTail = { String(controller.allText().suffix(1200)) }
                let waitForTail: (String, TimeInterval) throws -> Void = { needle, timeout in
                    let deadline = Date().addingTimeInterval(timeout)
                    while Date() < deadline {
                        if terminalTail().contains(needle) {
                            return
                        }
                        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                    }
                    XCTFail("Timed out waiting for terminal tail to contain '\(needle)'. Tail=\n\(terminalTail())")
                }

                try waitForTail("Enter choice number (0 - 12):", 10.0)
                sendChoice("11")
                try waitForTail("Enter choice number (0 - 8):", 10.0)
                sendChoice("2")
                try waitForTail("Enter choice number (0 - 6):", 10.0)
                sendChoice("5")
                try waitForTail("Enter choice number (0 - 6):", 10.0)
                sendChoice("3")
                try waitForTail("Enter choice number (0 - 6):", 10.0)
                sendChoice("6")
                try waitForTail("Enter choice number (0 - 11):", 10.0)

                for item in 1...11 {
                    sendChoice(String(item))
                    try waitForTail("Testing DECRQSS:", 10.0)
                    try waitForTail("Push <RETURN>", 10.0)
                    pressReturn()
                    try waitForTail("Enter choice number (0 - 11):", 10.0)
                }

                sendChoice("0")
                try waitForTail("Enter choice number (0 - 6):", 10.0)
                sendChoice("0")
                try waitForTail("Enter choice number (0 - 6):", 10.0)
                sendChoice("0")
                try waitForTail("Enter choice number (0 - 6):", 10.0)
                sendChoice("0")
                try waitForTail("Enter choice number (0 - 8):", 10.0)
                sendChoice("0")
                try waitForTail("Enter choice number (0 - 12):", 10.0)
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
    func testTerminalControllerRealPTYVttestVT320CursorMovementReplayCompletes() throws {
        guard let vttestPath = Self.findExecutable(named: "vttest") else {
            throw XCTSkip("vttest is not installed in this environment")
        }

        try withTemporaryDirectory { directory in
            try MainActor.assumeIsolated {
                let logPath = directory.appendingPathComponent("vttest-vt320-cursor.log").path

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
                sendChoice("2")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 4):", timeout: 10.0)

                sendChoice("1")
                try Self.waitForTerminalText(controller, toContain: "Test Pan down (SU)", timeout: 10.0)
                try Self.waitForTerminalText(controller, toContain: "There should be a horizontal row of *'s above, on the top row.", timeout: 10.0)
                try Self.waitForTerminalText(controller, toContain: "Push <RETURN>", timeout: 10.0)
                pressReturn()
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 4):", timeout: 10.0)

                sendChoice("2")
                try Self.waitForTerminalText(controller, toContain: "Test Pan up (SD)", timeout: 10.0)
                try Self.waitForTerminalText(controller, toContain: "There should be a horizontal row of *'s above, just above the message.", timeout: 10.0)
                try Self.waitForTerminalText(controller, toContain: "Push <RETURN>", timeout: 10.0)
                pressReturn()
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 4):", timeout: 10.0)

                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 6):", timeout: 10.0)
                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 8):", timeout: 10.0)
                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
                sendChoice("0")
                controller.sendInput("exit\n")

                let replayLog = try String(contentsOfFile: logPath, encoding: .utf8)
                XCTAssertTrue(replayLog.contains("Test Pan down (SU)"))
                XCTAssertTrue(replayLog.contains("Test Pan up (SD)"))
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("failed"), "vttest replay log=\n\(replayLog)")
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("not implemented"), "vttest replay log=\n\(replayLog)")
            }
        }
    }

    @MainActor
    func testTerminalControllerRealPTYVttestVT320ScreenDisplayReplayCompletes() throws {
        guard let vttestPath = Self.findExecutable(named: "vttest") else {
            throw XCTSkip("vttest is not installed in this environment")
        }

        try withTemporaryDirectory { directory in
            try MainActor.assumeIsolated {
                let logPath = directory.appendingPathComponent("vttest-vt320-screen.log").path

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
                        let tail = terminalTail()
                        if let match = needles.first(where: { tail.contains($0) }) {
                            return match
                        }
                        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                    }
                    XCTFail("Timed out waiting for terminal tail to contain one of \(needles). Tail=\n\(terminalTail())")
                    return needles[0]
                }
                let advancePastHoldToMenu: ([String], TimeInterval) throws -> Void = { menuNeedles, timeout in
                    let deadline = Date().addingTimeInterval(timeout)
                    while Date() < deadline {
                        let tail = terminalTail()
                        if menuNeedles.contains(where: { tail.contains($0) }) {
                            return
                        }
                        if tail.contains("Push <RETURN>") {
                            pressReturn()
                        }
                        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                    }
                    XCTFail("Timed out advancing past hold to menu \(menuNeedles). Tail=\n\(terminalTail())")
                }

                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
                sendChoice("11")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 8):", timeout: 10.0)
                sendChoice("2")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 6):", timeout: 10.0)
                sendChoice("6")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 2):", timeout: 10.0)

                sendChoice("1")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 4):", timeout: 10.0)
                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 2):", timeout: 10.0)

                sendChoice("2")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 3):", timeout: 10.0)
                let statusLineTitles: [Int: String] = [
                    1: "This is a simple test of the status-line",
                    2: "This test writes SGR controls to the status-line",
                    3: "This test demonstrates cursor-movement in the status-line",
                ]
                for item in 1...3 {
                    sendChoice(String(item))
                    try Self.waitForTerminalText(controller, toContain: statusLineTitles[item]!, timeout: 10.0)
                    _ = try waitForAnyTail(["Push <RETURN>", "Enter choice number (0 - 3):"], 10.0)
                    try advancePastHoldToMenu(["Enter choice number (0 - 3):"], 10.0)
                }

                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 2):", timeout: 10.0)
                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 6):", timeout: 10.0)
                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 8):", timeout: 10.0)
                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
                sendChoice("0")
                controller.sendInput("exit\n")

                let replayLog = try String(contentsOfFile: logPath, encoding: .utf8)
                XCTAssertTrue(replayLog.contains("VT320 Screen-Display Tests"))
                XCTAssertTrue(replayLog.contains("Test Status line (DECSASD/DECSSDT)"))
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("failed"), "vttest replay log=\n\(replayLog)")
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("not implemented"), "vttest replay log=\n\(replayLog)")
            }
        }
    }

    @MainActor
    func testTerminalControllerRealPTYVttestVT420PresentationReportsReplayCompletes() throws {
        guard let vttestPath = Self.findExecutable(named: "vttest") else {
            throw XCTSkip("vttest is not installed in this environment")
        }

        try withTemporaryDirectory { directory in
            try MainActor.assumeIsolated {
                let logPath = directory.appendingPathComponent("vttest-vt420-presentation.log").path

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
                let terminalTail = { String(controller.allText().suffix(1400)) }
                let advancePastHoldToMenu: ([String], TimeInterval) throws -> Void = { menuNeedles, timeout in
                    let deadline = Date().addingTimeInterval(timeout)
                    while Date() < deadline {
                        let tail = terminalTail()
                        if menuNeedles.contains(where: { tail.contains($0) }) {
                            return
                        }
                        if tail.contains("Push <RETURN>") {
                            pressReturn()
                        }
                        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                    }
                    XCTFail("Timed out advancing past hold to menu \(menuNeedles). Tail=\n\(terminalTail())")
                }

                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
                sendChoice("11")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 8):", timeout: 10.0)
                sendChoice("3")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 8):", timeout: 10.0)
                sendChoice("7")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 3):", timeout: 10.0)
                sendChoice("2")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 3):", timeout: 10.0)
                sendChoice("2")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 2):", timeout: 10.0)

                sendChoice("1")
                try Self.waitForTerminalText(controller, toContain: "Push <RETURN>", timeout: 10.0)
                try advancePastHoldToMenu(["Enter choice number (0 - 2):"], 10.0)

                sendChoice("2")
                try Self.waitForTerminalText(controller, toContain: "Push <RETURN>", timeout: 10.0)
                try advancePastHoldToMenu(["Enter choice number (0 - 2):"], 10.0)

                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 3):", timeout: 10.0)
                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 3):", timeout: 10.0)
                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 8):", timeout: 10.0)
                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 8):", timeout: 10.0)
                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
                sendChoice("0")
                controller.sendInput("exit\n")

                let replayLog = try String(contentsOfFile: logPath, encoding: .utf8)
                XCTAssertTrue(replayLog.contains("VT420 Presentation State Reports"))
                XCTAssertTrue(replayLog.contains("Request Mode (DECRQM)/Report Mode (DECRPM)"))
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("failed"), "vttest replay log=\n\(replayLog)")
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("not implemented"), "vttest replay log=\n\(replayLog)")
            }
        }
    }

    @MainActor
    func testTerminalControllerRealPTYVttestVT520ScreenDisplayCursorStyleReplayCompletes() throws {
        guard let vttestPath = Self.findExecutable(named: "vttest") else {
            throw XCTSkip("vttest is not installed in this environment")
        }

        try withTemporaryDirectory { directory in
            try MainActor.assumeIsolated {
                let logPath = directory.appendingPathComponent("vttest-vt520-cursor-style.log").path

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
                let terminalTail = { String(controller.allText().suffix(1600)) }
                let advancePastVT520CursorStyleScenario: (TimeInterval) throws -> Void = { timeout in
                    let deadline = Date().addingTimeInterval(timeout)
                    while Date() < deadline {
                        let tail = terminalTail()
                        if tail.contains("Enter choice number (0 - 3):") {
                            return
                        }
                        pressReturn()
                        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                    }
                    XCTFail("Timed out advancing VT520 cursor style replay. Tail=\n\(terminalTail())")
                }

                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
                sendChoice("11")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 8):", timeout: 10.0)
                sendChoice("4")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 6):", timeout: 10.0)
                sendChoice("6")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 3):", timeout: 10.0)

                sendChoice("2")
                try Self.waitForTerminalText(controller, toContain: "The cursor should be a blinking rectangle", timeout: 10.0)
                try advancePastVT520CursorStyleScenario(40.0)

                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 6):", timeout: 10.0)
                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 8):", timeout: 10.0)
                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
                sendChoice("0")
                controller.sendInput("exit\n")

                let replayLog = try String(contentsOfFile: logPath, encoding: .utf8)
                XCTAssertTrue(replayLog.contains("VT520 Screen-Display Tests"))
                XCTAssertTrue(replayLog.contains("Test Set Cursor Style (DECSCUSR)"))
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("failed"), "vttest replay log=\n\(replayLog)")
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("not implemented"), "vttest replay log=\n\(replayLog)")
            }
        }
    }

    @MainActor
    func testTerminalControllerRealPTYVttestVT520CursorMovementReplayCompletes() throws {
        guard let vttestPath = Self.findExecutable(named: "vttest") else {
            throw XCTSkip("vttest is not installed in this environment")
        }

        try withTemporaryDirectory { directory in
            try MainActor.assumeIsolated {
                let logPath = directory.appendingPathComponent("vttest-vt520-cursor-movement.log").path

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
                let terminalTail = { String(controller.allText().suffix(1600)) }
                let advancePastScenario: ([String], TimeInterval) throws -> Void = { menuNeedles, timeout in
                    let deadline = Date().addingTimeInterval(timeout)
                    while Date() < deadline {
                        let tail = terminalTail()
                        if menuNeedles.contains(where: { tail.contains($0) }) {
                            return
                        }
                        pressReturn()
                        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                    }
                    XCTFail("Timed out advancing VT520 cursor-movement replay. Tail=\n\(terminalTail())")
                }

                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
                sendChoice("11")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 8):", timeout: 10.0)
                sendChoice("4")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 6):", timeout: 10.0)
                sendChoice("2")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 15):", timeout: 10.0)

                sendChoice("7")
                try Self.waitForTerminalText(controller, toContain: "Push <RETURN>", timeout: 10.0)
                try advancePastScenario(["Enter choice number (0 - 15):"], 10.0)

                sendChoice("8")
                try Self.waitForTerminalText(controller, toContain: "Push <RETURN>", timeout: 10.0)
                try advancePastScenario(["Enter choice number (0 - 15):"], 10.0)

                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 6):", timeout: 10.0)
                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 8):", timeout: 10.0)
                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
                sendChoice("0")
                controller.sendInput("exit\n")

                let replayLog = try String(contentsOfFile: logPath, encoding: .utf8)
                XCTAssertTrue(replayLog.contains("VT520 Cursor-Movement"))
                XCTAssertTrue(replayLog.contains("Test Character-Position-Absolute (HPA)"))
                XCTAssertTrue(replayLog.contains("Test Cursor-Back-Tab (CBT)"))
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("failed"), "vttest replay log=\n\(replayLog)")
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("not implemented"), "vttest replay log=\n\(replayLog)")
            }
        }
    }

    func testTerminalControllerRealPTYVttestVT420DeviceStatusBasicReplayCompletes() throws {
        guard let vttestPath = Self.findExecutable(named: "vttest") else {
            throw XCTSkip("vttest is not installed in this environment")
        }

        try withTemporaryDirectory { directory in
            try MainActor.assumeIsolated {
                let logPath = directory.appendingPathComponent("vttest-vt420-device-status-basic.log").path

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
                let terminalTail = { String(controller.allText().suffix(1400)) }
                let advancePastHoldToMenu: ([String], TimeInterval) throws -> Void = { menuNeedles, timeout in
                    let deadline = Date().addingTimeInterval(timeout)
                    while Date() < deadline {
                        let tail = terminalTail()
                        if menuNeedles.contains(where: { tail.contains($0) }) {
                            return
                        }
                        if tail.contains("Push <RETURN>") {
                            pressReturn()
                        }
                        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                    }
                    XCTFail("Timed out advancing past hold to menu \(menuNeedles). Tail=\n\(terminalTail())")
                }

                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
                sendChoice("11")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 8):", timeout: 10.0)
                sendChoice("3")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 8):", timeout: 10.0)
                sendChoice("7")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 3):", timeout: 10.0)
                sendChoice("3")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 11):", timeout: 10.0)

                for item in ["2", "3", "4"] {
                    sendChoice(item)
                    try Self.waitForTerminalText(controller, toContain: "Push <RETURN>", timeout: 10.0)
                    try advancePastHoldToMenu(["Enter choice number (0 - 11):"], 10.0)
                }

                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 3):", timeout: 10.0)
                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 8):", timeout: 10.0)
                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 8):", timeout: 10.0)
                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
                sendChoice("0")
                controller.sendInput("exit\n")

                let replayLog = try String(contentsOfFile: logPath, encoding: .utf8)
                XCTAssertTrue(replayLog.contains("VT420 Device Status Reports (DSR)"))
                XCTAssertTrue(replayLog.contains("Test Printer Status"))
                XCTAssertTrue(replayLog.contains("Test UDK Status"))
                XCTAssertTrue(replayLog.contains("Test Keyboard Status"))
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("failed"), "vttest replay log=\n\(replayLog)")
                XCTAssertFalse(replayLog.localizedCaseInsensitiveContains("not implemented"), "vttest replay log=\n\(replayLog)")
            }
        }
    }

    @MainActor
    func testTerminalControllerRealPTYVttestVT420DeviceStatusExtendedReplayCompletes() throws {
        guard let vttestPath = Self.findExecutable(named: "vttest") else {
            throw XCTSkip("vttest is not installed in this environment")
        }

        try withTemporaryDirectory { directory in
            try MainActor.assumeIsolated {
                let logPath = directory.appendingPathComponent("vttest-vt420-device-status-extended.log").path

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
                let terminalTail = { String(controller.allText().suffix(1400)) }
                let advancePastHoldToMenu: ([String], TimeInterval) throws -> Void = { menuNeedles, timeout in
                    let deadline = Date().addingTimeInterval(timeout)
                    while Date() < deadline {
                        let tail = terminalTail()
                        if menuNeedles.contains(where: { tail.contains($0) }) {
                            return
                        }
                        if tail.contains("Push <RETURN>") {
                            pressReturn()
                        }
                        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                    }
                    XCTFail("Timed out advancing past hold to menu \(menuNeedles). Tail=\n\(terminalTail())")
                }

                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
                sendChoice("11")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 8):", timeout: 10.0)
                sendChoice("3")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 8):", timeout: 10.0)
                sendChoice("7")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 3):", timeout: 10.0)
                sendChoice("3")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 11):", timeout: 10.0)

                for item in ["5", "7", "8", "11"] {
                    sendChoice(item)
                    try Self.waitForTerminalText(controller, toContain: "Push <RETURN>", timeout: 10.0)
                    try advancePastHoldToMenu(["Enter choice number (0 - 11):"], 10.0)
                }

                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 3):", timeout: 10.0)
                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 8):", timeout: 10.0)
                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 8):", timeout: 10.0)
                sendChoice("0")
                try Self.waitForTerminalText(controller, toContain: "Enter choice number (0 - 12):", timeout: 10.0)
                sendChoice("0")
                controller.sendInput("exit\n")

                let replayLog = try String(contentsOfFile: logPath, encoding: .utf8)
                XCTAssertTrue(replayLog.contains("VT420 Device Status Reports (DSR)"))
                XCTAssertTrue(replayLog.contains("Test Macro Space"))
                XCTAssertTrue(replayLog.contains("Test Data Integrity"))
                XCTAssertTrue(replayLog.contains("Test Multiple Session Status"))
                XCTAssertTrue(replayLog.contains("Test Extended Cursor-Position (DECXCPR)"))
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
            let reconstructedOutput = try Self.reconstructedAuditOutput(from: payload)
            XCTAssertTrue(reconstructedOutput.contains("audit499 payload"))
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

    private static func openFileDescriptorCount() throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: "/dev/fd")
            .compactMap { Int($0) }
            .count
    }

    private static func currentKittyImagePayloadFilenames() -> Set<String> {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pterm-kitty-image-payloads", isDirectory: true)
        let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return Set(contents?.map(\.lastPathComponent) ?? [])
    }

    @MainActor
    private static func waitForCondition(
        timeout: TimeInterval,
        pollInterval: TimeInterval,
        description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: () throws -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() {
                return
            }
            RunLoop.main.run(until: Date().addingTimeInterval(pollInterval))
        }
        XCTFail("Timed out waiting for condition: \(description)", file: file, line: line)
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

private extension PTYIntegrationTests {
    static func reconstructedAuditOutput(from castData: Data) throws -> String {
        let text = String(decoding: castData, as: UTF8.self)
        var output = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.first == "[" else { continue }
            guard
                let data = line.data(using: .utf8),
                let array = try JSONSerialization.jsonObject(with: data) as? [Any],
                array.count == 3,
                let type = array[1] as? String,
                let payload = array[2] as? String,
                type == "o"
            else {
                continue
            }
            output.append(payload)
        }
        return output
    }
}

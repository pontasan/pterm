import AppKit
import CommonCrypto
import CryptoKit
import XCTest
@testable import PtermApp

final class AppInfrastructureTests: XCTestCase {
    func testLaunchOptionsParseChromeStyleProfileDirectoryEqualsForm() throws {
        let cwd = URL(fileURLWithPath: "/tmp/current", isDirectory: true)
        let options = try LaunchOptions.parse(
            arguments: ["--user-data-dir=profiles/run-01"],
            currentDirectory: cwd
        )

        XCTAssertEqual(
            options.profileRoot,
            cwd.appendingPathComponent("profiles/run-01", isDirectory: true).standardizedFileURL
        )
    }

    func testLaunchOptionsParseUserDataDirSeparateArgumentAndExpandTilde() throws {
        let options = try LaunchOptions.parse(arguments: ["--user-data-dir", "~/tmp-pterm-profile"])
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("tmp-pterm-profile", isDirectory: true)
            .standardizedFileURL

        XCTAssertEqual(options.profileRoot, expected)
    }

    func testLaunchOptionsRejectsMissingProfileRootValue() {
        XCTAssertThrowsError(try LaunchOptions.parse(arguments: ["--user-data-dir"])) { error in
            XCTAssertEqual(error as? LaunchOptionsError, .missingValue("--user-data-dir"))
        }
    }

    func testLaunchOptionsRejectsDuplicateProfileRootOptions() {
        XCTAssertThrowsError(
            try LaunchOptions.parse(arguments: ["--user-data-dir=/tmp/one", "--user-data-dir=/tmp/two"])
        ) { error in
            XCTAssertEqual(error as? LaunchOptionsError, .duplicateProfileRootOption)
        }
    }

    func testLaunchOptionsDefaultsRestoreSessionModeToAttempt() throws {
        let options = try LaunchOptions.parse(arguments: [])

        XCTAssertEqual(options.restoreSessionMode, .attempt)
        XCTAssertNil(options.profileRoot)
        XCTAssertFalse(options.cliMode)
        XCTAssertNil(options.immediateAction)
    }

    func testLaunchOptionsParsesRestoreSessionModeEqualsForm() throws {
        let options = try LaunchOptions.parse(arguments: ["--restore-session=force"])

        XCTAssertEqual(options.restoreSessionMode, .force)
    }

    func testLaunchOptionsParsesRestoreSessionModeSeparateValueForm() throws {
        let options = try LaunchOptions.parse(arguments: ["--restore-session", "never"])

        XCTAssertEqual(options.restoreSessionMode, .never)
    }

    func testLaunchOptionsRejectsInvalidRestoreSessionMode() {
        XCTAssertThrowsError(try LaunchOptions.parse(arguments: ["--restore-session=maybe"])) { error in
            XCTAssertEqual(error as? LaunchOptionsError, .invalidRestoreSessionMode("maybe"))
        }
    }

    func testLaunchOptionsParsesHelpFlag() throws {
        let options = try LaunchOptions.parse(arguments: ["--help"])

        XCTAssertEqual(options.immediateAction, .help)
    }

    func testLaunchOptionsParsesVersionFlag() throws {
        let options = try LaunchOptions.parse(arguments: ["--version"])

        XCTAssertEqual(options.immediateAction, .version)
    }

    func testLaunchOptionsParsesCLIModeFlag() throws {
        let options = try LaunchOptions.parse(arguments: ["--cli"])

        XCTAssertTrue(options.cliMode)
        XCTAssertNil(options.directLaunch)
    }

    func testLaunchOptionsRejectsDuplicateCLIModeFlag() {
        XCTAssertThrowsError(try LaunchOptions.parse(arguments: ["--cli", "--cli"])) { error in
            XCTAssertEqual(error as? LaunchOptionsError, .duplicateCLIModeOption)
        }
    }

    func testLaunchOptionsParsesDirectCommandEqualsForm() throws {
        let options = try LaunchOptions.parse(arguments: ["--command=/opt/homebrew/bin/vttest"])

        XCTAssertEqual(
            options.directLaunch,
            DirectLaunchOptions(
                executablePath: "/opt/homebrew/bin/vttest",
                arguments: []
            )
        )
    }

    func testLaunchOptionsParsesCLIPassthroughCommandAfterDoubleDash() throws {
        let options = try LaunchOptions.parse(
            arguments: ["--cli", "--", "/usr/bin/env", "printenv", "TERM"]
        )

        XCTAssertTrue(options.cliMode)
        XCTAssertEqual(
            options.directLaunch,
            DirectLaunchOptions(
                executablePath: "/usr/bin/env",
                arguments: ["printenv", "TERM"]
            )
        )
    }

    func testLaunchOptionsParsesDirectCommandAndPassthroughArguments() throws {
        let options = try LaunchOptions.parse(
            arguments: ["--command", "/usr/bin/env", "--", "printenv", "TERM"]
        )

        XCTAssertEqual(
            options.directLaunch,
            DirectLaunchOptions(
                executablePath: "/usr/bin/env",
                arguments: ["printenv", "TERM"]
            )
        )
    }

    func testLaunchOptionsRejectsDuplicateDirectCommandOptions() {
        XCTAssertThrowsError(
            try LaunchOptions.parse(arguments: ["--command=/bin/echo", "--command=/bin/date"])
        ) { error in
            XCTAssertEqual(error as? LaunchOptionsError, .duplicateCommandOption)
        }
    }

    func testLaunchOptionsRejectsEmptyDirectCommandPath() {
        XCTAssertThrowsError(try LaunchOptions.parse(arguments: ["--command="])) { error in
            XCTAssertEqual(error as? LaunchOptionsError, .emptyCommandPath)
        }
    }

    func testTransientWorkspaceNameUsesCommandBasenameAndUniqueSuffix() {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!

        let name = AppDelegate.transientWorkspaceName(
            commandPath: "/opt/homebrew/bin/vttest",
            id: id
        )

        XCTAssertTrue(name.contains("Temporary"))
        XCTAssertTrue(name.contains("vttest"))
        XCTAssertTrue(name.contains("12345678"))
    }

    func testPersistedPresentationPlanDropsTransientFocusedTerminal() {
        let transientID = UUID()

        let plan = AppDelegate.persistedPresentationPlan(
            currentPresentation: .focused(transientID),
            persistedTerminalIDs: []
        )

        XCTAssertEqual(
            plan,
            AppDelegate.PersistedPresentationPlan(
                mode: .integrated,
                focusedTerminalID: nil,
                splitTerminalIDs: []
            )
        )
    }

    func testPersistedPresentationPlanCollapsesSplitWhenOnlyOnePersistentTerminalRemains() {
        let persistedID = UUID()
        let transientID = UUID()

        let plan = AppDelegate.persistedPresentationPlan(
            currentPresentation: .split([persistedID, transientID]),
            persistedTerminalIDs: [persistedID]
        )

        XCTAssertEqual(
            plan,
            AppDelegate.PersistedPresentationPlan(
                mode: .focused,
                focusedTerminalID: persistedID,
                splitTerminalIDs: []
            )
        )
    }

    func testPtermCommandLineHelpTextMentionsSupportedOptions() {
        let help = PtermCommandLine.helpText()

        XCTAssertTrue(help.contains("--help"))
        XCTAssertTrue(help.contains("--version"))
        XCTAssertTrue(help.contains("--user-data-dir"))
        XCTAssertTrue(help.contains("--restore-session"))
        XCTAssertTrue(help.contains("--cli"))
        XCTAssertTrue(help.contains("--command"))
        XCTAssertTrue(help.contains("attempt"))
        XCTAssertTrue(help.contains("force"))
        XCTAssertTrue(help.contains("never"))
    }

    func testPtermCommandLineVersionTextUsesBundleMetadata() {
        final class DummyBundleToken {}
        let bundle = Bundle(for: DummyBundleToken.self)
        let version = PtermCommandLine.versionText(bundle: bundle)

        XCTAssertFalse(version.isEmpty)
    }

    func testCLIModePropagatesPipeEOFToForegroundProgram() throws {
        let process = Process()
        process.executableURL = try requiredReleaseAppExecutableURL()
        process.arguments = ["--cli", "--", "/bin/cat"]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let exitExpectation = expectation(description: "cli-cat-exit")
        process.terminationHandler = { _ in
            exitExpectation.fulfill()
        }

        try process.run()
        inputPipe.fileHandleForWriting.write(Data("abc\n".utf8))
        try inputPipe.fileHandleForWriting.close()

        wait(for: [exitExpectation], timeout: 5.0)

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: outputData, as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, "cli output=\(output)")
        XCTAssertTrue(output.contains("abc"), "cli output=\(output)")
    }

    func testCLIModeDoesNotKillForegroundProcessAfterShutdownGracePeriod() throws {
        let process = Process()
        process.executableURL = try requiredReleaseAppExecutableURL()
        process.arguments = ["--cli", "--", "/bin/sh", "-lc", "sleep 1; printf done"]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let exitExpectation = expectation(description: "cli-sleep-exit")
        process.terminationHandler = { _ in
            exitExpectation.fulfill()
        }

        try process.run()
        try inputPipe.fileHandleForWriting.close()

        wait(for: [exitExpectation], timeout: 5.0)

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: outputData, as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, "cli output=\(output)")
        XCTAssertTrue(output.contains("done"), "cli output=\(output)")
    }

    func testCLITerminalOutputFilterSuppressesSynchronizedOutputPayloadUntilResume() {
        let filter = CLITerminalOutputFilter()
        let firstChunk = Data("before\r\n\u{1B}[?2026hhidden payload".utf8)
        let secondChunk = Data("\u{1B}[?2026lafter\r\n".utf8)

        let firstOutput = firstChunk.withUnsafeBytes { rawBuffer -> Data in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return filter.filter(UnsafeBufferPointer(start: bytes.baseAddress, count: bytes.count))
        }
        let secondOutput = secondChunk.withUnsafeBytes { rawBuffer -> Data in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return filter.filter(UnsafeBufferPointer(start: bytes.baseAddress, count: bytes.count))
        }

        let output = String(decoding: firstOutput + secondOutput, as: UTF8.self)
        XCTAssertTrue(output.contains("before"), "cli output=\(output)")
        XCTAssertTrue(output.contains("after"), "cli output=\(output)")
        XCTAssertFalse(output.contains("hidden payload"), "cli output=\(output)")
        XCTAssertFalse(output.contains("\u{1B}[?2026h"), "cli output=\(output)")
        XCTAssertFalse(output.contains("\u{1B}[?2026l"), "cli output=\(output)")
    }

    func testCLITerminalOutputFilterResumesWhenPendingUpdateDisableSequenceSpansChunks() {
        let filter = CLITerminalOutputFilter()
        let firstChunk = Data("\u{1B}[?2026hhidden\u{1B}[?202".utf8)
        let secondChunk = Data("6lafter".utf8)

        let firstOutput = firstChunk.withUnsafeBytes { rawBuffer -> Data in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return filter.filter(UnsafeBufferPointer(start: bytes.baseAddress, count: bytes.count))
        }
        let secondOutput = secondChunk.withUnsafeBytes { rawBuffer -> Data in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return filter.filter(UnsafeBufferPointer(start: bytes.baseAddress, count: bytes.count))
        }

        let output = String(decoding: firstOutput + secondOutput, as: UTF8.self)
        XCTAssertEqual(output, "after")
    }

    func testPtermDirectoriesOverrideRebindsAllDerivedLocations() throws {
        let originalBase = PtermDirectories.base
        let originalConfig = PtermDirectories.config
        let originalSessions = PtermDirectories.sessions

        try withTemporaryDirectory { directory in
            let profileRoot = directory.appendingPathComponent(".pterm_test_profile", isDirectory: true)
            PtermDirectories.withBaseDirectory(profileRoot) {
                XCTAssertEqual(PtermDirectories.base, profileRoot.standardizedFileURL)
                XCTAssertEqual(PtermDirectories.config, profileRoot.appendingPathComponent("config.json"))
                XCTAssertEqual(PtermDirectories.files, profileRoot.appendingPathComponent("files"))
                XCTAssertEqual(PtermDirectories.sessions, profileRoot.appendingPathComponent("sessions"))
                XCTAssertEqual(
                    PtermDirectories.sessionScrollback,
                    profileRoot.appendingPathComponent("sessions").appendingPathComponent("scrollback")
                )
                XCTAssertEqual(PtermDirectories.audit, profileRoot.appendingPathComponent("audit"))
                XCTAssertEqual(PtermDirectories.workspaces, profileRoot.appendingPathComponent("workspaces"))
                XCTAssertTrue(PtermDirectories.isUsingOverriddenBaseDirectory)
            }
        }

        XCTAssertEqual(PtermDirectories.base, originalBase)
        XCTAssertEqual(PtermDirectories.config, originalConfig)
        XCTAssertEqual(PtermDirectories.sessions, originalSessions)
        XCTAssertFalse(PtermDirectories.isUsingOverriddenBaseDirectory)
    }

    func testTestProcessDefaultsPtermDirectoriesToTemporaryProfileRoot() {
        let defaultProfileRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pterm", isDirectory: true)
            .standardizedFileURL
        XCTAssertFalse(PtermDirectories.isUsingOverriddenBaseDirectory)
        XCTAssertNotEqual(PtermDirectories.base.standardizedFileURL, defaultProfileRoot)
        XCTAssertEqual(PtermDirectories.config, PtermDirectories.base.appendingPathComponent("config.json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: PtermDirectories.config.path))
    }

    func testWithTemporaryPtermConfigOverridesProfileRootForEntirePtermTree() throws {
        try withTemporaryPtermConfig { configURL in
            XCTAssertEqual(configURL, PtermDirectories.config)
            XCTAssertTrue(PtermDirectories.base.lastPathComponent.hasPrefix(".pterm_"))
            XCTAssertTrue(PtermDirectories.base.path.hasPrefix(NSTemporaryDirectory()))
            PtermDirectories.ensureDirectories()
            XCTAssertTrue(FileManager.default.fileExists(atPath: PtermDirectories.files.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: PtermDirectories.sessions.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: PtermDirectories.workspaces.path))
        }

        XCTAssertFalse(PtermDirectories.isUsingOverriddenBaseDirectory)
    }

    func testWithTemporaryPtermConfigCreatesFreshConfigFileInsideTemporaryProfileRoot() throws {
        try withTemporaryPtermConfig { configURL in
            XCTAssertTrue(FileManager.default.fileExists(atPath: configURL.path))
            XCTAssertTrue(configURL.path.hasPrefix(PtermDirectories.base.path))
            XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), "{}")
            XCTAssertEqual(try posixPermissions(of: configURL), 0o600)
        }
    }

    func testTerminalControllerResizeSchedulesDisplayUpdateWithoutWaitingForOutput() {
        let controller = TerminalController(
            rows: 4,
            cols: 12,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 256,
            scrollbackMaxCapacity: 256,
            fontName: "Menlo",
            fontSize: 13
        )

        let initialVersion = controller.currentRenderContentVersion
        let displayExpectation = expectation(description: "display request")
        controller.onNeedsDisplay = {
            displayExpectation.fulfill()
        }

        controller.resize(rows: 4, cols: 24)

        wait(for: [displayExpectation], timeout: 1.0)
        XCTAssertGreaterThan(controller.currentRenderContentVersion, initialVersion)
        XCTAssertEqual(controller.withModel { $0.cols }, 24)
    }

    func testInitialLaunchDispositionRestoresSessionWithoutForcingIntegratedView() {
        let focusedID = UUID()
        let session = PersistedSessionState(
            windowFrame: PersistedWindowFrame(frame: .init(x: 10, y: 20, width: 800, height: 600)),
            focusedTerminalID: focusedID,
            presentedMode: .focused,
            splitTerminalIDs: [],
            workspaceNames: ["Work"],
            terminals: [
                PersistedTerminalState(
                    id: focusedID,
                    workspaceName: "Work",
                    titleOverride: nil,
                    currentDirectory: NSHomeDirectory(),
                    settings: nil
                )
            ]
        )

        let disposition = AppDelegate.initialLaunchDisposition(
            restoredSession: session,
            bootstrappedConfiguredWorkspaces: true
        )

        XCTAssertEqual(disposition, .restoreSession(session))
    }

    func testInitialLaunchDispositionShowsIntegratedForConfiguredWorkspacesWithoutSession() {
        let disposition = AppDelegate.initialLaunchDisposition(
            restoredSession: nil,
            bootstrappedConfiguredWorkspaces: true
        )

        XCTAssertEqual(disposition, .showIntegrated)
    }

    func testInitialLaunchDispositionCreatesSingleTerminalWhenNoSessionOrConfiguredWorkspacesExist() {
        let disposition = AppDelegate.initialLaunchDisposition(
            restoredSession: nil,
            bootstrappedConfiguredWorkspaces: false
        )

        XCTAssertEqual(disposition, .createInitialTerminalAndShowIntegrated)
    }

    func testInitialWorkspaceNameStartsWithWorkspaceWhenEmpty() {
        XCTAssertEqual(AppDelegate.initialWorkspaceName(existingNames: []), "Workspace")
    }

    func testInitialWorkspaceNamePicksNextAvailableWorkspaceSuffix() {
        XCTAssertEqual(
            AppDelegate.initialWorkspaceName(existingNames: ["Workspace", "Workspace 2", "Alpha"]),
            "Workspace 3"
        )
    }

    func testGroupedControllersForSplitOrdersControllersDeterministicallyByWorkspaceThenTitle() {
        let first = TerminalController(
            rows: 4, cols: 12, termEnv: "xterm-256color", textEncoding: .utf8,
            scrollbackInitialCapacity: 1024, scrollbackMaxCapacity: 1024,
            fontName: "Menlo", fontSize: 13, initialDirectory: "/tmp/a1", customTitle: "z-last", workspaceName: "B"
        )
        let second = TerminalController(
            rows: 4, cols: 12, termEnv: "xterm-256color", textEncoding: .utf8,
            scrollbackInitialCapacity: 1024, scrollbackMaxCapacity: 1024,
            fontName: "Menlo", fontSize: 13, initialDirectory: "/tmp/b1", customTitle: "b-middle", workspaceName: "A"
        )
        let third = TerminalController(
            rows: 4, cols: 12, termEnv: "xterm-256color", textEncoding: .utf8,
            scrollbackInitialCapacity: 1024, scrollbackMaxCapacity: 1024,
            fontName: "Menlo", fontSize: 13, initialDirectory: "/tmp/a2", customTitle: "a-first", workspaceName: "A"
        )
        let fourth = TerminalController(
            rows: 4, cols: 12, termEnv: "xterm-256color", textEncoding: .utf8,
            scrollbackInitialCapacity: 1024, scrollbackMaxCapacity: 1024,
            fontName: "Menlo", fontSize: 13, initialDirectory: "/tmp/c1", customTitle: "a-first", workspaceName: "C"
        )
        let fifth = TerminalController(
            rows: 4, cols: 12, termEnv: "xterm-256color", textEncoding: .utf8,
            scrollbackInitialCapacity: 1024, scrollbackMaxCapacity: 1024,
            fontName: "Menlo", fontSize: 13, initialDirectory: "/tmp/b2", customTitle: "a-first", workspaceName: "B"
        )

        let grouped = AppDelegate.groupedControllersForSplit(
            [first, second, third, fourth, fifth],
            displayOrder: [first, second, third, fourth, fifth]
        )

        XCTAssertEqual(grouped.map(\.id), [second, third, first, fifth, fourth].map(\.id))
    }

    func testMonitoredMetricsPIDsIncludesOnlyAppPIDOutsideIntegratedVisibleActiveState() {
        let controller = TerminalController(
            rows: 24,
            cols: 80,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 1024,
            scrollbackMaxCapacity: 1024,
            fontName: "Menlo",
            fontSize: 13,
            initialDirectory: "/tmp",
            currentDirectoryProvider: { _ in nil }
        )

        let focused = AppDelegate.monitoredMetricsPIDs(
            appPID: 99,
            terminals: [controller],
            presentation: .focused(controller.id),
            appIsActive: true,
            windowIsVisible: true
        )
        XCTAssertEqual(focused, [99])

        let inactive = AppDelegate.monitoredMetricsPIDs(
            appPID: 99,
            terminals: [controller],
            presentation: .integrated,
            appIsActive: false,
            windowIsVisible: true
        )
        XCTAssertEqual(inactive, [99])
    }

    func testShouldRunMetricsMonitorRequiresVisibleWindowOnly() {
        XCTAssertTrue(AppDelegate.shouldRunMetricsMonitor(appIsActive: true, windowIsVisible: true))
        XCTAssertTrue(AppDelegate.shouldRunMetricsMonitor(appIsActive: false, windowIsVisible: true))
        XCTAssertFalse(AppDelegate.shouldRunMetricsMonitor(appIsActive: true, windowIsVisible: false))
        XCTAssertFalse(AppDelegate.shouldRunMetricsMonitor(appIsActive: false, windowIsVisible: false))
    }

    func testMetricsMonitorIntervalUsesSlowerSamplingOutsideIntegratedPresentation() {
        XCTAssertEqual(
            AppDelegate.metricsMonitorInterval(
                presentation: .integrated,
                appIsActive: true,
                windowIsVisible: true
            ),
            3.0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            AppDelegate.metricsMonitorInterval(
                presentation: .focused(UUID()),
                appIsActive: true,
                windowIsVisible: true
            ),
            10.0,
            accuracy: 0.001
        )
    }

    func testShouldTrackIntegratedOverviewActivityRequiresIntegratedVisibleActivePresentation() {
        XCTAssertTrue(
            AppDelegate.shouldTrackIntegratedOverviewActivity(
                presentation: .integrated,
                appIsActive: true,
                windowIsVisible: true
            )
        )
        XCTAssertFalse(
            AppDelegate.shouldTrackIntegratedOverviewActivity(
                presentation: .focused(UUID()),
                appIsActive: true,
                windowIsVisible: true
            )
        )
        XCTAssertTrue(
            AppDelegate.shouldTrackIntegratedOverviewActivity(
                presentation: .integrated,
                appIsActive: false,
                windowIsVisible: true
            )
        )
        XCTAssertFalse(
            AppDelegate.shouldTrackIntegratedOverviewActivity(
                presentation: .integrated,
                appIsActive: true,
                windowIsVisible: false
            )
        )
    }

    func testVisibleOutputIndicatorPromotionDependsOnIdleHistoryAndResizeSuppressionOnly() {
        XCTAssertTrue(
            AppDelegate.shouldPromoteOutputActivityToVisibleIndicator(
                terminalHasEverBeenIdle: true,
                secondsSinceLastResize: 1.01
            )
        )
        XCTAssertFalse(
            AppDelegate.shouldPromoteOutputActivityToVisibleIndicator(
                terminalHasEverBeenIdle: false,
                secondsSinceLastResize: 10.0
            )
        )
        XCTAssertFalse(
            AppDelegate.shouldPromoteOutputActivityToVisibleIndicator(
                terminalHasEverBeenIdle: true,
                secondsSinceLastResize: 0.25
            )
        )
    }

    func testGlassSubviewReinsertPolicySkipsNoOpReorderWhenAlreadyBelowHostedContent() {
        let parent = NSView(frame: .init(x: 0, y: 0, width: 100, height: 100))
        let glass = NSView(frame: parent.bounds)
        let hosted = NSView(frame: parent.bounds)
        parent.addSubview(glass)
        parent.addSubview(hosted)

        XCTAssertFalse(AppDelegate.shouldReinsertSubview(glass, below: hosted, in: parent))
    }

    func testGlassSubviewReinsertPolicyRequestsReorderWhenGlassIsAboveHostedContent() {
        let parent = NSView(frame: .init(x: 0, y: 0, width: 100, height: 100))
        let hosted = NSView(frame: parent.bounds)
        let glass = NSView(frame: parent.bounds)
        parent.addSubview(hosted)
        parent.addSubview(glass)

        XCTAssertTrue(AppDelegate.shouldReinsertSubview(glass, below: hosted, in: parent))
    }

    func testGlassSubviewReinsertPolicyRequestsAttachWhenGlassHasDifferentParent() {
        let parent = NSView(frame: .init(x: 0, y: 0, width: 100, height: 100))
        let otherParent = NSView(frame: parent.bounds)
        let glass = NSView(frame: parent.bounds)
        let hosted = NSView(frame: parent.bounds)
        otherParent.addSubview(glass)
        parent.addSubview(hosted)

        XCTAssertTrue(AppDelegate.shouldReinsertSubview(glass, below: hosted, in: parent))
    }

    func testRefreshCurrentDirectoriesRefreshesEachUniqueControllerOnce() {
        var refreshCalls: [UUID] = []
        let first = TerminalController(
            rows: 24,
            cols: 80,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 1024,
            scrollbackMaxCapacity: 1024,
            fontName: "Menlo",
            fontSize: 13,
            initialDirectory: "/tmp/one",
            currentDirectoryProvider: { pid in
                _ = pid
                return "/tmp/refreshed-\(pid)"
            }
        )
        let second = TerminalController(
            rows: 24,
            cols: 80,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 1024,
            scrollbackMaxCapacity: 1024,
            fontName: "Menlo",
            fontSize: 13,
            initialDirectory: "/tmp/two",
            currentDirectoryProvider: { pid in
                _ = pid
                return "/tmp/refreshed-\(pid)"
            }
        )

        let refreshed = AppDelegate.refreshCurrentDirectories(for: [first, first, second]) { controller in
            refreshCalls.append(controller.id)
            return true
        }

        XCTAssertEqual(refreshed, 2)
        XCTAssertEqual(refreshCalls, [first.id, second.id])
    }

    func testTerminalListReconciliationKeepsIntegratedPresentationWhenLastTerminalRemoved() {
        let result = AppDelegate.reconcilePresentationAfterTerminalListChange(
            currentPresentation: .integrated,
            remainingTerminalIDs: []
        )

        XCTAssertEqual(result, .integrated)
    }

    func testTerminalListReconciliationFallsBackToIntegratedWhenFocusedTerminalRemoved() {
        let focusedID = UUID()
        let result = AppDelegate.reconcilePresentationAfterTerminalListChange(
            currentPresentation: .focused(focusedID),
            remainingTerminalIDs: []
        )

        XCTAssertEqual(result, .integrated)
    }

    func testTerminalListReconciliationCollapsesSplitToFocusedThenIntegrated() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        let focusedResult = AppDelegate.reconcilePresentationAfterTerminalListChange(
            currentPresentation: .split([first, second, third]),
            remainingTerminalIDs: [second]
        )
        XCTAssertEqual(focusedResult, .focused(second))

        let integratedResult = AppDelegate.reconcilePresentationAfterTerminalListChange(
            currentPresentation: .split([first, second, third]),
            remainingTerminalIDs: []
        )
        XCTAssertEqual(integratedResult, .integrated)
    }

    func testTerminalListReconciliationPreservesRemainingSplitOrder() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        let result = AppDelegate.reconcilePresentationAfterTerminalListChange(
            currentPresentation: .split([first, second, third]),
            remainingTerminalIDs: [third, first]
        )

        XCTAssertEqual(result, .split([first, third]))
    }

    func testRGBColorParsesHexAndFormatsBackToUppercaseHex() {
        let color = RGBColor(hexString: "#12abEF")

        XCTAssertEqual(color, RGBColor(red: 0x12, green: 0xAB, blue: 0xEF))
        XCTAssertEqual(color?.hexString, "#12ABEF")
    }

    func testTerminalAppearanceConfigurationClampsBackgroundOpacity() {
        let low = TerminalAppearanceConfiguration(
            foreground: .defaultTerminalForeground,
            background: .defaultTerminalBackground,
            backgroundOpacity: -1.0
        )
        let high = TerminalAppearanceConfiguration(
            foreground: .defaultTerminalForeground,
            background: .defaultTerminalBackground,
            backgroundOpacity: 3.0
        )

        XCTAssertEqual(low.normalizedBackgroundOpacity, 0.0)
        XCTAssertEqual(high.normalizedBackgroundOpacity, 1.0)
    }

    func testDefaultTerminalForegroundIsPureWhite() {
        XCTAssertEqual(RGBColor.defaultTerminalForeground.hexString, "#FFFFFF")
        XCTAssertEqual(TerminalAppearanceConfiguration.default.foreground.hexString, "#FFFFFF")
    }

    func testDefaultTerminalBackgroundIsBlackAndOpacityIsZero() {
        XCTAssertEqual(RGBColor.defaultTerminalBackground.hexString, "#000000")
        XCTAssertEqual(TerminalAppearanceConfiguration.default.background.hexString, "#000000")
        XCTAssertEqual(TerminalAppearanceConfiguration.default.backgroundOpacity, 0.0)
        XCTAssertEqual(TerminalAppearanceConfiguration.default.normalizedBackgroundOpacity, 0.0)
    }

    func testPastedImageRegistryRegistersOnlyImageFilesAndResolvesOneBasedIndices() throws {
        try withTemporaryDirectory { directory in
            let image = directory.appendingPathComponent("preview.png")
            let text = directory.appendingPathComponent("note.txt")
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
            try Data("hello".utf8).write(to: text)

            let registry = PastedImageRegistry()
            registry.register(createdFiles: [text, image])

            XCTAssertEqual(registry.registeredImageCount(), 1)
            XCTAssertNil(registry.url(forPlaceholderIndex: 0))
            XCTAssertEqual(registry.url(forPlaceholderIndex: 1), image)
            XCTAssertNil(registry.url(forPlaceholderIndex: 2))
        }
    }

    func testPastedImageRegistrySkipsMissingFilesDuringLookup() throws {
        try withTemporaryDirectory { directory in
            let image = directory.appendingPathComponent("preview.png")
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)

            let registry = PastedImageRegistry()
            registry.register(createdFiles: [image])
            try FileManager.default.removeItem(at: image)

            XCTAssertNil(registry.url(forPlaceholderIndex: 1))
        }
    }

    func testPastedImageRegistrySupportsExplicitPlaceholderIndices() throws {
        try withTemporaryDirectory { directory in
            let image = directory.appendingPathComponent("preview.png")
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)

            let registry = PastedImageRegistry()
            registry.register(url: image, forPlaceholderIndex: 7)

            XCTAssertNil(registry.url(forPlaceholderIndex: 1))
            XCTAssertEqual(registry.url(forPlaceholderIndex: 7), image)
        }
    }

    func testPastedImageRegistryCanPersistRawRGBAKittyPayloadAsPNG() throws {
        try withTemporaryPtermConfig { _ in
            let registry = PastedImageRegistry()
            let rawRGBA = Data([255, 0, 0, 255, 0, 255, 0, 255])

            let url = try registry.register(
                imageData: rawRGBA,
                format: .rawRGBA,
                placeholderIndex: 2,
                pixelWidth: 2,
                pixelHeight: 1
            )

            XCTAssertEqual(url.pathExtension, "png")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertEqual(registry.url(forPlaceholderIndex: 2), url)
            XCTAssertNotNil(NSImage(contentsOf: url))
        }
    }

    func testPastedImageRegistryTransientRawKittyImageUsesBlobStorageAndStaysRenderable() throws {
        try withTemporaryPtermConfig { _ in
            let registry = PastedImageRegistry()
            let rawRGBA = Data([
                255, 0, 0, 255,
                0, 255, 0, 255,
                0, 0, 255, 255,
                255, 255, 0, 255
            ])

            try registry.registerTransient(
                imageData: rawRGBA,
                format: .rawRGBA,
                placeholderIndex: 9,
                pixelWidth: 2,
                pixelHeight: 2,
                columns: 2,
                rows: 2
            )

            let registered = try XCTUnwrap(registry.registeredImage(forPlaceholderIndex: 9))
            XCTAssertNil(registered.url)
            XCTAssertNotNil(registered.blobURL)
            XCTAssertNil(registered.rawPixelData)
            XCTAssertEqual(registered.rawPixelFormat, .rawRGBA)
            XCTAssertNotNil(TerminalInlineImageSupport.cgImage(for: registered))
            XCTAssertEqual(registered.columns, 2)
            XCTAssertEqual(registered.rows, 2)
        }
    }

    func testPastedImageRegistryRawBlobCanMaterializePreviewURLLazily() throws {
        try withTemporaryPtermConfig { _ in
            let registry = PastedImageRegistry()
            let rawRGBA = Data([
                255, 0, 0, 255,
                0, 255, 0, 255,
                0, 0, 255, 255,
                255, 255, 0, 255
            ])

            try registry.registerTransient(
                imageData: rawRGBA,
                format: .rawRGBA,
                placeholderIndex: 11,
                pixelWidth: 2,
                pixelHeight: 2
            )

            let url = try XCTUnwrap(registry.url(forPlaceholderIndex: 11))
            XCTAssertEqual(url.pathExtension, "png")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertNotNil(NSImage(contentsOf: url))
        }
    }

    func testPastedImageRegistryStoresCompressedTransientKittyImageOnDiskInsteadOfHeap() throws {
        try withTemporaryPtermConfig { _ in
            let registry = PastedImageRegistry()
            let maybeBitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 4,
                pixelsHigh: 4,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
            let bitmap = try XCTUnwrap(maybeBitmap)
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = context
            NSColor.systemRed.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 4, height: 4)).fill()
            let pngData = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

            try registry.registerTransient(
                imageData: pngData,
                format: .png,
                placeholderIndex: 10,
                pixelWidth: 4,
                pixelHeight: 4,
                columns: 2,
                rows: 2
            )

            let registered = try XCTUnwrap(registry.registeredImage(forPlaceholderIndex: 10))
            let url = try XCTUnwrap(registered.url)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertNil(registered.rawPixelData)
            XCTAssertNil(registered.rawPixelFormat)
            XCTAssertEqual(registered.columns, 2)
            XCTAssertEqual(registered.rows, 2)
            XCTAssertNotNil(NSImage(contentsOf: url))
        }
    }

    func testPastedImageRegistryScopesTransientKittyImagesByOwnerAndPurgesInvalidatedOwner() throws {
        try withTemporaryPtermConfig { _ in
            let registry = PastedImageRegistry()
            let ownerA = UUID()
            let ownerB = UUID()
            let rawRGBAA = Data([255, 0, 0, 255])
            let rawRGBAB = Data([0, 255, 0, 255])

            try registry.registerTransient(
                imageData: rawRGBAA,
                format: .rawRGBA,
                placeholderIndex: 1,
                ownerID: ownerA,
                pixelWidth: 1,
                pixelHeight: 1
            )
            try registry.registerTransient(
                imageData: rawRGBAB,
                format: .rawRGBA,
                placeholderIndex: 1,
                ownerID: ownerB,
                pixelWidth: 1,
                pixelHeight: 1
            )

            XCTAssertNotNil(registry.registeredImage(ownerID: ownerA, forPlaceholderIndex: 1))
            XCTAssertNotNil(registry.registeredImage(ownerID: ownerB, forPlaceholderIndex: 1))

            registry.removeImages(ownerID: ownerA)

            XCTAssertNil(registry.registeredImage(ownerID: ownerA, forPlaceholderIndex: 1))
            XCTAssertNotNil(registry.registeredImage(ownerID: ownerB, forPlaceholderIndex: 1))

            try registry.registerTransient(
                imageData: rawRGBAA,
                format: .rawRGBA,
                placeholderIndex: 1,
                ownerID: ownerA,
                pixelWidth: 1,
                pixelHeight: 1
            )
            XCTAssertNil(registry.registeredImage(ownerID: ownerA, forPlaceholderIndex: 1))
        }
    }

    func testPastedImageRegistryPurgesOnlyOwnerImagesThatAreNoLongerLive() throws {
        try withTemporaryPtermConfig { _ in
            let registry = PastedImageRegistry()
            let owner = UUID()
            let pngBytes = Data([
                0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
                0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52
            ])

            try registry.registerTransient(
                imageData: pngBytes,
                format: .png,
                placeholderIndex: 1,
                ownerID: owner
            )
            try registry.registerTransient(
                imageData: pngBytes,
                format: .png,
                placeholderIndex: 2,
                ownerID: owner
            )

            _ = registry.url(ownerID: owner, forPlaceholderIndex: 1)
            _ = registry.url(ownerID: owner, forPlaceholderIndex: 2)

            let removed = registry.purgeUnreferencedImages(ownerID: owner, retainingPlaceholderIndices: [2])

            XCTAssertEqual(removed.count, 1)
            XCTAssertNil(registry.registeredImage(ownerID: owner, forPlaceholderIndex: 1))
            XCTAssertNotNil(registry.registeredImage(ownerID: owner, forPlaceholderIndex: 2))
        }
    }

    func testPastedImageRegistryPreservesKittyCellPlacementMetadata() throws {
        try withTemporaryPtermConfig { _ in
            let registry = PastedImageRegistry()
            let pngData = Data([0x89, 0x50, 0x4E, 0x47])

            let url = try registry.register(
                imageData: pngData,
                format: .png,
                placeholderIndex: 5,
                columns: 4,
                rows: 3
            )

            let registered = try XCTUnwrap(registry.registeredImage(forPlaceholderIndex: 5))
            XCTAssertEqual(registered.url, url)
            XCTAssertEqual(registered.columns, 4)
            XCTAssertEqual(registered.rows, 3)
        }
    }

    func testTerminalColorDefaultDetectionOnlyMatchesDefaultCase() {
        XCTAssertTrue(TerminalColor.default.isDefaultColor)
        XCTAssertFalse(TerminalColor.indexed(0).isDefaultColor)
        XCTAssertFalse(TerminalColor.rgb(0, 0, 0).isDefaultColor)
    }

    func testPersistedWindowFrameRoundTripsNSRect() {
        let rect = NSRect(x: 10, y: 20, width: 640, height: 480)
        let persisted = PersistedWindowFrame(frame: rect)
        XCTAssertEqual(persisted.rect, rect)
    }

    func testPersistedSessionDecodingProvidesDefaultsForLegacyPayload() throws {
        let json = """
        {
          "windowFrame": { "x": 1, "y": 2, "width": 3, "height": 4 },
          "terminals": []
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(PersistedSessionState.self, from: json)
        XCTAssertEqual(decoded.presentedMode, .integrated)
        XCTAssertEqual(decoded.splitTerminalIDs, [])
        XCTAssertEqual(decoded.workspaceNames, [])
        XCTAssertNil(decoded.focusedTerminalID)
    }

    func testAtomicFileWriterCreatesAndReplacesFilesWithPermissions() throws {
        try withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("config.json")
            try AtomicFileWriter.write(Data("first".utf8), to: destination, permissions: 0o600)
            try AtomicFileWriter.write(Data("second".utf8), to: destination, permissions: 0o600)

            XCTAssertEqual(try String(contentsOf: destination), "second")
            XCTAssertEqual(try posixPermissions(of: destination) & 0o777, 0o600)
        }
    }

    func testAtomicFileWriterCreatesParentDirectoriesWithSecurePermissions() throws {
        try withTemporaryDirectory { directory in
            let nestedDir = directory.appendingPathComponent("a/b/c", isDirectory: true)
            let destination = nestedDir.appendingPathComponent("state.json")

            try AtomicFileWriter.write(Data("{}".utf8), to: destination, permissions: 0o600)

            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertEqual(try posixPermissions(of: nestedDir) & 0o777, 0o700)
        }
    }

    func testFileNameSanitizerReplacesReservedCharactersAndFallsBackForBlankValues() {
        XCTAssertEqual(FileNameSanitizer.sanitize(" a/b:c\n", fallback: "fallback"), "a_b_c")
        XCTAssertEqual(FileNameSanitizer.sanitize("   ", fallback: "fallback"), "fallback")
    }

    func testCoalescedCallbackSignalsImmediatelyOutsideBatch() {
        var callbackCount = 0
        let callback = CoalescedCallback {
            callbackCount += 1
        }

        callback.signal()
        callback.signal()

        XCTAssertEqual(callbackCount, 2)
    }

    func testCoalescedCallbackCoalescesSignalsWithinSingleBatch() {
        var callbackCount = 0
        let callback = CoalescedCallback {
            callbackCount += 1
        }

        callback.performBatch {
            callback.signal()
            callback.signal()
            callback.signal()
        }

        XCTAssertEqual(callbackCount, 1)
    }

    func testCoalescedCallbackNestedBatchesStillEmitSingleCallback() {
        var callbackCount = 0
        let callback = CoalescedCallback {
            callbackCount += 1
        }

        callback.performBatch {
            callback.signal()
            callback.performBatch {
                callback.signal()
                callback.signal()
            }
            callback.signal()
        }

        XCTAssertEqual(callbackCount, 1)
    }

    @MainActor
    func testDebouncedActionCoordinatorCoalescesRapidSchedules() {
        let fired = expectation(description: "debounced action fired once")
        fired.expectedFulfillmentCount = 1
        fired.assertForOverFulfill = true

        let coordinator = DebouncedActionCoordinator(
            debounceInterval: 0.05,
            scheduleQueue: .main
        ) {
            fired.fulfill()
        }

        coordinator.schedule()
        coordinator.schedule()
        coordinator.schedule()

        wait(for: [fired], timeout: 1.0)
    }

    @MainActor
    func testDebouncedActionCoordinatorFlushRunsPendingActionImmediately() {
        var fireCount = 0
        let coordinator = DebouncedActionCoordinator(
            debounceInterval: 1.0,
            scheduleQueue: .main
        ) {
            fireCount += 1
        }

        coordinator.schedule()
        coordinator.flush()

        XCTAssertEqual(fireCount, 1)
    }

    @MainActor
    func testDebouncedActionCoordinatorCancelPreventsPendingAction() {
        let coordinator = DebouncedActionCoordinator(
            debounceInterval: 0.05,
            scheduleQueue: .main
        ) {
            XCTFail("Canceled debounced action should not fire")
        }

        coordinator.schedule()
        coordinator.cancel()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }

    func testMemoryPressureCoordinatorInvokesHandlerWhenSimulated() {
        var invocationCount = 0
        let coordinator = MemoryPressureCoordinator(installSystemSource: false) {
            invocationCount += 1
        }

        coordinator.simulateMemoryPressureForTesting()
        coordinator.simulateMemoryPressureForTesting()

        XCTAssertEqual(invocationCount, 2)
    }

    func testSessionStoreReturnsNoneWhenNoSessionExistsAndCreatesCrashMarker() throws {
        try withTemporaryDirectory { directory in
            let store = SessionStore(directory: directory)
            XCTAssertEqual(try store.prepareRestoreDecision(), .none)
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("crash.marker").path))
        }
    }

    func testSessionStoreMarkCleanShutdownRemovesCrashMarker() throws {
        try withTemporaryDirectory { directory in
            let marker = directory.appendingPathComponent("crash.marker")
            try Data("x".utf8).write(to: marker)
            let store = SessionStore(directory: directory)
            try store.markCleanShutdown()
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    func testSessionStorePrepareRestoreDecisionThrowsForCorruptSession() throws {
        try withTemporaryDirectory { directory in
            let sessionURL = directory.appendingPathComponent("session.json")
            try Data("not-json".utf8).write(to: sessionURL)
            let store = SessionStore(directory: directory)
            XCTAssertThrowsError(try store.prepareRestoreDecision())
        }
    }

    func testSessionStoreTransitionsFromUncleanToCleanRestore() throws {
        try withTemporaryDirectory { directory in
            let store = SessionStore(directory: directory)
            let state = PersistedSessionState(
                windowFrame: PersistedWindowFrame(frame: NSRect(x: 1, y: 2, width: 3, height: 4)),
                focusedTerminalID: UUID(),
                presentedMode: .split,
                splitTerminalIDs: [UUID()],
                workspaceNames: ["Main"],
                terminals: []
            )

            try store.save(state)
            _ = try store.prepareRestoreDecision()
            XCTAssertEqual(try store.prepareRestoreDecision(), .requireUserConfirmation(state))
            try store.markCleanShutdown()
            XCTAssertEqual(try store.prepareRestoreDecision(), .restore(state))
        }
    }

    func testSessionStoreSaveUsesSecurePermissions() throws {
        try withTemporaryDirectory { directory in
            let store = SessionStore(directory: directory)
            try store.save(PersistedSessionState(
                windowFrame: PersistedWindowFrame(frame: .zero),
                focusedTerminalID: nil,
                presentedMode: .integrated,
                splitTerminalIDs: [],
                workspaceNames: [],
                terminals: []
            ))
            let sessionURL = directory.appendingPathComponent("session.json")
            XCTAssertEqual(try posixPermissions(of: sessionURL) & 0o777, 0o600)
        }
    }

    func testSessionStoreClearSessionIgnoresMissingDirectory() throws {
        try withTemporaryDirectory { directory in
            let target = directory.appendingPathComponent("missing")
            let store = SessionStore(directory: target)
            try store.clearSession()
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        }
    }

    func testSessionStoreClearSessionRemovesPersistedFiles() throws {
        try withTemporaryDirectory { directory in
            let store = SessionStore(directory: directory)
            try store.save(PersistedSessionState(
                windowFrame: PersistedWindowFrame(frame: .zero),
                focusedTerminalID: nil,
                presentedMode: .integrated,
                splitTerminalIDs: [],
                workspaceNames: [],
                terminals: []
            ))
            try store.clearSession()
            let remaining = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            XCTAssertTrue(remaining.isEmpty)
        }
    }

    func testAppNoteStoreLoadNoteReturnsNilWhenEncryptedNoteDoesNotExist() throws {
        try withTemporaryDirectory { directory in
            let store = AppNoteStore(rootDirectory: directory)
            XCTAssertNil(try store.loadNote())
        }
    }

    func testAppNoteStoreImportEncryptionKeyRejectsInvalidLengthBeforeKeychainMutation() {
        let store = AppNoteStore(rootDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))

        XCTAssertThrowsError(try store.importEncryptionKey(Data(repeating: 0xAA, count: 31))) { error in
            guard case AppNoteError.invalidKeyLength = error else {
                XCTFail("Expected invalidKeyLength, got \(error)")
                return
            }
        }
    }

    func testAppNoteStoreLoadNoteRejectsCorruptEncryptedPayload() throws {
        try withTemporaryDirectory { directory in
            try Data("not-an-encrypted-note".utf8).write(to: directory.appendingPathComponent("note.enc"))
            let store = AppNoteStore(rootDirectory: directory)

            XCTAssertThrowsError(try store.loadNote()) { error in
                guard case AppNoteError.invalidFormat = error else {
                    return XCTFail("Expected invalidFormat, got \(error)")
                }
            }
        }
    }

    func testAppNoteStoreLoadNoteRejectsDecryptedPayloadWithInvalidUTF8() throws {
        try withTemporaryDirectory { directory in
            let store = AppNoteStore(rootDirectory: directory)
            let originalKey = try store.exportEncryptionKey()
            defer { try? store.importEncryptionKey(originalKey) }

            let importedKey = Data(repeating: 0x44, count: 32)
            try store.importEncryptionKey(importedKey)
            let ciphertext = try encryptedNotePayloadForTest(plaintext: Data([0xFF]), key: importedKey)
            try ciphertext.write(to: directory.appendingPathComponent("note.enc"))

            XCTAssertThrowsError(try store.loadNote()) { error in
                guard case AppNoteError.invalidFormat = error else {
                    return XCTFail("Expected invalidFormat, got \(error)")
                }
            }
        }
    }

    func testAppNoteStoreImportEncryptionKeyRefreshesCachedKeyImmediately() throws {
        try withTemporaryDirectory { directory in
            let store = AppNoteStore(rootDirectory: directory)
            let originalKey = try store.exportEncryptionKey()
            defer { try? store.importEncryptionKey(originalKey) }

            let importedKey = Data(repeating: 0x55, count: 32)
            XCTAssertNotEqual(originalKey, importedKey)

            try store.importEncryptionKey(importedKey)

            XCTAssertEqual(try store.exportEncryptionKey(), importedKey)
        }
    }

    func testShellLaunchConfigurationNormalizesAndFallsBackToDefaults() {
        XCTAssertEqual(
            ShellLaunchConfiguration.normalizedLaunchOrder([
                " /bin/zsh ",
                "",
                "relative-shell",
                "/bin/zsh",
                "/bin/zsh",
                "/bin/bash"
            ]),
            ["/bin/zsh", "/bin/bash"]
        )
        XCTAssertEqual(
            ShellLaunchConfiguration.normalizedLaunchOrder(["relative-shell", " "]),
            ShellLaunchConfiguration.default.launchOrder
        )
    }

    func testPtermConfigStoreLoadsConfiguredShellLaunchOrder() throws {
        try withTemporaryPtermConfig { configURL in
            let json: [String: Any] = [
                "shells": [
                    "launch_order": ["/bin/bash", "/bin/sh", "/bin/bash", "relative-shell"]
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try AtomicFileWriter.write(data, to: configURL, permissions: 0o600)

            let loaded = PtermConfigStore.load(from: configURL)
            XCTAssertEqual(loaded.shellLaunch.launchOrder, ["/bin/bash", "/bin/sh"])
        }
    }

    func testPtermConfigStoreLoadsOutputConfirmedInputAnimationSetting() throws {
        try withTemporaryPtermConfig { configURL in
            let json: [String: Any] = [
                "text_interaction": [
                    "output_confirmed_input_animation": true
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try AtomicFileWriter.write(data, to: configURL, permissions: 0o600)

            let loaded = PtermConfigStore.load(from: configURL)
            XCTAssertTrue(loaded.textInteraction.outputConfirmedInputAnimation)
        }
    }

    func testPtermConfigStoreDefaultsTypewriterSoundToDisabled() {
        let loaded = PtermConfigStore.load(from: URL(fileURLWithPath: "/nonexistent/config.json"))

        XCTAssertFalse(loaded.textInteraction.typewriterSoundEnabled)
    }

    func testPtermConfigStoreLoadsTypewriterSoundSetting() throws {
        try withTemporaryPtermConfig { configURL in
            let json: [String: Any] = [
                "text_interaction": [
                    "typewriter_sound_enabled": false
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try AtomicFileWriter.write(data, to: configURL, permissions: 0o600)

            let loaded = PtermConfigStore.load(from: configURL)
            XCTAssertFalse(loaded.textInteraction.typewriterSoundEnabled)
        }
    }

    func testPtermConfigStoreDefaultsOutputFrameThrottlingToEnabled() {
        let loaded = PtermConfigStore.load(from: URL(fileURLWithPath: "/nonexistent/config.json"))

        XCTAssertEqual(loaded.textInteraction.outputFrameThrottlingMode, .continuous)
        XCTAssertFalse(loaded.textInteraction.showFPSInStatusBar)
    }

    func testPtermConfigStoreLoadsOutputFrameThrottlingSetting() throws {
        try withTemporaryPtermConfig { configURL in
            let json: [String: Any] = [
                "text_interaction": [
                    "output_frame_throttling_mode": "continuous",
                    "show_fps_in_status_bar": true
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try AtomicFileWriter.write(data, to: configURL, permissions: 0o600)

            let loaded = PtermConfigStore.load(from: configURL)
            XCTAssertEqual(loaded.textInteraction.outputFrameThrottlingMode, .continuous)
            XCTAssertTrue(loaded.textInteraction.showFPSInStatusBar)
        }
    }

    func testPtermConfigStoreDefaultsMCPServerToEnabledOnDefaultPort() {
        let loaded = PtermConfigStore.load(from: URL(fileURLWithPath: "/nonexistent/config.json"))

        XCTAssertEqual(loaded.mcpServer, .default)
    }

    func testPtermConfigStoreLoadsMCPServerSettings() throws {
        try withTemporaryPtermConfig { configURL in
            let json: [String: Any] = [
                "mcp_server": [
                    "enabled": false,
                    "port": 48001
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try AtomicFileWriter.write(data, to: configURL, permissions: 0o600)

            let loaded = PtermConfigStore.load(from: configURL)
            XCTAssertFalse(loaded.mcpServer.enabled)
            XCTAssertEqual(loaded.mcpServer.port, 48001)
        }
    }

    func testShortcutParserParsesConfiguredBindingsAndFallsBackOnInvalidValues() {
        let shortcuts = ShortcutParser.parseMap([
            "find_previous": "Cmd+Shift+G",
            "zoom_in": "Cmd++",
            "copy": "Shift+X"
        ])

        let findPrevious = shortcuts.binding(for: .findPrevious).primary
        XCTAssertEqual(findPrevious.modifiers, [.command, .shift])
        XCTAssertEqual(findPrevious.menuKeyEquivalent, "g")

        let zoomIn = shortcuts.binding(for: .zoomIn).primary
        XCTAssertEqual(zoomIn.modifiers, [.command, .shift])
        XCTAssertEqual(zoomIn.menuKeyEquivalent, "=")

        let copy = shortcuts.binding(for: .copy).primary
        XCTAssertEqual(copy.modifiers, [.command])
        XCTAssertEqual(copy.menuKeyEquivalent, "c")
    }

    func testShortcutParserSupportsNamedSpecialKeys() {
        let shortcuts = ShortcutParser.parseMap([
            "back_to_integrated": "Cmd+Esc",
            "focus_previous_terminal": "Cmd+Left",
            "focus_next_terminal": "Cmd+Right"
        ])

        XCTAssertEqual(shortcuts.binding(for: .backToIntegrated).primary.menuKeyEquivalent, "\u{1B}")
        XCTAssertEqual(shortcuts.binding(for: .focusPreviousTerminal).primary.menuKeyEquivalent,
                       String(UnicodeScalar(NSLeftArrowFunctionKey)!))
        XCTAssertEqual(shortcuts.binding(for: .focusNextTerminal).primary.menuKeyEquivalent,
                       String(UnicodeScalar(NSRightArrowFunctionKey)!))
    }

    func testShortcutConfigurationZoomInMatchesPrimaryAndAlternateBindings() {
        let binding = ShortcutConfiguration.default.binding(for: .zoomIn)
        XCTAssertEqual(binding.alternates.count, 1)

        let primaryEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "=",
            charactersIgnoringModifiers: "=",
            isARepeat: false,
            keyCode: 24
        )!
        let alternateEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "+",
            charactersIgnoringModifiers: "=",
            isARepeat: false,
            keyCode: 24
        )!

        XCTAssertTrue(binding.matches(primaryEvent))
        XCTAssertTrue(binding.matches(alternateEvent))
    }

    func testShortcutParserRejectsBindingsWithoutCommandModifier() {
        let parsed = ShortcutParser.parseMap([
            "copy": "Shift+C"
        ])
        XCTAssertEqual(parsed.binding(for: .copy).primary.menuKeyEquivalent, "c")
        XCTAssertEqual(parsed.binding(for: .copy).primary.modifiers, [.command])
    }

    func testShortcutActionsExposeSelectors() {
        for action in ShortcutAction.allCases {
            XCTAssertNotNil(action.appDelegateSelector)
        }
    }

    func testShortcutConfigurationDefaultsIncludeClearScreenAndScrollToTop() {
        let config = ShortcutConfiguration.default

        XCTAssertEqual(config.binding(for: .clearScreen).primary.menuKeyEquivalent, "k")
        XCTAssertEqual(config.binding(for: .clearScreen).primary.modifiers, [.command])
        XCTAssertEqual(config.binding(for: .scrollToTop).primary.menuKeyEquivalent, "l")
        XCTAssertEqual(config.binding(for: .scrollToTop).primary.modifiers, [.command])
    }

    func testKeyboardShortcutMenuKeyEquivalentMatchesSpecialKeyCodes() {
        let backtick = KeyboardShortcut(modifiers: [.command], trigger: .keyCode(50))
        let escape = KeyboardShortcut(modifiers: [.command], trigger: .keyCode(53))
        let left = KeyboardShortcut(modifiers: [.command], trigger: .keyCode(123))
        let right = KeyboardShortcut(modifiers: [.command], trigger: .keyCode(124))

        XCTAssertEqual(backtick.menuKeyEquivalent, "`")
        XCTAssertEqual(escape.menuKeyEquivalent, "\u{1B}")
        XCTAssertEqual(left.menuKeyEquivalent, String(UnicodeScalar(NSLeftArrowFunctionKey)!))
        XCTAssertEqual(right.menuKeyEquivalent, String(UnicodeScalar(NSRightArrowFunctionKey)!))
    }

    @MainActor
    func testKeyboardShortcutMatchesCharacterCaseInsensitively() {
        let shortcut = KeyboardShortcut(modifiers: [.command], trigger: .character("c"))
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .capsLock],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "C",
            charactersIgnoringModifiers: "C",
            isARepeat: false,
            keyCode: 8
        )

        XCTAssertEqual(shortcut.matches(event!), true)
    }

    func testTerminfoResolverRejectsInvalidConfiguredName() {
        let resolved = TerminfoResolver.resolveConfiguredTerm("../bad name")
        XCTAssertNotEqual(resolved, "../bad name")
        XCTAssertFalse(resolved.isEmpty)
    }

    func testSingleInstanceLockRejectsSecondOwnerUntilRelease() throws {
        try withTemporaryDirectory { directory in
            let lockURL = directory.appendingPathComponent("lock")
            let first = SingleInstanceLock(lockURL: lockURL)
            let second = SingleInstanceLock(lockURL: lockURL)

            XCTAssertTrue(try first.acquireOrActivateExisting())
            XCTAssertFalse(try second.acquireOrActivateExisting())

            first.release()

            XCTAssertTrue(try second.acquireOrActivateExisting())
            second.release()
        }
    }

    func testSingleInstanceLockCreatesLockFileWithSecurePermissions() throws {
        try withTemporaryDirectory { directory in
            let lockURL = directory.appendingPathComponent("lock")
            let lock = SingleInstanceLock(lockURL: lockURL)
            XCTAssertTrue(try lock.acquireOrActivateExisting())
            defer { lock.release() }
            XCTAssertEqual(try posixPermissions(of: lockURL) & 0o777, 0o600)
        }
    }

    func testSingleInstanceLockReleaseIsIdempotent() throws {
        try withTemporaryDirectory { directory in
            let lock = SingleInstanceLock(lockURL: directory.appendingPathComponent("lock"))
            XCTAssertTrue(try lock.acquireOrActivateExisting())
            lock.release()
            lock.release()
        }
    }

    func testReadWriteLockSerializesWritesAgainstConcurrentReads() {
        let lock = ReadWriteLock()
        let queue = DispatchQueue(label: "lock-test", attributes: .concurrent)
        let group = DispatchGroup()
        var values: [Int] = []

        for readValue in 0..<10 {
            group.enter()
            queue.async {
                lock.withReadLock {
                    _ = values.count
                }
                group.leave()
            }

            group.enter()
            queue.async {
                lock.withWriteLock {
                    values.append(readValue)
                }
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(values.sorted(), Array(0..<10))
    }

    func testClipboardFileStoreQuotesPathsAndDeletesExpiredFiles() throws {
        try withTemporaryDirectory { directory in
            let oldDate = Date(timeIntervalSince1970: 1000)
            let currentDate = oldDate.addingTimeInterval(25 * 60 * 60)
            let store = ClipboardFileStore(rootDirectory: directory, nowProvider: { currentDate })
            let file = directory.appendingPathComponent("old.bin")
            try Data("x".utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path)

            XCTAssertEqual(store.shellQuotedPath("/tmp/has ' quote"), "'/tmp/has '\\'' quote'")
            try store.cleanupExpiredFiles()
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }

    @MainActor
    func testClipboardFileStoreImportsBinaryPasteboardPayload() throws {
        try withTemporaryDirectory { directory in
            let store = ClipboardFileStore(rootDirectory: directory)
            let pasteboard = NSPasteboard.withUniqueName()
            pasteboard.clearContents()

            let item = NSPasteboardItem()
            item.setData(Data([0x01, 0x02, 0x03]), forType: .png)
            pasteboard.writeObjects([item])

            let result = try XCTUnwrap(store.importFromPasteboard(pasteboard))
            XCTAssertEqual(result.createdFiles.count, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.createdFiles[0].path))
            XCTAssertTrue(result.textToPaste.contains(result.createdFiles[0].lastPathComponent))
            XCTAssertEqual(try posixPermissions(of: result.createdFiles[0]) & 0o777, 0o600)
        }
    }

    @MainActor
    func testClipboardFileStoreImportsFileURLsAndQuotesStoredDestinationPath() throws {
        try withTemporaryDirectory { directory in
            let externalRoot = directory.appendingPathComponent("external")
            try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
            let source = externalRoot.appendingPathComponent("hello world.txt")
            try Data("a".utf8).write(to: source)

            let managedRoot = directory.appendingPathComponent("managed files'root")
            let store = ClipboardFileStore(rootDirectory: managedRoot)
            let pasteboard = NSPasteboard.withUniqueName()
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.writeObjects([source as NSURL]))

            let result = try XCTUnwrap(store.importFromPasteboard(pasteboard))
            XCTAssertEqual(result.createdFiles.count, 1)
            XCTAssertTrue(result.textToPaste.contains("'\\''"))
            XCTAssertTrue(result.textToPaste.hasPrefix("'"))
            XCTAssertTrue(result.textToPaste.hasSuffix("'"))

            for created in result.createdFiles {
                XCTAssertTrue(FileManager.default.fileExists(atPath: created.path))
                XCTAssertEqual(try posixPermissions(of: created) & 0o777, 0o600)
                XCTAssertEqual(created.deletingLastPathComponent().lastPathComponent, "managed files'root")
            }
        }
    }

    func testClipboardFileStoreImportFileURLsMatchesPasteboardFileImportBehavior() throws {
        try withTemporaryDirectory { directory in
            let externalRoot = directory.appendingPathComponent("external")
            try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
            let source = externalRoot.appendingPathComponent("drop file.txt")
            try Data("payload".utf8).write(to: source)

            let managedRoot = directory.appendingPathComponent("managed")
            let store = ClipboardFileStore(rootDirectory: managedRoot)

            let result = try XCTUnwrap(store.importFileURLs([source]))
            XCTAssertEqual(result.createdFiles.count, 1)

            let imported = try XCTUnwrap(result.createdFiles.first)
            XCTAssertTrue(imported.path.hasPrefix(managedRoot.path))
            XCTAssertEqual(result.textToPaste, store.shellQuotedPath(imported.path))
            XCTAssertEqual(try String(contentsOf: imported), "payload")
        }
    }

    func testClipboardFileStoreCleanupCreatesManagedDirectoryWithSecurePermissions() throws {
        try withTemporaryDirectory { directory in
            let managed = directory.appendingPathComponent("managed")
            let store = ClipboardFileStore(rootDirectory: managed)

            try store.cleanupExpiredFiles()

            XCTAssertTrue(FileManager.default.fileExists(atPath: managed.path))
            XCTAssertEqual(try posixPermissions(of: managed) & 0o777, 0o700)
        }
    }

    func testClipboardFileStoreRejectsDeletingOutsideManagedRoot() throws {
        try withTemporaryDirectory { directory in
            let store = ClipboardFileStore(rootDirectory: directory)
            let outside = directory.deletingLastPathComponent().appendingPathComponent("outside.txt")
            XCTAssertThrowsError(try store.deleteStoredFile(at: outside))
        }
    }

    func testClipboardFileStoreDeleteAllStoredFilesRemovesManagedContents() throws {
        try withTemporaryDirectory { directory in
            let store = ClipboardFileStore(rootDirectory: directory)
            let first = directory.appendingPathComponent("a.bin")
            let second = directory.appendingPathComponent("b.bin")
            try Data([0x01]).write(to: first)
            try Data([0x02]).write(to: second)

            try store.deleteAllStoredFiles()

            let remaining = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            XCTAssertTrue(remaining.isEmpty)
        }
    }

    func testClipboardCleanupServiceDeletesExpiredFilesOnSchedule() throws {
        try withTemporaryDirectory { directory in
            let expiredDate = Date(timeIntervalSince1970: 1000)
            let now = expiredDate.addingTimeInterval(25 * 60 * 60)
            let store = ClipboardFileStore(rootDirectory: directory, nowProvider: { now })
            let service = ClipboardCleanupService(fileStore: store, interval: 0.05)
            let stale = directory.appendingPathComponent("stale.bin")
            try Data([0xFF]).write(to: stale)
            try FileManager.default.setAttributes([.modificationDate: expiredDate], ofItemAtPath: stale.path)

            service.start()
            defer { service.stop() }

            let deadline = Date().addingTimeInterval(1.0)
            while FileManager.default.fileExists(atPath: stale.path) && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }

            XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        }
    }

    func testAuditLoggerWritesPlaintextHeaderAndEvents() throws {
        try withTemporaryDirectory { directory in
            let logger = TerminalAuditLogger(
                rootDirectory: directory,
                sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                timeZoneIdentifier: "Asia/Tokyo",
                termEnv: "xterm-256color",
                workspaceNameProvider: { "Main/Workspace" },
                terminalNameProvider: { "tail -f" },
                sizeProvider: { (120, 30) },
                nowProvider: { Date(timeIntervalSince1970: 1_700_000_000) }
            )

            logger.recordOutput(Data("$ ".utf8))
            logger.recordInput(Data("ls\r".utf8))
            logger.close()

            let files = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
                .filter { $0.hasSuffix(".cast") }
            XCTAssertEqual(files.count, 1)

            let contents = try String(contentsOf: directory.appendingPathComponent(files[0]))
            XCTAssertTrue(contents.contains("\"version\":2"))
            XCTAssertTrue(contents.contains("\"session_id\":\"00000000-0000-0000-0000-000000000001\""))
            XCTAssertTrue(contents.contains("$ "))
            XCTAssertTrue(contents.contains("ls"))
        }
    }

    func testAuditLoggerWritesAndDecryptsEncryptedFrames() throws {
        try withTemporaryDirectory { directory in
            let key = SymmetricKey(data: Data(repeating: 0x11, count: 32))
            let logger = TerminalAuditLogger(
                rootDirectory: directory,
                sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                timeZoneIdentifier: "Asia/Tokyo",
                termEnv: "xterm-256color",
                encryptionEnabled: true,
                workspaceNameProvider: { "Main" },
                terminalNameProvider: { "secure" },
                sizeProvider: { (80, 24) },
                keyProvider: { key },
                nowProvider: { Date(timeIntervalSince1970: 1_700_000_000) }
            )

            logger.recordOutput(Data("secret\n".utf8))
            logger.close()

            let castPath = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
                .first(where: { $0.hasSuffix(".cast") })
            let encrypted = try Data(contentsOf: directory.appendingPathComponent(try XCTUnwrap(castPath)))
            let decrypted = try TerminalAuditLogger.decryptFile(encrypted, key: key)
            let text = String(decoding: decrypted, as: UTF8.self)
            XCTAssertTrue(text.contains("secret"))
            XCTAssertTrue(text.contains("\"version\":2"))
        }
    }

    func testAuditLoggerAppendsHMACLineEveryHundredEvents() throws {
        try withTemporaryDirectory { directory in
            let key = SymmetricKey(data: Data(repeating: 0x22, count: 32))
            let logger = TerminalAuditLogger(
                rootDirectory: directory,
                sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                timeZoneIdentifier: "Asia/Tokyo",
                termEnv: "xterm-256color",
                encryptionEnabled: true,
                workspaceNameProvider: { "Main" },
                terminalNameProvider: { "audit" },
                sizeProvider: { (80, 24) },
                keyProvider: { key },
                nowProvider: { Date(timeIntervalSince1970: 1_700_000_000) }
            )

            for _ in 0..<100 {
                logger.recordOutput(Data("x".utf8))
            }
            logger.close()

            let castPath = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
                .first(where: { $0.hasSuffix(".cast") })
            let encrypted = try Data(contentsOf: directory.appendingPathComponent(try XCTUnwrap(castPath)))
            let decrypted = try TerminalAuditLogger.decryptFile(encrypted, key: key)
            let text = String(decoding: decrypted, as: UTF8.self)
            XCTAssertTrue(text.contains("\"h\""))
            XCTAssertTrue(text.contains("hmac-sha256:"))
        }
    }

    func testAuditLoggerFlushesBufferedHighFrequencyWritesOnClose() throws {
        try withTemporaryDirectory { directory in
            let logger = TerminalAuditLogger(
                rootDirectory: directory,
                sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
                timeZoneIdentifier: "Asia/Tokyo",
                termEnv: "xterm-256color",
                workspaceNameProvider: { "Perf" },
                terminalNameProvider: { "stress" },
                sizeProvider: { (80, 24) },
                nowProvider: { Date(timeIntervalSince1970: 1_700_000_000) }
            )

            for index in 0..<400 {
                logger.recordOutput(Data("line-\(index)\n".utf8))
            }
            logger.close()

            let castPath = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
                .first(where: { $0.hasSuffix(".cast") })
            let contents = try String(contentsOf: directory.appendingPathComponent(try XCTUnwrap(castPath)))
            XCTAssertTrue(contents.contains("line-0"))
            XCTAssertTrue(contents.contains("line-399"))
        }
    }

    func testAuditLoggerConcurrentInputOutputWritersPersistLatestMarkers() throws {
        try withTemporaryDirectory { directory in
            let logger = TerminalAuditLogger(
                rootDirectory: directory,
                sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
                timeZoneIdentifier: "Asia/Tokyo",
                termEnv: "xterm-256color",
                workspaceNameProvider: { "Main" },
                terminalNameProvider: { "tty" },
                sizeProvider: { (80, 24) },
                nowProvider: { Date(timeIntervalSince1970: 1_700_000_000) }
            )

            let group = DispatchGroup()
            let queue = DispatchQueue(label: "audit-concurrent-writers", attributes: .concurrent)
            for index in 0..<200 {
                group.enter()
                queue.async {
                    logger.recordInput(Data("in-\(index)\n".utf8))
                    logger.recordOutput(Data("out-\(index)\n".utf8))
                    group.leave()
                }
            }

            XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
            logger.close()

            let castPath = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
                .first(where: { $0.hasSuffix(".cast") })
            let contents = try String(contentsOf: directory.appendingPathComponent(try XCTUnwrap(castPath)))
            XCTAssertTrue(contents.contains("in-0"))
            XCTAssertTrue(contents.contains("out-199"))
        }
    }

    func testAuditLoggerDecryptFileRejectsCorruptPayload() {
        let key = SymmetricKey(data: Data(repeating: 0x33, count: 32))
        XCTAssertThrowsError(try TerminalAuditLogger.decryptFile(Data("bad".utf8), key: key))
    }

    func testAuditLoggerCleanupWithNilRetentionKeepsExistingDirectories() throws {
        try withTemporaryDirectory { directory in
            let existing = directory.appendingPathComponent("2025-03-01")
            try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
            let logger = TerminalAuditLogger(
                rootDirectory: directory,
                sessionID: UUID(),
                termEnv: "xterm-256color",
                workspaceNameProvider: { "Main" },
                terminalNameProvider: { "tail" },
                sizeProvider: { (80, 24) }
            )

            try logger.cleanupExpiredLogs(retentionDays: nil)
            XCTAssertTrue(FileManager.default.fileExists(atPath: existing.path))
        }
    }

    func testAuditLoggerCleanupIgnoresNonDateDirectories() throws {
        try withTemporaryDirectory { directory in
            let existing = directory.appendingPathComponent("not-a-date")
            try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
            let logger = TerminalAuditLogger(
                rootDirectory: directory,
                sessionID: UUID(),
                termEnv: "xterm-256color",
                workspaceNameProvider: { "Main" },
                terminalNameProvider: { "tail" },
                sizeProvider: { (80, 24) },
                nowProvider: { Date(timeIntervalSince1970: 1_741_737_600) }
            )

            try logger.cleanupExpiredLogs(retentionDays: 7)
            XCTAssertTrue(FileManager.default.fileExists(atPath: existing.path))
        }
    }

    func testAuditLoggerCleanupRetentionZeroRemovesPastDateDirectories() throws {
        try withTemporaryDirectory { directory in
            let oldDir = directory.appendingPathComponent("2025-03-11")
            try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
            let logger = TerminalAuditLogger(
                rootDirectory: directory,
                sessionID: UUID(),
                timeZoneIdentifier: "Asia/Tokyo",
                termEnv: "xterm-256color",
                workspaceNameProvider: { "Main" },
                terminalNameProvider: { "tail" },
                sizeProvider: { (80, 24) },
                nowProvider: { Date(timeIntervalSince1970: 1_741_737_600) }
            )

            try logger.cleanupExpiredLogs(retentionDays: 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: oldDir.path))
        }
    }

    func testAuditLoggerCleanupExpiredLogsRemovesOldDirectoriesOnly() throws {
        try withTemporaryDirectory { directory in
            let oldDir = directory.appendingPathComponent("2025-03-01")
            let keepDir = directory.appendingPathComponent("2025-03-12")
            try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: keepDir, withIntermediateDirectories: true)

            let logger = TerminalAuditLogger(
                rootDirectory: directory,
                sessionID: UUID(),
                timeZoneIdentifier: "Asia/Tokyo",
                termEnv: "xterm-256color",
                workspaceNameProvider: { "Main" },
                terminalNameProvider: { "tail" },
                sizeProvider: { (80, 24) },
                nowProvider: { Date(timeIntervalSince1970: 1_741_737_600) } // 2026-03-12 JST morning
            )
            try logger.cleanupExpiredLogs(retentionDays: 7)

            XCTAssertFalse(FileManager.default.fileExists(atPath: oldDir.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: keepDir.path))
        }
    }

    func testAuditKeyStoreCreatesAndReloadsStableKeyFromKeychain() throws {
        // Clean up any previous test key
        try? AuditKeyStore.deleteKeyFromKeychain()
        defer { try? AuditKeyStore.deleteKeyFromKeychain() }

        let first = try AuditKeyStore.loadOrCreateKey()
        let second = try AuditKeyStore.loadOrCreateKey()
        XCTAssertEqual(first.withUnsafeBytes { Data($0) }, second.withUnsafeBytes { Data($0) })
        XCTAssertEqual(first.withUnsafeBytes { Data($0) }.count, 32)
    }

    func testAuditPathBuilderUsesProvidedTimeZone() {
        let date = Date(timeIntervalSince1970: 1_741_718_000) // boundary around JST day
        XCTAssertEqual(AuditPathBuilder.dayString(for: date, timeZoneIdentifier: "UTC"), "2025-03-11")
        XCTAssertEqual(AuditPathBuilder.dayString(for: date, timeZoneIdentifier: "Asia/Tokyo"), "2025-03-12")
    }

    func testAuditLoggerCloseIsSafeWithoutRecordedEvents() {
        let logger = TerminalAuditLogger(
            rootDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            sessionID: UUID(),
            termEnv: "xterm-256color",
            workspaceNameProvider: { "Main" },
            terminalNameProvider: { "idle" },
            sizeProvider: { (80, 24) }
        )

        logger.close()
        logger.close()
    }

    func testExportImportManagerNormalizesImportedPermissionsRecursively() throws {
        try withTemporaryDirectory { directory in
            let noteStore = AppNoteStore(rootDirectory: directory.appendingPathComponent("note-root"))
            let manager = PtermExportImportManager(
                noteStore: noteStore,
                fileManager: .default,
                configURL: directory.appendingPathComponent("config.json"),
                sessionsURL: directory.appendingPathComponent("sessions"),
                workspacesURL: directory.appendingPathComponent("workspaces"),
                auditURL: directory.appendingPathComponent("audit")
            )

            let sessions = directory.appendingPathComponent("sessions")
            let nested = sessions.appendingPathComponent("scrollback")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let regular = nested.appendingPathComponent("state.bin")
            let auditKey = directory.appendingPathComponent("audit").appendingPathComponent(".key")
            try FileManager.default.createDirectory(at: auditKey.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: regular)
            try Data("k".utf8).write(to: auditKey)

            try manager.normalizeImportedPermissions(for: [sessions, auditKey.deletingLastPathComponent()])

            XCTAssertEqual(try posixPermissions(of: sessions) & 0o777, 0o700)
            XCTAssertEqual(try posixPermissions(of: nested) & 0o777, 0o700)
            XCTAssertEqual(try posixPermissions(of: regular) & 0o777, 0o600)
            XCTAssertEqual(try posixPermissions(of: auditKey) & 0o777, 0o400)
        }
    }

    func testExportImportManagerDefaultExportURLUsesExpectedPrefixAndSuffix() {
        let manager = PtermExportImportManager(noteStore: AppNoteStore(rootDirectory: URL(fileURLWithPath: NSTemporaryDirectory())))
        let fileName = manager.defaultExportURL().lastPathComponent
        XCTAssertTrue(fileName.hasPrefix("pterm-export-"))
        XCTAssertTrue(fileName.hasSuffix(".zip"))
    }

    func testExportImportManagerRequiresPasswordForExportAndImport() throws {
        try withTemporaryDirectory { directory in
            let manager = PtermExportImportManager(
                noteStore: AppNoteStore(rootDirectory: directory.appendingPathComponent("notes")),
                configURL: directory.appendingPathComponent("config.json"),
                sessionsURL: directory.appendingPathComponent("sessions"),
                workspacesURL: directory.appendingPathComponent("workspaces"),
                auditURL: directory.appendingPathComponent("audit")
            )
            let archiveURL = directory.appendingPathComponent("archive.zip")

            // Password validation was removed — export/import no longer require
            // a password.  Verify that export succeeds without a password argument.
            try manager.exportArchive(to: archiveURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))
        }
    }

    func testExportImportManagerExportsPlaintextNoteWithoutKeysEnvelope() throws {
        try withTemporaryDirectory { directory in
            let noteStore = AppNoteStore(rootDirectory: directory.appendingPathComponent("notes"))
            try noteStore.saveNote("plain export note")

            let manager = PtermExportImportManager(
                noteStore: noteStore,
                configURL: directory.appendingPathComponent("config.json"),
                sessionsURL: directory.appendingPathComponent("sessions"),
                workspacesURL: directory.appendingPathComponent("workspaces"),
                auditURL: directory.appendingPathComponent("audit")
            )
            let archiveURL = directory.appendingPathComponent("archive.zip")
            let extractionRoot = directory.appendingPathComponent("extracted")

            try manager.exportArchive(to: archiveURL)
            try FileManager.default.createDirectory(at: extractionRoot, withIntermediateDirectories: true)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", archiveURL.path, extractionRoot.path]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)

            let payloadRoot = try XCTUnwrap(
                FileManager.default.contentsOfDirectory(at: extractionRoot, includingPropertiesForKeys: nil).first
            )
            XCTAssertEqual(
                try String(contentsOf: payloadRoot.appendingPathComponent("note.txt"), encoding: .utf8),
                "plain export note"
            )
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: payloadRoot.appendingPathComponent("keys.enc").path)
            )
        }
    }

    func testExportImportManagerImportArchiveReEncryptsPlaintextNoteIntoDestinationStore() throws {
        try withTemporaryDirectory { directory in
            let archiveRoot = directory.appendingPathComponent("payload")
            let archiveURL = directory.appendingPathComponent("archive.zip")
            let noteStore = AppNoteStore(rootDirectory: directory.appendingPathComponent("notes"))
            try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
            try Data("imported note".utf8).write(to: archiveRoot.appendingPathComponent("note.txt"))

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--keepParent", archiveRoot.path, archiveURL.path]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)

            let manager = PtermExportImportManager(
                noteStore: noteStore,
                configURL: directory.appendingPathComponent("config.json"),
                sessionsURL: directory.appendingPathComponent("sessions"),
                workspacesURL: directory.appendingPathComponent("workspaces"),
                auditURL: directory.appendingPathComponent("audit")
            )

            try manager.importArchive(from: archiveURL)

            XCTAssertEqual(try noteStore.loadNote(), "imported note")
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent("notes").appendingPathComponent("note.enc").path
                )
            )
        }
    }

    func testExportImportManagerInspectArchiveReportsIncludedAndOverwrittenItems() throws {
        try withTemporaryDirectory { directory in
            let archiveRoot = directory.appendingPathComponent("payload")
            let archiveURL = directory.appendingPathComponent("archive.zip")
            let configURL = directory.appendingPathComponent("dest-config.json")
            let sessionsURL = directory.appendingPathComponent("dest-sessions")
            let workspacesURL = directory.appendingPathComponent("dest-workspaces")
            let auditURL = directory.appendingPathComponent("dest-audit")
            let noteStore = AppNoteStore(rootDirectory: directory.appendingPathComponent("notes"))
            try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: archiveRoot.appendingPathComponent("config.json"))
            try FileManager.default.createDirectory(at: archiveRoot.appendingPathComponent("sessions"), withIntermediateDirectories: true)
            try Data("note".utf8).write(to: archiveRoot.appendingPathComponent("note.txt"))
            try Data("existing".utf8).write(to: configURL)
            try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
            try noteStore.saveNote("existing note")

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--keepParent", archiveRoot.path, archiveURL.path]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)

            let manager = PtermExportImportManager(
                noteStore: noteStore,
                configURL: configURL,
                sessionsURL: sessionsURL,
                workspacesURL: workspacesURL,
                auditURL: auditURL
            )

            let preview = try manager.inspectArchive(archiveURL)
            XCTAssertEqual(Set(preview.includedItems), Set(["config.json", "sessions/", "note.txt"]))
            XCTAssertEqual(Set(preview.overwrittenItems), Set(["config.json", "sessions/", "note.txt"]))
        }
    }

    func testExportImportManagerInspectArchiveRejectsInvalidZipPayload() throws {
        try withTemporaryDirectory { directory in
            let archiveURL = directory.appendingPathComponent("invalid.zip")
            try Data("not-a-zip".utf8).write(to: archiveURL)
            let manager = PtermExportImportManager(
                noteStore: AppNoteStore(rootDirectory: directory.appendingPathComponent("notes")),
                configURL: directory.appendingPathComponent("config.json"),
                sessionsURL: directory.appendingPathComponent("sessions"),
                workspacesURL: directory.appendingPathComponent("workspaces"),
                auditURL: directory.appendingPathComponent("audit")
            )

            XCTAssertThrowsError(try manager.inspectArchive(archiveURL))
        }
    }

    func testExportImportManagerInspectArchiveRejectsSymbolicLinksInArchive() throws {
        try withTemporaryDirectory { directory in
            let archiveRoot = directory.appendingPathComponent("payload")
            let archiveURL = directory.appendingPathComponent("archive.zip")
            try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
            let symlinkURL = archiveRoot.appendingPathComponent("config.json")
            try FileManager.default.createSymbolicLink(atPath: symlinkURL.path, withDestinationPath: "/etc/passwd")

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--keepParent", archiveRoot.path, archiveURL.path]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)

            let manager = PtermExportImportManager(
                noteStore: AppNoteStore(rootDirectory: directory.appendingPathComponent("notes")),
                configURL: directory.appendingPathComponent("config.json"),
                sessionsURL: directory.appendingPathComponent("sessions"),
                workspacesURL: directory.appendingPathComponent("workspaces"),
                auditURL: directory.appendingPathComponent("audit")
            )

            XCTAssertThrowsError(try manager.inspectArchive(archiveURL)) { error in
                guard case let PtermExportImportError.unsafeArchiveEntry(path) = error else {
                    return XCTFail("Expected unsafeArchiveEntry, got \(error)")
                }
                XCTAssertEqual(path, "config.json")
            }
        }
    }

    func testExportImportManagerImportArchiveRejectsSymbolicLinksBeforeRestoringFiles() throws {
        try withTemporaryDirectory { directory in
            let archiveRoot = directory.appendingPathComponent("payload")
            let archiveURL = directory.appendingPathComponent("archive.zip")
            let configURL = directory.appendingPathComponent("dest-config.json")
            try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
            try Data("note".utf8).write(to: archiveRoot.appendingPathComponent("note.txt"))
            let symlinkURL = archiveRoot.appendingPathComponent("sessions")
            try FileManager.default.createSymbolicLink(atPath: symlinkURL.path, withDestinationPath: "/tmp")
            try Data("existing".utf8).write(to: configURL)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--keepParent", archiveRoot.path, archiveURL.path]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)

            let manager = PtermExportImportManager(
                noteStore: AppNoteStore(rootDirectory: directory.appendingPathComponent("notes")),
                configURL: configURL,
                sessionsURL: directory.appendingPathComponent("sessions"),
                workspacesURL: directory.appendingPathComponent("workspaces"),
                auditURL: directory.appendingPathComponent("audit")
            )

            XCTAssertThrowsError(try manager.importArchive(from: archiveURL)) { error in
                guard case let PtermExportImportError.unsafeArchiveEntry(path) = error else {
                    return XCTFail("Expected unsafeArchiveEntry, got \(error)")
                }
                XCTAssertEqual(path, "sessions")
            }
            XCTAssertEqual(try String(contentsOf: configURL), "existing")
        }
    }

    @MainActor
    func testProcessMetricsMonitorEmitsSnapshotForEmptyPIDSet() {
        let monitor = ProcessMetricsMonitor(interval: 60)
        let expectation = expectation(description: "metrics-update")
        monitor.onUpdate = { snapshot in
            XCTAssertTrue(snapshot.cpuUsageByPID.isEmpty)
            XCTAssertGreaterThan(snapshot.appMemoryBytes, 0)
            expectation.fulfill()
        }

        monitor.start(pidsProvider: { [] })
        wait(for: [expectation], timeout: 1.0)
        monitor.stop()
    }

    func testProcessMetricsMonitorStartsWithoutDescendantScratchAllocation() {
        let monitor = ProcessMetricsMonitor(interval: 60)

        XCTAssertEqual(monitor.debugDescendantQueueScratchCapacity, 0)
        XCTAssertEqual(monitor.debugDescendantResultScratchCapacity, 0)
        XCTAssertEqual(monitor.debugChildPIDBufferScratchCapacity, 0)
    }

    @MainActor
    func testProcessMetricsMonitorStopKeepsDescendantScratchAtZero() {
        let monitor = ProcessMetricsMonitor(interval: 60)

        monitor.stop()

        XCTAssertEqual(monitor.debugDescendantQueueScratchCapacity, 0)
        XCTAssertEqual(monitor.debugDescendantResultScratchCapacity, 0)
        XCTAssertEqual(monitor.debugChildPIDBufferScratchCapacity, 0)
    }

    func testProcessMetricsMonitorStopReleasesLastSampleHistoryToo() {
        let monitor = ProcessMetricsMonitor(interval: 60)
        monitor.debugPrimeLastSamples([11, 22, 33])

        XCTAssertEqual(monitor.debugLastSampleCount, 3)

        monitor.stop()

        XCTAssertEqual(monitor.debugLastSampleCount, 0)
    }

    func testProcessMetricsMonitorDescendantScratchRemainsDisabled() {
        let monitor = ProcessMetricsMonitor(interval: 60)
        monitor.debugPrimeDescendantScratch(queueCount: 512, resultCount: 1024, childCount: 2048)

        monitor.debugCompactDescendantScratchForTesting(
            retainingQueueCount: 4,
            resultCount: 8,
            childCount: 16
        )

        XCTAssertEqual(monitor.debugDescendantQueueScratchCapacity, 0)
        XCTAssertEqual(monitor.debugDescendantResultScratchCapacity, 0)
        XCTAssertEqual(monitor.debugChildPIDBufferScratchCapacity, 0)
    }

    func testProcessMetricsMonitorConvertsAbsoluteTicksUsingMachTimebase() {
        let monitor = ProcessMetricsMonitor(interval: 60)
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)

        let ticksPerSecond = UInt64((1_000_000_000.0 * Double(timebase.denom)) / Double(timebase.numer))
        let seconds = monitor.cpuTimeSeconds(fromAbsoluteTicks: ticksPerSecond)

        XCTAssertEqual(seconds, 1.0, accuracy: 0.001)
    }

    @MainActor
    func testProcessMetricsMonitorCapturesCPUForLiveChildProcess() throws {
        try withTemporaryDirectory { directory in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.currentDirectoryURL = directory
            process.arguments = ["-c", "sleep 2"]
            try process.run()
            defer {
                if process.isRunning {
                    process.terminate()
                    process.waitUntilExit()
                }
            }

            let monitor = ProcessMetricsMonitor(interval: 60)
            let expectation = expectation(description: "metrics-update-live-child")
            monitor.onUpdate = { snapshot in
                guard let cpu = snapshot.cpuUsageByPID[process.processIdentifier] else {
                    return
                }
                XCTAssertGreaterThanOrEqual(cpu, 0)
                expectation.fulfill()
            }

            monitor.start(pidsProvider: { [process.processIdentifier] })
            wait(for: [expectation], timeout: 1.0)
            monitor.stop()
        }
    }

    func testProcessInspectionCapturesCurrentDirectoryForLiveChildProcess() throws {
        try withTemporaryDirectory { directory in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.currentDirectoryURL = directory
            process.arguments = ["-c", "sleep 2"]
            try process.run()
            defer {
                if process.isRunning {
                    process.terminate()
                    process.waitUntilExit()
                }
            }

            let cwd = try XCTUnwrap(ProcessInspection.currentDirectory(pid: process.processIdentifier))
            XCTAssertEqual(
                URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path,
                directory.resolvingSymlinksInPath().path
            )
        }
    }

    func testProcessInspectionCapturesCurrentProcessName() {
        let name = ProcessInspection.processName(pid: getpid())

        XCTAssertFalse((name ?? "").isEmpty)
    }

    func testTerminalControllerTracksLastOutputTimestampAndScreenRevision() {
        let controller = TerminalController(
            rows: 4,
            cols: 12,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 256,
            scrollbackMaxCapacity: 256,
            fontName: "Menlo",
            fontSize: 13
        )

        XCTAssertNil(controller.lastOutputAt)
        let initialRevision = controller.screenRevision

        controller.debugProcessPTYOutputForTesting(Data("hello\n".utf8))

        XCTAssertNotNil(controller.lastOutputAt)
        XCTAssertGreaterThan(controller.screenRevision, initialRevision)
    }

    func testMCPVisibleTextRawPreservesLeadingAndTrailingWhitespace() {
        let controller = TerminalController(
            rows: 2,
            cols: 6,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 32,
            scrollbackMaxCapacity: 32,
            fontName: "Menlo",
            fontSize: 13
        )

        controller.debugProcessPTYOutputForTesting(Data("  hi  \n".utf8))

        let snapshot = controller.captureRenderSnapshot()
        let raw = AppDelegate.mcpVisibleText(from: snapshot, trimWhitespace: false)
        let trimmed = AppDelegate.mcpVisibleText(from: snapshot, trimWhitespace: true)

        XCTAssertTrue(raw.hasPrefix("  hi  "))
        XCTAssertEqual(trimmed.components(separatedBy: "\n").first, "hi")
    }

    func testMCPVisibleTextUsesRenderedGraphemeClusters() {
        let controller = TerminalController(
            rows: 2,
            cols: 8,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 32,
            scrollbackMaxCapacity: 32,
            fontName: "Menlo",
            fontSize: 13
        )

        controller.debugProcessPTYOutputForTesting(Data("👩‍💻 e\u{301}\n".utf8))

        let snapshot = controller.captureRenderSnapshot()
        let raw = AppDelegate.mcpVisibleText(from: snapshot, trimWhitespace: false)

        XCTAssertTrue(raw.contains("👩‍💻"))
        XCTAssertTrue(raw.contains("e\u{301}"))
    }

    func testMCPVisibleTextANSIRawPreservesWhitespaceAndStyle() {
        let controller = TerminalController(
            rows: 2,
            cols: 12,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: 32,
            scrollbackMaxCapacity: 32,
            fontName: "Menlo",
            fontSize: 13
        )

        controller.debugProcessPTYOutputForTesting(Data(" \u{001B}[1;31mA\u{001B}[0m \n".utf8))

        let snapshot = controller.captureRenderSnapshot()
        let ansiRaw = AppDelegate.mcpVisibleTextANSI(from: snapshot, trimWhitespace: false)
        let ansiTrimmed = AppDelegate.mcpVisibleTextANSI(from: snapshot, trimWhitespace: true)

        XCTAssertTrue(ansiRaw.hasPrefix(" "))
        XCTAssertTrue(ansiRaw.contains("\u{001B}[0;1;31;49;59mA"))
        XCTAssertTrue(ansiRaw.contains("\u{001B}[m"))
        XCTAssertTrue(ansiTrimmed.hasPrefix("\u{001B}[0;1;31;49;59mA"))
    }

    func testMCPTerminalWaitConditionMatchesForegroundRevisionAndIdleState() throws {
        let terminalID = UUID()
        let observation = AppDelegate.MCPTerminalObservation(
            terminalID: terminalID,
            foregroundProcessName: "claude",
            screenRevision: 12,
            lastOutputAt: Date().addingTimeInterval(-2.0)
        )
        let condition = try AppDelegate.MCPTerminalWaitCondition(arguments: [
            "terminal_id": terminalID.uuidString,
            "foreground_process_name": "claude",
            "screen_revision_gt": 11,
            "idle_for_ms": 500,
            "timeout_ms": 1000
        ])

        XCTAssertTrue(condition.isSatisfied(by: observation, now: Date()))
    }

    func testMCPTerminalWaitConditionRejectsUnsatisfiedObservation() throws {
        let terminalID = UUID()
        let observation = AppDelegate.MCPTerminalObservation(
            terminalID: terminalID,
            foregroundProcessName: "zsh",
            screenRevision: 4,
            lastOutputAt: Date()
        )
        let condition = try AppDelegate.MCPTerminalWaitCondition(arguments: [
            "terminal_id": terminalID.uuidString,
            "foreground_process_name": "claude",
            "screen_revision_gt": 10,
            "idle_for_ms": 1000
        ])

        XCTAssertFalse(condition.isSatisfied(by: observation, now: Date()))
    }

    func testPTYStartsWithoutReadBufferAllocation() {
        let pty = PTY()
        XCTAssertEqual(pty.debugReadBufferCapacity, 0)
    }

    func testPTYReadBufferCanBePrimedAndReleasedAfterIdleShrink() {
        let pty = PTY()
        pty.debugPrimeReadBufferCapacity(32 * 1024)
        XCTAssertEqual(pty.debugReadBufferCapacity, 32 * 1024)

        pty.debugShrinkIdleReadBufferNow()
        XCTAssertEqual(pty.debugReadBufferCapacity, 0)
    }

    func testPTYPrimeReadBufferUsesMinimumCapacityFloor() {
        let pty = PTY()
        pty.debugPrimeReadBufferCapacity(128)
        XCTAssertEqual(pty.debugReadBufferCapacity, 4096)
    }

    // MARK: - AI Configuration

    func testAIModelTypeRawValueRoundTrips() {
        for model in AIModelType.allCases {
            XCTAssertEqual(AIModelType(rawValue: model.rawValue), model)
        }
    }

    func testAIModelTypeConfiguredValueRoundTrips() {
        for model in AIModelType.allCases {
            XCTAssertEqual(AIModelType(configuredValue: model.configuredValue), model)
        }
    }

    func testAIModelTypeConfiguredValueIsCaseInsensitive() {
        XCTAssertEqual(AIModelType(configuredValue: "CLAUDE_CODE"), .claudeCode)
        XCTAssertEqual(AIModelType(configuredValue: "Codex"), .codex)
        XCTAssertEqual(AIModelType(configuredValue: " GEMINI "), .gemini)
    }

    func testAIModelTypeRejectsInvalidConfiguredValue() {
        XCTAssertNil(AIModelType(configuredValue: "cursor"))
        XCTAssertNil(AIModelType(configuredValue: ""))
        XCTAssertNil(AIModelType(configuredValue: "gpt4"))
    }

    func testAIModelTypeAllCasesContainsExactlyThreeModels() {
        XCTAssertEqual(AIModelType.allCases.count, 3)
        XCTAssertTrue(AIModelType.allCases.contains(.claudeCode))
        XCTAssertTrue(AIModelType.allCases.contains(.codex))
        XCTAssertTrue(AIModelType.allCases.contains(.gemini))
    }

    func testAIModelTypeDisplayNames() {
        XCTAssertEqual(AIModelType.claudeCode.displayName, "Claude Code")
        XCTAssertEqual(AIModelType.codex.displayName, "Codex")
        XCTAssertEqual(AIModelType.gemini.displayName, "Gemini")
    }

    func testAIConfigurationDefaultsEnabledWithClaudeCode() {
        let config = AIConfiguration.default
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.model, .claudeCode)
    }

    func testAIConfigurationDefaultLanguageUsesPreferredLanguages() {
        let defaultLang = AIConfiguration.defaultLanguage
        XCTAssertFalse(defaultLang.isEmpty)
        // It should derive from preferredLanguages, not Locale.current (which is bundle-dependent)
        let preferred = Locale.preferredLanguages.first ?? "en"
        let expected = Locale(identifier: preferred).identifier
        XCTAssertEqual(defaultLang, expected)
    }

    func testPtermConfigStoreDefaultsAIToEnabledClaudeCode() {
        let loaded = PtermConfigStore.load(from: URL(fileURLWithPath: "/nonexistent/config.json"))
        XCTAssertEqual(loaded.ai, .default)
        XCTAssertTrue(loaded.ai.enabled)
        XCTAssertEqual(loaded.ai.model, .claudeCode)
    }

    func testPtermConfigStoreLoadsAISettings() throws {
        try withTemporaryPtermConfig { configURL in
            let json: [String: Any] = [
                "ai": [
                    "enabled": false,
                    "language": "fr",
                    "model": "gemini"
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try AtomicFileWriter.write(data, to: configURL, permissions: 0o600)

            let loaded = PtermConfigStore.load(from: configURL)
            XCTAssertFalse(loaded.ai.enabled)
            XCTAssertEqual(loaded.ai.language, "fr")
            XCTAssertEqual(loaded.ai.model, .gemini)
        }
    }

    func testPtermConfigStoreLoadsAIModelCodex() throws {
        try withTemporaryPtermConfig { configURL in
            let json: [String: Any] = [
                "ai": ["model": "codex"]
            ]
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try AtomicFileWriter.write(data, to: configURL, permissions: 0o600)

            let loaded = PtermConfigStore.load(from: configURL)
            XCTAssertEqual(loaded.ai.model, .codex)
        }
    }

    func testPtermConfigStoreDefaultsAIOnInvalidModel() throws {
        try withTemporaryPtermConfig { configURL in
            let json: [String: Any] = [
                "ai": ["model": "invalid_model"]
            ]
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try AtomicFileWriter.write(data, to: configURL, permissions: 0o600)

            let loaded = PtermConfigStore.load(from: configURL)
            XCTAssertEqual(loaded.ai.model, .claudeCode)
        }
    }

    func testPtermConfigStoreDefaultsAIOnMissingSection() throws {
        try withTemporaryPtermConfig { configURL in
            let json: [String: Any] = ["term": "xterm-256color"]
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try AtomicFileWriter.write(data, to: configURL, permissions: 0o600)

            let loaded = PtermConfigStore.load(from: configURL)
            XCTAssertTrue(loaded.ai.enabled)
            XCTAssertEqual(loaded.ai.model, .claudeCode)
        }
    }

    func testPtermConfigStoreLoadsPartialAISection() throws {
        try withTemporaryPtermConfig { configURL in
            let json: [String: Any] = [
                "ai": ["language": "ko"]
            ]
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try AtomicFileWriter.write(data, to: configURL, permissions: 0o600)

            let loaded = PtermConfigStore.load(from: configURL)
            XCTAssertTrue(loaded.ai.enabled)
            XCTAssertEqual(loaded.ai.language, "ko")
            XCTAssertEqual(loaded.ai.model, .claudeCode)
        }
    }

    // MARK: - AIService Prompt Building

    func testAIServiceBuildPromptIncludesLanguageInstructionAndQuestion() {
        let prompt = AIService.buildPrompt(
            question: "What is this?",
            language: "ja",
            context: nil,
            chatHistory: []
        )
        XCTAssertTrue(prompt.contains("MUST respond entirely in"))
        XCTAssertTrue(prompt.contains("User question: What is this?"))
        XCTAssertTrue(prompt.contains("REMINDER"))
    }

    func testAIServiceBuildPromptUsesNSLocaleForSelfLocalizedName() {
        let prompt = AIService.buildPrompt(
            question: "test",
            language: "ja",
            context: nil,
            chatHistory: []
        )
        // Must contain the self-localized name "日本語" (not "Japanese" alone)
        XCTAssertTrue(prompt.contains("日本語"), "Prompt must contain self-localized language name via NSLocale, got: \(prompt.prefix(200))")
    }

    func testAIServiceBuildPromptIncludesEnglishLanguageNameForClarity() {
        let prompt = AIService.buildPrompt(
            question: "test",
            language: "ja",
            context: nil,
            chatHistory: []
        )
        XCTAssertTrue(prompt.contains("Japanese"), "Prompt must include English name for unambiguous identification")
    }

    func testAIServiceBuildPromptForEnglishDoesNotDuplicateLanguageName() {
        let prompt = AIService.buildPrompt(
            question: "test",
            language: "en",
            context: nil,
            chatHistory: []
        )
        // For English, self name == english name, so no parenthesized duplicate
        XCTAssertTrue(prompt.contains("English"))
        XCTAssertFalse(prompt.contains("English (English)"))
    }

    func testAIServiceBuildPromptIncludesTerminalContext() {
        let context = AIService.TerminalContext(
            workingDirectory: "/Users/test/project",
            foregroundProcess: "vim",
            viewportText: "hello world"
        )
        let prompt = AIService.buildPrompt(
            question: "help",
            language: "en",
            context: context,
            chatHistory: []
        )
        XCTAssertTrue(prompt.contains("/Users/test/project"))
        XCTAssertTrue(prompt.contains("vim"))
        XCTAssertTrue(prompt.contains("hello world"))
    }

    func testAIServiceBuildPromptOmitsEmptyForegroundProcess() {
        let context = AIService.TerminalContext(
            workingDirectory: "/tmp",
            foregroundProcess: "",
            viewportText: ""
        )
        let prompt = AIService.buildPrompt(
            question: "test",
            language: "en",
            context: context,
            chatHistory: []
        )
        XCTAssertFalse(prompt.contains("Running process"))
    }

    func testAIServiceBuildPromptIncludesChatHistory() {
        let history: [(role: String, content: String)] = [
            (role: "user", content: "previous question"),
            (role: "assistant", content: "previous answer")
        ]
        let prompt = AIService.buildPrompt(
            question: "follow up",
            language: "en",
            context: nil,
            chatHistory: history
        )
        XCTAssertTrue(prompt.contains("Conversation history"))
        XCTAssertTrue(prompt.contains("User: previous question"))
        XCTAssertTrue(prompt.contains("Assistant: previous answer"))
        XCTAssertTrue(prompt.contains("User question: follow up"))
    }

    func testAIServiceBuildSummarizePromptIncludesSelectedText() {
        let prompt = AIService.buildSummarizePrompt(
            selectedText: "error: segfault at 0x0",
            language: "ja",
            context: nil
        )
        XCTAssertTrue(prompt.contains("error: segfault at 0x0"))
        XCTAssertTrue(prompt.contains("Analyze and summarize"))
        XCTAssertTrue(prompt.contains("日本語"))
    }

    func testAIServiceBuildSummarizePromptLanguageEnforced() {
        let prompt = AIService.buildSummarizePrompt(
            selectedText: "test output",
            language: "zh_CN",
            context: nil
        )
        // Must contain Chinese self-name
        XCTAssertTrue(prompt.contains("中文"), "Prompt must contain self-localized Chinese name")
        // Language instruction appears at top AND bottom
        let reminderCount = prompt.components(separatedBy: "MUST").count - 1
        XCTAssertGreaterThanOrEqual(reminderCount, 2, "Language instruction must appear at top and bottom")
    }

    func testAIServiceBuildPromptLanguageEnforcedAtTopAndBottom() {
        let prompt = AIService.buildPrompt(
            question: "help",
            language: "ko",
            context: nil,
            chatHistory: []
        )
        // Check "MUST" appears in both IMPORTANT and REMINDER lines
        XCTAssertTrue(prompt.hasPrefix("IMPORTANT:"))
        XCTAssertTrue(prompt.contains("REMINDER:"))
        XCTAssertTrue(prompt.contains("한국어"), "Prompt must contain self-localized Korean name")
    }

    // MARK: - AIService Error Descriptions

    func testAIErrorCLINotFoundIncludesModelName() {
        let error = AIService.AIError.cliNotFound(.claudeCode)
        XCTAssertTrue(error.description.contains("Claude Code"))

        let error2 = AIService.AIError.cliNotFound(.gemini)
        XCTAssertTrue(error2.description.contains("Gemini"))
    }

    func testAIErrorDisabledSuggestsSettings() {
        let error = AIService.AIError.aiDisabled
        XCTAssertTrue(error.description.contains("Settings"))
    }

    func testAIErrorProcessTerminatedIncludesExitCode() {
        let error = AIService.AIError.processTerminated(42)
        XCTAssertTrue(error.description.contains("42"))
    }

    // MARK: - TerminalController Viewport Text

    func testTerminalControllerViewportTextReturnsStringWithinMaxLines() {
        let controller = TerminalController(
            rows: 10, cols: 20,
            termEnv: "xterm-256color", textEncoding: .utf8,
            scrollbackInitialCapacity: 4096, scrollbackMaxCapacity: 4096,
            fontName: "Menlo", fontSize: 13
        )

        let text = controller.viewportText(maxLines: 3)
        let lineCount = text.components(separatedBy: "\n").count
        XCTAssertLessThanOrEqual(lineCount, 3)
    }

    func testTerminalControllerViewportTextDefaultMaxIs100() {
        let controller = TerminalController(
            rows: 4, cols: 10,
            termEnv: "xterm-256color", textEncoding: .utf8,
            scrollbackInitialCapacity: 4096, scrollbackMaxCapacity: 4096,
            fontName: "Menlo", fontSize: 13
        )
        // Default maxLines=100, with only 4 rows, should return at most 4 lines
        let text = controller.viewportText()
        let lineCount = text.components(separatedBy: "\n").count
        XCTAssertLessThanOrEqual(lineCount, 4)
    }

    func testTerminalControllerWorkingDirectoryPathExposesExpandedPath() {
        let controller = TerminalController(
            rows: 4, cols: 20,
            termEnv: "xterm-256color", textEncoding: .utf8,
            scrollbackInitialCapacity: 4096, scrollbackMaxCapacity: 4096,
            fontName: "Menlo", fontSize: 13,
            initialDirectory: "~"
        )
        let path = controller.workingDirectoryPath
        XCTAssertFalse(path.isEmpty)
        // Expanded path should not contain tilde
        XCTAssertFalse(path.hasPrefix("~"))
        XCTAssertTrue(path.hasPrefix("/"))
    }
}

private func encryptedNotePayloadForTest(plaintext: Data, key: Data) throws -> Data {
    let magic = Data("PTN1".utf8)
    let salt = Data(repeating: 0x11, count: 16)
    let iv = Data(repeating: 0x22, count: kCCBlockSizeAES128)
    var output = Data(count: plaintext.count + kCCBlockSizeAES128)
    let outputCapacity = output.count
    var outLength = 0

    let status = output.withUnsafeMutableBytes { outputBytes in
        plaintext.withUnsafeBytes { inputBytes in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, key.count,
                        ivBytes.baseAddress,
                        inputBytes.baseAddress, plaintext.count,
                        outputBytes.baseAddress, outputCapacity,
                        &outLength
                    )
                }
            }
        }
    }

    guard status == kCCSuccess else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
    output.removeSubrange(outLength..<output.count)
    return magic + salt + iv + output
}

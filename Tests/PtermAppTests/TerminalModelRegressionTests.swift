import XCTest
@testable import PtermApp

final class TerminalModelRegressionTests: XCTestCase {
    func testCursorStateSaveRestoreAndClampRoundTripsState() {
        var cursor = CursorState(
            row: 10,
            col: 20,
            visible: true,
            shape: .underline,
            blinking: false,
            attributes: .init(
                foreground: .indexed(3),
                background: .rgb(1, 2, 3),
                bold: true,
                italic: true,
                underline: true,
                strikethrough: false,
                inverse: false,
                hidden: false,
                dim: false,
                blink: true
            ),
            originMode: true,
            autoWrapMode: false,
            pendingWrap: true,
            savedState: nil
        )

        cursor.save()
        cursor.row = 99
        cursor.col = 99
        cursor.shape = .bar
        cursor.blinking = true
        cursor.attributes = .default
        cursor.originMode = false
        cursor.autoWrapMode = true
        cursor.pendingWrap = true

        cursor.restore()
        XCTAssertEqual(cursor.row, 10)
        XCTAssertEqual(cursor.col, 20)
        XCTAssertEqual(cursor.shape, .underline)
        XCTAssertFalse(cursor.blinking)
        XCTAssertEqual(cursor.attributes.foreground, .indexed(3))
        XCTAssertTrue(cursor.originMode)
        XCTAssertFalse(cursor.autoWrapMode)
        XCTAssertFalse(cursor.pendingWrap)

        cursor.row = 100
        cursor.col = 100
        cursor.pendingWrap = true
        cursor.clamp(rows: 5, cols: 6)
        XCTAssertEqual(cursor.row, 4)
        XCTAssertEqual(cursor.col, 5)
        XCTAssertFalse(cursor.pendingWrap)
    }

    func testTerminalModelBellInvokesCallback() {
        let harness = TerminalModelHarness()
        var bellCount = 0
        harness.model.onBell = { bellCount += 1 }

        harness.feed(codepoints: [0x07])

        XCTAssertEqual(bellCount, 1)
    }

    func testTerminalModelBellCanFireMultipleTimes() {
        let harness = TerminalModelHarness()
        var bellCount = 0
        harness.model.onBell = { bellCount += 1 }

        harness.feed(codepoints: [0x07, 0x07, 0x07])

        XCTAssertEqual(bellCount, 3)
    }

    func testDisplayLocalInterruptPromptBoundaryMovesToNextLineWhenCurrentLineHasContent() {
        let harness = TerminalModelHarness(rows: 3, cols: 8)
        harness.feed("abc")

        harness.model.displayLocalInterruptPromptBoundary()

        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 0).codepoint, 0x61)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 1).codepoint, 0x62)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 2).codepoint, 0x63)
        XCTAssertEqual(harness.model.grid.cell(at: 1, col: 0).codepoint, 0x20)
        XCTAssertEqual(harness.model.cursor.row, 1)
        XCTAssertEqual(harness.model.cursor.col, 0)
    }

    func testDisplayLocalInterruptPromptBoundaryAdvancesEvenOnEmptyLine() {
        let harness = TerminalModelHarness(rows: 3, cols: 8)

        harness.model.displayLocalInterruptPromptBoundary()

        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 0).codepoint, 0x20)
        XCTAssertEqual(harness.model.cursor.row, 1)
        XCTAssertEqual(harness.model.cursor.col, 0)
    }

    func testTerminalGridInsertBlanksAndDeleteCellsShiftContent() {
        let grid = TerminalGrid(rows: 1, cols: 5)
        for (col, codepoint) in [UInt32(65), 66, 67, 68, 69].enumerated() {
            grid.setCell(Cell(codepoint: codepoint, attributes: .default, width: 1, isWideContinuation: false),
                         at: 0, col: col)
        }

        grid.insertBlanks(row: 0, col: 1, count: 2)
        XCTAssertEqual(grid.rowCells(0).map(\.codepoint), [65, 0x20, 0x20, 66, 67])

        grid.deleteCells(row: 0, col: 2, count: 2)
        XCTAssertEqual(grid.rowCells(0).map(\.codepoint), [65, 0x20, 67, 0x20, 0x20])
    }

    func testTerminalModelOSC52WriteAndReadRoundTripsClipboardPayload() {
        let harness = TerminalModelHarness()
        var writtenClipboard: String?
        var responses: [String] = []
        harness.model.onClipboardWrite = { writtenClipboard = $0 }
        harness.model.onClipboardRead = { "hello" }
        harness.model.onResponse = { responses.append($0) }

        harness.feed("\u{1B}]52;c;5pel5pys\u{07}")
        XCTAssertEqual(writtenClipboard, "日本")

        harness.feed("\u{1B}]52;c;?\u{07}")
        XCTAssertEqual(responses.last, "\u{1B}]52;c;aGVsbG8=\u{07}")
    }

    func testTerminalModelOSC52IgnoresInvalidBase64Payload() {
        let harness = TerminalModelHarness()
        var writtenClipboard: String?
        harness.model.onClipboardWrite = { writtenClipboard = $0 }

        harness.feed("\u{1B}]52;c;%%%invalid%%%\u{07}")

        XCTAssertNil(writtenClipboard)
    }

    func testTerminalModelOSC52IgnoresPayloadWithoutSeparator() {
        let harness = TerminalModelHarness()
        var writtenClipboard: String?
        harness.model.onClipboardWrite = { writtenClipboard = $0 }

        harness.feed("\u{1B}]52;c\u{07}")

        XCTAssertNil(writtenClipboard)
    }

    func testTerminalModelOSC52WriteFallsBackToUTF8WhenCustomDecoderReturnsNil() {
        let harness = TerminalModelHarness()
        var writtenClipboard: String?
        harness.model.onClipboardWrite = { writtenClipboard = $0 }
        harness.model.decodeText = { _ in nil }

        harness.feed("\u{1B}]52;c;aGVsbG8=\u{07}")

        XCTAssertEqual(writtenClipboard, "hello")
    }

    func testTerminalModelOSC52WriteRejectsInvalidUTF8WhenNoDecoderSucceeds() {
        let harness = TerminalModelHarness()
        var writtenClipboard: String?
        harness.model.onClipboardWrite = { writtenClipboard = $0 }
        harness.model.decodeText = { _ in nil }

        harness.feed("\u{1B}]52;c;//79\u{07}")

        XCTAssertNil(writtenClipboard)
    }

    func testTerminalModelOSC52ReadWithoutClipboardDoesNotEmitResponse() {
        let harness = TerminalModelHarness()
        var responses: [String] = []
        harness.model.onClipboardRead = { nil }
        harness.model.onResponse = { responses.append($0) }

        harness.feed("\u{1B}]52;c;?\u{07}")

        XCTAssertTrue(responses.isEmpty)
    }

    func testTerminalModelOSC52ReadFallsBackToUTF8WhenCustomEncoderReturnsNil() {
        let harness = TerminalModelHarness()
        var responses: [String] = []
        harness.model.onClipboardRead = { "hello" }
        harness.model.encodeText = { _ in nil }
        harness.model.onResponse = { responses.append($0) }

        harness.feed("\u{1B}]52;c;?\u{07}")

        XCTAssertEqual(responses, ["\u{1B}]52;c;aGVsbG8=\u{07}"])
    }

    func testTerminalModelOSC52ReadPreservesRequestedClipboardTarget() {
        let harness = TerminalModelHarness()
        var responses: [String] = []
        harness.model.onClipboardRead = { "hello" }
        harness.model.onResponse = { responses.append($0) }

        harness.feed("\u{1B}]52;p;?\u{07}")

        XCTAssertEqual(responses, ["\u{1B}]52;p;aGVsbG8=\u{07}"])
    }

    func testTerminalModelShiftOutAndShiftInSwitchBetweenG1AndG0Charsets() {
        let harness = TerminalModelHarness(rows: 2, cols: 4)

        harness.feed("\u{1B})A") // G1 = British
        harness.feed(codepoints: [0x0E, 0x23, 0x0F, 0x23]) // SO '#' SI '#'

        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 0).codepoint, 0x00A3)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 1).codepoint, 0x23)
    }

    func testTerminalModelVT100CharsetDesignationSupportsDECSpecialGraphicsInG0AndG1() {
        let harness = TerminalModelHarness(rows: 2, cols: 4)

        harness.feed("\u{1B}(0")
        harness.feed("q")
        harness.feed("\u{1B}(B")
        harness.feed("\u{1B})0")
        harness.feed(codepoints: [0x0E])
        harness.feed("x")

        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 0).codepoint, 0x2500)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 1).codepoint, 0x2502)
    }

    func testTerminalModelOSC0UpdatesTitle() {
        let harness = TerminalModelHarness()
        var titles: [String] = []
        harness.model.onTitleChange = { titles.append($0) }

        harness.feed("\u{1B}]0;Build Log\u{07}")

        XCTAssertEqual(harness.model.title, "Build Log")
        XCTAssertEqual(titles.last, "Build Log")
    }

    func testTerminalModelDoesNotRespondToTitleReportQuery() {
        let harness = TerminalModelHarness()
        var responses: [String] = []
        harness.model.onResponse = { responses.append($0) }

        harness.feed("\u{1B}[21t")

        XCTAssertTrue(responses.isEmpty)
    }

    func testTerminalModelDoesNotRespondToIconTitleReportQuery() {
        let harness = TerminalModelHarness()
        var responses: [String] = []
        harness.model.onResponse = { responses.append($0) }

        harness.feed("\u{1B}[20t")

        XCTAssertTrue(responses.isEmpty)
    }

    func testTerminalModelDoesNotRespondToWindowTitleReportQuery() {
        let harness = TerminalModelHarness()
        var responses: [String] = []
        harness.model.onResponse = { responses.append($0) }

        harness.feed("\u{1B}[19t")

        XCTAssertTrue(responses.isEmpty)
    }

    func testTerminalModelResetClearsModesAndAlternateScreen() {
        let harness = TerminalModelHarness(rows: 3, cols: 4)
        harness.feed("A")
        harness.feed("\u{1B}[?2004h\u{1B}[?1003h\u{1B}[?1006h\u{1B}[?1004h")
        harness.feed("\u{1B}[?1049h")

        XCTAssertTrue(harness.model.isAlternateScreen)
        XCTAssertTrue(harness.model.bracketedPasteMode)
        XCTAssertEqual(harness.model.mouseReporting, .anyEvent)
        XCTAssertEqual(harness.model.mouseProtocol, .sgr)
        XCTAssertTrue(harness.model.focusTrackingEnabled)

        harness.feed("\u{1B}c")

        XCTAssertFalse(harness.model.isAlternateScreen)
        XCTAssertFalse(harness.model.bracketedPasteMode)
        XCTAssertEqual(harness.model.mouseReporting, .none)
        XCTAssertEqual(harness.model.mouseProtocol, .x10)
        XCTAssertFalse(harness.model.focusTrackingEnabled)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 0).codepoint, 0x20)
    }

    func testTerminalModelResetDoesNotClearExistingWindowTitle() {
        let harness = TerminalModelHarness(rows: 3, cols: 4)
        harness.feed("\u{1B}]0;Existing\u{07}")

        harness.feed("\u{1B}c")

        XCTAssertEqual(harness.model.title, "Existing")
    }

    func testTerminalModelResetRestoresDefaultTabStops() {
        let harness = TerminalModelHarness(rows: 1, cols: 20)
        harness.feed("\u{1B}[10G")
        harness.feed("\u{1B}H")
        harness.feed("\r")
        harness.feed("\u{1B}c")
        harness.feed(codepoints: [0x09])

        XCTAssertEqual(harness.model.cursor.col, 8)
    }

    func testTerminalModelOriginModeMovesCursorBetweenScrollRegionAndHome() {
        let harness = TerminalModelHarness(rows: 5, cols: 5)
        harness.feed("\u{1B}[2;4r")
        harness.feed("\u{1B}[?6h")
        XCTAssertEqual(harness.model.cursor.row, 1)
        XCTAssertEqual(harness.model.cursor.col, 0)

        harness.feed("\u{1B}[?6l")
        XCTAssertEqual(harness.model.cursor.row, 0)
        XCTAssertEqual(harness.model.cursor.col, 0)
    }

    func testTerminalModelAlternateScreenRestoresSavedCursorAndPrimaryBuffer() {
        let harness = TerminalModelHarness(rows: 3, cols: 4)
        harness.feed("AB")
        harness.feed("\u{1B}[2;3H")
        let savedRow = harness.model.cursor.row
        let savedCol = harness.model.cursor.col

        harness.feed("\u{1B}[?1049h")
        harness.feed("Z")
        XCTAssertEqual(harness.model.grid.cell(at: savedRow, col: savedCol).codepoint, 90)

        harness.feed("\u{1B}[?1049l")

        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 0).codepoint, 65)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 1).codepoint, 66)
        XCTAssertEqual(harness.model.cursor.row, savedRow)
        XCTAssertEqual(harness.model.cursor.col, savedCol)
    }

    func testTerminalModelTitleSanitizesControlCharactersAndRateLimitsUpdates() {
        let harness = TerminalModelHarness()
        var titles: [String] = []
        harness.model.onTitleChange = { titles.append($0) }

        for index in 0..<10 {
            harness.feed("\u{1B}]2;safe\u{202E}title\(index)\u{07}")
        }

        XCTAssertEqual(titles.count, 8)
        XCTAssertEqual(titles.first, "safetitle0")
        XCTAssertEqual(harness.model.title, "safetitle7")
    }

    func testTerminalModelTitleSanitizeStripsDELByte() {
        let harness = TerminalModelHarness()

        harness.feed("\u{1B}]2;before\u{7F}after\u{07}")

        XCTAssertEqual(harness.model.title, "beforeafter")
    }

    func testTerminalModelTitleSanitizeStripsBidiOverrideCharacters() {
        let harness = TerminalModelHarness()

        harness.feed("\u{1B}]2;safe\u{202E}title\u{202C}\u{07}")

        XCTAssertEqual(harness.model.title, "safetitle")
    }

    func testTerminalModelTitleSanitizeStripsEmbeddedC0Controls() {
        let harness = TerminalModelHarness()

        harness.feed("\u{1B}]2;tab\tline\nbreak\u{07}")

        XCTAssertEqual(harness.model.title, "tablinebreak")
    }

    func testTerminalModelTitleSanitizeTruncatesToMaximumLength() {
        let harness = TerminalModelHarness()
        let longTitle = String(repeating: "a", count: 400)

        harness.feed("\u{1B}]2;\(longTitle)\u{07}")

        XCTAssertEqual(harness.model.title.count, 256)
        XCTAssertEqual(harness.model.title, String(repeating: "a", count: 256))
    }

    func testTerminalModelTitleSanitizeStripsBidiIsolates() {
        let harness = TerminalModelHarness()

        harness.feed("\u{1B}]2;safe\u{2066}title\u{2069}\u{07}")

        XCTAssertEqual(harness.model.title, "safetitle")
    }

    func testTerminalModelTitleSanitizeStripsC1ControlBytes() {
        let harness = TerminalModelHarness()

        harness.feed("\u{1B}]2;safe\u{85}title\u{07}")

        XCTAssertEqual(harness.model.title, "safetitle")
    }

    func testTerminalModelTitleSanitizeAllowsEmptyResultAndStillNotifies() {
        let harness = TerminalModelHarness()
        var titles: [String] = []
        harness.model.onTitleChange = { titles.append($0) }

        harness.feed("\u{1B}]2;\u{202E}\u{2066}\u{7F}\u{07}")

        XCTAssertEqual(harness.model.title, "")
        XCTAssertEqual(titles, [""])
    }

    func testTerminalModelFocusTrackingAndDSREmitExpectedResponses() {
        let harness = TerminalModelHarness(rows: 4, cols: 5)
        var responses: [String] = []
        harness.model.onResponse = { responses.append($0) }

        harness.feed("\u{1B}[?1004h")
        harness.model.notifyFocusChanged(true)
        harness.model.notifyFocusChanged(false)

        harness.feed("\u{1B}[3;4H")
        harness.feed("\u{1B}[6n")
        harness.feed("\u{1B}[5n")

        XCTAssertEqual(responses, ["\u{1B}[I", "\u{1B}[O", "\u{1B}[3;4R", "\u{1B}[0n"])
    }

    func testTerminalModelDSRCursorPositionUsesOneBasedCoordinates() {
        let harness = TerminalModelHarness(rows: 4, cols: 5)
        var responses: [String] = []
        harness.model.onResponse = { responses.append($0) }

        harness.feed("\u{1B}[4;5H")
        harness.feed("\u{1B}[6n")

        XCTAssertEqual(responses, ["\u{1B}[4;5R"])
    }

    func testTerminalModelDSRStatusReportReturnsOKResponse() {
        let harness = TerminalModelHarness()
        var responses: [String] = []
        harness.model.onResponse = { responses.append($0) }

        harness.feed("\u{1B}[5n")

        XCTAssertEqual(responses, ["\u{1B}[0n"])
    }

    func testTerminalModelUnknownDSRDoesNotEmitResponse() {
        let harness = TerminalModelHarness()
        var responses: [String] = []
        harness.model.onResponse = { responses.append($0) }

        harness.feed("\u{1B}[7n")

        XCTAssertTrue(responses.isEmpty)
    }

    func testTerminalModelPrimaryDeviceAttributesAdvertiseVT420ClassTerminal() {
        let harness = TerminalModelHarness()
        var responses: [String] = []
        harness.model.onResponse = { responses.append($0) }

        harness.feed("\u{1B}[c")

        XCTAssertEqual(responses, ["\u{1B}[?64;1;2;6;8;9;15c"])
    }

    func testTerminalModelSecondaryDeviceAttributesEmitFirmwareStyleResponse() {
        let harness = TerminalModelHarness()
        var responses: [String] = []
        harness.model.onResponse = { responses.append($0) }

        harness.feed("\u{1B}[>c")

        XCTAssertEqual(responses, ["\u{1B}[>41;0;0c"])
    }

    func testTerminalModelRequestTerminalParametersReturnsValidReportsForZeroAndOne() {
        let harness = TerminalModelHarness()
        var responses: [String] = []
        harness.model.onResponse = { responses.append($0) }

        harness.feed("\u{1B}[0x")
        harness.feed("\u{1B}[1x")

        XCTAssertEqual(
            responses,
            [
                "\u{1B}[2;1;1;120;120;1;0x",
                "\u{1B}[3;1;1;120;120;1;0x",
            ]
        )
    }

    func testTerminalModelENQEmitsAnswerbackMessage() {
        let harness = TerminalModelHarness()
        var responses: [String] = []
        harness.model.onResponse = { responses.append($0) }

        harness.feed(codepoints: [0x05])

        XCTAssertEqual(responses, ["pterm"])
    }

    func testTerminalModelLineFeedNewLineModeSetAndReset() {
        let harness = TerminalModelHarness()

        harness.feed("\u{1B}[20h")
        XCTAssertTrue(harness.model.newLineMode)

        harness.feed("\u{1B}[20l")
        XCTAssertFalse(harness.model.newLineMode)
    }

    func testTerminalModelPendingUpdateModeEmitsCallbackAndResets() {
        let harness = TerminalModelHarness()
        var changes: [Bool] = []
        harness.model.onPendingUpdateModeChange = { changes.append($0) }

        harness.feed("\u{1B}[?2026h")
        harness.feed("\u{1B}[?2026l")
        harness.feed("\u{1B}[?2026h")
        harness.model.reset()

        XCTAssertEqual(changes, [true, false, true, false])
        XCTAssertFalse(harness.model.pendingUpdateModeEnabled)
    }

    func testTerminalModelLongUnsupportedOSCChunkedAcrossFeedsIsIgnored() {
        let harness = TerminalModelHarness(rows: 2, cols: 16)
        harness.feed("A")
        harness.feed("\u{1B}]6;")
        harness.feed(String(repeating: "x", count: 1024))
        harness.feed("\u{7}B")

        let row = String(
            harness.model.grid.rowCells(0)
                .map { Character(UnicodeScalar($0.codepoint) ?? " ") }
        ).trimmingCharacters(in: .whitespaces)

        XCTAssertEqual(harness.model.title, "")
        XCTAssertEqual(row, "AB")
    }

    func testTerminalModelNotifyFocusChangedWithoutTrackingDoesNotEmitResponse() {
        let harness = TerminalModelHarness()
        var responses: [String] = []
        harness.model.onResponse = { responses.append($0) }

        harness.model.notifyFocusChanged(true)
        harness.model.notifyFocusChanged(false)

        XCTAssertTrue(responses.isEmpty)
    }

    func testTerminalModelDecSpecialGraphicsTranslationMapsLineDrawingCharacters() {
        let harness = TerminalModelHarness(rows: 1, cols: 2)

        harness.feed("\u{1B})0")
        harness.feed(codepoints: [0x0E]) // SO -> invoke G1
        harness.feed("q")
        harness.feed(codepoints: [0x0F]) // SI -> back to G0

        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 0).codepoint, 0x2500)
    }

    func testTerminalModelMouseReportingHonorsPolicy() {
        let harness = TerminalModelHarness()
        harness.model.mouseReportingPolicy = { mode, isAlternateScreen in
            mode == .buttonEvent && isAlternateScreen
        }

        harness.feed("\u{1B}[?1003h")
        XCTAssertEqual(harness.model.mouseReporting, .none)

        harness.feed("\u{1B}[?1049h")
        harness.feed("\u{1B}[?1002h")
        XCTAssertEqual(harness.model.mouseReporting, .buttonEvent)

        harness.feed("\u{1B}[?1049l")
        XCTAssertEqual(harness.model.mouseReporting, .none)
    }

    func testTerminalModelWindowManipulationDispatchesResizeRequests() {
        let harness = TerminalModelHarness()
        var characterResize: (Int, Int)?
        var pixelResize: (Int, Int)?
        harness.model.onWindowResizeRequest = { characterResize = ($0, $1) }
        harness.model.onWindowPixelResizeRequest = { pixelResize = ($0, $1) }

        harness.feed("\u{1B}[8;24;80t")
        harness.feed("\u{1B}[4;600;800t")

        XCTAssertEqual(characterResize?.0, 24)
        XCTAssertEqual(characterResize?.1, 80)
        XCTAssertEqual(pixelResize?.0, 800)
        XCTAssertEqual(pixelResize?.1, 600)
    }

    func testTerminalModelResettingSGRMouseModeRestoresX10Protocol() {
        let harness = TerminalModelHarness()
        harness.feed("\u{1B}[?1006h")
        XCTAssertEqual(harness.model.mouseProtocol, .sgr)

        harness.feed("\u{1B}[?1006l")
        XCTAssertEqual(harness.model.mouseProtocol, .x10)
    }

    func testTerminalModelApplicationCursorKeysModeToggles() {
        let harness = TerminalModelHarness()

        harness.feed("\u{1B}[?1h")
        XCTAssertTrue(harness.model.applicationCursorKeys)

        harness.feed("\u{1B}[?1l")
        XCTAssertFalse(harness.model.applicationCursorKeys)
    }

    func testTerminalModelBracketedPasteModeToggles() {
        let harness = TerminalModelHarness()

        harness.feed("\u{1B}[?2004h")
        XCTAssertTrue(harness.model.bracketedPasteMode)

        harness.feed("\u{1B}[?2004l")
        XCTAssertFalse(harness.model.bracketedPasteMode)
    }

    func testTerminalModelAlternateScreen1047SwitchesBuffersWithoutCursorSaveRestore() {
        let harness = TerminalModelHarness(rows: 2, cols: 3)
        harness.feed("ABC")
        harness.feed("\u{1B}[2;2H")
        let originalRow = harness.model.cursor.row

        harness.feed("\u{1B}[?1047h")
        harness.feed("Z")
        XCTAssertTrue(harness.model.isAlternateScreen)
        XCTAssertEqual(harness.model.grid.cell(at: 1, col: 1).codepoint, 90)

        harness.feed("\u{1B}[?1047l")
        XCTAssertFalse(harness.model.isAlternateScreen)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 0).codepoint, 65)
        XCTAssertEqual(harness.model.cursor.row, originalRow)
        XCTAssertEqual(harness.model.cursor.col, 2)
    }

    func testTerminalModelEraseScrollbackInvokesCallbackAndClearsGrid() {
        let harness = TerminalModelHarness(rows: 2, cols: 3)
        var cleared = 0
        harness.model.onClearScrollback = { cleared += 1 }
        harness.feed("ABCDEF")

        harness.feed("\u{1B}[3J")

        XCTAssertEqual(cleared, 1)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 0).codepoint, 0x20)
        XCTAssertEqual(harness.model.grid.cell(at: 1, col: 2).codepoint, 0x20)
    }

    func testTerminalModelEraseDisplayModeThreeClearsEntireGrid() {
        let harness = TerminalModelHarness(rows: 2, cols: 3)
        harness.feed("ABCDEF")

        harness.feed("\u{1B}[3J")

        for row in 0..<2 {
            for col in 0..<3 {
                XCTAssertEqual(harness.model.grid.cell(at: row, col: col).codepoint, 0x20)
            }
        }
    }

    func testTerminalModelEraseLineModeTwoClearsEntireLine() {
        let harness = TerminalModelHarness(rows: 2, cols: 3)
        harness.feed("ABCDEF")
        harness.feed("\u{1B}[2;2H")

        harness.feed("\u{1B}[2K")

        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 0).codepoint, 65)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 1).codepoint, 66)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 2).codepoint, 67)
        XCTAssertEqual(harness.model.grid.cell(at: 1, col: 0).codepoint, 0x20)
        XCTAssertEqual(harness.model.grid.cell(at: 1, col: 1).codepoint, 0x20)
        XCTAssertEqual(harness.model.grid.cell(at: 1, col: 2).codepoint, 0x20)
    }

    func testTerminalModelOSC2UpdatesTitleLikeOSC0() {
        let harness = TerminalModelHarness()
        var titles: [String] = []
        harness.model.onTitleChange = { titles.append($0) }

        harness.feed("\u{1B}]2;Deploy Logs\u{07}")

        XCTAssertEqual(harness.model.title, "Deploy Logs")
        XCTAssertEqual(titles, ["Deploy Logs"])
    }

    func testTerminalModelOSC2CanClearExistingTitleToEmptyString() {
        let harness = TerminalModelHarness()
        var titles: [String] = []
        harness.model.onTitleChange = { titles.append($0) }
        harness.feed("\u{1B}]2;Existing\u{07}")

        harness.feed("\u{1B}]2;\u{07}")

        XCTAssertEqual(harness.model.title, "")
        XCTAssertEqual(titles.suffix(2), ["Existing", ""])
    }

    func testTerminalModelOSC7UpdatesWorkingDirectoryFromFileURL() {
        let harness = TerminalModelHarness()
        var workingDirectories: [String] = []
        harness.model.onWorkingDirectoryChange = { workingDirectories.append($0) }

        harness.feed("\u{1B}]7;file:///tmp/project\u{07}")

        XCTAssertEqual(workingDirectories, ["/tmp/project"])
    }

    func testTerminalModelOSC1DoesNotChangeWindowTitle() {
        let harness = TerminalModelHarness()
        var titles: [String] = []
        harness.model.onTitleChange = { titles.append($0) }

        harness.feed("\u{1B}]1;Icon Only\u{07}")

        XCTAssertEqual(harness.model.title, "")
        XCTAssertTrue(titles.isEmpty)
    }

    func testTerminalModelOSC1PreservesExistingWindowTitle() {
        let harness = TerminalModelHarness()
        var titles: [String] = []
        harness.model.onTitleChange = { titles.append($0) }
        harness.feed("\u{1B}]2;Existing\u{07}")

        harness.feed("\u{1B}]1;Icon Only\u{07}")

        XCTAssertEqual(harness.model.title, "Existing")
        XCTAssertEqual(titles, ["Existing"])
    }

    func testTerminalModelOSC0CanClearExistingTitleToEmptyString() {
        let harness = TerminalModelHarness()
        var titles: [String] = []
        harness.model.onTitleChange = { titles.append($0) }
        harness.feed("\u{1B}]0;Existing\u{07}")

        harness.feed("\u{1B}]0;\u{07}")

        XCTAssertEqual(harness.model.title, "")
        XCTAssertEqual(titles.suffix(2), ["Existing", ""])
    }

    func testTerminalModelMalformedOSCIgnoredWithoutChangingTitle() {
        let harness = TerminalModelHarness()
        harness.feed("\u{1B}]0;Existing\u{07}")
        var titles: [String] = []
        harness.model.onTitleChange = { titles.append($0) }

        harness.feed("\u{1B}]2Deploy Logs\u{07}")

        XCTAssertEqual(harness.model.title, "Existing")
        XCTAssertTrue(titles.isEmpty)
    }

    func testTerminalModelNonNumericOSCIgnoredWithoutChangingTitle() {
        let harness = TerminalModelHarness()
        harness.feed("\u{1B}]0;Existing\u{07}")
        var titles: [String] = []
        harness.model.onTitleChange = { titles.append($0) }

        harness.feed("\u{1B}]foo;ignored\u{07}")

        XCTAssertEqual(harness.model.title, "Existing")
        XCTAssertTrue(titles.isEmpty)
    }

    func testTerminalModelUnsupportedNumericOSCIgnoredWithoutChangingTitleOrClipboard() {
        let harness = TerminalModelHarness()
        harness.feed("\u{1B}]0;Existing\u{07}")
        var titles: [String] = []
        var clipboardWrites: [String] = []
        harness.model.onTitleChange = { titles.append($0) }
        harness.model.onClipboardWrite = { clipboardWrites.append($0) }

        harness.feed("\u{1B}]4;1;rgb:ffff/0000/0000\u{07}")

        XCTAssertEqual(harness.model.title, "Existing")
        XCTAssertTrue(titles.isEmpty)
        XCTAssertTrue(clipboardWrites.isEmpty)
    }

    func testTerminalModelLongUnsupportedOSCIgnoredWithoutChangingTitle() {
        let harness = TerminalModelHarness()
        harness.feed("\u{1B}]0;Existing\u{07}")

        let payload = String(repeating: "x", count: 16_384)
        harness.feed("\u{1B}]6;\(payload)\u{07}")

        XCTAssertEqual(harness.model.title, "Existing")
    }

    func testTerminalModelSGRUpdatesAttributesAndResetRestoresDefaults() {
        let harness = TerminalModelHarness()

        harness.feed("\u{1B}[1;3;4;38;2;1;2;3;48;5;42mX")
        let styled = harness.model.grid.cell(at: 0, col: 0)
        XCTAssertTrue(styled.attributes.bold)
        XCTAssertTrue(styled.attributes.italic)
        XCTAssertTrue(styled.attributes.underline)
        XCTAssertEqual(styled.attributes.foreground, .rgb(1, 2, 3))
        XCTAssertEqual(styled.attributes.background, .indexed(42))

        harness.feed("\u{1B}[0mY")
        let reset = harness.model.grid.cell(at: 0, col: 1)
        XCTAssertEqual(reset.attributes, .default)
    }

    func testTerminalModelSaveRestoreCursorRoundTripsPositionAndAttributes() {
        let harness = TerminalModelHarness(rows: 3, cols: 4)
        harness.feed("\u{1B}[2;2H")
        harness.feed("\u{1B}[31m")
        harness.feed("\u{1B}7")
        harness.feed("\u{1B}[1;1H")
        harness.feed("\u{1B}[0m")

        harness.feed("\u{1B}8")
        harness.feed("Q")

        let cell = harness.model.grid.cell(at: 1, col: 1)
        XCTAssertEqual(cell.codepoint, 81)
        XCTAssertEqual(cell.attributes.foreground, .indexed(1))
    }

    func testTerminalModelNELMovesCursorToNextLineColumnZero() {
        let harness = TerminalModelHarness(rows: 3, cols: 4)
        harness.feed("AB")

        harness.feed("\u{1B}E")
        harness.feed("Z")

        XCTAssertEqual(harness.model.cursor.row, 1)
        XCTAssertEqual(harness.model.grid.cell(at: 1, col: 0).codepoint, 90)
    }

    func testTerminalModelNELAtBottomScrollsAndResetsColumn() {
        let harness = TerminalModelHarness(rows: 2, cols: 3)
        harness.feed("ABCDEF")

        harness.feed("\u{1B}E")
        harness.feed("Z")

        XCTAssertEqual(harness.model.cursor.row, 1)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 0).codepoint, 68)
        XCTAssertEqual(harness.model.grid.cell(at: 1, col: 0).codepoint, 90)
    }

    func testTerminalModelINDMovesCursorDownWithoutResettingColumn() {
        let harness = TerminalModelHarness(rows: 3, cols: 4)
        harness.feed("AB")

        harness.feed("\u{1B}D")
        harness.feed("Z")

        XCTAssertEqual(harness.model.cursor.row, 1)
        XCTAssertEqual(harness.model.grid.cell(at: 1, col: 2).codepoint, 90)
    }

    func testTerminalModelINDAtBottomScrollsWithoutResettingColumn() {
        let harness = TerminalModelHarness(rows: 2, cols: 3)
        harness.feed("ABCDEF")

        harness.feed("\u{1B}D")
        harness.feed("Z")

        XCTAssertEqual(harness.model.cursor.row, 1)
        XCTAssertEqual(harness.model.cursor.col, 2)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 0).codepoint, 68)
        XCTAssertEqual(harness.model.grid.cell(at: 1, col: 2).codepoint, 90)
    }

    func testTerminalModelLineFeedAtBottomScrollsOutWrappedState() {
        let harness = TerminalModelHarness(rows: 2, cols: 2)
        var scrolled: [([Cell], Bool)] = []
        harness.model.onScrollOut = { row in
            scrolled.append((row.cells, row.isWrapped))
        }

        harness.feed("ABCD")
        harness.feed("E")

        XCTAssertEqual(scrolled.count, 1)
        XCTAssertEqual(scrolled[0].0.first?.codepoint, 65)
        XCTAssertFalse(scrolled[0].1)
        XCTAssertEqual(harness.model.grid.cell(at: 1, col: 0).codepoint, 69)
    }

    func testTerminalModelReverseIndexAtScrollTopScrollsRegionDown() {
        let harness = TerminalModelHarness(rows: 3, cols: 1)
        harness.feed("ABC")
        harness.feed("\u{1B}[1;3r")
        harness.feed("\u{1B}[1;1H")

        harness.feed("\u{1B}M")

        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 0).codepoint, 0x20)
        XCTAssertEqual(harness.model.grid.cell(at: 1, col: 0).codepoint, 65)
        XCTAssertEqual(harness.model.grid.cell(at: 2, col: 0).codepoint, 66)
    }

    func testTerminalModelReverseIndexAboveScrollTopOnlyMovesCursorUp() {
        let harness = TerminalModelHarness(rows: 3, cols: 3)
        harness.feed("\u{1B}[1;3r")
        harness.feed("\u{1B}[3;2H")

        harness.feed("\u{1B}M")

        XCTAssertEqual(harness.model.cursor.row, 1)
        XCTAssertEqual(harness.model.cursor.col, 1)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 0).codepoint, 0x20)
    }

    func testTerminalModelReverseIndexAtScrollTopPreservesColumn() {
        let harness = TerminalModelHarness(rows: 3, cols: 3)
        harness.feed("ABCDEF")
        harness.feed("\u{1B}[1;3r")
        harness.feed("\u{1B}[1;3H")

        harness.feed("\u{1B}M")

        XCTAssertEqual(harness.model.cursor.row, 0)
        XCTAssertEqual(harness.model.cursor.col, 2)
    }

    func testTerminalModelInsertAndDeleteLinesOperateWithinScrollRegion() {
        let harness = TerminalModelHarness(rows: 4, cols: 1)
        harness.feed("ABCD")
        harness.feed("\u{1B}[2;4r")
        harness.feed("\u{1B}[2;1H")

        harness.feed("\u{1B}[1L")
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 0).codepoint, 65)
        XCTAssertEqual(harness.model.grid.cell(at: 1, col: 0).codepoint, 0x20)
        XCTAssertEqual(harness.model.grid.cell(at: 2, col: 0).codepoint, 66)

        harness.feed("\u{1B}[1M")
        XCTAssertEqual(harness.model.grid.cell(at: 1, col: 0).codepoint, 66)
    }

    func testTerminalModelSUAndSDScrollConfiguredRegionOnly() {
        let harness = TerminalModelHarness(rows: 4, cols: 1)
        harness.feed("ABCD")
        harness.feed("\u{1B}[2;4r")

        harness.feed("\u{1B}[1S")
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 0).codepoint, 65)
        XCTAssertEqual(harness.model.grid.cell(at: 1, col: 0).codepoint, 67)

        harness.feed("\u{1B}[1T")
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 0).codepoint, 65)
        XCTAssertEqual(harness.model.grid.cell(at: 1, col: 0).codepoint, 0x20)
    }

    func testTerminalModelTabStopsAdvanceAndCanBeSetExplicitly() {
        let harness = TerminalModelHarness(rows: 1, cols: 20)
        harness.feed("A")
        harness.feed(codepoints: [0x09]) // HT -> default tab stop at 8
        XCTAssertEqual(harness.model.cursor.col, 8)

        harness.feed("\u{1B}H") // HTS at col 8
        harness.feed("\r")
        harness.feed(codepoints: [0x09])
        XCTAssertEqual(harness.model.cursor.col, 8)
    }

    func testTerminalModelTabWithoutFurtherStopClampsToLastColumn() {
        let harness = TerminalModelHarness(rows: 1, cols: 10)
        harness.feed("\u{1B}[10G")

        harness.feed(codepoints: [0x09])

        XCTAssertEqual(harness.model.cursor.col, 9)
    }

    func testTerminalModelResizeReinitializesDefaultTabStops() {
        let harness = TerminalModelHarness(rows: 1, cols: 12)
        harness.model.resize(newRows: 1, newCols: 24)

        harness.feed("A")
        harness.feed(codepoints: [0x09])

        XCTAssertEqual(harness.model.cursor.col, 8)

        harness.feed(codepoints: [0x09])
        XCTAssertEqual(harness.model.cursor.col, 16)
    }

    func testTerminalModelTabStopsWorkAcrossBitsetWordBoundary() {
        let harness = TerminalModelHarness(rows: 1, cols: 80)
        harness.feed("\u{1B}[65G") // move to col 64 (1-based)

        harness.feed(codepoints: [0x09]) // default next tab stop at 72
        XCTAssertEqual(harness.model.cursor.col, 72)

        harness.feed("\u{1B}[66G") // move to col 65
        harness.feed("\u{1B}H") // HTS at col 65
        harness.feed("\r")

        harness.feed(codepoints: [0x09])
        XCTAssertEqual(harness.model.cursor.col, 8)

        harness.feed(codepoints: [0x09])
        XCTAssertEqual(harness.model.cursor.col, 16)

        harness.feed("\u{1B}[65G")
        harness.feed(codepoints: [0x09])
        XCTAssertEqual(harness.model.cursor.col, 65)
    }

    func testTerminalModelCHTAdvancesAcrossTabStopsAndClampsAtRightEdge() {
        let harness = TerminalModelHarness(rows: 1, cols: 20)
        harness.feed("A")

        harness.feed("\u{1B}[2I")
        XCTAssertEqual(harness.model.cursor.col, 16)

        harness.feed("\u{1B}[10I")
        XCTAssertEqual(harness.model.cursor.col, 19)
    }

    func testTerminalModelCBTMovesBackwardAcrossTabStops() {
        let harness = TerminalModelHarness(rows: 1, cols: 40)
        harness.feed("\u{1B}[33G")
        XCTAssertEqual(harness.model.cursor.col, 32)

        harness.feed("\u{1B}[1Z")
        XCTAssertEqual(harness.model.cursor.col, 24)

        harness.feed("\u{1B}[2Z")
        XCTAssertEqual(harness.model.cursor.col, 8)

        harness.feed("\u{1B}[99Z")
        XCTAssertEqual(harness.model.cursor.col, 0)
    }

    func testTerminalModelHPAAndHPASetAbsoluteColumn() {
        let harness = TerminalModelHarness(rows: 1, cols: 20)

        harness.feed("\u{1B}[10`")
        XCTAssertEqual(harness.model.cursor.col, 9)

        harness.feed("\u{1B}[3G")
        XCTAssertEqual(harness.model.cursor.col, 2)
    }

    func testTerminalModelHPRAndVPRAdvanceRelativeWithoutWrapping() {
        let harness = TerminalModelHarness(rows: 6, cols: 10)

        harness.feed("\u{1B}[3a")
        XCTAssertEqual(harness.model.cursor.col, 3)

        harness.feed("\u{1B}[4e")
        XCTAssertEqual(harness.model.cursor.row, 4)

        harness.feed("\u{1B}[99a")
        XCTAssertEqual(harness.model.cursor.col, 9)

        harness.feed("\u{1B}[99e")
        XCTAssertEqual(harness.model.cursor.row, 5)
    }

    func testTerminalModelTabClearsPendingWrapWithoutAdvancingRow() {
        let harness = TerminalModelHarness(rows: 2, cols: 3)
        harness.feed("ABC")

        XCTAssertTrue(harness.model.cursor.pendingWrap)

        harness.feed(codepoints: [0x09])
        harness.feed("Z")

        XCTAssertEqual(harness.model.cursor.row, 0)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 2).codepoint, 90)
    }

    func testTerminalModelTBCClearsCurrentAndAllTabStops() {
        let harness = TerminalModelHarness(rows: 1, cols: 20)
        harness.feed("\u{1B}[9G")
        harness.feed("\u{1B}[0g")
        harness.feed("\r")
        harness.feed(codepoints: [0x09])
        XCTAssertEqual(harness.model.cursor.col, 16)

        harness.feed("\u{1B}[3g")
        harness.feed("\r")
        harness.feed(codepoints: [0x09])
        XCTAssertEqual(harness.model.cursor.col, 19)
    }

    func testTerminalModelInsertModeShiftsExistingCellsWhilePrinting() {
        let harness = TerminalModelHarness(rows: 1, cols: 6)
        harness.feed("AB")
        harness.feed("\r")

        harness.feed("\u{1B}[4h")
        harness.feed("Z")
        harness.feed("\u{1B}[4l")

        XCTAssertEqual(harness.model.grid.rowCells(0).map(\.codepoint), [90, 65, 66, 0x20, 0x20, 0x20])
    }

    func testTerminalModelSLAndSRShiftCurrentRow() {
        let harness = TerminalModelHarness(rows: 1, cols: 6)
        harness.feed("ABCDE")
        harness.feed("\r")

        harness.feed("\u{1B}[2 A")
        XCTAssertEqual(harness.model.grid.rowCells(0).map(\.codepoint), [0x20, 0x20, 65, 66, 67, 68])

        harness.feed("\u{1B}[3 @")
        XCTAssertEqual(harness.model.grid.rowCells(0).map(\.codepoint), [66, 67, 68, 0x20, 0x20, 0x20])
    }

    func testTerminalModelDECSCAProtectedCellsSurviveEDAndEL() {
        let harness = TerminalModelHarness(rows: 2, cols: 6)
        harness.feed("\u{1B}[1\"q")
        harness.feed("ABC")
        harness.feed("\u{1B}[0\"q")
        harness.feed("DEF")

        harness.feed("\r")
        harness.feed("\u{1B}[2K")

        XCTAssertEqual(harness.model.grid.rowCells(0).map(\.codepoint), [65, 66, 67, 0x20, 0x20, 0x20])

        harness.feed("\u{1B}[2J")
        XCTAssertEqual(harness.model.grid.rowCells(0).map(\.codepoint), [65, 66, 67, 0x20, 0x20, 0x20])
    }

    func testTerminalModelDECSEDAndDECSELPreserveProtectedCells() {
        let harness = TerminalModelHarness(rows: 1, cols: 6)
        harness.feed("\u{1B}[1\"q")
        harness.feed("ABC")
        harness.feed("\u{1B}[0\"q")
        harness.feed("DEF")

        harness.feed("\r")
        harness.feed("\u{1B}[?2K")
        XCTAssertEqual(harness.model.grid.rowCells(0).map(\.codepoint), [65, 66, 67, 0x20, 0x20, 0x20])

        harness.feed("\u{1B}[?2J")
        XCTAssertEqual(harness.model.grid.rowCells(0).map(\.codepoint), [65, 66, 67, 0x20, 0x20, 0x20])
    }

    func testTerminalModelSPAEPAMarksProtectedAreaWithoutChangingBaseProtectionAttribute() {
        let harness = TerminalModelHarness(rows: 1, cols: 6)

        harness.feed("\u{1B}V")
        harness.feed("ABC")
        harness.feed("\u{1B}W")
        harness.feed("DEF")
        harness.feed("\r")
        harness.feed("\u{1B}[2K")

        XCTAssertEqual(harness.model.grid.rowCells(0).map(\.codepoint), [65, 66, 67, 0x20, 0x20, 0x20])
        XCTAssertFalse(harness.model.grid.cell(at: 0, col: 3).attributes.decProtected)
    }

    func testTerminalModelProtectedCellsSurviveICHAndDCH() {
        let harness = TerminalModelHarness(rows: 1, cols: 8)
        harness.feed("##")
        harness.feed("\u{1B}[1\"q")
        harness.feed("****")
        harness.feed("\u{1B}[0\"q")
        harness.feed("##")

        harness.feed("\r")
        harness.feed("\u{1B}[3C")
        harness.feed("\u{1B}[2@")
        XCTAssertEqual(Array(harness.model.grid.rowCells(0)[2...5]).map(\.codepoint), [42, 42, 42, 42])
        XCTAssertTrue(Array(harness.model.grid.rowCells(0)[2...5]).allSatisfy(\.attributes.decProtected))

        harness.feed("\r")
        harness.feed("\u{1B}[1P")
        XCTAssertEqual(Array(harness.model.grid.rowCells(0)[2...5]).map(\.codepoint), [42, 42, 42, 42])
        XCTAssertTrue(Array(harness.model.grid.rowCells(0)[2...5]).allSatisfy(\.attributes.decProtected))
    }

    func testTerminalModelCarriageReturnMovesCursorToColumnZero() {
        let harness = TerminalModelHarness(rows: 1, cols: 4)
        harness.feed("AB")

        harness.feed(codepoints: [0x0D])
        harness.feed("Z")

        XCTAssertEqual(harness.model.cursor.col, 1)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 0).codepoint, 90)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 1).codepoint, 66)
    }

    func testTerminalModelCarriageReturnClearsPendingWrapWithoutScrolling() {
        let harness = TerminalModelHarness(rows: 2, cols: 3)
        harness.feed("ABC")

        XCTAssertTrue(harness.model.cursor.pendingWrap)

        harness.feed(codepoints: [0x0D])
        harness.feed("Z")

        XCTAssertEqual(harness.model.cursor.row, 0)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 0).codepoint, 90)
        XCTAssertEqual(harness.model.grid.cell(at: 1, col: 0).codepoint, 0x20)
    }

    func testTerminalModelCarriageReturnAtColumnZeroLeavesCursorAndCellsUnchanged() {
        let harness = TerminalModelHarness(rows: 1, cols: 4)

        harness.feed(codepoints: [0x0D])

        XCTAssertEqual(harness.model.cursor.col, 0)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 0).codepoint, 0x20)
    }

    func testTerminalModelBackspaceMovesCursorLeftWithoutErasingCell() {
        let harness = TerminalModelHarness(rows: 1, cols: 4)
        harness.feed("AB")

        harness.feed(codepoints: [0x08])
        harness.feed("Z")

        XCTAssertEqual(harness.model.cursor.col, 2)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 0).codepoint, 65)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 1).codepoint, 90)
    }

    func testTerminalModelBackspaceAtColumnZeroDoesNothing() {
        let harness = TerminalModelHarness(rows: 1, cols: 4)

        harness.feed(codepoints: [0x08])

        XCTAssertEqual(harness.model.cursor.col, 0)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 0).codepoint, 0x20)
    }

    func testTerminalModelLineFeedVerticalTabAndFormFeedBehaveIdentically() {
        let lineFeed = TerminalModelHarness(rows: 3, cols: 4)
        lineFeed.feed("AB")
        lineFeed.feed(codepoints: [0x0A])
        lineFeed.feed("X")

        let verticalTab = TerminalModelHarness(rows: 3, cols: 4)
        verticalTab.feed("AB")
        verticalTab.feed(codepoints: [0x0B])
        verticalTab.feed("X")

        let formFeed = TerminalModelHarness(rows: 3, cols: 4)
        formFeed.feed("AB")
        formFeed.feed(codepoints: [0x0C])
        formFeed.feed("X")

        for harness in [lineFeed, verticalTab, formFeed] {
            XCTAssertEqual(harness.model.cursor.row, 1)
            XCTAssertEqual(harness.model.cursor.col, 3)
            XCTAssertEqual(harness.model.grid.cell(at: 1, col: 2).codepoint, 88)
        }
    }

    func testTerminalModelCursorVisibilityAndShapeModesAreApplied() {
        let harness = TerminalModelHarness()
        harness.feed("\u{1B}[?25l")
        XCTAssertFalse(harness.model.cursor.visible)

        harness.feed("\u{1B}[5 q")
        XCTAssertEqual(harness.model.cursor.shape, .bar)
        XCTAssertTrue(harness.model.cursor.blinking)

        harness.feed("\u{1B}[?25h")
        harness.feed("\u{1B}[6 q")
        XCTAssertTrue(harness.model.cursor.visible)
        XCTAssertEqual(harness.model.cursor.shape, .bar)
        XCTAssertFalse(harness.model.cursor.blinking)
    }

    func testTerminalModelREPRepeatsPreviousPrintableCharacter() {
        let harness = TerminalModelHarness(rows: 1, cols: 5)
        harness.feed("A")
        harness.feed("\u{1B}[3b")

        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 0).codepoint, 65)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 1).codepoint, 65)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 2).codepoint, 65)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 3).codepoint, 65)
    }

    func testTerminalModelREPAtColumnZeroPreservesBlankCells() {
        let harness = TerminalModelHarness(rows: 1, cols: 4)
        harness.feed("\u{1B}[5b")

        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 0).codepoint, 0x20)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 1).codepoint, 0x20)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 2).codepoint, 0x20)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 3).codepoint, 0x20)
        XCTAssertEqual(harness.model.cursor.row, 0)
        XCTAssertEqual(harness.model.cursor.col, 3)
    }

    func testTerminalModelVT220DSRKeyboardStatusReportsNorthAmericanReadyLK201() {
        let harness = TerminalModelHarness()
        var responses: [String] = []
        harness.model.onResponse = { responses.append($0) }

        harness.feed("\u{1B}[?26n")

        XCTAssertEqual(responses, ["\u{1B}[?27;1;0;0n"])
    }

    func testTerminalModelVT320DSRLocatorStatusReportsNoLocator() {
        let harness = TerminalModelHarness()
        var responses: [String] = []
        harness.model.onResponse = { responses.append($0) }

        harness.feed("\u{1B}[?55n")

        XCTAssertEqual(responses, ["\u{1B}[?53n"])
    }

    func testTerminalModelVT320DSRIdentifyLocatorReportsCannotIdentify() {
        let harness = TerminalModelHarness()
        var responses: [String] = []
        harness.model.onResponse = { responses.append($0) }

        harness.feed("\u{1B}[?56n")

        XCTAssertEqual(responses, ["\u{1B}[?57;0n"])
    }

    func testTerminalModelVT220DSRPrinterStatusReportsNoPrinter() {
        let harness = TerminalModelHarness()
        var responses: [String] = []
        harness.model.onResponse = { responses.append($0) }

        harness.feed("\u{1B}[?15n")

        XCTAssertEqual(responses, ["\u{1B}[?13n"])
    }

    func testTerminalModelVT220DSRUDKStatusReportsUnlocked() {
        let harness = TerminalModelHarness()
        var responses: [String] = []
        harness.model.onResponse = { responses.append($0) }

        harness.feed("\u{1B}[?25n")

        XCTAssertEqual(responses, ["\u{1B}[?20n"])
    }

    func testTerminalModelVT420DSRDataIntegrityReportsNoErrors() {
        let harness = TerminalModelHarness()
        var responses: [String] = []
        harness.model.onResponse = { responses.append($0) }

        harness.feed("\u{1B}[?75n")

        XCTAssertEqual(responses, ["\u{1B}[?70n"])
    }

    func testTerminalModelVT420DSRMultiSessionReportsNotReady() {
        let harness = TerminalModelHarness()
        var responses: [String] = []
        harness.model.onResponse = { responses.append($0) }

        harness.feed("\u{1B}[?85n")

        XCTAssertEqual(responses, ["\u{1B}[?83n"])
    }

    func testTerminalModelVT420DSRMacroSpaceReportsSupportedResponse() {
        let harness = TerminalModelHarness()
        var responses: [String] = []
        harness.model.onResponse = { responses.append($0) }

        harness.feed("\u{1B}[?62n")

        XCTAssertEqual(responses, ["\u{1B}[0*{"])
    }

    func testTerminalModelVT420DECXCPRIncludesPageNumber() {
        let harness = TerminalModelHarness(rows: 4, cols: 8)
        harness.model.cursor.row = 2
        harness.model.cursor.col = 3
        var responses: [String] = []
        harness.model.onResponse = { responses.append($0) }

        harness.feed("\u{1B}[?6n")

        XCTAssertEqual(responses, ["\u{1B}[?3;4;1R"])
    }

    func testTerminalModelS8C1TEmits8BitCSIResponsesUntilS7C1TResetsMode() {
        let harness = TerminalModelHarness()
        var responseData: [Data] = []
        harness.model.onResponseData = { responseData.append($0) }

        harness.feed("\u{1B} G")
        harness.feed("\u{1B}[6n")
        harness.feed("\u{1B} F")
        harness.feed("\u{1B}[6n")

        XCTAssertEqual(responseData.count, 2)
        XCTAssertEqual(Array(responseData[0]), [0x9B, 0x31, 0x3B, 0x31, 0x52])
        XCTAssertEqual(Array(responseData[1]), Array(Data("\u{1B}[1;1R".utf8)))
    }

    func testTerminalModelDECSTRSoftResetPreservesScreenButRestoresModes() {
        let harness = TerminalModelHarness(rows: 3, cols: 8)
        var responseData: [Data] = []
        harness.model.onResponseData = { responseData.append($0) }

        harness.feed("ABC")
        harness.feed("\u{1B} G")
        harness.feed("\u{1B}[4h")
        harness.feed("\u{1B}[?1004h")

        harness.feed("\u{1B}[!p")
        harness.feed("\u{1B}[6n")

        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 0).codepoint, 0x41)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 1).codepoint, 0x42)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 2).codepoint, 0x43)
        XCTAssertFalse(harness.model.focusTrackingEnabled)
        XCTAssertEqual(Array(responseData.last ?? Data()), Array(Data("\u{1B}[1;1R".utf8)))
    }

    func testTerminalModelVT220LockingShiftsInvokeG2AndG3IntoGL() {
        let harness = TerminalModelHarness(rows: 2, cols: 8)

        harness.feed("\u{1B}*0") // G2 = DEC Special Graphics
        harness.feed("\u{1B}+A") // G3 = British
        harness.feed("\u{1B}nq") // LS2, then print q
        harness.feed("\u{0F}q")  // SI back to G0 ASCII
        harness.feed("\u{1B}o#") // LS3, then print #
        harness.feed("\u{0F}#")  // SI back to G0 ASCII

        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 0).codepoint, 0x2500)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 1).codepoint, 0x71)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 2).codepoint, 0x00A3)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 3).codepoint, 0x23)
    }

    func testTerminalModelVT220SingleShiftsApplyToOneGraphicCharacterOnly() {
        let harness = TerminalModelHarness(rows: 2, cols: 8)

        harness.feed("\u{1B}*0") // G2 = DEC Special Graphics
        harness.feed("\u{1B}+A") // G3 = British
        harness.feed("\u{1B}Nqq") // SS2 for first q only
        harness.feed("\u{1B}O##") // SS3 for first # only

        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 0).codepoint, 0x2500)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 1).codepoint, 0x71)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 2).codepoint, 0x00A3)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 3).codepoint, 0x23)
    }

    func testTerminalModelDECRQSSReturnsValidDCSStatusStringResponse() {
        let harness = TerminalModelHarness(rows: 3, cols: 8)
        var responses: [Data] = []
        harness.model.onResponseData = { responses.append($0) }

        harness.feed("\u{1B}P$q\"q\u{1B}\\")

        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(String(data: responses[0], encoding: .isoLatin1), "\u{1B}P1$r\"q\u{1B}\\")
    }

    func testTerminalModelTertiaryDeviceAttributesReturnsHexUnitID() {
        let harness = TerminalModelHarness(rows: 3, cols: 8)
        var responses: [Data] = []
        harness.model.onResponseData = { responses.append($0) }

        harness.feed("\u{1B}[=c")

        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(String(data: responses[0], encoding: .isoLatin1), "\u{1B}P!|00000000\u{1B}\\")
    }

    func testTerminalModelDECRQSSReportsCurrentCursorStyle() {
        let harness = TerminalModelHarness(rows: 3, cols: 8)
        var responses: [Data] = []
        harness.model.onResponseData = { responses.append($0) }

        harness.feed("\u{1B}[6 q")
        harness.feed("\u{1B}P$q q\u{1B}\\")

        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(String(data: responses[0], encoding: .isoLatin1), "\u{1B}P1$r6 q\u{1B}\\")
    }

    func testTerminalModelDECSNLSRequestsResizeAndDECRQSSReportsConfiguredLineCount() {
        let harness = TerminalModelHarness(rows: 24, cols: 80)
        var responses: [Data] = []
        var characterResize: (Int, Int)?
        harness.model.onResponseData = { responses.append($0) }
        harness.model.onWindowResizeRequest = { characterResize = ($0, $1) }

        harness.feed("\u{1B}[48*|")
        harness.feed("\u{1B}P$q*|\u{1B}\\")

        XCTAssertEqual(characterResize?.0, 48)
        XCTAssertEqual(characterResize?.1, 80)
        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(String(data: responses[0], encoding: .isoLatin1), "\u{1B}P1$r48*|\u{1B}\\")
    }

    func testTerminalModelDECRQPSRAndDECRQTSREmitDCSReports() {
        let harness = TerminalModelHarness(rows: 3, cols: 8)
        var responses: [Data] = []
        harness.model.onResponseData = { responses.append($0) }

        harness.feed("\u{1B}[1$u")
        harness.feed("\u{1B}[1$w")
        harness.feed("\u{1B}[2$w")

        XCTAssertEqual(responses.count, 3)
        let strings = responses.compactMap { String(data: $0, encoding: .isoLatin1) }
        XCTAssertEqual(strings[0], "\u{1B}P1$s\u{1B}\\")
        XCTAssertTrue(strings[1].hasPrefix("\u{1B}P1$u1;1;1;"), strings[1])
        XCTAssertTrue(strings[1].hasSuffix("BBBB\u{1B}\\"), strings[1])
        XCTAssertEqual(strings[2], "\u{1B}P2$u1\u{1B}\\")
    }

    func testTerminalModelDECSCLUpdatesOperatingLevelAndDECRQSSReflectsIt() {
        let harness = TerminalModelHarness(rows: 3, cols: 8)
        var responses: [Data] = []
        harness.model.onResponseData = { responses.append($0) }

        harness.feed("\u{1B}[64;0\"p")
        harness.feed("\u{1B}P$q\"p\u{1B}\\")
        harness.feed("\u{1B}[61;1\"p")
        harness.feed("\u{1B}P$q\"p\u{1B}\\")

        let strings = responses.compactMap { String(data: $0, encoding: .isoLatin1) }
        XCTAssertEqual(strings, [
            "\u{0090}1$r64;0\"p\u{009C}",
            "\u{1B}P1$r61;1\"p\u{1B}\\",
        ])
    }

    func testTerminalModelDECRQMReportsKnownAndUnknownModes() {
        let harness = TerminalModelHarness(rows: 3, cols: 8)
        var responses: [Data] = []
        harness.model.onResponseData = { responses.append($0) }

        harness.feed("\u{1B}[4h")
        harness.feed("\u{1B}[20$p")
        harness.feed("\u{1B}[4$p")
        harness.feed("\u{1B}[?7$p")
        harness.feed("\u{1B}[?999$p")

        let strings = responses.compactMap { String(data: $0, encoding: .isoLatin1) }
        XCTAssertEqual(strings, [
            "\u{1B}[20;2$y",
            "\u{1B}[4;1$y",
            "\u{1B}[?7;1$y",
            "\u{1B}[?999;0$y",
        ])
    }

    func testTerminalModelREPCapsRepeatCountToScreenArea() {
        let capped = TerminalModelHarness(rows: 2, cols: 3)
        capped.feed("A")
        capped.feed("\u{1B}[6b")

        let excessive = TerminalModelHarness(rows: 2, cols: 3)
        excessive.feed("A")
        excessive.feed("\u{1B}[999b")

        for row in 0..<2 {
            for col in 0..<3 {
                XCTAssertEqual(
                    excessive.model.grid.cell(at: row, col: col).codepoint,
                    capped.model.grid.cell(at: row, col: col).codepoint
                )
            }
        }
        XCTAssertEqual(excessive.model.cursor.row, capped.model.cursor.row)
        XCTAssertEqual(excessive.model.cursor.col, capped.model.cursor.col)
    }

    func testTerminalModelAutoWrapDisabledOverwritesLastColumnWithoutWrapping() {
        let harness = TerminalModelHarness(rows: 2, cols: 3)
        harness.feed("\u{1B}[?7l")
        harness.feed("ABCD")

        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 0).codepoint, 65)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 1).codepoint, 66)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 2).codepoint, 68)
        XCTAssertEqual(harness.model.grid.cell(at: 1, col: 0).codepoint, 0x20)
    }

    func testTerminalModelEraseLineModesRespectCursorPosition() {
        let harness = TerminalModelHarness(rows: 1, cols: 4)
        harness.feed("ABCD")
        harness.feed("\u{1B}[1;3H")
        harness.feed("\u{1B}[1K")

        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 0).codepoint, 0x20)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 1).codepoint, 0x20)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 2).codepoint, 0x20)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 3).codepoint, 68)
    }

    func testTerminalModelECHClearsRequestedCharacterCount() {
        let harness = TerminalModelHarness(rows: 1, cols: 5)
        harness.feed("ABCDE")
        harness.feed("\u{1B}[1;2H")

        harness.feed("\u{1B}[2X")

        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 0).codepoint, 65)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 1).codepoint, 0x20)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 2).codepoint, 0x20)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 3).codepoint, 68)
    }

    func testTerminalModelEraseDisplayModeZeroClearsFromCursorToEnd() {
        let harness = TerminalModelHarness(rows: 2, cols: 3)
        harness.feed("ABCDEF")
        harness.feed("\u{1B}[1;2H")

        harness.feed("\u{1B}[0J")

        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 0).codepoint, 65)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 1).codepoint, 0x20)
        XCTAssertEqual(harness.model.grid.cell(at: 1, col: 2).codepoint, 0x20)
    }

    func testTerminalModelEraseDisplayModeOneClearsFromStartToCursor() {
        let harness = TerminalModelHarness(rows: 2, cols: 3)
        harness.feed("ABCDEF")
        harness.feed("\u{1B}[2;2H")

        harness.feed("\u{1B}[1J")

        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 0).codepoint, 0x20)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 2).codepoint, 0x20)
        XCTAssertEqual(harness.model.grid.cell(at: 1, col: 0).codepoint, 0x20)
        XCTAssertEqual(harness.model.grid.cell(at: 1, col: 1).codepoint, 0x20)
        XCTAssertEqual(harness.model.grid.cell(at: 1, col: 2).codepoint, 70)
    }

    func testTerminalModelEraseDisplayModeTwoClearsEntireScreen() {
        let harness = TerminalModelHarness(rows: 2, cols: 3)
        harness.feed("ABCDEF")

        harness.feed("\u{1B}[2J")

        for row in 0..<2 {
            for col in 0..<3 {
                XCTAssertEqual(harness.model.grid.cell(at: row, col: col).codepoint, 0x20)
            }
        }
    }

    func testTerminalModelWindowManipulationClampsZeroPixelResizeDimensionsToOne() {
        let harness = TerminalModelHarness()
        var pixelResize: (Int, Int)?
        harness.model.onWindowPixelResizeRequest = { pixelResize = ($0, $1) }

        harness.feed("\u{1B}[4;0;800t")
        harness.feed("\u{1B}[4;600;0t")

        XCTAssertEqual(pixelResize?.0, 1)
        XCTAssertEqual(pixelResize?.1, 600)
    }

    func testTerminalModelWindowManipulationClampsBothZeroPixelResizeDimensionsToOne() {
        let harness = TerminalModelHarness()
        var pixelResize: (Int, Int)?
        harness.model.onWindowPixelResizeRequest = { pixelResize = ($0, $1) }

        harness.feed("\u{1B}[4;0;0t")

        XCTAssertEqual(pixelResize?.0, 1)
        XCTAssertEqual(pixelResize?.1, 1)
    }

    func testTerminalModelWindowManipulationTreatsZeroCharacterResizeDimensionsAsCurrentSize() {
        let harness = TerminalModelHarness()
        var characterResize: (Int, Int)?
        harness.model.onWindowResizeRequest = { characterResize = ($0, $1) }

        harness.feed("\u{1B}[8;0;0t")

        XCTAssertEqual(characterResize?.0, harness.model.rows)
        XCTAssertEqual(characterResize?.1, harness.model.cols)
    }

    func testTerminalModelUnsupportedWindowManipulationDoesNotInvokeCallbacks() {
        let harness = TerminalModelHarness()
        var characterResize: (Int, Int)?
        var pixelResize: (Int, Int)?
        harness.model.onWindowResizeRequest = { characterResize = ($0, $1) }
        harness.model.onWindowPixelResizeRequest = { pixelResize = ($0, $1) }

        harness.feed("\u{1B}[9;24;80t")

        XCTAssertNil(characterResize)
        XCTAssertNil(pixelResize)
    }
}

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
        harness.model.onScrollOut = { scrolled.append(($0, $1)) }

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

    func testTerminalModelTabClearsPendingWrapWithoutAdvancingRow() {
        let harness = TerminalModelHarness(rows: 2, cols: 3)
        harness.feed("ABC")

        XCTAssertTrue(harness.model.cursor.pendingWrap)

        harness.feed(codepoints: [0x09])
        harness.feed("Z")

        XCTAssertEqual(harness.model.cursor.row, 0)
        XCTAssertEqual(harness.model.grid.cell(at: 0, col: 2).codepoint, 90)
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

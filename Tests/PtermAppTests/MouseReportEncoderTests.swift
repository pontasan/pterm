import XCTest
@testable import PtermApp

final class MouseReportEncoderTests: XCTestCase {
    private func sgr(_ button: Int, _ column: Int, _ row: Int, _ phase: MouseReportEncoder.Phase) -> String? {
        MouseReportEncoder.encode(button: button, column: column, row: row, phase: phase, protocolMode: .sgr)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    private func legacy(_ button: Int, _ column: Int, _ row: Int, _ phase: MouseReportEncoder.Phase,
                        _ protocolMode: TerminalModel.MouseProtocol = .x10) -> [UInt8]? {
        MouseReportEncoder.encode(button: button, column: column, row: row, phase: phase, protocolMode: protocolMode)
            .map { Array($0) }
    }

    func testSGRReportsUseOneBasedDecimalCoordinatesAndPressReleaseSuffix() {
        XCTAssertEqual(sgr(0, 0, 0, .press), "\u{1B}[<0;1;1M")
        XCTAssertEqual(sgr(2, 9, 4, .press), "\u{1B}[<2;10;5M")
        XCTAssertEqual(sgr(0, 9, 4, .release), "\u{1B}[<0;10;5m")
        XCTAssertEqual(sgr(0, 299, 99, .drag), "\u{1B}[<32;300;100M")
        XCTAssertEqual(sgr(64, 3, 2, .wheel), "\u{1B}[<64;4;3M")
        XCTAssertEqual(sgr(65, 3, 2, .wheel), "\u{1B}[<65;4;3M")
    }

    func testMotionWithoutButtonReportsButtonThreeNotLeftDrag() {
        // xterm: motion with no button held is Cb = 3 + 32. Reporting 32 would
        // tell the application that the left button is being dragged.
        XCTAssertEqual(sgr(MouseReportEncoder.noButton, 4, 1, .motion), "\u{1B}[<35;5;2M")
        XCTAssertEqual(legacy(MouseReportEncoder.noButton, 0, 0, .motion), [0x1B, 0x5B, 0x4D, 32 + 35, 33, 33])
    }

    func testLegacyReportsEncodeThirtyTwoPlusOneBasedPosition() {
        // Upper-left cell is reported as "!" "!" (32 + 1).
        XCTAssertEqual(legacy(0, 0, 0, .press), [0x1B, 0x5B, 0x4D, 32, 33, 33])
        XCTAssertEqual(legacy(0, 9, 4, .release), [0x1B, 0x5B, 0x4D, 32 + 3, 32 + 10, 32 + 5])
        XCTAssertEqual(legacy(1, 9, 4, .drag), [0x1B, 0x5B, 0x4D, 32 + 33, 32 + 10, 32 + 5])
    }

    func testLegacyReportsKeepHighBytesRawAndDropUnrepresentablePositions() {
        // Column 200 must be the raw byte 232, not a UTF-8 replacement sequence.
        XCTAssertEqual(legacy(0, 199, 0, .press), [0x1B, 0x5B, 0x4D, 32, 232, 33])
        XCTAssertEqual(legacy(0, 222, 222, .press), [0x1B, 0x5B, 0x4D, 32, 255, 255])
        XCTAssertNil(legacy(0, 223, 0, .press))
        XCTAssertNil(legacy(0, 0, 223, .press))
    }

    func testUTF8ReportsEncodeLargeCoordinatesAsUTF8Scalars() {
        XCTAssertEqual(legacy(0, 0, 0, .press, .utf8), [0x1B, 0x5B, 0x4D, 32, 33, 33])
        // 32 + 200 = 232 = U+00E8 -> C3 A8
        XCTAssertEqual(legacy(0, 199, 0, .press, .utf8), [0x1B, 0x5B, 0x4D, 32, 0xC3, 0xA8, 33])
        XCTAssertNotNil(legacy(0, 2014, 0, .press, .utf8))
        XCTAssertNil(legacy(0, 2015, 0, .press, .utf8))
    }

    func testDECSETMouseModesMapToXtermTrackingLevels() {
        let harness = TerminalModelHarness(rows: 3, cols: 4)
        harness.feed("\u{1B}[?9h")
        XCTAssertEqual(harness.model.mouseReporting, .x10)
        harness.feed("\u{1B}[?9l\u{1B}[?1000h")
        XCTAssertEqual(harness.model.mouseReporting, .normal, "1000 is VT200 tracking and must report releases")
        harness.feed("\u{1B}[?1000l")
        XCTAssertEqual(harness.model.mouseReporting, .none)
    }
}

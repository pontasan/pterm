import XCTest
@testable import PtermApp

final class AppScrollOutputPaceTests: XCTestCase {
    func testFastOutputSettlesWithinOneFrame() {
        var pace = AppScrollOutputPace()
        for read in 0..<20 { pace.noteRead(atUptime: Double(read) * 0.0005) }
        XCTAssertEqual(pace.settlePause, 1.0 / 60.0, accuracy: 0.0001)
    }

    func testGapsWithinARepaintOverASlowLinkLengthenThePause() {
        var pace = AppScrollOutputPace()
        for read in 0..<5 { pace.noteRead(atUptime: Double(read) * 0.03) }
        XCTAssertGreaterThan(pace.settlePause, 0.03, "A gap this size must not end a repaint.")
    }

    func testAPauseBetweenRepaintsIsNotTakenForAGapWithinOne() {
        var pace = AppScrollOutputPace()
        pace.noteRead(atUptime: 0)
        pace.noteRead(atUptime: 5)
        XCTAssertEqual(pace.settlePause, 1.0 / 60.0, accuracy: 0.0001)
    }

    /// Found with a real application: repaints a tenth of a second apart stretched the pause to
    /// two tenths, so frames were no longer seen settled and selections lost their text.
    func testTheTimeBetweenMarkedRepaintsIsNotTakenForAGapWithinOne() {
        var pace = AppScrollOutputPace()
        for repaint in 0..<10 {
            let start = Double(repaint) * 0.1
            pace.noteRead(atUptime: start)
            pace.noteRead(atUptime: start + 0.001)
            pace.noteRepaintBoundary()
        }
        XCTAssertEqual(pace.settlePause, 1.0 / 60.0, accuracy: 0.0001)
    }

    func testGapsWithinAMarkedRepaintStillCount() {
        var pace = AppScrollOutputPace()
        pace.noteRepaintBoundary()
        pace.noteRead(atUptime: 1)
        pace.noteRead(atUptime: 1.03)
        pace.noteRepaintBoundary()
        pace.noteRead(atUptime: 2)
        XCTAssertGreaterThan(pace.settlePause, 0.03, "The slow link was measured, and stays known.")
    }

    func testTheLinkGettingFastAgainShortensThePause() {
        var pace = AppScrollOutputPace()
        pace.noteRead(atUptime: 0)
        pace.noteRead(atUptime: 0.1)
        let slow = pace.settlePause
        var now = 0.1
        for _ in 0..<500 {
            now += 0.0005
            pace.noteRead(atUptime: now)
        }
        XCTAssertLessThan(pace.settlePause, slow)
    }
}

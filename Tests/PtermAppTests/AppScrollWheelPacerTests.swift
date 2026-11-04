import XCTest
@testable import PtermApp

final class AppScrollWheelPacerTests: XCTestCase {
    private let up = MouseReportEncoder.wheelUpButton
    private let down = MouseReportEncoder.wheelDownButton

    func testOnlyOneBatchIsOutstanding() {
        var pacer = AppScrollWheelPacer()
        XCTAssertEqual(pacer.add(button: up, count: 5), 1)
        XCTAssertTrue(pacer.isAwaitingRepaint)
        XCTAssertEqual(pacer.add(button: up, count: 5), 0)
        XCTAssertEqual(pacer.pendingCount, 9)
    }

    func testBatchGrowsWhileStepsAreSmallAndShrinksWhenLarge() {
        var pacer = AppScrollWheelPacer()
        _ = pacer.add(button: up, count: 8)
        XCTAssertEqual(pacer.repaintSettled(rowsMoved: 1, movingRows: 40, latency: 0.01), 2, "Small step: double.")
        XCTAssertEqual(pacer.repaintSettled(rowsMoved: 15, movingRows: 40, latency: 0.01), 2, "Middling step: keep.")
        XCTAssertEqual(pacer.repaintSettled(rowsMoved: 25, movingRows: 40, latency: 0.01), 1, "Over half the screen: halve.")
    }

    func testBatchNeverGoesBelowOne() {
        var pacer = AppScrollWheelPacer()
        _ = pacer.add(button: up, count: 4)
        XCTAssertEqual(pacer.repaintSettled(rowsMoved: 100, movingRows: 40, latency: 0.01), 1)
    }

    func testRepaintThatMovedNothingDoesNotReleaseTheNextBatch() {
        var pacer = AppScrollWheelPacer()
        _ = pacer.add(button: up, count: 4)
        XCTAssertEqual(pacer.repaintSettled(rowsMoved: 0, movingRows: 40, latency: 0.01), 0)
        XCTAssertTrue(pacer.isAwaitingRepaint, "A status line changing is not the answer to the wheel.")
    }

    func testTimeoutKeepsDeliveringWhenTheApplicationDoesNotAnswer() {
        var pacer = AppScrollWheelPacer()
        _ = pacer.add(button: up, count: 3)
        XCTAssertEqual(pacer.responseTimedOut(), 1)
        XCTAssertEqual(pacer.responseTimedOut(), 1)
        XCTAssertEqual(pacer.responseTimedOut(), 0)
        XCTAssertFalse(pacer.isAwaitingRepaint)
    }

    func testReversingCancelsWhatTheOldDirectionHadNotDelivered() {
        var pacer = AppScrollWheelPacer()
        _ = pacer.add(button: up, count: 10)
        XCTAssertEqual(pacer.add(button: down, count: 2), 0, "The batch in flight still gets its answer first.")
        XCTAssertEqual(pacer.pendingCount, 2)
    }

    func testWhatWasLearnedDoesNotOutlastTheBurst() {
        var pacer = AppScrollWheelPacer()
        _ = pacer.add(button: up, count: 3)
        XCTAssertEqual(pacer.repaintSettled(rowsMoved: 1, movingRows: 40, latency: 0.01), 2)
        XCTAssertEqual(pacer.repaintSettled(rowsMoved: 1, movingRows: 40, latency: 0.01), 0)
        XCTAssertEqual(pacer.add(button: up, count: 8), 1, "A new burst starts carefully again.")
    }

    func testQueueIsBoundedSoTheScreenStopsSoonAfterTheUser() {
        var pacer = AppScrollWheelPacer()
        _ = pacer.add(button: up, count: 2)
        _ = pacer.repaintSettled(rowsMoved: 1, movingRows: 40, latency: 0.02)
        _ = pacer.add(button: up, count: 100_000)
        let queued = pacer.pendingCount
        XCTAssertLessThan(queued, 100, "Far less than a fling can produce.")
        XCTAssertGreaterThan(queued, 0)
    }

    func testResponseTimeoutFollowsTheMeasuredLatency() {
        var pacer = AppScrollWheelPacer()
        let initial = pacer.responseTimeout
        _ = pacer.add(button: up, count: 4)
        _ = pacer.repaintSettled(rowsMoved: 1, movingRows: 40, latency: 1)
        XCTAssertGreaterThan(pacer.responseTimeout, initial, "A slow application must not be mistaken for an ignoring one.")
    }

    func testTakeAllEmptiesTheQueue() {
        var pacer = AppScrollWheelPacer()
        _ = pacer.add(button: up, count: 5)
        XCTAssertEqual(pacer.takeAll(), 4)
        XCTAssertEqual(pacer.pendingCount, 0)
        XCTAssertFalse(pacer.isAwaitingRepaint)
    }
}

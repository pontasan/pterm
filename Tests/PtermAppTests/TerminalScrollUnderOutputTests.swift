import AppKit
import Metal
import MetalKit
import XCTest
@testable import PtermApp

/// Scrolling through history while the terminal keeps printing.
///
/// Every test drives the real wheel path of a `TerminalScrollView` hosted in a window and
/// judges the result by the rows the next frame would show.
@MainActor
final class TerminalScrollUnderOutputTests: XCTestCase {
    private struct Fixture {
        let window: NSWindow
        let scrollView: TerminalScrollView
        let controller: TerminalController
        let cellHeight: CGFloat

        var view: TerminalView { scrollView.terminalView }

        /// Global index of the first row the next frame shows.
        var firstVisibleRow: Int { controller.captureRenderSnapshot().firstVisibleGlobalRow }
        var scrollOffset: Int { controller.withViewport { _, _, offset in offset } }
        var scrollbackRows: Int { controller.withViewport { _, scrollback, _ in scrollback.rowCount } }

        func print(lines: Int, from start: Int = 0) {
            var text = ""
            for index in start..<(start + lines) {
                text += "line \(index)\r\n"
            }
            controller.debugProcessPTYOutputForTesting(Data(text.utf8))
        }

        func wheel(lines: Int, phase: Int64 = 0, momentumPhase: Int64 = 0) throws {
            try wheel(pixels: Int32((CGFloat(lines) * cellHeight).rounded()), phase: phase, momentumPhase: momentumPhase)
        }

        func wheel(pixels: Int32, phase: Int64 = 0, momentumPhase: Int64 = 0) throws {
            let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                              wheel1: pixels, wheel2: 0, wheel3: 0))
            // A synthesized event takes on the keys held on the real keyboard.
            event.flags = []
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
            let point = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
            event.location = window.convertPoint(toScreen: view.convert(point, to: nil))
            view.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
        }
    }

    private func makeFixture(scrollbackCapacity: Int = 1 << 22) throws -> Fixture {
        guard let renderer = MetalRenderer(scaleFactor: 2.0) else {
            throw XCTSkip("Metal unavailable")
        }
        let controller = TerminalController(
            rows: 10,
            cols: 40,
            termEnv: "xterm-256color",
            textEncoding: .utf8,
            scrollbackInitialCapacity: scrollbackCapacity,
            scrollbackMaxCapacity: scrollbackCapacity,
            fontName: "Menlo",
            fontSize: 13
        )
        let scrollView = TerminalScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 300), renderer: renderer)
        scrollView.terminalView.terminalController = controller
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
        window.contentView?.addSubview(scrollView)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(scrollView.terminalView)
        scrollView.refreshViewportLayoutAndTerminalSize()
        return Fixture(window: window, scrollView: scrollView, controller: controller,
                       cellHeight: renderer.glyphAtlas.cellHeight)
    }

    /// Output that arrives between two frames must not undo the reader's position: the wheel
    /// moves by what the fingers did, measured from the rows that were on screen.
    func testWheelMovesFromVisibleRowsWhenOutputArrivedSinceLastFrame() throws {
        let f = try makeFixture()
        f.print(lines: 500)
        f.scrollView.syncScroller()
        drainMainQueue(testCase: self)

        try f.wheel(lines: 20)
        XCTAssertEqual(f.scrollOffset, 20)
        let before = f.firstVisibleRow

        // No frame is drawn between this output and the next wheel event.
        f.print(lines: 300, from: 500)
        XCTAssertEqual(f.firstVisibleRow, before, "Output must leave a scrolled-back view where it is.")

        try f.wheel(lines: 1)
        XCTAssertEqual(f.firstVisibleRow, before - 1)
    }

    /// A frame captured before a wheel event must not put the view back where it was.
    func testWheelProgressSurvivesScrollerSyncOfAnEarlierFrame() throws {
        let f = try makeFixture()
        f.print(lines: 500)
        f.scrollView.syncScroller()
        drainMainQueue(testCase: self)
        let bottom = f.firstVisibleRow

        // The frame records the scroll state it drew and syncs the scroller on a later turn.
        f.view.draw(in: f.view)
        try f.wheel(lines: 5)
        drainMainQueue(testCase: self)
        XCTAssertEqual(f.firstVisibleRow, bottom - 5)

        try f.wheel(lines: 5)
        XCTAssertEqual(f.firstVisibleRow, bottom - 10)
    }

    /// Sustained output with interleaved wheel events: each event moves exactly its own
    /// distance, whatever the terminal printed in between.
    func testWheelStaysExactThroughSustainedOutput() throws {
        let f = try makeFixture()
        f.print(lines: 400)
        f.scrollView.syncScroller()
        drainMainQueue(testCase: self)

        try f.wheel(lines: 30)
        var expected = f.firstVisibleRow
        var printed = 400
        for step in 0..<40 {
            f.print(lines: 37, from: printed)
            printed += 37
            if step % 3 == 0 {
                f.view.draw(in: f.view)
            }
            if step % 5 == 0 {
                drainMainQueue(testCase: self)
            }
            let lines = step % 4 == 3 ? -2 : 3
            try f.wheel(lines: lines)
            expected -= lines
            XCTAssertEqual(f.firstVisibleRow, expected, "step \(step)")
        }
    }

    /// Scrolling back down to the newest output resumes following it.
    func testWheelDownToBottomResumesFollowingOutput() throws {
        let f = try makeFixture()
        f.print(lines: 200)
        f.scrollView.syncScroller()
        drainMainQueue(testCase: self)

        try f.wheel(lines: 8)
        f.print(lines: 50, from: 200)
        XCTAssertEqual(f.scrollOffset, 58, "The rows being read stay put while output arrives.")
        try f.wheel(lines: -58)
        XCTAssertEqual(f.scrollOffset, 0)
        f.print(lines: 50, from: 250)
        XCTAssertEqual(f.scrollOffset, 0)
    }

    /// The scroller reflects the position the wheel reached.
    func testScrollerKnobFollowsWheelPosition() throws {
        let f = try makeFixture()
        f.print(lines: 500)
        f.scrollView.syncScroller()
        drainMainQueue(testCase: self)
        let bottomY = f.scrollView.contentView.bounds.origin.y

        try f.wheel(lines: 100)
        f.scrollView.syncScroller()
        let scrolledY = f.scrollView.contentView.bounds.origin.y
        // The knob travels the same share of its track as the view does of the history.
        XCTAssertEqual((bottomY - scrolledY) / bottomY, 100 / CGFloat(f.scrollbackRows), accuracy: 0.0001)
        XCTAssertEqual(f.scrollOffset, 100)
    }

    /// A trackpad gesture, from the first touch through momentum, scrolls by its own events and
    /// returns at once: the wheel never enters a gesture-tracking loop of the scroll view.
    func testTrackpadGestureWithMomentumScrollsByItsEvents() throws {
        let f = try makeFixture()
        f.print(lines: 500)
        f.scrollView.syncScroller()
        drainMainQueue(testCase: self)
        let bottom = f.firstVisibleRow

        try f.wheel(lines: 1, phase: 1)                         // began
        for _ in 0..<6 { try f.wheel(lines: 2, phase: 2) }      // changed
        try f.wheel(pixels: 0, phase: 4)                        // ended
        try f.wheel(lines: 3, momentumPhase: 1)                 // momentum began
        for _ in 0..<4 { try f.wheel(lines: 1, momentumPhase: 2) }
        try f.wheel(pixels: 0, momentumPhase: 3)                // momentum ended

        XCTAssertEqual(f.firstVisibleRow, bottom - 20)
    }

    /// Wheel events over the scroller or another overlay of the scroll view scroll the terminal too.
    func testWheelDeliveredToScrollViewScrollsTerminal() throws {
        let f = try makeFixture()
        f.print(lines: 500)
        f.scrollView.syncScroller()
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                          wheel1: Int32((4 * f.cellHeight).rounded()), wheel2: 0, wheel3: 0))
        event.flags = []
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        f.scrollView.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
        XCTAssertEqual(f.scrollOffset, 4)
    }

    /// The wheel stops at both ends of the history and nowhere else.
    func testWheelClampsAtHistoryEnds() throws {
        let f = try makeFixture()
        f.print(lines: 60)
        f.scrollView.syncScroller()
        let history = f.scrollbackRows
        XCTAssertGreaterThan(history, 0)

        try f.wheel(lines: 10_000)
        XCTAssertEqual(f.scrollOffset, history)
        XCTAssertEqual(f.scrollView.contentView.bounds.origin.y, 0, accuracy: 0.5)
        try f.wheel(lines: -10_000)
        XCTAssertEqual(f.scrollOffset, 0)
    }

    /// Dragging the knob still positions the terminal, and the position survives a sync.
    func testScrollerDragPositionsTerminal() throws {
        let f = try makeFixture()
        f.print(lines: 500)
        f.scrollView.syncScroller()
        let history = f.scrollbackRows
        let maxY = f.scrollView.documentView!.frame.height - f.scrollView.bounds.height

        f.scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: maxY / 2))
        f.scrollView.reflectScrolledClipView(f.scrollView.contentView)
        XCTAssertEqual(f.scrollOffset, history - Int((0.5 * CGFloat(history)).rounded()))

        let dragged = f.scrollOffset
        f.scrollView.syncScroller()
        XCTAssertEqual(f.scrollOffset, dragged)
        XCTAssertEqual(f.scrollView.contentView.bounds.origin.y, maxY / 2, accuracy: f.cellHeight)
    }

    func testWheelScrollLinesAccumulatesTrackpadPointsIntoLines() {
        let cell: CGFloat = 17
        var state = TerminalView.wheelScrollLines(delta: 10, precise: true, cellHeight: cell, accumulator: 0)
        XCTAssertEqual(state.lines, 0)
        state = TerminalView.wheelScrollLines(delta: 10, precise: true, cellHeight: cell, accumulator: state.accumulator)
        XCTAssertEqual(state.lines, 1)
        XCTAssertEqual(state.accumulator, 3, accuracy: 0.001)
        // Reversing drops what was left of the old direction.
        state = TerminalView.wheelScrollLines(delta: -17, precise: true, cellHeight: cell, accumulator: state.accumulator)
        XCTAssertEqual(state.lines, -1)
        XCTAssertEqual(state.accumulator, 0, accuracy: 0.001)
        // Nothing moved, nothing lost.
        state = TerminalView.wheelScrollLines(delta: 0, precise: true, cellHeight: cell, accumulator: 5)
        XCTAssertEqual(state.lines, 0)
        XCTAssertEqual(state.accumulator, 5)
    }

    func testWheelScrollLinesMovesAtLeastOneLinePerWheelNotch() {
        XCTAssertEqual(TerminalView.wheelScrollLines(delta: 0.1, precise: false, cellHeight: 17, accumulator: 0).lines, 1)
        XCTAssertEqual(TerminalView.wheelScrollLines(delta: -0.1, precise: false, cellHeight: 17, accumulator: 0).lines, -1)
        XCTAssertEqual(TerminalView.wheelScrollLines(delta: 4.2, precise: false, cellHeight: 17, accumulator: 0).lines, 5)
    }

    /// Every offset survives the trip to the scroller and back, for small and very long histories.
    func testScrollerPositionRoundTripsEveryOffset() {
        let cell: CGFloat = 17
        let viewport: CGFloat = 40 * cell + 6
        for history in [1, 2, 39, 40, 41, 1_000, 2_000_000] {
            let document = max(viewport, CGFloat(history + 40) * cell)
            let offsets = history <= 1_000 ? Array(0...history) : [0, 1, 2, history / 3, history - 2, history - 1, history]
            for offset in offsets {
                let y = TerminalScrollView.clipOriginY(scrollOffset: offset, scrollbackRowCount: history,
                                                       documentHeight: document, viewportHeight: viewport)
                XCTAssertEqual(
                    TerminalScrollView.scrollOffset(clipOriginY: y, scrollbackRowCount: history,
                                                    documentHeight: document, viewportHeight: viewport),
                    offset, "history \(history) offset \(offset)")
            }
        }
        XCTAssertNil(TerminalScrollView.scrollOffset(clipOriginY: 0, scrollbackRowCount: 0,
                                                     documentHeight: viewport, viewportHeight: viewport))
    }

    // MARK: - Lock priority

    private static func currentSchedulingPriority() -> Int32 {
        var info = thread_extended_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_extended_info>.size / MemoryLayout<natural_t>.size)
        let port = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, port) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(port, thread_flavor_t(THREAD_EXTENDED_INFO), $0, &count)
            }
        }
        precondition(result == KERN_SUCCESS, "thread_info failed: \(result)")
        return info.pth_curpri
    }

    /// A background thread inside the terminal lock runs as urgently as the main thread that
    /// may be waiting for it, and goes back to its own priority when it leaves.
    func testBackgroundThreadHoldsTerminalLockAtMainThreadPriority() {
        let lock = ReadWriteLock()
        // The test runner's main thread is not a user-interactive one; an application's is.
        let measured = expectation(description: "user-interactive priority")
        nonisolated(unsafe) var mainPriority: Int32 = 0
        DispatchQueue.global(qos: .userInteractive).async {
            mainPriority = Self.currentSchedulingPriority()
            measured.fulfill()
        }
        wait(for: [measured], timeout: 5)
        for qos in [DispatchQoS.QoSClass.background, .utility, .default, .userInitiated] {
            let done = expectation(description: "\(qos)")
            DispatchQueue.global(qos: qos).async {
                let outside = Self.currentSchedulingPriority()
                let inWrite = lock.withWriteLock { Self.currentSchedulingPriority() }
                let inRead = lock.withReadLock { Self.currentSchedulingPriority() }
                let inTryRead = lock.tryWithReadLock { Self.currentSchedulingPriority() }
                let after = Self.currentSchedulingPriority()
                // A process that is not the frontmost application has its upper classes
                // levelled by the system, so only the classes below them are sure to start lower.
                if qos == .background || qos == .utility {
                    XCTAssertLessThan(outside, mainPriority, "\(qos)")
                }
                XCTAssertGreaterThanOrEqual(inWrite, mainPriority, "\(qos)")
                XCTAssertGreaterThanOrEqual(inRead, mainPriority, "\(qos)")
                XCTAssertGreaterThanOrEqual(inTryRead ?? -1, mainPriority, "\(qos)")
                XCTAssertEqual(after, outside, "\(qos)")
                done.fulfill()
            }
            wait(for: [done], timeout: 5)
        }
    }
}

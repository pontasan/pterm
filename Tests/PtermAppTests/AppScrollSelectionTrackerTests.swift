import XCTest
@testable import PtermApp

final class AppScrollSelectionTrackerTests: XCTestCase {
    private let blank = AppScrollRowHash.blank

    private func captured(_ value: UInt64) -> AppScrollSelectionTracker.CapturedRow {
        AppScrollSelectionTracker.CapturedRow(
            cells: [Cell(codepoint: UInt32(value & 0xFFFF), attributes: .default, width: 1, isWideContinuation: false)],
            isWrapped: false
        )
    }

    private func makeTracker(_ frame: [UInt64], base: Int = 100, limit: Int = 1000) -> AppScrollSelectionTracker {
        AppScrollSelectionTracker(frame: frame, baseGlobalRow: base, maximumCapturedRows: limit) { self.captured(frame[$0]) }
    }

    /// A complete repaint: followed, then settled.
    @discardableResult
    private func ingest(_ tracker: inout AppScrollSelectionTracker, _ frame: [UInt64], base: Int = 100) -> Bool {
        tracker.follow(frame: frame, baseGlobalRow: base, activeRow: nil)
        return tracker.settle(frame: frame, baseGlobalRow: base) { self.captured(frame[$0]) }
    }

    /// One read of a repaint in progress.
    private func partial(_ tracker: inout AppScrollSelectionTracker, _ frame: [UInt64], base: Int = 100, active: Int) {
        tracker.follow(frame: frame, baseGlobalRow: base, activeRow: active)
    }

    private func value(_ tracker: AppScrollSelectionTracker, _ globalRow: Int) -> UInt32? {
        tracker.capturedRow(atGlobalRow: globalRow)?.cells.first?.codepoint
    }

    func testAlignsBothDirectionsAndIgnoresFixedRows() {
        var tracker = makeTracker([1, 2, 3, 4, 5, 90])
        ingest(&tracker, [2, 3, 4, 5, 6, 90])
        XCTAssertEqual(tracker.globalShift, -1)
        XCTAssertEqual(tracker.movingBand, 0..<5)
        ingest(&tracker, [1, 2, 3, 4, 5, 90])
        XCTAssertEqual(tracker.globalShift, 0)
        ingest(&tracker, [4, 5, 6, 7, 8, 90])
        XCTAssertEqual(tracker.globalShift, -3)
    }

    /// The defect that broke real use: one repaint arrives over several reads.
    func testRepaintSplitAcrossReadsDoesNotDoubleCountTheMovement() {
        var tracker = makeTracker([1, 2, 3, 4, 5, 6, 90])
        partial(&tracker, [2, 3, 4, 4, 5, 6, 90], active: 3)
        partial(&tracker, [2, 3, 4, 5, 5, 6, 90], active: 4)
        partial(&tracker, [2, 3, 4, 5, 6, 6, 90], active: 5)
        ingest(&tracker, [2, 3, 4, 5, 6, 7, 90])
        XCTAssertEqual(tracker.globalShift, -1, "Summing per read would report -2 or more.")
        XCTAssertEqual(value(tracker, 99), 1, "The row that left the top stays intact.")
        XCTAssertEqual(value(tracker, 105), 7)
        XCTAssertEqual(tracker.movingBand, 0..<6, "The band grows to the rows repainted later, and stops at the fixed row.")
    }

    func testHalfPaintedStatesAreNeverStored() {
        var tracker = makeTracker([1, 2, 3, 4, 5, 6, 90])
        ingest(&tracker, [2, 3, 4, 5, 6, 7, 90])
        XCTAssertEqual(value(tracker, 104), 6)
        // The next repaint is half done, with text that was never seen on row 0.
        partial(&tracker, [77, 3, 4, 5, 6, 7, 90], active: 1)
        XCTAssertEqual(tracker.globalShift, -1)
        XCTAssertEqual(value(tracker, 100), 2, "A half-painted row must not replace what is stored.")
    }

    func testSettledFrameStoresTheRowTheCursorIsParkedOn() {
        var tracker = makeTracker([1, 2, 3, 4, 5, 90])
        partial(&tracker, [2, 3, 4, 5, 6, 90], active: 4)
        XCTAssertNil(value(tracker, 104), "A row still being written has not been stored.")
        ingest(&tracker, [2, 3, 4, 5, 6, 90])
        XCTAssertEqual(value(tracker, 104), 6)
    }

    func testEditRepeatingAnotherLineIsStoredInASettledFrame() {
        var tracker = makeTracker((1...12).map { UInt64($0) } + [90])
        ingest(&tracker, (2...13).map { UInt64($0) } + [90])
        var edited: [UInt64] = (2...13).map { UInt64($0) } + [90]
        edited[3] = 2
        ingest(&tracker, edited)
        XCTAssertEqual(tracker.globalShift, -1)
        XCTAssertEqual(value(tracker, 103), 2)
    }

    func testInPlaceEditKeepsPositionAndUpdatesTheRow() {
        var tracker = makeTracker([1, 2, 3, 4, 5, 6, 7, 8, 90])
        ingest(&tracker, [2, 3, 4, 5, 6, 7, 8, 9, 90])
        XCTAssertTrue(ingest(&tracker, [2, 3, 44, 5, 6, 7, 8, 9, 90]))
        XCTAssertEqual(tracker.globalShift, -1)
        XCTAssertEqual(value(tracker, 102), 44)
    }

    func testEditRepeatingOneOtherLineDoesNotMoveTheSelection() {
        var tracker = makeTracker([1, 2, 3, 4, 5, 6])
        XCTAssertTrue(ingest(&tracker, [1, 2, 3, 4, 1, 6]))
        XCTAssertEqual(tracker.globalShift, 0)
    }

    func testRepeatedLinesAlignToTheNearestShift() {
        var tracker = makeTracker([1, 7, 7, 7, 7, 2, 3, 4])
        ingest(&tracker, [7, 7, 7, 7, 2, 3, 4, 5])
        XCTAssertEqual(tracker.globalShift, -1)
    }

    func testBlankRowsAreNotEvidence() {
        var tracker = makeTracker([1, blank, blank, blank, 2, blank])
        ingest(&tracker, [blank, blank, blank, 2, blank, blank])
        XCTAssertEqual(tracker.globalShift, 0, "A single text row is not enough to move, and blanks do not vote.")
    }

    func testScreenSharingNoTextCannotBeLocated() {
        var tracker = makeTracker([1, 2, 3, 4, 90])
        XCTAssertFalse(ingest(&tracker, [5, 6, 7, 8, 90]))
    }

    private func ingest(_ tracker: inout AppScrollSelectionTracker, _ frame: [UInt64], scrollingUp: Bool) -> Bool {
        tracker.follow(frame: frame, baseGlobalRow: 100, activeRow: nil)
        return tracker.settle(frame: frame, baseGlobalRow: 100, scrollingUp: scrollingUp) { self.captured(frame[$0]) }
    }

    func testScrollPastAllStoredTextKeepsItAndAlignsWhenItShowsAgain() {
        for scrollingUp in [true, false] {
            let original: [UInt64] = [1, 2, 3, 4, 90]
            var tracker = makeTracker(original)
            XCTAssertTrue(ingest(&tracker, [11, 12, 13, 14, 90], scrollingUp: scrollingUp), "Scrolled away is not gone.")
            XCTAssertEqual(tracker.globalShift > 0, scrollingUp, "The text is on the side the user scrolled away from.")
            XCTAssertEqual(value(tracker, 100 + tracker.globalShift), 1, "Stored text is untouched.")
            // Scrolling on within the new text keeps working.
            let shift = tracker.globalShift
            XCTAssertTrue(ingest(&tracker, [12, 13, 14, 15, 90], scrollingUp: scrollingUp))
            XCTAssertEqual(tracker.globalShift, shift - 1)
            // And the original text finds its place again by itself.
            XCTAssertTrue(ingest(&tracker, original, scrollingUp: !scrollingUp))
            XCTAssertEqual(tracker.globalShift, 0)
            XCTAssertEqual(value(tracker, 100), 1)
        }
    }

    func testTextOnBothSidesOfAJumpJoinsAsSoonAsOneScreenShowsBoth() {
        var tracker = makeTracker([1, 2, 3, 4, 5, 90])
        ingest(&tracker, [2, 3, 4, 5, 6, 90], scrollingUp: true)
        ingest(&tracker, [1, 2, 3, 4, 5, 90], scrollingUp: true)
        XCTAssertTrue(ingest(&tracker, [11, 12, 13, 14, 15, 90], scrollingUp: true))
        let jumped = tracker.globalShift
        XCTAssertGreaterThan(jumped, 1000)
        XCTAssertTrue(ingest(&tracker, [12, 13, 14, 15, 16, 90], scrollingUp: false))
        // Only two rows of the older text show, and most of the screen is still the newer text.
        XCTAssertTrue(ingest(&tracker, [15, 16, 17, 1, 2, 90], scrollingUp: false))
        XCTAssertEqual(tracker.globalShift, 3, "The older text shows at rows 3 and 4, so it moved down by 3.")
        XCTAssertFalse(tracker.isUndisplayed(globalRow: 100), "No gap is left.")
        XCTAssertEqual(value(tracker, 103), 1)
        XCTAssertEqual(value(tracker, 100), 15, "The newer text has its true number too.")
        // Numbers are consistent from here on, in both directions.
        XCTAssertTrue(ingest(&tracker, [13, 14, 15, 16, 17, 90], scrollingUp: true))
        XCTAssertEqual(tracker.globalShift, 5)
        XCTAssertEqual(value(tracker, 106), 2)
    }

    func testRowsOnBothSidesOfAJoinKeepTheirText() {
        var tracker = makeTracker([1, 2, 3, 4, 5, 90])
        XCTAssertTrue(ingest(&tracker, [11, 12, 13, 14, 15, 90], scrollingUp: true))
        // A selection made now, on a row of the newer text and one of the older text.
        let shift = tracker.globalShift
        let joinCount = tracker.joinCount
        let newerRow = 101 // 12
        let olderRow = 100 + shift // 1, off the screen
        XCTAssertTrue(ingest(&tracker, [14, 15, 16, 1, 2, 90], scrollingUp: false))
        XCTAssertEqual(tracker.joinCount, joinCount + 1)
        func moved(_ row: Int) -> Int {
            tracker.globalRow(ofRow: row, atShift: shift, joinCount: joinCount, toShift: tracker.globalShift, toJoinCount: tracker.joinCount)
        }
        XCTAssertEqual(value(tracker, moved(newerRow)), 12)
        XCTAssertEqual(value(tracker, moved(olderRow)), 1)
    }

    func testTextStoredAgainBeyondAJumpJoinsWithItsFirstCopy() {
        var tracker = makeTracker([1, 2, 3, 4, 5, 90])
        ingest(&tracker, [2, 3, 4, 5, 6, 90], scrollingUp: false)
        ingest(&tracker, [1, 2, 3, 4, 5, 90], scrollingUp: true)
        // The application jumps away and scrolling back reaches the same lines at new numbers.
        XCTAssertTrue(ingest(&tracker, [11, 12, 13, 14, 15, 90], scrollingUp: true))
        XCTAssertTrue(ingest(&tracker, [1, 2, 3, 11, 12, 90], scrollingUp: true))
        XCTAssertEqual(tracker.globalShift, 0, "Lines known on both sides put the screen back on the older numbers.")
        XCTAssertFalse(tracker.isUndisplayed(globalRow: 110))
    }

    func testDifferenceRightAfterAMoveDoesNotReplaceStoredTextButALastingOneDoes() {
        var tracker = makeTracker([1, 2, 3, 4, 5, 90])
        ingest(&tracker, [2, 3, 4, 5, 6, 90])
        // The content moved, and row 3 shows other text than what was stored for it.
        ingest(&tracker, [3, 4, 5, 77, 7, 90])
        XCTAssertEqual(tracker.globalShift, -2)
        XCTAssertEqual(value(tracker, 103), 6, "Stored text survives.")
        // Still there without a move: the application did edit it.
        ingest(&tracker, [3, 4, 5, 77, 7, 90])
        XCTAssertEqual(value(tracker, 103), 77)
    }

    /// The defect behind a selection staying off by a few rows after output scrolled it: the view
    /// recorded one state and moved its rows to a later one, so the difference applied twice.
    func testMovingARowGoesToTheRequestedStateEvenWhenTheTrackerHasMovedOn() {
        var tracker = makeTracker([1, 2, 3, 4, 5, 90])
        ingest(&tracker, [2, 3, 4, 5, 6, 90])
        let shift = tracker.globalShift
        let joinCount = tracker.joinCount
        // Output arrives between reading the state and moving the rows.
        ingest(&tracker, [4, 5, 6, 7, 8, 90])
        XCTAssertNotEqual(tracker.globalShift, shift)
        XCTAssertEqual(tracker.globalRow(ofRow: 102, atShift: 0, joinCount: joinCount, toShift: shift, toJoinCount: joinCount), 102 + shift)
    }

    func testRowsBetweenTextReachedByAJumpAreKnownToBeUndisplayed() {
        var tracker = makeTracker([1, 2, 3, 4, 90], limit: 100)
        XCTAssertTrue(ingest(&tracker, [11, 12, 13, 14, 90], scrollingUp: true))
        XCTAssertFalse(tracker.isUndisplayed(globalRow: 100 + tracker.globalShift), "A stored row.")
        XCTAssertTrue(tracker.isUndisplayed(globalRow: 100 + tracker.globalShift - 1), "Just before the stored rows.")
        XCTAssertFalse(tracker.isUndisplayed(globalRow: 104), "The row on the screen.")
    }

    func testAPaddedOverlayIsRecognizedOverLongAndShortLinesAlike() {
        let width = 20
        func cells(_ text: String, overlay: Bool) -> AppScrollSelectionTracker.CapturedRow {
            var result = (0..<width).map { column -> Cell in
                let scalar = Array(text.unicodeScalars).dropFirst(column).first
                return Cell(codepoint: scalar?.value ?? 0x20, attributes: .default, width: 1, isWideContinuation: false)
            }
            if overlay {
                var attributes = CellAttributes.default
                attributes.background = .rgb(55, 55, 55)
                for (offset, scalar) in " HINT ".unicodeScalars.enumerated() {
                    result[8 + offset] = Cell(codepoint: scalar.value, attributes: attributes, width: 1, isWideContinuation: false)
                }
            }
            return AppScrollSelectionTracker.CapturedRow(cells: result, isWrapped: false)
        }
        // A long line differs on the padding too, a short one only on the letters.
        let lines = ["aaaaaaaaaaaaaaaaaaaa", "bbbb", "cccccccccccccccccccc", "dddd", "eeeeeeeeeeeeeeeeeeee", "ffff", "gggggggggggggggggggg"]
        func frameRows(first: Int, overlay: Bool) -> [AppScrollSelectionTracker.CapturedRow] {
            (0..<4).map { cells(lines[first + $0], overlay: overlay && $0 == 3) }
        }
        func hashes(_ rows: [AppScrollSelectionTracker.CapturedRow]) -> [UInt64] {
            rows.map { AppScrollRowHash.hash(cells: $0.cells) }
        }
        let initial = frameRows(first: 3, overlay: false)
        var tracker = AppScrollSelectionTracker(frame: hashes(initial), baseGlobalRow: 100, maximumCapturedRows: 100) { initial[$0] }
        for first in [2, 1, 0] {
            let rows = frameRows(first: first, overlay: true)
            tracker.follow(frame: hashes(rows), baseGlobalRow: 100, activeRow: nil)
            XCTAssertTrue(tracker.settle(frame: hashes(rows), baseGlobalRow: 100) { rows[$0] })
        }
        // Every line that passed under the overlay is stored without it.
        for (index, line) in lines.enumerated() {
            let globalRow = 100 + index - 3 + tracker.globalShift
            let stored = tracker.capturedRow(atGlobalRow: globalRow)
            let text = stored.map { String(String.UnicodeScalarView($0.cells.compactMap { Unicode.Scalar($0.codepoint) })) } ?? ""
            XCTAssertEqual(text.trimmingCharacters(in: .whitespaces), line, "line \(index)")
        }
    }

    func testRowPinnedAtTheTopIsNotPartOfTheText() {
        // Scrolling up, a header appears on row 0 and then stays while the text moves under it.
        var tracker = makeTracker([1, 2, 3, 4, 5, 90])
        ingest(&tracker, [2, 3, 4, 5, 6, 90])
        XCTAssertEqual(tracker.globalShift, -1)
        XCTAssertEqual(value(tracker, 99), 1, "Row 1 is now above the screen.")
        ingest(&tracker, [50, 4, 5, 6, 7, 90])
        ingest(&tracker, [50, 5, 6, 7, 8, 90])
        ingest(&tracker, [50, 6, 7, 8, 9, 90])
        XCTAssertEqual(tracker.movingBand, 1..<5)
        let shift = tracker.globalShift
        XCTAssertEqual(shift, -4)
        for line in 1...9 {
            XCTAssertEqual(value(tracker, 100 + line - 1 + shift), UInt32(line), "line \(line)")
        }
    }

    func testPinnedRowBecomesTextAgainWhenItMoves() {
        var tracker = makeTracker([1, 2, 3, 4, 5, 90])
        ingest(&tracker, [2, 3, 4, 5, 6, 90])
        ingest(&tracker, [50, 4, 5, 6, 7, 90])
        ingest(&tracker, [50, 5, 6, 7, 8, 90])
        XCTAssertEqual(tracker.movingBand, 1..<5)
        // Back at the start the header is gone, and the first row moves again.
        ingest(&tracker, [1, 2, 3, 4, 5, 90])
        XCTAssertEqual(tracker.globalShift, 0)
        XCTAssertEqual(tracker.movingBand, 0..<5)
    }

    func testOverlayWithItsOwnBackgroundIsKnownOnFirstSightAndCutWideCharactersSurvive() {
        let width = 12
        func wide(_ line: UInt32) -> [Cell] {
            var cells: [Cell] = []
            for _ in 0..<(width / 2) {
                cells.append(Cell(codepoint: 0x3042 + line, attributes: .default, width: 2, isWideContinuation: false))
                cells.append(Cell(codepoint: 0, attributes: .default, width: 0, isWideContinuation: true))
            }
            return cells
        }
        func row(_ line: UInt32, overlay: Bool) -> AppScrollSelectionTracker.CapturedRow {
            var cells = wide(line)
            if overlay {
                // Starting on a continuation cell cuts the wide character before it in half.
                cells[4] = Cell(codepoint: 0x20, attributes: .default, width: 1, isWideContinuation: false)
                var attributes = CellAttributes.default
                attributes.background = .rgb(55, 55, 55)
                for (offset, scalar) in " HI ".unicodeScalars.enumerated() {
                    cells[5 + offset] = Cell(codepoint: scalar.value, attributes: attributes, width: 1, isWideContinuation: false)
                }
            }
            return AppScrollSelectionTracker.CapturedRow(cells: cells, isWrapped: false)
        }
        func frame(_ first: UInt32, overlay: Bool) -> [AppScrollSelectionTracker.CapturedRow] {
            (0..<4).map { row(first + $0, overlay: overlay && $0 == 3) }
        }
        func hashes(_ rows: [AppScrollSelectionTracker.CapturedRow]) -> [UInt64] {
            rows.map { AppScrollRowHash.hash(cells: $0.cells) }
        }
        let initial = frame(5, overlay: false)
        var tracker = AppScrollSelectionTracker(frame: hashes(initial), baseGlobalRow: 100, maximumCapturedRows: 100) { initial[$0] }
        // Only one repaint with the overlay: its line must not depend on seeing a second one.
        let scrolled = frame(4, overlay: true)
        tracker.follow(frame: hashes(scrolled), baseGlobalRow: 100, activeRow: nil)
        XCTAssertTrue(tracker.settle(frame: hashes(scrolled), baseGlobalRow: 100) { scrolled[$0] })
        XCTAssertEqual(tracker.globalShift, 1)
        let underOverlay = tracker.capturedRow(atGlobalRow: 103)
        XCTAssertEqual(underOverlay.map { AppScrollRowHash.hash(cells: $0.cells) }, AppScrollRowHash.hash(cells: wide(7)),
                       "The line under the overlay stays whole, including the wide character it cut.")
    }

    func testRepeatedLinesInUnseenTextDoNotAlignByCoincidence() {
        // 7 occurs many times in what was seen, and twice on a screen of otherwise unseen text.
        var tracker = makeTracker([7, 1, 7, 2, 7, 3, 7, 4, 90])
        XCTAssertTrue(ingest(&tracker, [7, 20, 7, 21, 22, 23, 24, 25, 90], scrollingUp: true))
        XCTAssertGreaterThan(tracker.globalShift, 1000, "Not at a position that only the repeats suggest.")
    }

    func testPositionThatContradictsStoredTextIsNotTaken() {
        // Rows 5 and 6 fit one row further, but the rows around them say otherwise.
        var tracker = makeTracker([1, 2, 3, 4, 5, 6, 8, 9])
        tracker.follow(frame: [20, 21, 5, 6, 22, 23, 24, 25], baseGlobalRow: 100, activeRow: nil)
        XCTAssertEqual(tracker.globalShift, 0)
    }

    func testSmallEditWithoutSharedTextIsNotAReplacement() {
        var tracker = makeTracker([1, 2, 3, 4, 5, 6])
        XCTAssertTrue(ingest(&tracker, [1, 2, 3, 4, 8, 9]))
    }

    func testRowsPushedIntoScrollbackKeepTheirGlobalRow() {
        var tracker = makeTracker([65, 66, 67, 68], base: 10)
        ingest(&tracker, [66, 67, 68, 69], base: 11)
        XCTAssertEqual(tracker.globalShift, 0)
    }

    func testRevisitedTextAlignsAbsolutelyAfterLongScroll() {
        var frame: [UInt64] = (1...5).map { UInt64($0) }
        var tracker = makeTracker(frame)
        for step in 1...40 {
            frame = (1...5).map { UInt64($0 + step) }
            ingest(&tracker, frame)
        }
        XCTAssertEqual(tracker.globalShift, -40)
        frame = (1...5).map { UInt64($0) }
        var current = 40
        while current > 0 {
            current -= 1
            frame = (1...5).map { UInt64($0 + current) }
            ingest(&tracker, frame)
        }
        XCTAssertEqual(tracker.globalShift, 0)
        XCTAssertEqual(value(tracker, 100), 1)
    }

    /// Claude Code draws "Jump to bottom" over the last moving row while scrolled up, on top
    /// of the text in the middle of the row.
    func testOverlayOnTheLastMovingRowStaysOutOfTheText() {
        func cells(_ text: String) -> [Cell] {
            text.padding(toLength: 40, withPad: " ", startingAt: 0).unicodeScalars.map {
                Cell(codepoint: $0.value, attributes: .default, width: 1, isWideContinuation: false)
            }
        }
        func line(_ n: Int) -> String { "line \(n) with text reaching past the hint" }
        func overlaid(_ text: String) -> String {
            let padded = text.padding(toLength: 40, withPad: " ", startingAt: 0)
            return String(padded.prefix(10)) + " Jump down " + String(padded.dropFirst(21))
        }
        var screen: [[Cell]] = (1...5).map { cells(line($0)) } + [cells("INPUT")]
        func hashes() -> [UInt64] { screen.map { AppScrollRowHash.hash(cells: $0) } }
        func row(_ gridRow: Int) -> AppScrollSelectionTracker.CapturedRow {
            AppScrollSelectionTracker.CapturedRow(cells: screen[gridRow], isWrapped: false)
        }
        var tracker = AppScrollSelectionTracker(frame: hashes(), baseGlobalRow: 0, maximumCapturedRows: 100, row: row)
        func repaint(first: Int) {
            screen = (0..<5).map { cells(overlaidIfLast($0, first: first)) } + [cells("INPUT")]
            tracker.follow(frame: hashes(), baseGlobalRow: 0, activeRow: nil)
            XCTAssertTrue(tracker.settle(frame: hashes(), baseGlobalRow: 0, row: row))
        }
        func overlaidIfLast(_ index: Int, first: Int) -> String {
            index == 4 ? overlaid(line(first + index)) : line(first + index)
        }
        func stored(_ n: Int) -> String? {
            tracker.capturedRow(atGlobalRow: n - 1 + tracker.globalShift)?.cells.map { $0.renderedString() }.joined()
                .trimmingCharacters(in: .whitespaces)
        }
        // Scrolling up: lines 1...5 reach the overlaid row and then leave the screen.
        for first in stride(from: 0, through: -8, by: -1) { repaint(first: first) }
        XCTAssertEqual(tracker.globalShift, 9)
        XCTAssertEqual(tracker.movingBand, 0..<5)
        for n in 1...3 {
            XCTAssertEqual(stored(n), line(n), "line \(n) must be stored without the overlay")
        }
        // An edit of one line, which also differs in one run, is still an edit.
        let plain = cells("plain text on a line")
        var editedTracker = AppScrollSelectionTracker(frame: [AppScrollRowHash.hash(cells: plain)], baseGlobalRow: 0, maximumCapturedRows: 10) { _ in
            AppScrollSelectionTracker.CapturedRow(cells: plain, isWrapped: false)
        }
        let edited = cells("plain edit on a line")
        let editedFrame = [AppScrollRowHash.hash(cells: edited)]
        editedTracker.follow(frame: editedFrame, baseGlobalRow: 0, activeRow: nil)
        XCTAssertTrue(editedTracker.settle(frame: editedFrame, baseGlobalRow: 0) { _ in
            AppScrollSelectionTracker.CapturedRow(cells: edited, isWrapped: false)
        })
    }

    func testCaptureLimitBoundsMemoryAndKeepsTheExtentForGapReporting() {
        var frame: [UInt64] = [1000, 1001, 1002]
        var tracker = makeTracker(frame, base: 0, limit: 5)
        for step in 1...20 {
            let first = UInt64(1000 + step)
            frame = [first, first + 1, first + 2]
            ingest(&tracker, frame, base: 0)
        }
        XCTAssertEqual(value(tracker, 0), 1020)
        XCTAssertNil(value(tracker, -20), "The farthest row is evicted.")
        XCTAssertEqual(tracker.scrolledTextGlobalRowExtent?.lowerBound, -20)
    }

    func testHashIgnoresAttributesAndTrailingBlanksButNotInnerBlanks() {
        func cells(_ text: String, bold: Bool = false) -> [Cell] {
            var attributes = CellAttributes.default
            attributes.bold = bold
            return text.unicodeScalars.map {
                Cell(codepoint: $0.value, attributes: attributes, width: 1, isWideContinuation: false)
            }
        }
        XCTAssertEqual(AppScrollRowHash.hash(cells: cells("AB")), AppScrollRowHash.hash(cells: cells("AB   ")))
        XCTAssertEqual(AppScrollRowHash.hash(cells: cells("AB")), AppScrollRowHash.hash(cells: cells("AB", bold: true)))
        XCTAssertNotEqual(AppScrollRowHash.hash(cells: cells("A B")), AppScrollRowHash.hash(cells: cells("AB")))
        XCTAssertEqual(AppScrollRowHash.hash(cells: cells("   ")), blank)
    }
}

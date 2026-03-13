import XCTest
@testable import PtermApp

final class CommittedTextAnimationMatcherTests: XCTestCase {
    func testInsertIntentMatchesLocalizedOutputDiff() {
        let baseline = snapshot(
            rows: [
                [.empty, .empty, .empty, .empty]
            ],
            cursorRow: 0,
            cursorCol: 1
        )
        let current = snapshot(
            rows: [
                [.empty, .scalar("a"), .empty, .empty]
            ],
            cursorRow: 0,
            cursorCol: 2
        )
        let intent = CommittedTextAnimationIntent(
            kind: .insert,
            text: "a",
            row: 0,
            col: 1,
            columnWidth: 1,
            cursorRow: 0,
            cursorCol: 2,
            capturedAt: 0,
            expiresAt: 1,
            baselineSnapshot: baseline
        )

        let evaluation = CommittedTextAnimationMatcher.evaluate(intent, currentSnapshot: current, now: 0.1)

        XCTAssertEqual(
            evaluation,
            .matched(
                CommittedTextAnimationMatch(
                    text: "a",
                    row: 0,
                    col: 1,
                    columnWidth: 1,
                    cursorRow: 0,
                    cursorCol: 2,
                    kind: .fadeIn
                )
            )
        )
    }

    func testDeleteIntentMatchesLocalizedOutputDiff() {
        let baseline = snapshot(
            rows: [
                [.empty, .scalar("x"), .empty, .empty]
            ],
            cursorRow: 0,
            cursorCol: 1
        )
        let current = snapshot(
            rows: [
                [.empty, .empty, .empty, .empty]
            ],
            cursorRow: 0,
            cursorCol: 1
        )
        let intent = CommittedTextAnimationIntent(
            kind: .deleteForward,
            text: "x",
            row: 0,
            col: 1,
            columnWidth: 1,
            cursorRow: 0,
            cursorCol: 1,
            capturedAt: 0,
            expiresAt: 1,
            baselineSnapshot: baseline
        )

        let evaluation = CommittedTextAnimationMatcher.evaluate(intent, currentSnapshot: current, now: 0.1)

        XCTAssertEqual(
            evaluation,
            .matched(
                CommittedTextAnimationMatch(
                    text: "x",
                    row: 0,
                    col: 1,
                    columnWidth: 1,
                    cursorRow: 0,
                    cursorCol: 1,
                    kind: .fadeOut
                )
            )
        )
    }

    func testInsertIntentKeepsPendingAcrossLargeUnexpectedRedrawUntilTimeout() {
        let baseline = snapshot(
            rows: [
                [.empty, .empty, .empty, .empty, .empty],
                [.empty, .empty, .empty, .empty, .empty],
                [.empty, .empty, .empty, .empty, .empty],
                [.empty, .empty, .empty, .empty, .empty],
                [.empty, .empty, .empty, .empty, .empty]
            ],
            cursorRow: 0,
            cursorCol: 1
        )
        let current = snapshot(
            rows: [
                [.scalar("a"), .scalar("b"), .scalar("c"), .scalar("d"), .scalar("e")],
                [.scalar("f"), .scalar("g"), .scalar("h"), .scalar("i"), .scalar("j")],
                [.scalar("k"), .scalar("l"), .scalar("m"), .scalar("n"), .scalar("o")],
                [.scalar("p"), .scalar("q"), .scalar("r"), .scalar("s"), .scalar("t")],
                [.scalar("u"), .scalar("v"), .scalar("w"), .scalar("x"), .scalar("y")]
            ],
            cursorRow: 4,
            cursorCol: 3
        )
        let intent = CommittedTextAnimationIntent(
            kind: .insert,
            text: "a",
            row: 0,
            col: 1,
            columnWidth: 1,
            cursorRow: 0,
            cursorCol: 2,
            capturedAt: 0,
            expiresAt: 1,
            baselineSnapshot: baseline
        )

        let pendingEvaluation = CommittedTextAnimationMatcher.evaluate(intent, currentSnapshot: current, now: 0.1)
        let timeoutEvaluation = CommittedTextAnimationMatcher.evaluate(intent, currentSnapshot: current, now: 1.1)

        XCTAssertEqual(pendingEvaluation, .pending)
        XCTAssertEqual(timeoutEvaluation, .discard)
    }

    func testInsertIntentMatchesSingleRowRedrawWhenTextAppearsAtShiftedColumn() {
        let baseline = snapshot(
            rows: [
                row("", cols: 24)
            ],
            cursorRow: 0,
            cursorCol: 0
        )
        let current = snapshot(
            rows: [
                row("claude> a", cols: 24)
            ],
            cursorRow: 0,
            cursorCol: 9
        )
        let intent = CommittedTextAnimationIntent(
            kind: .insert,
            text: "a",
            row: 0,
            col: 0,
            columnWidth: 1,
            cursorRow: 0,
            cursorCol: 1,
            capturedAt: 0,
            expiresAt: 1,
            baselineSnapshot: baseline
        )

        let evaluation = CommittedTextAnimationMatcher.evaluate(intent, currentSnapshot: current, now: 0.1)

        XCTAssertEqual(
            evaluation,
            .matched(
                CommittedTextAnimationMatch(
                    text: "a",
                    row: 0,
                    col: 8,
                    columnWidth: 1,
                    cursorRow: 0,
                    cursorCol: 9,
                    kind: .fadeIn
                )
            )
        )
    }

    func testInsertIntentMatchesWhenPromptAlreadyExistsInBaseline() {
        let baseline = snapshot(
            rows: [
                row("claude> ", cols: 24)
            ],
            cursorRow: 0,
            cursorCol: 8
        )
        let current = snapshot(
            rows: [
                row("claude> a", cols: 24)
            ],
            cursorRow: 0,
            cursorCol: 9
        )
        let intent = CommittedTextAnimationIntent(
            kind: .insert,
            text: "a",
            row: 0,
            col: 8,
            columnWidth: 1,
            cursorRow: 0,
            cursorCol: 9,
            capturedAt: 0,
            expiresAt: 1,
            baselineSnapshot: baseline
        )

        let evaluation = CommittedTextAnimationMatcher.evaluate(intent, currentSnapshot: current, now: 0.1)

        XCTAssertEqual(
            evaluation,
            .matched(
                CommittedTextAnimationMatch(
                    text: "a",
                    row: 0,
                    col: 8,
                    columnWidth: 1,
                    cursorRow: 0,
                    cursorCol: 9,
                    kind: .fadeIn
                )
            )
        )
    }

    func testInsertIntentPrefersCursorAdjacentMatchOverEarlierPromptCharacter() {
        let baseline = snapshot(
            rows: [
                row("data> ", cols: 24)
            ],
            cursorRow: 0,
            cursorCol: 6
        )
        let current = snapshot(
            rows: [
                row("data> a", cols: 24)
            ],
            cursorRow: 0,
            cursorCol: 7
        )
        let intent = CommittedTextAnimationIntent(
            kind: .insert,
            text: "a",
            row: 0,
            col: 6,
            columnWidth: 1,
            cursorRow: 0,
            cursorCol: 7,
            capturedAt: 0,
            expiresAt: 1,
            baselineSnapshot: baseline
        )

        let evaluation = CommittedTextAnimationMatcher.evaluate(intent, currentSnapshot: current, now: 0.1)

        XCTAssertEqual(
            evaluation,
            .matched(
                CommittedTextAnimationMatch(
                    text: "a",
                    row: 0,
                    col: 6,
                    columnWidth: 1,
                    cursorRow: 0,
                    cursorCol: 7,
                    kind: .fadeIn
                )
            )
        )
    }

    func testInsertIntentMatchesEvenWhenOtherTUIRowsAlsoRedraw() {
        let baseline = snapshot(
            rows: [
                row("status: idle", cols: 32),
                row("claude> ", cols: 32),
                row("hint: press esc", cols: 32)
            ],
            cursorRow: 1,
            cursorCol: 8
        )
        let current = snapshot(
            rows: [
                row("status: typing", cols: 32),
                row("claude> a", cols: 32),
                row("hint: press esc", cols: 32)
            ],
            cursorRow: 1,
            cursorCol: 9
        )
        let intent = CommittedTextAnimationIntent(
            kind: .insert,
            text: "a",
            row: 1,
            col: 8,
            columnWidth: 1,
            cursorRow: 1,
            cursorCol: 9,
            capturedAt: 0,
            expiresAt: 1,
            baselineSnapshot: baseline
        )

        let evaluation = CommittedTextAnimationMatcher.evaluate(intent, currentSnapshot: current, now: 0.1)

        XCTAssertEqual(
            evaluation,
            .matched(
                CommittedTextAnimationMatch(
                    text: "a",
                    row: 1,
                    col: 8,
                    columnWidth: 1,
                    cursorRow: 1,
                    cursorCol: 9,
                    kind: .fadeIn
                )
            )
        )
    }

    func testInsertIntentMatchesWhenManyEarlierRowsRedrawBeforeInputRow() {
        let baseline = snapshot(
            rows: [
                row("status 01", cols: 32),
                row("status 02", cols: 32),
                row("status 03", cols: 32),
                row("status 04", cols: 32),
                row("status 05", cols: 32),
                row("status 06", cols: 32),
                row("status 07", cols: 32),
                row("claude> ", cols: 32)
            ],
            cursorRow: 7,
            cursorCol: 8
        )
        let current = snapshot(
            rows: [
                row("spinner 01", cols: 32),
                row("spinner 02", cols: 32),
                row("spinner 03", cols: 32),
                row("spinner 04", cols: 32),
                row("spinner 05", cols: 32),
                row("spinner 06", cols: 32),
                row("spinner 07", cols: 32),
                row("claude> a", cols: 32)
            ],
            cursorRow: 7,
            cursorCol: 9
        )
        let intent = CommittedTextAnimationIntent(
            kind: .insert,
            text: "a",
            row: 7,
            col: 8,
            columnWidth: 1,
            cursorRow: 7,
            cursorCol: 9,
            capturedAt: 0,
            expiresAt: 1,
            baselineSnapshot: baseline
        )

        XCTAssertEqual(current.text(at: 7, col: 8, columnWidth: 1), "a")
        XCTAssertNil(baseline.text(at: 7, col: 8, columnWidth: 1))

        let evaluation = CommittedTextAnimationMatcher.evaluate(intent, currentSnapshot: current, now: 0.1)

        XCTAssertEqual(
            evaluation,
            .matched(
                CommittedTextAnimationMatch(
                    text: "a",
                    row: 7,
                    col: 8,
                    columnWidth: 1,
                    cursorRow: 7,
                    cursorCol: 9,
                    kind: .fadeIn
                )
            )
        )
    }

    func testInsertIntentMatchesWhenCursorHasNotYetAdvancedButTextAppearsNearOriginalLocation() {
        let baseline = snapshot(
            rows: [
                row("claude> ", cols: 32)
            ],
            cursorRow: 0,
            cursorCol: 8
        )
        let current = snapshot(
            rows: [
                row("claude> a", cols: 32)
            ],
            cursorRow: 0,
            cursorCol: 0
        )
        let intent = CommittedTextAnimationIntent(
            kind: .insert,
            text: "a",
            row: 0,
            col: 8,
            columnWidth: 1,
            cursorRow: 0,
            cursorCol: 9,
            capturedAt: 0,
            expiresAt: 1,
            baselineSnapshot: baseline
        )

        let evaluation = CommittedTextAnimationMatcher.evaluate(intent, currentSnapshot: current, now: 0.1)

        XCTAssertEqual(
            evaluation,
            .matched(
                CommittedTextAnimationMatch(
                    text: "a",
                    row: 0,
                    col: 8,
                    columnWidth: 1,
                    cursorRow: 0,
                    cursorCol: 9,
                    kind: .fadeIn
                )
            )
        )
    }

    func testInsertIntentMatchesChangedRowEvenWhenItDiffersFromCapturedRow() {
        let baseline = snapshot(
            rows: [
                row("header", cols: 24),
                row("", cols: 24),
                row("", cols: 24),
                row("", cols: 24),
                row("", cols: 24),
                row("", cols: 24)
            ],
            cursorRow: 5,
            cursorCol: 0
        )
        let current = snapshot(
            rows: [
                row("header", cols: 24),
                row("", cols: 24),
                row("", cols: 24),
                row("❯ a", cols: 24),
                row("", cols: 24),
                row("", cols: 24)
            ],
            cursorRow: 3,
            cursorCol: 0
        )
        let intent = CommittedTextAnimationIntent(
            kind: .insert,
            text: "a",
            row: 5,
            col: 0,
            columnWidth: 1,
            cursorRow: 5,
            cursorCol: 1,
            capturedAt: 0,
            expiresAt: 1,
            baselineSnapshot: baseline
        )

        let evaluation = CommittedTextAnimationMatcher.evaluate(intent, currentSnapshot: current, now: 0.1)

        XCTAssertEqual(
            evaluation,
            .matched(
                CommittedTextAnimationMatch(
                    text: "a",
                    row: 3,
                    col: 2,
                    columnWidth: 1,
                    cursorRow: 3,
                    cursorCol: 3,
                    kind: .fadeIn
                )
            )
        )
    }

    func testInsertIntentRemainsPendingUntilSubsequentRedrawContainsTypedText() {
        let baseline = snapshot(
            rows: [
                row("", cols: 24)
            ],
            cursorRow: 0,
            cursorCol: 0
        )
        let intermediate = snapshot(
            rows: [
                row("claude> ", cols: 24)
            ],
            cursorRow: 0,
            cursorCol: 8
        )
        let current = snapshot(
            rows: [
                row("claude> a", cols: 24)
            ],
            cursorRow: 0,
            cursorCol: 9
        )
        let intent = CommittedTextAnimationIntent(
            kind: .insert,
            text: "a",
            row: 0,
            col: 0,
            columnWidth: 1,
            cursorRow: 0,
            cursorCol: 1,
            capturedAt: 0,
            expiresAt: 1,
            baselineSnapshot: baseline
        )

        let pendingEvaluation = CommittedTextAnimationMatcher.evaluate(intent, currentSnapshot: intermediate, now: 0.1)
        let matchedEvaluation = CommittedTextAnimationMatcher.evaluate(intent, currentSnapshot: current, now: 0.2)

        XCTAssertEqual(pendingEvaluation, .pending)
        XCTAssertEqual(
            matchedEvaluation,
            .matched(
                CommittedTextAnimationMatch(
                    text: "a",
                    row: 0,
                    col: 8,
                    columnWidth: 1,
                    cursorRow: 0,
                    cursorCol: 9,
                    kind: .fadeIn
                )
            )
        )
    }

    func testInsertIntentKeepsPendingForUnrelatedAnimatedRedrawUntilTimeout() {
        let baseline = snapshot(
            rows: [
                row("", cols: 40),
                row("", cols: 40)
            ],
            cursorRow: 1,
            cursorCol: 2
        )
        let current = snapshot(
            rows: [
                row("                             spinner", cols: 40),
                row("", cols: 40)
            ],
            cursorRow: 0,
            cursorCol: 35
        )
        let intent = CommittedTextAnimationIntent(
            kind: .insert,
            text: "a",
            row: 1,
            col: 2,
            columnWidth: 1,
            cursorRow: 1,
            cursorCol: 3,
            capturedAt: 0,
            expiresAt: 1,
            baselineSnapshot: baseline
        )

        let pendingEvaluation = CommittedTextAnimationMatcher.evaluate(intent, currentSnapshot: current, now: 0.1)
        let timeoutEvaluation = CommittedTextAnimationMatcher.evaluate(intent, currentSnapshot: current, now: 1.1)

        XCTAssertEqual(pendingEvaluation, .pending)
        XCTAssertEqual(timeoutEvaluation, .discard)
    }

    func testDeleteIntentMatchesPromptRowRedraw() {
        let baseline = snapshot(
            rows: [
                row("claude> abc", cols: 24)
            ],
            cursorRow: 0,
            cursorCol: 11
        )
        let current = snapshot(
            rows: [
                row("claude> ab", cols: 24)
            ],
            cursorRow: 0,
            cursorCol: 10
        )
        let intent = CommittedTextAnimationIntent(
            kind: .deleteBackward,
            text: "c",
            row: 0,
            col: 10,
            columnWidth: 1,
            cursorRow: 0,
            cursorCol: 10,
            capturedAt: 0,
            expiresAt: 1,
            baselineSnapshot: baseline
        )

        let evaluation = CommittedTextAnimationMatcher.evaluate(intent, currentSnapshot: current, now: 0.1)

        XCTAssertEqual(
            evaluation,
            .matched(
                CommittedTextAnimationMatch(
                    text: "c",
                    row: 0,
                    col: 10,
                    columnWidth: 1,
                    cursorRow: 0,
                    cursorCol: 10,
                    kind: .fadeOut
                )
            )
        )
    }

    func testDeleteIntentDiscardsUnrelatedRedrawNearPrompt() {
        let baseline = snapshot(
            rows: [
                row("claude> abc", cols: 32),
                row("", cols: 32)
            ],
            cursorRow: 0,
            cursorCol: 11
        )
        let current = snapshot(
            rows: [
                row("claude> abc", cols: 32),
                row("status: thinking...", cols: 32)
            ],
            cursorRow: 1,
            cursorCol: 18
        )
        let intent = CommittedTextAnimationIntent(
            kind: .deleteBackward,
            text: "c",
            row: 0,
            col: 10,
            columnWidth: 1,
            cursorRow: 0,
            cursorCol: 10,
            capturedAt: 0,
            expiresAt: 1,
            baselineSnapshot: baseline
        )

        let evaluation = CommittedTextAnimationMatcher.evaluate(intent, currentSnapshot: current, now: 0.1)

        XCTAssertEqual(evaluation, .discard)
    }

    func testDeleteIntentMatchesEvenWhenOtherTUIRowsAlsoRedraw() {
        let baseline = snapshot(
            rows: [
                row("status: idle", cols: 32),
                row("claude> abc", cols: 32),
                row("hint: press esc", cols: 32)
            ],
            cursorRow: 1,
            cursorCol: 11
        )
        let current = snapshot(
            rows: [
                row("status: typing", cols: 32),
                row("claude> ab", cols: 32),
                row("hint: press esc", cols: 32)
            ],
            cursorRow: 1,
            cursorCol: 10
        )
        let intent = CommittedTextAnimationIntent(
            kind: .deleteBackward,
            text: "c",
            row: 1,
            col: 10,
            columnWidth: 1,
            cursorRow: 1,
            cursorCol: 10,
            capturedAt: 0,
            expiresAt: 1,
            baselineSnapshot: baseline
        )

        let evaluation = CommittedTextAnimationMatcher.evaluate(intent, currentSnapshot: current, now: 0.1)

        XCTAssertEqual(
            evaluation,
            .matched(
                CommittedTextAnimationMatch(
                    text: "c",
                    row: 1,
                    col: 10,
                    columnWidth: 1,
                    cursorRow: 1,
                    cursorCol: 10,
                    kind: .fadeOut
                )
            )
        )
    }

    func testDeleteIntentMatchesWhenManyEarlierRowsRedrawBeforeInputRow() {
        let baseline = snapshot(
            rows: [
                row("status 01", cols: 32),
                row("status 02", cols: 32),
                row("status 03", cols: 32),
                row("status 04", cols: 32),
                row("status 05", cols: 32),
                row("status 06", cols: 32),
                row("status 07", cols: 32),
                row("claude> abc", cols: 32)
            ],
            cursorRow: 7,
            cursorCol: 11
        )
        let current = snapshot(
            rows: [
                row("spinner 01", cols: 32),
                row("spinner 02", cols: 32),
                row("spinner 03", cols: 32),
                row("spinner 04", cols: 32),
                row("spinner 05", cols: 32),
                row("spinner 06", cols: 32),
                row("spinner 07", cols: 32),
                row("claude> ab", cols: 32)
            ],
            cursorRow: 7,
            cursorCol: 10
        )
        let intent = CommittedTextAnimationIntent(
            kind: .deleteBackward,
            text: "c",
            row: 7,
            col: 10,
            columnWidth: 1,
            cursorRow: 7,
            cursorCol: 10,
            capturedAt: 0,
            expiresAt: 1,
            baselineSnapshot: baseline
        )

        let evaluation = CommittedTextAnimationMatcher.evaluate(intent, currentSnapshot: current, now: 0.1)

        XCTAssertEqual(
            evaluation,
            .matched(
                CommittedTextAnimationMatch(
                    text: "c",
                    row: 7,
                    col: 10,
                    columnWidth: 1,
                    cursorRow: 7,
                    cursorCol: 10,
                    kind: .fadeOut
                )
            )
        )
    }

    func testDeleteIntentMatchesChangedRowEvenWhenItDiffersFromCapturedRow() {
        let baseline = snapshot(
            rows: [
                row("header", cols: 24),
                row("", cols: 24),
                row("", cols: 24),
                row("❯ ab", cols: 24),
                row("", cols: 24),
                row("", cols: 24)
            ],
            cursorRow: 5,
            cursorCol: 0
        )
        let current = snapshot(
            rows: [
                row("header", cols: 24),
                row("", cols: 24),
                row("", cols: 24),
                row("❯ a", cols: 24),
                row("", cols: 24),
                row("", cols: 24)
            ],
            cursorRow: 3,
            cursorCol: 0
        )
        let intent = CommittedTextAnimationIntent(
            kind: .deleteBackward,
            text: "b",
            row: 5,
            col: 0,
            columnWidth: 1,
            cursorRow: 5,
            cursorCol: 0,
            capturedAt: 0,
            expiresAt: 1,
            baselineSnapshot: baseline
        )

        let evaluation = CommittedTextAnimationMatcher.evaluate(intent, currentSnapshot: current, now: 0.1)

        XCTAssertEqual(
            evaluation,
            .matched(
                CommittedTextAnimationMatch(
                    text: "b",
                    row: 3,
                    col: 3,
                    columnWidth: 1,
                    cursorRow: 3,
                    cursorCol: 0,
                    kind: .fadeOut
                )
            )
        )
    }

    private func snapshot(
        rows: [[TerminalViewportTextSnapshot.Cell]],
        cursorRow: Int,
        cursorCol: Int
    ) -> TerminalViewportTextSnapshot {
        TerminalViewportTextSnapshot(
            rows: rows.count,
            cols: rows.first?.count ?? 0,
            scrollOffset: 0,
            cursorRow: cursorRow,
            cursorCol: cursorCol,
            cells: rows
        )
    }

    private func row(_ text: String, cols: Int) -> [TerminalViewportTextSnapshot.Cell] {
        let scalars = Array(text)
        return (0..<cols).map { index in
            guard index < scalars.count else { return .empty }
            return .scalar(scalars[index])
        }
    }
}

private extension TerminalViewportTextSnapshot.Cell {
    static func scalar(_ character: Character) -> Self {
        let scalar = character.unicodeScalars.first!.value
        return Self(codepoint: scalar, width: 1, isWideContinuation: false)
    }
}

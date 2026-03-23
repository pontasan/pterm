import XCTest
@testable import PtermApp

final class LineDiffTests: XCTestCase {

    // MARK: - LCS (Longest Common Subsequence)

    func testLCSBothEmpty() {
        XCTAssertEqual(LineDiff.longestCommonSubsequence([], []), [])
    }

    func testLCSOneEmpty() {
        XCTAssertEqual(LineDiff.longestCommonSubsequence(["A"], []), [])
        XCTAssertEqual(LineDiff.longestCommonSubsequence([], ["A"]), [])
    }

    func testLCSIdentical() {
        let lines = ["A", "B", "C"]
        XCTAssertEqual(LineDiff.longestCommonSubsequence(lines, lines), lines)
    }

    func testLCSNoCommon() {
        XCTAssertEqual(LineDiff.longestCommonSubsequence(["A", "B"], ["X", "Y"]), [])
    }

    func testLCSBasic() {
        // Classic LCS example.
        let a = ["A", "B", "C", "D"]
        let b = ["A", "C", "D", "E"]
        XCTAssertEqual(LineDiff.longestCommonSubsequence(a, b), ["A", "C", "D"])
    }

    func testLCSWithInsertionAtStart() {
        let a = ["A", "B", "C"]
        let b = ["Z", "A", "B", "C"]
        XCTAssertEqual(LineDiff.longestCommonSubsequence(a, b), ["A", "B", "C"])
    }

    func testLCSWithInsertionInMiddle() {
        let a = ["A", "B", "C"]
        let b = ["A", "X", "B", "C"]
        XCTAssertEqual(LineDiff.longestCommonSubsequence(a, b), ["A", "B", "C"])
    }

    func testLCSWithInsertionAtEnd() {
        let a = ["A", "B"]
        let b = ["A", "B", "C", "D"]
        XCTAssertEqual(LineDiff.longestCommonSubsequence(a, b), ["A", "B"])
    }

    func testLCSWithDeletion() {
        let a = ["A", "B", "C", "D"]
        let b = ["A", "D"]
        XCTAssertEqual(LineDiff.longestCommonSubsequence(a, b), ["A", "D"])
    }

    func testLCSWithReplacement() {
        let a = ["A", "B", "C"]
        let b = ["A", "X", "C"]
        XCTAssertEqual(LineDiff.longestCommonSubsequence(a, b), ["A", "C"])
    }

    func testLCSDuplicateLines() {
        let a = ["A", "A", "B"]
        let b = ["A", "B", "A"]
        let lcs = LineDiff.longestCommonSubsequence(a, b)
        // LCS length should be 2 ("A", "B" or "A", "A").
        XCTAssertEqual(lcs.count, 2)
    }

    func testLCSSingleElement() {
        XCTAssertEqual(LineDiff.longestCommonSubsequence(["A"], ["A"]), ["A"])
        XCTAssertEqual(LineDiff.longestCommonSubsequence(["A"], ["B"]), [])
    }

    func testLCSOrderPreserved() {
        let a = ["D", "C", "B", "A"]
        let b = ["A", "B", "C", "D"]
        // Only one element can be common in order.
        let lcs = LineDiff.longestCommonSubsequence(a, b)
        XCTAssertEqual(lcs.count, 1)
    }

    // MARK: - addedLines (diff)

    func testAddedLinesBothEmpty() {
        XCTAssertEqual(LineDiff.addedLines(previous: [], current: []), [])
    }

    func testAddedLinesPreviousEmpty() {
        // Everything in current is new.
        XCTAssertEqual(
            LineDiff.addedLines(previous: [], current: ["A", "B"]),
            ["A", "B"]
        )
    }

    func testAddedLinesCurrentEmpty() {
        // Everything was deleted — no additions.
        XCTAssertEqual(
            LineDiff.addedLines(previous: ["A", "B"], current: []),
            []
        )
    }

    func testAddedLinesIdentical() {
        let lines = ["A", "B", "C"]
        XCTAssertEqual(LineDiff.addedLines(previous: lines, current: lines), [])
    }

    func testAddedLinesInsertionAtStart() {
        XCTAssertEqual(
            LineDiff.addedLines(previous: ["A", "B", "C"], current: ["Z", "A", "B", "C"]),
            ["Z"]
        )
    }

    func testAddedLinesInsertionInMiddle() {
        XCTAssertEqual(
            LineDiff.addedLines(previous: ["A", "B", "C"], current: ["A", "X", "B", "C"]),
            ["X"]
        )
    }

    func testAddedLinesInsertionAtEnd() {
        XCTAssertEqual(
            LineDiff.addedLines(previous: ["A", "B"], current: ["A", "B", "C"]),
            ["C"]
        )
    }

    func testAddedLinesReplacement() {
        // "B" replaced by "X".
        XCTAssertEqual(
            LineDiff.addedLines(previous: ["A", "B", "C"], current: ["A", "X", "C"]),
            ["X"]
        )
    }

    func testAddedLinesMultipleInsertions() {
        XCTAssertEqual(
            LineDiff.addedLines(
                previous: ["A", "B", "C"],
                current: ["X", "A", "Y", "B", "Z", "C"]
            ),
            ["X", "Y", "Z"]
        )
    }

    func testAddedLinesCompleteReplacement() {
        XCTAssertEqual(
            LineDiff.addedLines(previous: ["A", "B", "C"], current: ["X", "Y", "Z"]),
            ["X", "Y", "Z"]
        )
    }

    func testAddedLinesDeletion() {
        // "B" deleted — no additions.
        XCTAssertEqual(
            LineDiff.addedLines(previous: ["A", "B", "C"], current: ["A", "C"]),
            []
        )
    }

    func testAddedLinesDeletionAndInsertion() {
        // "C" deleted, "D" added.
        XCTAssertEqual(
            LineDiff.addedLines(previous: ["A", "B", "C"], current: ["A", "B", "D"]),
            ["D"]
        )
    }

    // The user's original example from the conversation.
    func testAddedLinesUserExample() {
        XCTAssertEqual(
            LineDiff.addedLines(
                previous: ["A", "B", "C"],
                current: ["Z", "A", "B", "D"]
            ),
            ["Z", "D"]
        )
    }

    func testAddedLinesReorder() {
        // Lines reordered — LCS will keep the longest ordered subsequence,
        // and report the rest as additions.
        let result = LineDiff.addedLines(
            previous: ["A", "B", "C"],
            current: ["C", "B", "A"]
        )
        // LCS is length 1 (e.g. "A" or "C"), so 2 lines are "added".
        XCTAssertEqual(result.count, 2)
    }

    func testAddedLinesDuplicateLineInCurrent() {
        // "A" appears twice in current but once in previous.
        XCTAssertEqual(
            LineDiff.addedLines(
                previous: ["A", "B"],
                current: ["A", "A", "B"]
            ),
            ["A"]
        )
    }

    func testAddedLinesDuplicateLineInBoth() {
        XCTAssertEqual(
            LineDiff.addedLines(
                previous: ["A", "A", "B"],
                current: ["A", "A", "B"]
            ),
            []
        )
    }

    // MARK: - TUI Streaming Scenarios

    func testStreamingAppendSingleLine() {
        // Simulates a streaming AI response appending one line.
        XCTAssertEqual(
            LineDiff.addedLines(
                previous: ["$ claude", "Hello, how can I"],
                current: ["$ claude", "Hello, how can I", "help you today?"]
            ),
            ["help you today?"]
        )
    }

    func testStreamingUpdateLastLine() {
        // Simulates a TUI updating the last line (partial → complete).
        XCTAssertEqual(
            LineDiff.addedLines(
                previous: ["$ claude", "Hello, how can I"],
                current: ["$ claude", "Hello, how can I help you today?"]
            ),
            ["Hello, how can I help you today?"]
        )
    }

    func testStreamingMultipleNewLines() {
        XCTAssertEqual(
            LineDiff.addedLines(
                previous: ["$ claude", "Response line 1"],
                current: ["$ claude", "Response line 1", "Response line 2", "Response line 3"]
            ),
            ["Response line 2", "Response line 3"]
        )
    }

    func testTUIScrollUp() {
        // Screen scrolled: top line removed, new line at bottom.
        XCTAssertEqual(
            LineDiff.addedLines(
                previous: ["Line 1", "Line 2", "Line 3", "Line 4"],
                current: ["Line 2", "Line 3", "Line 4", "Line 5"]
            ),
            ["Line 5"]
        )
    }

    func testTUIStatusBarUpdate() {
        // Only the status bar (last line) changed.
        XCTAssertEqual(
            LineDiff.addedLines(
                previous: ["Content A", "Content B", "Status: idle"],
                current: ["Content A", "Content B", "Status: running"]
            ),
            ["Status: running"]
        )
    }

    func testTUIFullRedraw() {
        // Complete screen replacement (e.g., switching views).
        XCTAssertEqual(
            LineDiff.addedLines(
                previous: ["Old view line 1", "Old view line 2"],
                current: ["New view line 1", "New view line 2", "New view line 3"]
            ),
            ["New view line 1", "New view line 2", "New view line 3"]
        )
    }

    func testPromptLineReappears() {
        // Prompt line is the same but appears after new content.
        // LCS should match the prompt, so only new response lines are diff.
        XCTAssertEqual(
            LineDiff.addedLines(
                previous: ["user@host:~$"],
                current: ["output line 1", "output line 2", "user@host:~$"]
            ),
            ["output line 1", "output line 2"]
        )
    }

    func testClaudeCodeTypicalFlow() {
        // Simulates Claude Code: prompt stays, response grows.
        let previous = [
            "$ claude 'explain this'",
            "⏺ Sure, let me explain.",
            "",
        ]
        let current = [
            "$ claude 'explain this'",
            "⏺ Sure, let me explain.",
            "This code does X.",
            "It also handles Y.",
            "",
        ]
        // Empty strings are filtered out before calling diff in IOHookManager,
        // but LineDiff itself handles them correctly.
        XCTAssertEqual(
            LineDiff.addedLines(previous: previous, current: current),
            ["This code does X.", "It also handles Y."]
        )
    }

    // MARK: - Edge Cases

    func testSingleLineUnchanged() {
        XCTAssertEqual(LineDiff.addedLines(previous: ["A"], current: ["A"]), [])
    }

    func testSingleLineChanged() {
        XCTAssertEqual(LineDiff.addedLines(previous: ["A"], current: ["B"]), ["B"])
    }

    func testEmptyStringsInLines() {
        XCTAssertEqual(
            LineDiff.addedLines(previous: ["", "A", ""], current: ["", "A", "", "B"]),
            ["B"]
        )
    }

    func testLargeIdenticalInput() {
        // Stress test: 100 identical lines → no diff.
        let lines = (0..<100).map { "Line \($0)" }
        XCTAssertEqual(LineDiff.addedLines(previous: lines, current: lines), [])
    }

    func testLargeCompletelyDifferent() {
        let previous = (0..<50).map { "Old \($0)" }
        let current = (0..<50).map { "New \($0)" }
        XCTAssertEqual(LineDiff.addedLines(previous: previous, current: current), current)
    }

    func testLargeAppend() {
        // 50 existing lines + 10 new lines.
        let existing = (0..<50).map { "Line \($0)" }
        let appended = (50..<60).map { "Line \($0)" }
        XCTAssertEqual(
            LineDiff.addedLines(previous: existing, current: existing + appended),
            appended
        )
    }

    func testUnicodeContent() {
        XCTAssertEqual(
            LineDiff.addedLines(
                previous: ["こんにちは", "世界"],
                current: ["こんにちは", "世界", "新しい行"]
            ),
            ["新しい行"]
        )
    }

    func testUnicodeReplacement() {
        XCTAssertEqual(
            LineDiff.addedLines(
                previous: ["Hello", "World"],
                current: ["Hello", "世界"]
            ),
            ["世界"]
        )
    }

    func testEmojiLines() {
        XCTAssertEqual(
            LineDiff.addedLines(
                previous: ["⏺ Working...", "❯ prompt"],
                current: ["⏺ Working...", "Result: OK", "❯ prompt"]
            ),
            ["Result: OK"]
        )
    }

    // MARK: - Consecutive Duplicates

    func testConsecutiveDuplicateLines() {
        // ["A","A","A"] → ["A","A","A","B"] → only "B" is new.
        XCTAssertEqual(
            LineDiff.addedLines(
                previous: ["A", "A", "A"],
                current: ["A", "A", "A", "B"]
            ),
            ["B"]
        )
    }

    func testAllSameLine() {
        // Identical content should produce no diff.
        XCTAssertEqual(
            LineDiff.addedLines(
                previous: ["X", "X", "X"],
                current: ["X", "X", "X"]
            ),
            []
        )
    }

    func testInterleavedChanges() {
        // Complex interleaving: every other line changed.
        XCTAssertEqual(
            LineDiff.addedLines(
                previous: ["A", "B", "C", "D", "E"],
                current: ["A", "X", "C", "Y", "E"]
            ),
            ["X", "Y"]
        )
    }

    func testWhitespaceOnlyDifference() {
        // Leading/trailing whitespace makes lines different.
        XCTAssertEqual(
            LineDiff.addedLines(
                previous: [" A", "B "],
                current: ["A ", " B"]
            ),
            ["A ", " B"]
        )
    }

    func testVeryLongLines() {
        // Lines with 1000+ chars.
        let longA = String(repeating: "a", count: 1500)
        let longB = String(repeating: "b", count: 1500)
        XCTAssertEqual(
            LineDiff.addedLines(
                previous: [longA],
                current: [longA, longB]
            ),
            [longB]
        )
    }

    func testSingleCharLines() {
        XCTAssertEqual(
            LineDiff.addedLines(
                previous: ["a", "b", "c"],
                current: ["a", "x", "c"]
            ),
            ["x"]
        )
    }

    // MARK: - Additional Edge Cases (Iteration 4+)

    func testLCSWithManyDuplicates() {
        // Stress test with many identical lines.
        let a = Array(repeating: "same", count: 20)
        let b = Array(repeating: "same", count: 20)
        XCTAssertEqual(LineDiff.longestCommonSubsequence(a, b), a)
        XCTAssertEqual(LineDiff.addedLines(previous: a, current: b), [])
    }

    func testAddedLinesGrowingDuplicates() {
        // Previous has 3 "X", current has 5 "X" - 2 new "X"s.
        XCTAssertEqual(
            LineDiff.addedLines(
                previous: ["X", "X", "X"],
                current: ["X", "X", "X", "X", "X"]
            ),
            ["X", "X"]
        )
    }

    func testAddedLinesShrinkingDuplicates() {
        // Previous has 5 "X", current has 3 "X" - no additions.
        XCTAssertEqual(
            LineDiff.addedLines(
                previous: ["X", "X", "X", "X", "X"],
                current: ["X", "X", "X"]
            ),
            []
        )
    }

    func testAddedLinesNewlineCharInContent() {
        // Lines that contain newline-like characters (actual \n in the string).
        // LineDiff operates on string arrays, so newlines in content are just
        // characters within a string element.
        XCTAssertEqual(
            LineDiff.addedLines(
                previous: ["line with\ttab"],
                current: ["line with\ttab", "new line"]
            ),
            ["new line"]
        )
    }

    func testAddedLinesMixedLengths() {
        // Mix of short and long lines.
        let short = "x"
        let long = String(repeating: "a", count: 500)
        XCTAssertEqual(
            LineDiff.addedLines(
                previous: [short, long],
                current: [short, long, "new"]
            ),
            ["new"]
        )
    }

    func testAddedLinesOnlyMiddleChanged() {
        // Only the middle of a 5-line block changed.
        XCTAssertEqual(
            LineDiff.addedLines(
                previous: ["A", "B", "C", "D", "E"],
                current: ["A", "B", "X", "D", "E"]
            ),
            ["X"]
        )
    }

    func testAddedLinesSingleDuplicateGrowth() {
        // One extra duplicate at the end.
        XCTAssertEqual(
            LineDiff.addedLines(
                previous: ["A", "B"],
                current: ["A", "B", "B"]
            ),
            ["B"]
        )
    }

    func testAddedLinesEmptyCurrentWithNonEmptyPrevious() {
        // All previous content removed.
        XCTAssertEqual(
            LineDiff.addedLines(
                previous: ["A", "B", "C"],
                current: []
            ),
            []
        )
    }

    func testLCSWithAlternatingPattern() {
        // Alternating: "A","B","A","B" vs "A","B","A","B"
        let lines = ["A", "B", "A", "B"]
        XCTAssertEqual(LineDiff.longestCommonSubsequence(lines, lines), lines)
    }

    func testLCSPerformanceWith100Lines() {
        // Performance sanity check: 100x100 should complete quickly.
        let a = (0..<100).map { "line-\($0)" }
        let b = (0..<100).map { $0 % 3 == 0 ? "changed-\($0)" : "line-\($0)" }
        let result = LineDiff.addedLines(previous: a, current: b)
        // Every 3rd line is changed.
        XCTAssertEqual(result.count, 34)  // 0,3,6,...,99 = 34 values
    }
}

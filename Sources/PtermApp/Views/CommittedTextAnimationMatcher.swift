import Foundation

struct TerminalViewportTextSnapshot: Equatable {
    struct Cell: Equatable {
        let codepoint: UInt32
        let width: Int
        let isWideContinuation: Bool

        static let empty = Cell(codepoint: 0, width: 1, isWideContinuation: false)
    }

    let rows: Int
    let cols: Int
    let scrollOffset: Int
    let cursorRow: Int
    let cursorCol: Int
    let cells: [[Cell]]

    func text(at row: Int, col: Int, columnWidth: Int) -> String? {
        guard row >= 0, row < rows, col >= 0, col < cols, columnWidth > 0 else { return nil }
        var text = ""
        var consumedWidth = 0
        var currentCol = col
        while currentCol < cols && consumedWidth < columnWidth {
            let cell = cells[row][currentCol]
            if cell.isWideContinuation {
                currentCol += 1
                continue
            }
            if cell.codepoint == 0 || cell.codepoint < 0x20 {
                return nil
            }
            guard let scalar = UnicodeScalar(cell.codepoint) else { return nil }
            text.unicodeScalars.append(scalar)
            consumedWidth += max(cell.width, 1)
            currentCol += max(cell.width, 1)
        }
        return consumedWidth == columnWidth ? text : nil
    }

    func cell(atRow row: Int, col: Int) -> Cell? {
        guard row >= 0, row < rows, col >= 0, col < cols else { return nil }
        return cells[row][col]
    }
}

struct CommittedTextAnimationIntent {
    enum Kind {
        case insert
        case deleteBackward
        case deleteForward
    }

    let kind: Kind
    let text: String
    let row: Int
    let col: Int
    let columnWidth: Int
    let cursorRow: Int?
    let cursorCol: Int?
    let capturedAt: CFTimeInterval
    let expiresAt: CFTimeInterval
    let baselineSnapshot: TerminalViewportTextSnapshot
}

struct CommittedTextAnimationMatch: Equatable {
    enum Kind: Equatable {
        case fadeIn
        case fadeOut
    }

    let text: String
    let row: Int
    let col: Int
    let columnWidth: Int
    let cursorRow: Int?
    let cursorCol: Int?
    let kind: Kind
}

enum CommittedTextAnimationIntentEvaluation: Equatable {
    case pending
    case discard
    case matched(CommittedTextAnimationMatch)
}

enum CommittedTextAnimationMatcher {
    private struct DiffSummary {
        struct RowChange {
            var count: Int = 0
            var minCol: Int?
            var maxCol: Int?

            mutating func record(col: Int) {
                count += 1
                minCol = Swift.min(minCol ?? col, col)
                maxCol = Swift.max(maxCol ?? col, col)
            }
        }

        let count: Int
        let minRow: Int?
        let maxRow: Int?
        let minCol: Int?
        let maxCol: Int?
        let rowChanges: [Int: RowChange]
        let exceededLimit: Bool

        var rowSpan: Int {
            guard let minRow, let maxRow else { return 0 }
            return maxRow - minRow + 1
        }

        var colSpan: Int {
            guard let minCol, let maxCol else { return 0 }
            return maxCol - minCol + 1
        }
    }

    static func evaluate(
        _ intent: CommittedTextAnimationIntent,
        currentSnapshot: TerminalViewportTextSnapshot,
        now: CFTimeInterval
    ) -> CommittedTextAnimationIntentEvaluation {
        guard now <= intent.expiresAt else { return .discard }
        guard geometryMatches(intent.baselineSnapshot, currentSnapshot) else { return .discard }

        let diff = diffSummary(from: intent.baselineSnapshot, to: currentSnapshot, limit: 512)
        guard diff.count > 0 else { return .pending }

        switch intent.kind {
        case .insert:
            return evaluateInsert(intent, currentSnapshot: currentSnapshot, diff: diff)
        case .deleteBackward, .deleteForward:
            return evaluateDelete(intent, currentSnapshot: currentSnapshot, diff: diff)
        }
    }

    static func debugDescribeInsertCandidates(
        for intent: CommittedTextAnimationIntent,
        currentSnapshot: TerminalViewportTextSnapshot
    ) -> String {
        var parts: [String] = []
        parts.append("cursor=(\(currentSnapshot.cursorRow),\(currentSnapshot.cursorCol))")
        let rowRange = max(0, intent.row - 2)...min(currentSnapshot.rows - 1, intent.row + 4)
        for row in rowRange {
            var matches: [String] = []
            for col in 0..<currentSnapshot.cols {
                if currentSnapshot.text(at: row, col: col, columnWidth: intent.columnWidth) == intent.text {
                    matches.append("\(col)")
                }
            }
            let rowText = debugRowText(row: row, snapshot: currentSnapshot)
            parts.append("row\(row)=\(rowText.debugDescription) matches=[\(matches.joined(separator: ","))]")
        }
        return parts.joined(separator: " | ")
    }

    private static func debugRowText(row: Int, snapshot: TerminalViewportTextSnapshot) -> String {
        guard row >= 0, row < snapshot.rows else { return "" }
        var result = ""
        var col = 0
        while col < snapshot.cols {
            let cell = snapshot.cells[row][col]
            if cell.isWideContinuation {
                col += 1
                continue
            }
            if cell.codepoint == 0 {
                result.append(" ")
                col += 1
                continue
            }
            if let scalar = UnicodeScalar(cell.codepoint) {
                result.unicodeScalars.append(scalar)
            } else {
                result.append("?")
            }
            col += max(cell.width, 1)
        }
        return result
    }

    private static func evaluateInsert(
        _ intent: CommittedTextAnimationIntent,
        currentSnapshot: TerminalViewportTextSnapshot,
        diff: DiffSummary
    ) -> CommittedTextAnimationIntentEvaluation {
        if let rowMatch = detectInsertedTextMatch(
            intent: intent,
            baselineSnapshot: intent.baselineSnapshot,
            currentSnapshot: currentSnapshot,
            diff: diff
        ) {
            return .matched(
                CommittedTextAnimationMatch(
                    text: intent.text,
                    row: rowMatch.row,
                    col: rowMatch.col,
                    columnWidth: intent.columnWidth,
                    cursorRow: rowMatch.row,
                    cursorCol: rowMatch.cursorCol,
                    kind: .fadeIn
                )
            )
        }

        if let cursorAdjacentLocation = cursorAdjacentInsertLocation(
            text: intent.text,
            columnWidth: intent.columnWidth,
            baselineSnapshot: intent.baselineSnapshot,
            in: currentSnapshot
        ), canTreatAsConfirmedInsert(
            cursorAdjacentLocation,
            intent: intent,
            currentSnapshot: currentSnapshot,
            diff: diff
        ) {
            return .matched(
                CommittedTextAnimationMatch(
                    text: intent.text,
                    row: cursorAdjacentLocation.row,
                    col: cursorAdjacentLocation.col,
                    columnWidth: intent.columnWidth,
                    cursorRow: cursorAdjacentLocation.row,
                    cursorCol: min(cursorAdjacentLocation.col + intent.columnWidth, currentSnapshot.cols),
                    kind: .fadeIn
                )
            )
        }

        let matchedLocation = nearestMatchingLocation(
            text: intent.text,
            columnWidth: intent.columnWidth,
            aroundRow: intent.row,
            aroundCol: intent.col,
            baselineSnapshot: intent.baselineSnapshot,
            in: currentSnapshot,
            candidateRows: Array(diff.rowChanges.keys),
            maxColDistance: currentSnapshot.cols
        )
        if let matchedLocation {
            if canTreatAsConfirmedInsert(
                matchedLocation,
                intent: intent,
                currentSnapshot: currentSnapshot,
                diff: diff
            ) {
                return .matched(
                    CommittedTextAnimationMatch(
                        text: intent.text,
                        row: matchedLocation.row,
                        col: matchedLocation.col,
                        columnWidth: intent.columnWidth,
                        cursorRow: matchedLocation.row,
                        cursorCol: min(matchedLocation.col + intent.columnWidth, currentSnapshot.cols),
                        kind: .fadeIn
                    )
                )
            }
        }

        if diff.exceededLimit || diff.rowSpan > 6 {
            return .pending
        }

        return .pending
    }

    private static func evaluateDelete(
        _ intent: CommittedTextAnimationIntent,
        currentSnapshot: TerminalViewportTextSnapshot,
        diff: DiffSummary
    ) -> CommittedTextAnimationIntentEvaluation {
        if let rowMatch = detectDeletedTextMatch(
            intent: intent,
            baselineSnapshot: intent.baselineSnapshot,
            currentSnapshot: currentSnapshot,
            diff: diff
        ) {
            return .matched(
                CommittedTextAnimationMatch(
                    text: intent.text,
                    row: rowMatch.row,
                    col: rowMatch.col,
                    columnWidth: intent.columnWidth,
                    cursorRow: rowMatch.cursorRow,
                    cursorCol: rowMatch.cursorCol,
                    kind: .fadeOut
                )
            )
        }

        guard intent.baselineSnapshot.text(at: intent.row, col: intent.col, columnWidth: intent.columnWidth) == intent.text else {
            return .discard
        }

        if currentSnapshot.text(at: intent.row, col: intent.col, columnWidth: intent.columnWidth) != intent.text,
           canTreatAsConfirmedDelete(intent, currentSnapshot: currentSnapshot, diff: diff) {
            return .matched(
                CommittedTextAnimationMatch(
                    text: intent.text,
                    row: intent.row,
                    col: intent.col,
                    columnWidth: intent.columnWidth,
                    cursorRow: intent.cursorRow,
                    cursorCol: intent.cursorCol,
                    kind: .fadeOut
                )
            )
        }

        if diff.exceededLimit || diff.rowSpan > 6 {
            return .discard
        }

        return isDiffLocal(diff, expectedRow: intent.row, expectedCol: intent.col, tolerance: max(6, intent.columnWidth + 3))
            ? .pending
            : .discard
    }

    private static func geometryMatches(
        _ lhs: TerminalViewportTextSnapshot,
        _ rhs: TerminalViewportTextSnapshot
    ) -> Bool {
        lhs.rows == rhs.rows &&
            lhs.cols == rhs.cols &&
            lhs.scrollOffset == rhs.scrollOffset
    }

    private static func nearestMatchingLocation(
        text: String,
        columnWidth: Int,
        aroundRow: Int,
        aroundCol: Int,
        baselineSnapshot: TerminalViewportTextSnapshot,
        in snapshot: TerminalViewportTextSnapshot,
        candidateRows: [Int],
        maxColDistance: Int
    ) -> (row: Int, col: Int)? {
        var bestMatch: (row: Int, col: Int, score: Int)?
        let rows = candidateRows.isEmpty ? Array(0..<snapshot.rows) : candidateRows.sorted()
        for row in rows where row >= 0 && row < snapshot.rows {
            for col in 0..<snapshot.cols {
                guard snapshot.text(at: row, col: col, columnWidth: columnWidth) == text else { continue }
                guard baselineSnapshot.text(at: row, col: col, columnWidth: columnWidth) != text else { continue }
                let rowDistance = abs(row - aroundRow)
                let colDistance = abs(col - aroundCol)
                guard colDistance <= maxColDistance else { continue }
                let cursorAlignedGap: Int
                if snapshot.cursorRow == row, snapshot.cursorCol >= col + columnWidth {
                    cursorAlignedGap = snapshot.cursorCol - (col + columnWidth)
                } else {
                    cursorAlignedGap = snapshot.cols
                }
                let score = cursorAlignedGap * 10_000 + rowDistance * 1_000 + colDistance
                if let bestMatch, bestMatch.score <= score {
                    continue
                }
                bestMatch = (row, col, score)
            }
        }
        return bestMatch.map { ($0.row, $0.col) }
    }

    private static func detectInsertedTextMatch(
        intent: CommittedTextAnimationIntent,
        baselineSnapshot: TerminalViewportTextSnapshot,
        currentSnapshot: TerminalViewportTextSnapshot,
        diff: DiffSummary
    ) -> (row: Int, col: Int, cursorCol: Int)? {
        var bestMatch: (row: Int, col: Int, cursorCol: Int, score: Int)?
        let candidateRows = diff.rowChanges.keys.sorted()
        for row in candidateRows {
            guard let rowChange = diff.rowChanges[row],
                  rowChange.count <= min(160, currentSnapshot.cols) else {
                continue
            }
            for col in 0..<currentSnapshot.cols {
                guard currentSnapshot.text(at: row, col: col, columnWidth: intent.columnWidth) == intent.text else { continue }
                guard baselineSnapshot.text(at: row, col: col, columnWidth: intent.columnWidth) != intent.text else { continue }

                let alignment = insertAlignmentScore(
                    row: row,
                    col: col,
                    columnWidth: intent.columnWidth,
                    baselineSnapshot: baselineSnapshot,
                    currentSnapshot: currentSnapshot
                )
                guard alignment >= 8 else { continue }

                let lowerRowBonus = row * 8
                let cursorAdjacentBonus: Int
                if currentSnapshot.cursorRow == row,
                   currentSnapshot.cursorCol >= col + intent.columnWidth,
                   currentSnapshot.cursorCol - (col + intent.columnWidth) <= max(3, intent.columnWidth + 1) {
                    cursorAdjacentBonus = 10_000
                } else {
                    cursorAdjacentBonus = 0
                }
                let originalRowBonus = row == intent.row ? 500 : 0
                let originalColPenalty = min(abs(col - intent.col), 40)
                let score = cursorAdjacentBonus + lowerRowBonus + alignment * 10 + originalRowBonus - originalColPenalty
                if let bestMatch, bestMatch.score >= score {
                    continue
                }
                bestMatch = (
                    row: row,
                    col: col,
                    cursorCol: currentSnapshot.cursorRow == row ? max(currentSnapshot.cursorCol, col + intent.columnWidth) : col + intent.columnWidth,
                    score: score
                )
            }
        }
        return bestMatch.map { ($0.row, $0.col, min($0.cursorCol, currentSnapshot.cols)) }
    }

    private static func detectDeletedTextMatch(
        intent: CommittedTextAnimationIntent,
        baselineSnapshot: TerminalViewportTextSnapshot,
        currentSnapshot: TerminalViewportTextSnapshot,
        diff: DiffSummary
    ) -> (row: Int, col: Int, cursorRow: Int?, cursorCol: Int?)? {
        if let rowDeletion = detectDeletedTextByRowDiff(
            intent: intent,
            baselineSnapshot: baselineSnapshot,
            currentSnapshot: currentSnapshot,
            diff: diff
        ) {
            return rowDeletion
        }

        var bestMatch: (row: Int, col: Int, cursorRow: Int?, cursorCol: Int?, score: Int)?
        let candidateRows = diff.rowChanges.keys.sorted()
        for row in candidateRows {
            guard let rowChange = diff.rowChanges[row],
                  rowChange.count <= min(160, currentSnapshot.cols) else {
                continue
            }
            for col in 0..<baselineSnapshot.cols {
                guard baselineSnapshot.text(at: row, col: col, columnWidth: intent.columnWidth) == intent.text else { continue }
                guard currentSnapshot.text(at: row, col: col, columnWidth: intent.columnWidth) != intent.text else { continue }

                let alignment = deleteAlignmentScore(
                    row: row,
                    col: col,
                    columnWidth: intent.columnWidth,
                    baselineSnapshot: baselineSnapshot,
                    currentSnapshot: currentSnapshot
                )
                guard alignment >= 8 else { continue }

                let lowerRowBonus = row * 8
                let cursorOnRowBonus = currentSnapshot.cursorRow == row ? 500 : 0
                let originalRowBonus = row == intent.row ? 500 : 0
                let originalColPenalty = min(abs(col - intent.col), 40)
                let score = lowerRowBonus + alignment * 10 + cursorOnRowBonus + originalRowBonus - originalColPenalty
                if let bestMatch, bestMatch.score >= score {
                    continue
                }
                bestMatch = (
                    row: row,
                    col: col,
                    cursorRow: currentSnapshot.cursorRow == row ? row : intent.cursorRow,
                    cursorCol: currentSnapshot.cursorRow == row ? currentSnapshot.cursorCol : intent.cursorCol,
                    score: score
                )
            }
        }
        return bestMatch.map { ($0.row, $0.col, $0.cursorRow, $0.cursorCol) }
    }

    private static func detectDeletedTextByRowDiff(
        intent: CommittedTextAnimationIntent,
        baselineSnapshot: TerminalViewportTextSnapshot,
        currentSnapshot: TerminalViewportTextSnapshot,
        diff: DiffSummary
    ) -> (row: Int, col: Int, cursorRow: Int?, cursorCol: Int?)? {
        var bestMatch: (row: Int, col: Int, cursorRow: Int?, cursorCol: Int?, score: Int)?
        for row in diff.rowChanges.keys.sorted() {
            guard let rowChange = diff.rowChanges[row],
                  rowChange.count <= min(160, currentSnapshot.cols) else {
                continue
            }
            let baselineLine = debugRowText(row: row, snapshot: baselineSnapshot)
            let currentLine = debugRowText(row: row, snapshot: currentSnapshot)
            guard baselineLine.count == currentLine.count + intent.text.count else {
                continue
            }
            let prefixCount = sharedPrefixCount(baselineLine, currentLine)
            let suffixCount = sharedSuffixCount(baselineLine, currentLine)
            guard prefixCount + suffixCount >= max(2, currentLine.count - 4) else {
                continue
            }
            let startIndex = baselineLine.index(baselineLine.startIndex, offsetBy: prefixCount)
            let endOffset = max(prefixCount, baselineLine.count - suffixCount)
            let endIndex = baselineLine.index(baselineLine.startIndex, offsetBy: endOffset)
            let removed = String(baselineLine[startIndex..<endIndex])
            guard removed == intent.text else { continue }
            let col = displayColumnCount(ofPrefix: String(baselineLine[..<startIndex]))
            let lowerRowBonus = row * 8
            let originalRowBonus = row == intent.row ? 500 : 0
            let originalColPenalty = min(abs(col - intent.col), 40)
            let score = lowerRowBonus + originalRowBonus + suffixCount * 10 - originalColPenalty
            if let bestMatch, bestMatch.score >= score {
                continue
            }
            bestMatch = (
                row: row,
                col: col,
                cursorRow: currentSnapshot.cursorRow == row ? row : intent.cursorRow,
                cursorCol: currentSnapshot.cursorRow == row ? currentSnapshot.cursorCol : intent.cursorCol,
                score: score
            )
        }
        return bestMatch.map { ($0.row, $0.col, $0.cursorRow, $0.cursorCol) }
    }

    private static func insertAlignmentScore(
        row: Int,
        col: Int,
        columnWidth: Int,
        baselineSnapshot: TerminalViewportTextSnapshot,
        currentSnapshot: TerminalViewportTextSnapshot
    ) -> Int {
        let prefix = contiguousPrefixEquality(
            row: row,
            endCol: col,
            baselineSnapshot: baselineSnapshot,
            currentSnapshot: currentSnapshot
        )
        let suffix = shiftedSuffixEqualityForInsert(
            row: row,
            col: col,
            columnWidth: columnWidth,
            baselineSnapshot: baselineSnapshot,
            currentSnapshot: currentSnapshot
        )
        return prefix + suffix
    }

    private static func deleteAlignmentScore(
        row: Int,
        col: Int,
        columnWidth: Int,
        baselineSnapshot: TerminalViewportTextSnapshot,
        currentSnapshot: TerminalViewportTextSnapshot
    ) -> Int {
        let prefix = contiguousPrefixEquality(
            row: row,
            endCol: col,
            baselineSnapshot: baselineSnapshot,
            currentSnapshot: currentSnapshot
        )
        let suffix = shiftedSuffixEqualityForDelete(
            row: row,
            col: col,
            columnWidth: columnWidth,
            baselineSnapshot: baselineSnapshot,
            currentSnapshot: currentSnapshot
        )
        return prefix + suffix
    }

    private static func contiguousPrefixEquality(
        row: Int,
        endCol: Int,
        baselineSnapshot: TerminalViewportTextSnapshot,
        currentSnapshot: TerminalViewportTextSnapshot
    ) -> Int {
        guard endCol > 0 else { return 0 }
        var score = 0
        for col in 0..<min(endCol, min(baselineSnapshot.cols, currentSnapshot.cols)) {
            if baselineSnapshot.cells[row][col] == currentSnapshot.cells[row][col] {
                score += 1
            } else {
                break
            }
        }
        return score
    }

    private static func shiftedSuffixEqualityForInsert(
        row: Int,
        col: Int,
        columnWidth: Int,
        baselineSnapshot: TerminalViewportTextSnapshot,
        currentSnapshot: TerminalViewportTextSnapshot
    ) -> Int {
        guard col + columnWidth <= currentSnapshot.cols else { return 0 }
        var score = 0
        var baselineCol = col
        var currentCol = col + columnWidth
        while baselineCol < baselineSnapshot.cols, currentCol < currentSnapshot.cols {
            if baselineSnapshot.cells[row][baselineCol] == currentSnapshot.cells[row][currentCol] {
                score += 1
            }
            baselineCol += 1
            currentCol += 1
        }
        return score
    }

    private static func shiftedSuffixEqualityForDelete(
        row: Int,
        col: Int,
        columnWidth: Int,
        baselineSnapshot: TerminalViewportTextSnapshot,
        currentSnapshot: TerminalViewportTextSnapshot
    ) -> Int {
        guard col + columnWidth <= baselineSnapshot.cols else { return 0 }
        var score = 0
        var baselineCol = col + columnWidth
        var currentCol = col
        while baselineCol < baselineSnapshot.cols, currentCol < currentSnapshot.cols {
            if baselineSnapshot.cells[row][baselineCol] == currentSnapshot.cells[row][currentCol] {
                score += 1
            }
            baselineCol += 1
            currentCol += 1
        }
        return score
    }

    private static func sharedPrefixCount(_ lhs: String, _ rhs: String) -> Int {
        let lhsChars = Array(lhs)
        let rhsChars = Array(rhs)
        let limit = min(lhsChars.count, rhsChars.count)
        var count = 0
        while count < limit, lhsChars[count] == rhsChars[count] {
            count += 1
        }
        return count
    }

    private static func sharedSuffixCount(_ lhs: String, _ rhs: String) -> Int {
        let lhsChars = Array(lhs)
        let rhsChars = Array(rhs)
        let limit = min(lhsChars.count, rhsChars.count)
        var count = 0
        while count < limit,
              lhsChars[lhsChars.count - 1 - count] == rhsChars[rhsChars.count - 1 - count] {
            count += 1
        }
        return count
    }

    private static func displayColumnCount(ofPrefix prefix: String) -> Int {
        prefix.unicodeScalars.reduce(0) { partial, scalar in
            partial + max(CharacterWidth.width(of: scalar.value), 1)
        }
    }

    private static func cursorAdjacentInsertLocation(
        text: String,
        columnWidth: Int,
        baselineSnapshot: TerminalViewportTextSnapshot,
        in snapshot: TerminalViewportTextSnapshot
    ) -> (row: Int, col: Int)? {
        let row = snapshot.cursorRow
        let col = snapshot.cursorCol - columnWidth
        guard row >= 0,
              row < snapshot.rows,
              col >= 0,
              snapshot.text(at: row, col: col, columnWidth: columnWidth) == text,
              baselineSnapshot.text(at: row, col: col, columnWidth: columnWidth) != text else {
            return nil
        }
        return (row, col)
    }

    private static func canTreatAsConfirmedInsert(
        _ matchedLocation: (row: Int, col: Int),
        intent: CommittedTextAnimationIntent,
        currentSnapshot: TerminalViewportTextSnapshot,
        diff: DiffSummary
    ) -> Bool {
        guard let rowChange = diff.rowChanges[matchedLocation.row],
              rowChange.count > 0 else {
            return false
        }

        let matchedMaxCol = matchedLocation.col + max(intent.columnWidth - 1, 0)
        let rowTouchesMatchedRange = (rowChange.minCol ?? matchedLocation.col) <= matchedMaxCol &&
            (rowChange.maxCol ?? matchedLocation.col) >= matchedLocation.col
        guard rowTouchesMatchedRange else { return false }

        let cursorGap = currentSnapshot.cursorCol - (matchedLocation.col + intent.columnWidth)
        let cursorSharesRow = currentSnapshot.cursorRow == matchedLocation.row &&
            cursorGap >= 0 &&
            cursorGap <= max(3, intent.columnWidth + 1)

        if rowChange.count <= min(128, currentSnapshot.cols) &&
            cursorSharesRow {
            return true
        }

        let staysNearOriginalColumn = matchedLocation.row == intent.row &&
            abs(matchedLocation.col - intent.col) <= max(8, intent.columnWidth + 4)
        if rowChange.count <= min(24, currentSnapshot.cols / 2) &&
            staysNearOriginalColumn {
            return true
        }

        return false
    }

    private static func canTreatAsConfirmedDelete(
        _ intent: CommittedTextAnimationIntent,
        currentSnapshot: TerminalViewportTextSnapshot,
        diff: DiffSummary
    ) -> Bool {
        guard let rowChange = diff.rowChanges[intent.row],
              rowChange.count > 0 else {
            return false
        }

        let deletedMaxCol = intent.col + max(intent.columnWidth - 1, 0)
        let rowTouchesDeletedRange = (rowChange.minCol ?? intent.col) <= deletedMaxCol &&
            (rowChange.maxCol ?? intent.col) >= intent.col
        guard rowTouchesDeletedRange else { return false }

        let cursorSharesRow = currentSnapshot.cursorRow == intent.row &&
            currentSnapshot.cursorCol >= intent.col &&
            currentSnapshot.cursorCol <= intent.col + max(2, intent.columnWidth)

        if rowChange.count <= 64 && cursorSharesRow {
            return true
        }

        return isDiffLocal(diff, expectedRow: intent.row, expectedCol: intent.col, tolerance: max(4, intent.columnWidth + 2))
    }

    private static func isDiffLocal(
        _ diff: DiffSummary,
        expectedRow: Int,
        expectedCol: Int,
        tolerance: Int
    ) -> Bool {
        guard let minRow = diff.minRow,
              let maxRow = diff.maxRow,
              let minCol = diff.minCol,
              let maxCol = diff.maxCol else {
            return false
        }
        let rowDistance = max(abs(minRow - expectedRow), abs(maxRow - expectedRow))
        let colDistance = max(abs(minCol - expectedCol), abs(maxCol - expectedCol))
        return rowDistance <= 1 && colDistance <= tolerance
    }

    private static func diffSummary(
        from baseline: TerminalViewportTextSnapshot,
        to current: TerminalViewportTextSnapshot,
        limit: Int
    ) -> DiffSummary {
        var count = 0
        var minRow: Int?
        var maxRow: Int?
        var minCol: Int?
        var maxCol: Int?
        var rowChanges: [Int: DiffSummary.RowChange] = [:]
        var exceededLimit = false

        for row in 0..<min(baseline.rows, current.rows) {
            for col in 0..<min(baseline.cols, current.cols) {
                if baseline.cells[row][col] == current.cells[row][col] {
                    continue
                }
                count += 1
                minRow = min(minRow ?? row, row)
                maxRow = max(maxRow ?? row, row)
                minCol = min(minCol ?? col, col)
                maxCol = max(maxCol ?? col, col)
                var rowChange = rowChanges[row] ?? DiffSummary.RowChange()
                rowChange.record(col: col)
                rowChanges[row] = rowChange
                if count >= limit {
                    exceededLimit = true
                }
            }
        }

        return DiffSummary(
            count: count,
            minRow: minRow,
            maxRow: maxRow,
            minCol: minCol,
            maxCol: maxCol,
            rowChanges: rowChanges,
            exceededLimit: exceededLimit
        )
    }
}

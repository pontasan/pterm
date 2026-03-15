import Foundation

/// Terminal character grid.
/// Stores a 2D array of cells representing the visible terminal screen.
/// Each row has a `isWrapped` flag indicating whether it is a soft-wrapped
/// continuation of the previous row (as opposed to a hard line break).
final class TerminalGrid {
    /// Number of rows
    private(set) var rows: Int

    /// Number of columns
    private(set) var cols: Int

    /// Cell storage: row-major order
    fileprivate var cells: [Cell]

    /// Per-row wrap flags packed into 64-bit words.
    fileprivate var lineWrappedWords: [UInt64]

    /// Snapshot of per-row wrap flags for local transforms and tests.
    var lineWrapped: [Bool] {
        (0..<rows).map(isWrapped)
    }

    /// Scroll region top (inclusive, 0-based)
    var scrollTop: Int = 0

    /// Scroll region bottom (inclusive, 0-based)
    var scrollBottom: Int

    init(rows: Int, cols: Int) {
        self.rows = rows
        self.cols = cols
        self.scrollBottom = rows - 1
        self.cells = Array(repeating: Cell.empty, count: rows * cols)
        self.lineWrappedWords = Array(repeating: 0, count: Self.wrapWordCount(for: rows))
    }

    // MARK: - Cell Access

    /// Get cell at (row, col). Returns empty cell if out of bounds.
    func cell(at row: Int, col: Int) -> Cell {
        guard row >= 0, row < rows, col >= 0, col < cols else {
            return Cell.empty
        }
        return cells[row * cols + col]
    }

    /// Set cell at (row, col). No-op if out of bounds.
    func setCell(_ cell: Cell, at row: Int, col: Int) {
        guard row >= 0, row < rows, col >= 0, col < cols else { return }
        cells[row * cols + col] = cell
    }

    // MARK: - Wrap Flag

    /// Mark a row as a soft-wrapped continuation of the previous row.
    func setWrapped(_ row: Int, _ wrapped: Bool) {
        guard row >= 0, row < rows else { return }
        let (wordIndex, bitMask) = Self.wrapBitLocation(for: row)
        if wrapped {
            lineWrappedWords[wordIndex] |= bitMask
        } else {
            lineWrappedWords[wordIndex] &= ~bitMask
        }
    }

    /// Check if a row is soft-wrapped.
    func isWrapped(_ row: Int) -> Bool {
        guard row >= 0, row < rows else { return false }
        let (wordIndex, bitMask) = Self.wrapBitLocation(for: row)
        return (lineWrappedWords[wordIndex] & bitMask) != 0
    }

    // MARK: - Line Operations

    /// Clear a range of cells in a row to empty.
    func clearCells(row: Int, fromCol: Int, toCol: Int) {
        guard row >= 0, row < rows else { return }
        let start = max(0, fromCol)
        let end = min(cols, toCol + 1)
        for col in start..<end {
            cells[row * cols + col] = Cell.empty
        }
    }

    /// Clear entire row.
    func clearRow(_ row: Int) {
        clearCells(row: row, fromCol: 0, toCol: cols - 1)
        if row >= 0 && row < rows {
            setWrapped(row, false)
        }
    }

    /// Clear entire grid.
    func clearAll() {
        cells = Array(repeating: Cell.empty, count: rows * cols)
        resetWrapStorage(for: rows)
    }

    // MARK: - Scrolling

    /// Scroll the scroll region up by `count` lines.
    /// Top lines are removed, bottom lines filled with empty cells.
    func scrollUp(count: Int = 1) {
        guard count > 0 else { return }
        let top = scrollTop
        let bottom = scrollBottom
        let regionHeight = bottom - top + 1

        if count >= regionHeight {
            for row in top...bottom {
                clearRow(row)
            }
            return
        }

        // Move lines up
        for row in top...(bottom - count) {
            let srcOffset = (row + count) * cols
            let dstOffset = row * cols
            cells.replaceSubrange(dstOffset..<(dstOffset + cols),
                                  with: cells[srcOffset..<(srcOffset + cols)])
            setWrapped(row, isWrapped(row + count))
        }

        // Clear newly exposed lines at bottom
        for row in (bottom - count + 1)...bottom {
            clearRow(row)
        }
    }

    /// Scroll the scroll region down by `count` lines.
    /// Bottom lines are removed, top lines filled with empty cells.
    func scrollDown(count: Int = 1) {
        guard count > 0 else { return }
        let top = scrollTop
        let bottom = scrollBottom
        let regionHeight = bottom - top + 1

        if count >= regionHeight {
            for row in top...bottom {
                clearRow(row)
            }
            return
        }

        // Move lines down (iterate from bottom to avoid overwrite)
        for row in stride(from: bottom, through: top + count, by: -1) {
            let srcOffset = (row - count) * cols
            let dstOffset = row * cols
            cells.replaceSubrange(dstOffset..<(dstOffset + cols),
                                  with: cells[srcOffset..<(srcOffset + cols)])
            setWrapped(row, isWrapped(row - count))
        }

        // Clear newly exposed lines at top
        for row in top..<(top + count) {
            clearRow(row)
        }
    }

    /// A row that was trimmed from the grid during resize.
    struct TrimmedRow {
        let cells: [Cell]
        let isWrapped: Bool
    }

    /// Result of a resize operation.
    struct ResizeResult {
        let cursorRow: Int
        let cursorCol: Int
        /// Rows that were pushed off the top of the grid.
        /// These should be saved to scrollback to prevent data loss.
        let trimmedRows: [TrimmedRow]
    }

    // MARK: - Resize with Re-wrap

    /// Resize the grid with intelligent line re-wrapping.
    /// Returns the new cursor position and any rows trimmed from the top
    /// (which the caller should save to scrollback).
    func resize(newRows: Int, newCols: Int, cursorRow: Int, cursorCol: Int) -> ResizeResult {
        if newCols == cols {
            // Column count unchanged — simple row adjustment
            return resizeRowsOnly(newRows: newRows, cursorRow: cursorRow, cursorCol: cursorCol)
        }

        // 1. Collect logical lines by joining soft-wrapped rows
        let logicalLines = collectLogicalLines()

        // 2. Find cursor position in logical line space
        let (cursorLogicalIdx, cursorLogicalCol) = mapCursorToLogical(
            cursorRow: cursorRow, cursorCol: cursorCol)

        // 3. Re-wrap logical lines at new column width
        var newCells = [Cell]()
        var newWrapped = [Bool]()
        var newCursorRow = 0
        var newCursorCol = cursorLogicalCol

        for (lineIdx, logicalLine) in logicalLines.enumerated() {
            let wrappedRows = wrapLogicalLine(logicalLine, cols: newCols)

            for (rowInLine, rowCells) in wrappedRows.enumerated() {
                // Track cursor position
                if lineIdx == cursorLogicalIdx {
                    let offsetInLine = rowInLine * newCols
                    if cursorLogicalCol >= offsetInLine &&
                       cursorLogicalCol < offsetInLine + newCols {
                        newCursorRow = newCells.count / newCols
                        newCursorCol = cursorLogicalCol - offsetInLine
                    }
                }

                newCells.append(contentsOf: rowCells)
                // Pad to full row width
                if rowCells.count < newCols {
                    newCells.append(contentsOf:
                        Array(repeating: Cell.empty, count: newCols - rowCells.count))
                }

                // First row of a logical line: not wrapped. Subsequent: wrapped.
                newWrapped.append(rowInLine > 0)
            }
        }

        // 4. Trim or pad to newRows
        let totalRows = newCells.count / newCols
        var trimmedRows: [TrimmedRow] = []

        if totalRows > newRows {
            // Capture excess rows from the top before discarding
            let excessRows = totalRows - newRows
            for i in 0..<excessRows {
                let start = i * newCols
                let rowCells = Array(newCells[start..<(start + newCols)])
                trimmedRows.append(TrimmedRow(cells: rowCells, isWrapped: newWrapped[i]))
            }
            newCells.removeFirst(excessRows * newCols)
            newWrapped.removeFirst(excessRows)
            newCursorRow -= excessRows
        } else if totalRows < newRows {
            let padRows = newRows - totalRows
            newCells.append(contentsOf:
                Array(repeating: Cell.empty, count: padRows * newCols))
            newWrapped.append(contentsOf:
                Array(repeating: false, count: padRows))
        }

        self.rows = newRows
        self.cols = newCols
        self.cells = newCells
        self.setWrappedFlags(newWrapped)
        self.scrollTop = 0
        self.scrollBottom = newRows - 1

        let clampedRow = max(0, min(newRows - 1, newCursorRow))
        let clampedCol = max(0, min(newCols - 1, newCursorCol))
        return ResizeResult(cursorRow: clampedRow, cursorCol: clampedCol, trimmedRows: trimmedRows)
    }

    /// Simple row-only resize (column count unchanged).
    private func resizeRowsOnly(newRows: Int, cursorRow: Int, cursorCol: Int) -> ResizeResult {
        var newCursorRow = cursorRow
        var trimmedRows: [TrimmedRow] = []

        if newRows < rows {
            // Shrinking: if cursor is below new bottom, scroll content up
            if cursorRow >= newRows {
                let scrollAmount = cursorRow - newRows + 1
                // Capture rows being scrolled out
                for i in 0..<scrollAmount {
                    let start = i * cols
                    let rowCells = Array(cells[start..<(start + cols)])
                    trimmedRows.append(TrimmedRow(cells: rowCells, isWrapped: isWrapped(i)))
                }
                cells.removeFirst(scrollAmount * cols)
                var newWrapped = wrappedFlagsArray(startingAt: scrollAmount, count: rows - scrollAmount)
                cells.append(contentsOf:
                    Array(repeating: Cell.empty, count: scrollAmount * cols))
                newWrapped.append(contentsOf: Array(repeating: false, count: scrollAmount))
                setWrappedFlags(newWrapped)
                newCursorRow -= scrollAmount
            }
            // Trim to newRows
            cells = Array(cells.prefix(newRows * cols))
            setWrappedFlags(wrappedFlagsArray(startingAt: 0, count: newRows))
        } else if newRows > rows {
            // Growing: add empty rows at bottom
            let padRows = newRows - rows
            cells.append(contentsOf:
                Array(repeating: Cell.empty, count: padRows * cols))
            var newWrapped = wrappedFlagsArray(startingAt: 0, count: rows)
            newWrapped.append(contentsOf: Array(repeating: false, count: padRows))
            setWrappedFlags(newWrapped)
        }

        self.rows = newRows
        self.scrollTop = 0
        self.scrollBottom = newRows - 1

        return ResizeResult(
            cursorRow: max(0, min(newRows - 1, newCursorRow)),
            cursorCol: cursorCol,
            trimmedRows: trimmedRows
        )
    }

    /// Collect logical lines by joining soft-wrapped rows.
    private func collectLogicalLines() -> [[Cell]] {
        var logicalLines = [[Cell]]()
        var currentLine = [Cell]()

        for row in 0..<rows {
            let offset = row * cols
            let rowCells = Array(cells[offset..<(offset + cols)])

            if row == 0 || !isWrapped(row) {
                // Start of a new logical line
                if row > 0 {
                    logicalLines.append(currentLine)
                }
                currentLine = trimTrailingEmpty(rowCells)
            } else {
                // Continuation (soft wrap) — append to current logical line
                // Restore to full width before appending
                let fullPrev = padToWidth(currentLine, width: cols)
                currentLine = fullPrev + trimTrailingEmpty(rowCells)
            }
        }
        logicalLines.append(currentLine)

        return logicalLines
    }

    /// Map cursor position (row, col) to logical line index and offset.
    private func mapCursorToLogical(cursorRow: Int, cursorCol: Int) -> (lineIdx: Int, colInLine: Int) {
        var logicalIdx = 0
        var rowInLogical = 0

        for row in 0..<rows {
            if row > 0 && !isWrapped(row) {
                logicalIdx += 1
                rowInLogical = 0
            }
            if row == cursorRow {
                return (logicalIdx, rowInLogical * cols + cursorCol)
            }
            rowInLogical += 1
        }
        return (logicalIdx, cursorCol)
    }

    /// Wrap a logical line of cells into rows of the given width.
    private func wrapLogicalLine(_ line: [Cell], cols newCols: Int) -> [[Cell]] {
        if line.isEmpty {
            return [[]]  // One empty row
        }

        var result = [[Cell]]()
        var idx = 0

        while idx < line.count {
            let end = min(idx + newCols, line.count)
            let row = Array(line[idx..<end])
            result.append(row)
            idx = end
        }

        if result.isEmpty {
            result.append([])
        }

        return result
    }

    /// Trim trailing empty (space) cells from a row.
    private func trimTrailingEmpty(_ rowCells: [Cell]) -> [Cell] {
        var end = rowCells.count
        while end > 0 && rowCells[end - 1].codepoint == 0x20
                       && rowCells[end - 1].attributes == .default {
            end -= 1
        }
        return Array(rowCells.prefix(end))
    }

    /// Pad a cell array to a given width with empty cells.
    private func padToWidth(_ line: [Cell], width: Int) -> [Cell] {
        if line.count >= width { return line }
        return line + Array(repeating: Cell.empty, count: width - line.count)
    }

    // MARK: - Row Data

    /// Get raw cell data for a row (for ring buffer storage).
    func rowCells(_ row: Int) -> ArraySlice<Cell> {
        guard row >= 0, row < rows else { return [] }
        let start = row * cols
        return cells[start..<(start + cols)]
    }

    /// Insert blank cells at column, shifting existing cells right.
    func insertBlanks(row: Int, col: Int, count: Int) {
        guard row >= 0, row < rows, col >= 0, col < cols else { return }
        let offset = row * cols
        let shift = min(count, cols - col)

        // Shift cells right
        for c in stride(from: cols - 1, through: col + shift, by: -1) {
            cells[offset + c] = cells[offset + c - shift]
        }

        // Fill inserted cells with empty
        for c in col..<min(col + shift, cols) {
            cells[offset + c] = Cell.empty
        }
    }

    /// Delete cells at column, shifting remaining cells left.
    func deleteCells(row: Int, col: Int, count: Int) {
        guard row >= 0, row < rows, col >= 0, col < cols else { return }
        let offset = row * cols
        let shift = min(count, cols - col)

        // Shift cells left
        for c in col..<(cols - shift) {
            cells[offset + c] = cells[offset + c + shift]
        }

        // Fill vacated cells at end with empty
        for c in (cols - shift)..<cols {
            cells[offset + c] = Cell.empty
        }
    }

    // MARK: - Wrap Storage

    private static func wrapWordCount(for rows: Int) -> Int {
        max(0, (rows + 63) / 64)
    }

    private static func wrapBitLocation(for row: Int) -> (wordIndex: Int, bitMask: UInt64) {
        (row / 64, UInt64(1) << UInt64(row % 64))
    }

    private func resetWrapStorage(for rows: Int) {
        lineWrappedWords = Array(repeating: 0, count: Self.wrapWordCount(for: rows))
    }

    private func setWrappedFlags(_ wrappedFlags: [Bool]) {
        lineWrappedWords = Array(repeating: 0, count: Self.wrapWordCount(for: wrappedFlags.count))
        for (row, wrapped) in wrappedFlags.enumerated() where wrapped {
            let (wordIndex, bitMask) = Self.wrapBitLocation(for: row)
            lineWrappedWords[wordIndex] |= bitMask
        }
    }

    private func wrappedFlagsArray(startingAt startRow: Int, count: Int) -> [Bool] {
        guard count > 0 else { return [] }
        var wrappedFlags: [Bool] = []
        wrappedFlags.reserveCapacity(count)
        for row in startRow..<(startRow + count) {
            wrappedFlags.append(isWrapped(row))
        }
        return wrappedFlags
    }

    // MARK: - Snapshot

    /// Return a frozen copy of this grid for lock-free rendering.
    func snapshot() -> TerminalGrid {
        let copy = TerminalGrid(rows: rows, cols: cols)
        copy.cells = cells
        copy.lineWrappedWords = lineWrappedWords
        copy.scrollTop = scrollTop
        copy.scrollBottom = scrollBottom
        return copy
    }
}

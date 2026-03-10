import Foundation

/// Terminal character grid.
/// Stores a 2D array of cells representing the visible terminal screen.
final class TerminalGrid {
    /// Number of rows
    private(set) var rows: Int

    /// Number of columns
    private(set) var cols: Int

    /// Cell storage: row-major order
    private var cells: [Cell]

    /// Scroll region top (inclusive, 0-based)
    var scrollTop: Int = 0

    /// Scroll region bottom (inclusive, 0-based)
    var scrollBottom: Int

    init(rows: Int, cols: Int) {
        self.rows = rows
        self.cols = cols
        self.scrollBottom = rows - 1
        self.cells = Array(repeating: Cell.empty, count: rows * cols)
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
    }

    /// Clear entire grid.
    func clearAll() {
        cells = Array(repeating: Cell.empty, count: rows * cols)
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
            // Clear entire scroll region
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
        }

        // Clear newly exposed lines at top
        for row in top..<(top + count) {
            clearRow(row)
        }
    }

    // MARK: - Resize

    /// Resize the grid. Preserves content where possible.
    func resize(newRows: Int, newCols: Int) {
        var newCells = Array(repeating: Cell.empty, count: newRows * newCols)

        let copyRows = min(rows, newRows)
        let copyCols = min(cols, newCols)

        for row in 0..<copyRows {
            for col in 0..<copyCols {
                newCells[row * newCols + col] = cells[row * cols + col]
            }
        }

        self.rows = newRows
        self.cols = newCols
        self.cells = newCells
        self.scrollTop = 0
        self.scrollBottom = newRows - 1
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
}

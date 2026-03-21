import Foundation

/// Represents a position in the terminal grid.
struct GridPosition: Equatable {
    var row: Int
    var col: Int
}

/// Selection mode: normal (line-continuous) or rectangular (column).
enum SelectionMode {
    case normal
    case rectangular
}

/// Manages text selection state for a terminal.
///
/// Supports two modes:
/// - Normal selection: continuous text from start to end, wrapping across lines.
/// - Rectangular selection: a rectangular (column) region defined by two corners.
struct TerminalSelection {
    /// Anchor point (where the selection started)
    var anchor: GridPosition

    /// Active point (where the cursor/mouse currently is)
    var active: GridPosition

    /// Selection mode
    var mode: SelectionMode

    /// Whether the selection is currently active (user is dragging)
    var isDragging: Bool = false

    init(anchor: GridPosition, active: GridPosition, mode: SelectionMode) {
        self.anchor = anchor
        self.active = active
        self.mode = mode
    }

    /// Normalized start position (top-left for rectangular, earlier position for normal).
    var start: GridPosition {
        switch mode {
        case .normal:
            if anchor.row < active.row || (anchor.row == active.row && anchor.col <= active.col) {
                return anchor
            }
            return active
        case .rectangular:
            return GridPosition(row: min(anchor.row, active.row),
                              col: min(anchor.col, active.col))
        }
    }

    /// Normalized end position (bottom-right for rectangular, later position for normal).
    var end: GridPosition {
        switch mode {
        case .normal:
            if anchor.row < active.row || (anchor.row == active.row && anchor.col <= active.col) {
                return active
            }
            return anchor
        case .rectangular:
            return GridPosition(row: max(anchor.row, active.row),
                              col: max(anchor.col, active.col))
        }
    }

    /// Check if a cell at (row, col) is within the selection.
    func contains(row: Int, col: Int) -> Bool {
        let s = start
        let e = end

        switch mode {
        case .normal:
            if row < s.row || row > e.row { return false }
            if s.row == e.row {
                return col >= s.col && col <= e.col
            }
            if row == s.row { return col >= s.col }
            if row == e.row { return col <= e.col }
            return true

        case .rectangular:
            return row >= s.row && row <= e.row && col >= s.col && col <= e.col
        }
    }

    /// Check if the selection is empty (zero-size).
    var isEmpty: Bool {
        return anchor == active
    }

    /// Word delimiter characters for double-click word selection.
    private static let wordDelimiters: Set<UInt32> = {
        var set = Set<UInt32>()
        let chars = " \t!@#$%^&*()-=+[]{}|;:'\",.<>?/\\`"
        for scalar in chars.unicodeScalars {
            set.insert(scalar.value)
        }
        return set
    }()

    /// Check if a codepoint is a word delimiter.
    static func isWordDelimiter(_ codepoint: UInt32) -> Bool {
        return codepoint <= 0x20 || wordDelimiters.contains(codepoint)
    }

    /// Extract selected text from a terminal grid.
    func extractText(from grid: TerminalGrid) -> String {
        guard !isEmpty else { return "" }
        let s = start
        let e = end

        var result = ""

        switch mode {
        case .normal:
            for row in s.row...e.row {
                let colStart = (row == s.row) ? s.col : 0
                let colEnd = (row == e.row) ? e.col : grid.cols - 1

                for col in colStart...colEnd {
                    let cell = grid.cell(at: row, col: col)
                    if cell.isWideContinuation { continue }
                    result.append(cell.renderedString())
                }

                // Add newline between rows (not after the last row)
                if row < e.row {
                    // Trim trailing spaces before adding newline
                    while result.hasSuffix(" ") {
                        result.removeLast()
                    }
                    if !grid.isWrapped(row + 1) {
                        result.append("\n")
                    }
                }
            }

        case .rectangular:
            for row in s.row...e.row {
                for col in s.col...min(e.col, grid.cols - 1) {
                    let cell = grid.cell(at: row, col: col)
                    if cell.isWideContinuation { continue }
                    result.append(cell.renderedString())
                }
                if row < e.row {
                    while result.hasSuffix(" ") {
                        result.removeLast()
                    }
                    result.append("\n")
                }
            }
        }

        return result
    }

    /// Create a word selection around the given position.
    static func wordSelection(at pos: GridPosition, in grid: TerminalGrid) -> TerminalSelection {
        let row = pos.row

        // Find word start (scan left)
        var colStart = pos.col
        while colStart > 0 {
            let cell = grid.cell(at: row, col: colStart - 1)
            if isWordDelimiter(cell.codepoint) { break }
            colStart -= 1
        }

        // Find word end (scan right)
        var colEnd = pos.col
        while colEnd < grid.cols - 1 {
            let cell = grid.cell(at: row, col: colEnd + 1)
            if isWordDelimiter(cell.codepoint) { break }
            colEnd += 1
        }

        return TerminalSelection(
            anchor: GridPosition(row: row, col: colStart),
            active: GridPosition(row: row, col: colEnd),
            mode: .normal
        )
    }

    /// Create a line selection for the given row.
    static func lineSelection(row: Int, cols: Int) -> TerminalSelection {
        return TerminalSelection(
            anchor: GridPosition(row: row, col: 0),
            active: GridPosition(row: row, col: cols - 1),
            mode: .normal
        )
    }

    /// Return a new selection with all row values shifted by the given delta.
    func offsetRows(by delta: Int) -> TerminalSelection {
        var result = self
        result.anchor.row += delta
        result.active.row += delta
        return result
    }

    /// Clamp the selection rows to the given range, returning a potentially empty selection.
    func clampedToRowRange(_ range: Range<Int>) -> TerminalSelection {
        guard !range.isEmpty else {
            return TerminalSelection(anchor: GridPosition(row: 0, col: 0),
                                     active: GridPosition(row: 0, col: 0),
                                     mode: mode)
        }
        let s = start
        let e = end
        // If the selection is entirely outside the range, return empty
        if e.row < range.lowerBound || s.row >= range.upperBound {
            return TerminalSelection(anchor: GridPosition(row: 0, col: 0),
                                     active: GridPosition(row: 0, col: 0),
                                     mode: mode)
        }
        var result = self
        // Clamp anchor and active row values
        result.anchor.row = max(range.lowerBound, min(range.upperBound - 1, result.anchor.row))
        result.active.row = max(range.lowerBound, min(range.upperBound - 1, result.active.row))
        // If the clamped start row is after the original, reset start col to 0
        if result.start.row > s.row {
            if result.anchor.row == result.start.row && anchor.row < active.row {
                result.anchor.col = 0
            } else if result.active.row == result.start.row && active.row < anchor.row {
                result.active.col = 0
            }
        }
        return result
    }
}

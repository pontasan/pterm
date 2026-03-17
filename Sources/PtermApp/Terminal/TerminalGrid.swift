import Foundation

/// Terminal character grid.
/// Stores a 2D array of cells representing the visible terminal screen.
/// Each row has a `isWrapped` flag indicating whether it is a soft-wrapped
/// continuation of the previous row (as opposed to a hard line break).
final class TerminalGrid {
    /// Row content hints are intentionally layout-independent.
    /// Resize/reflow invalidates wrap/visible layout state, but "can this row be
    /// serialized as compact default/uniform/full?" depends only on the row's cells.
    /// We therefore track per-physical-row content hints here and either keep them
    /// exact across simple mutations or mark them dirty for on-demand recomputation.
    private enum RowEncodingHintState {
        case blankDefault
        case compactDefault(serializedCount: Int)
        case dirty
    }

    private static let defaultASCIIByteCells: [Cell] = (0..<128).map { byte in
        if byte == 0x20 {
            return .empty
        }
        return Cell(
            codepoint: UInt32(byte),
            attributes: .default,
            width: 1,
            isWideContinuation: false
        )
    }
    private static let defaultWideContinuationCell = Cell(
        codepoint: 0,
        attributes: .default,
        width: 0,
        isWideContinuation: true
    )

    /// Number of rows
    private(set) var rows: Int

    /// Number of columns
    private(set) var cols: Int

    /// Cell storage: row-major order
    private var cells: [Cell]
    private var emptyRowTemplate: [Cell]
    private var rowEncodingHintStates: [RowEncodingHintState]

    /// Logical row -> physical storage row mapping.
    /// Scroll operations rotate this indirection instead of physically
    /// copying every row's cells on each line feed.
    private var rowOrder: [Int]
    private var hasRowPermutation = false
    /// Fast path for full-screen scroll: logical row 0 maps to rowOrder[rowOrderHead].
    /// Partial region transforms first normalize this head back into rowOrder itself.
    private var rowOrderHead = 0

    /// Wrap flags are stored per physical row so row rotation automatically
    /// carries wrap state with the row content.
    private var physicalWrappedFlags: [Bool]
    private var physicalLineAttributes: [TerminalLineAttribute]
    private var nonSingleWidthLineCount: Int
    private var physicalMayContainProtectedCells: [Bool]
    /// Blank rows are tracked as metadata so scroll-heavy workloads can expose
    /// fresh empty rows without touching `cols` cells on every line feed.
    /// Writers materialize the row lazily before mutating individual cells.
    private var physicalBlankRows: [Bool]
    /// Short default-attribute ASCII rows can stay sparse while they are only
    /// built as a contiguous prefix from column 0. This avoids materializing an
    /// entire viewport-width row for workloads like `seq` that mostly write a
    /// handful of digits and immediately line-feed.
    private var physicalSparseCompactDefaultPrefixCounts: [Int]

    /// Snapshot of per-row wrap flags for local transforms and tests.
    var lineWrapped: [Bool] {
        (0..<rows).map(isWrapped)
    }

    /// Scroll region top (inclusive, 0-based)
    var scrollTop: Int = 0

    /// Scroll region bottom (inclusive, 0-based)
    var scrollBottom: Int
    /// Alternate screen never serializes into scrollback, so exact compact-row
    /// hint maintenance can be disabled there to keep mutation hot paths lean.
    var tracksPreciseRowEncodingHints = true

    convenience init(rows: Int, cols: Int) {
        self.init(rows: rows, cols: cols, allocateStorage: true)
    }

    private init(rows: Int, cols: Int, allocateStorage: Bool) {
        self.rows = rows
        self.cols = cols
        self.scrollBottom = rows - 1
        self.cells = allocateStorage ? Array(repeating: Cell.empty, count: rows * cols) : []
        self.emptyRowTemplate = allocateStorage ? Array(repeating: Cell.empty, count: cols) : []
        self.rowEncodingHintStates = allocateStorage ? Array(repeating: .blankDefault, count: rows) : []
        self.rowOrder = []
        self.physicalWrappedFlags = allocateStorage ? Array(repeating: false, count: rows) : []
        self.physicalLineAttributes = allocateStorage ? Array(repeating: .singleWidth, count: rows) : []
        self.nonSingleWidthLineCount = 0
        self.physicalMayContainProtectedCells = allocateStorage ? Array(repeating: false, count: rows) : []
        self.physicalBlankRows = allocateStorage ? Array(repeating: true, count: rows) : []
        self.physicalSparseCompactDefaultPrefixCounts = allocateStorage ? Array(repeating: 0, count: rows) : []
    }

    // MARK: - Cell Access

    /// Get cell at (row, col). Returns empty cell if out of bounds.
    func cell(at row: Int, col: Int) -> Cell {
        let dimensions = readableDimensions()
        guard row >= 0, row < dimensions.rows, col >= 0, col < dimensions.cols,
              let physicalRow = readablePhysicalRow(for: row, readableRowCount: dimensions.rows) else {
            return Cell.empty
        }
        if isPhysicalRowBlank(physicalRow) {
            return .empty
        }
        let sparsePrefixCount = physicalSparseCompactDefaultPrefixCounts[physicalRow]
        if sparsePrefixCount > 0, col >= sparsePrefixCount {
            return .empty
        }
        let index = physicalRow * dimensions.cols + col
        guard index >= 0, index < cells.count else {
            return .empty
        }
        return cells[index]
    }

    /// Set cell at (row, col). No-op if out of bounds.
    func setCell(_ cell: Cell, at row: Int, col: Int) {
        guard row >= 0, row < rows, col >= 0, col < cols else { return }
        let physicalRow = physicalRow(for: row)
        materializePhysicalRowIfNeeded(physicalRow)
        if cell.attributes.decProtected {
            physicalMayContainProtectedCells[physicalRow] = true
        }
        cells[physicalRow * cols + col] = cell
        guard tracksPreciseRowEncodingHints else { return }
        markRowEncodingHintDirty(row)
    }

    /// Write a contiguous run of single-width cells into one row.
    /// The caller guarantees bounds and width semantics.
    func writeSingleWidthCells(
        _ codepoints: UnsafeBufferPointer<UInt32>,
        attributes: CellAttributes,
        atRow row: Int,
        startCol: Int
    ) {
        guard !codepoints.isEmpty else { return }
        writeSingleWidthCells(
            codepoints.baseAddress!,
            count: codepoints.count,
            attributes: attributes,
            atRow: row,
            startCol: startCol
        )
    }

    func writeSingleWidthCells(
        _ codepoints: UnsafePointer<UInt32>,
        count: Int,
        attributes: CellAttributes,
        atRow row: Int,
        startCol: Int
    ) {
        guard count > 0 else { return }
        let physicalRow = physicalRow(for: row)
        materializePhysicalRowIfNeeded(physicalRow)
        let offset = physicalRow * cols + startCol
        initializeSingleWidthCells(at: offset, codepoints: codepoints, count: count, attributes: attributes)
        if attributes.decProtected {
            physicalMayContainProtectedCells[physicalRow] = true
        }
        guard tracksPreciseRowEncodingHints else {
            markRowEncodingHintDirty(row)
            return
        }
        updateCompactDefaultHintIfPossible(
            row: row,
            startCol: startCol,
            scalarProvider: { codepoints[$0] },
            count: count,
            attributes: attributes
        )
    }

    func writeSingleWidthDefaultCells(
        _ codepoints: UnsafePointer<UInt32>,
        count: Int,
        atRow row: Int,
        startCol: Int
    ) {
        guard count > 0 else { return }
        let physicalRow = physicalRow(for: row)
        let priorSparsePrefixCount = physicalSparseCompactDefaultPrefixCounts[physicalRow]
        let canUseSparseFastPath = startCol == 0 && isPhysicalRowBlank(physicalRow)
        let canExtendSparseFastPath = priorSparsePrefixCount > 0 && startCol == priorSparsePrefixCount

        if canUseSparseFastPath || canExtendSparseFastPath {
            let offset = physicalRow * cols + startCol
            initializeSingleWidthDefaultCells(at: offset, codepoints: codepoints, count: count)
            physicalBlankRows[physicalRow] = false
            physicalSparseCompactDefaultPrefixCounts[physicalRow] = startCol + count
            rowEncodingHintStates[physicalRow] = .compactDefault(serializedCount: startCol + count)
            return
        }

        materializePhysicalRowIfNeeded(physicalRow)
        let offset = physicalRow * cols + startCol
        guard tracksPreciseRowEncodingHints else {
            initializeSingleWidthDefaultCells(at: offset, codepoints: codepoints, count: count)
            markRowEncodingHintDirty(row)
            return
        }
        physicalBlankRows[physicalRow] = false
        physicalSparseCompactDefaultPrefixCounts[physicalRow] = 0
        let priorSerializedCount: Int
        switch rowEncodingHintStates[physicalRow] {
        case .blankDefault:
            priorSerializedCount = 0
        case .compactDefault(let serializedCount):
            priorSerializedCount = serializedCount
        case .dirty:
            initializeSingleWidthDefaultCells(at: offset, codepoints: codepoints, count: count)
            return
        }

        let serializedCount = initializeSingleWidthDefaultCellsTrackingSerializedCount(
            at: offset,
            codepoints: codepoints,
            count: count,
            startCol: startCol,
            priorSerializedCount: priorSerializedCount
        )
        if serializedCount >= 0 {
            rowEncodingHintStates[physicalRow] = serializedCount == 0
                ? .blankDefault
                : .compactDefault(serializedCount: serializedCount)
        } else {
            rowEncodingHintStates[physicalRow] = .dirty
        }
    }

    func writeSingleWidthASCIIBytes(
        _ bytes: UnsafePointer<UInt8>,
        count: Int,
        attributes: CellAttributes,
        atRow row: Int,
        startCol: Int
    ) {
        guard count > 0 else { return }
        let physicalRow = physicalRow(for: row)
        materializePhysicalRowIfNeeded(physicalRow)
        let offset = physicalRow * cols + startCol
        initializeSingleWidthASCIIBytes(at: offset, bytes: bytes, count: count, attributes: attributes)
        if attributes.decProtected {
            physicalMayContainProtectedCells[physicalRow] = true
        }
        guard tracksPreciseRowEncodingHints else {
            markRowEncodingHintDirty(row)
            return
        }
        updateCompactDefaultHintIfPossible(
            row: row,
            startCol: startCol,
            scalarProvider: { UInt32(bytes[$0]) },
            count: count,
            attributes: attributes
        )
    }

    func writeSingleWidthDefaultASCIIBytes(
        _ bytes: UnsafePointer<UInt8>,
        count: Int,
        atRow row: Int,
        startCol: Int
    ) {
        guard count > 0 else { return }
        let physicalRow = physicalRow(for: row)
        let priorSparsePrefixCount = physicalSparseCompactDefaultPrefixCounts[physicalRow]
        let canUseSparseFastPath = startCol == 0 && isPhysicalRowBlank(physicalRow)
        let canExtendSparseFastPath = priorSparsePrefixCount > 0 && startCol == priorSparsePrefixCount

        if canUseSparseFastPath || canExtendSparseFastPath {
            let offset = physicalRow * cols + startCol
            initializeDefaultASCIIBytes(at: offset, bytes: bytes, count: count)
            physicalBlankRows[physicalRow] = false
            physicalSparseCompactDefaultPrefixCounts[physicalRow] = startCol + count
            rowEncodingHintStates[physicalRow] = .compactDefault(serializedCount: startCol + count)
            return
        }

        materializePhysicalRowIfNeeded(physicalRow)
        let offset = physicalRow * cols + startCol
        initializeDefaultASCIIBytes(at: offset, bytes: bytes, count: count)

        switch rowEncodingHintStates[physicalRow] {
        case .dirty:
            physicalBlankRows[physicalRow] = false
        case .blankDefault:
            physicalBlankRows[physicalRow] = false
            rowEncodingHintStates[physicalRow] = .compactDefault(serializedCount: startCol + count)
        case .compactDefault(let serializedCount):
            physicalBlankRows[physicalRow] = false
            rowEncodingHintStates[physicalRow] = .compactDefault(
                serializedCount: max(serializedCount, startCol + count)
            )
        }
    }

    func writeSingleWidthDefaultASCIIBytesWithoutSpaces(
        _ bytes: UnsafePointer<UInt8>,
        count: Int,
        atRow row: Int,
        startCol: Int
    ) {
        writeSingleWidthDefaultASCIIBytes(bytes, count: count, atRow: row, startCol: startCol)
    }

    func writeRepeatedSingleWidthASCIIByte(
        _ byte: UInt8,
        count: Int,
        attributes: CellAttributes,
        atRow row: Int,
        startCol: Int
    ) {
        guard count > 0 else { return }
        if attributes == .default {
            writeRepeatedSingleWidthDefaultASCIIByte(byte, count: count, atRow: row, startCol: startCol)
            return
        }

        let physicalRow = physicalRow(for: row)
        materializePhysicalRowIfNeeded(physicalRow)
        let offset = physicalRow * cols + startCol
        let cell = Cell(
            codepoint: UInt32(byte),
            attributes: attributes,
            width: 1,
            isWideContinuation: false
        )
        fillCells(cell, count: count, at: offset)
        if attributes.decProtected {
            physicalMayContainProtectedCells[physicalRow] = true
        }
        guard tracksPreciseRowEncodingHints else {
            markRowEncodingHintDirty(row)
            return
        }
        updateCompactDefaultHintIfPossible(
            row: row,
            startCol: startCol,
            scalarProvider: { _ in UInt32(byte) },
            count: count,
            attributes: attributes
        )
    }

    func writeRepeatedSingleWidthDefaultASCIIByte(
        _ byte: UInt8,
        count: Int,
        atRow row: Int,
        startCol: Int
    ) {
        guard count > 0 else { return }
        let physicalRow = physicalRow(for: row)
        let priorSparsePrefixCount = physicalSparseCompactDefaultPrefixCounts[physicalRow]
        let canUseSparseFastPath = startCol == 0 && isPhysicalRowBlank(physicalRow)
        let canExtendSparseFastPath = priorSparsePrefixCount > 0 && startCol == priorSparsePrefixCount
        let cell = Self.defaultASCIIByteCells[Int(byte)]

        if canUseSparseFastPath || canExtendSparseFastPath {
            let offset = physicalRow * cols + startCol
            fillCells(cell, count: count, at: offset)
            physicalBlankRows[physicalRow] = false
            physicalSparseCompactDefaultPrefixCounts[physicalRow] = startCol + count
            rowEncodingHintStates[physicalRow] = .compactDefault(serializedCount: startCol + count)
            return
        }

        materializePhysicalRowIfNeeded(physicalRow)
        let offset = physicalRow * cols + startCol
        fillCells(cell, count: count, at: offset)

        switch rowEncodingHintStates[physicalRow] {
        case .dirty:
            physicalBlankRows[physicalRow] = false
        case .blankDefault:
            physicalBlankRows[physicalRow] = false
            rowEncodingHintStates[physicalRow] = .compactDefault(serializedCount: startCol + count)
        case .compactDefault(let serializedCount):
            physicalBlankRows[physicalRow] = false
            rowEncodingHintStates[physicalRow] = .compactDefault(
                serializedCount: max(serializedCount, startCol + count)
            )
        }
    }

    func writeDoubleWidthCells(
        _ codepoints: UnsafePointer<UInt32>,
        count: Int,
        attributes: CellAttributes,
        atRow row: Int,
        startCol: Int
    ) {
        guard count > 0 else { return }
        let physicalRow = physicalRow(for: row)
        materializePhysicalRowIfNeeded(physicalRow)
        let offset = physicalRow * cols + startCol
        initializeDoubleWidthCells(at: offset, codepoints: codepoints, count: count, attributes: attributes)
        if attributes.decProtected {
            physicalMayContainProtectedCells[physicalRow] = true
        }
        markRowEncodingHintDirty(row)
    }

    func writeDoubleWidthDefaultCells(
        _ codepoints: UnsafePointer<UInt32>,
        count: Int,
        atRow row: Int,
        startCol: Int
    ) {
        guard count > 0 else { return }
        let physicalRow = physicalRow(for: row)
        materializePhysicalRowIfNeeded(physicalRow)
        let offset = physicalRow * cols + startCol
        initializeDoubleWidthDefaultCells(at: offset, codepoints: codepoints, count: count)
        markRowEncodingHintDirty(row)
    }


    // MARK: - Wrap Flag

    /// Mark a row as a soft-wrapped continuation of the previous row.
    func setWrapped(_ row: Int, _ wrapped: Bool) {
        guard row >= 0, row < rows else { return }
        let physicalRow = physicalRow(for: row)
        guard physicalWrappedFlags[physicalRow] != wrapped else { return }
        physicalWrappedFlags[physicalRow] = wrapped
    }

    /// Check if a row is soft-wrapped.
    func isWrapped(_ row: Int) -> Bool {
        let dimensions = readableDimensions()
        guard row >= 0, row < dimensions.rows,
              let physicalRow = readablePhysicalRow(for: row, readableRowCount: dimensions.rows) else { return false }
        return physicalWrappedFlags[physicalRow]
    }

    func lineAttribute(at row: Int) -> TerminalLineAttribute {
        let dimensions = readableDimensions()
        guard row >= 0, row < dimensions.rows,
              let physicalRow = readablePhysicalRow(for: row, readableRowCount: dimensions.rows) else { return .singleWidth }
        return physicalLineAttributes[physicalRow]
    }

    var hasOnlySingleWidthLines: Bool {
        nonSingleWidthLineCount == 0
    }

    func setLineAttribute(_ attribute: TerminalLineAttribute, at row: Int) {
        guard row >= 0, row < rows else { return }
        let physicalRow = physicalRow(for: row)
        let previous = physicalLineAttributes[physicalRow]
        guard previous != attribute else { return }
        if previous.isDoubleWidth && !attribute.isDoubleWidth {
            nonSingleWidthLineCount -= 1
        } else if !previous.isDoubleWidth && attribute.isDoubleWidth {
            nonSingleWidthLineCount += 1
        }
        physicalLineAttributes[physicalRow] = attribute
    }

    // MARK: - Line Operations

    /// Clear a range of cells in a row to empty.
    func clearCells(row: Int, fromCol: Int, toCol: Int) {
        guard row >= 0, row < rows else { return }
        let start = max(0, fromCol)
        let end = min(cols, toCol + 1)
        guard start < end else { return }

        let physicalRow = physicalRow(for: row)
        if start == 0, end == cols {
            setPhysicalRowBlank(physicalRow)
            if tracksPreciseRowEncodingHints {
                rowEncodingHintStates[physicalRow] = .blankDefault
            }
            return
        }

        materializeRowIfNeeded(row)
        let offset = rowBaseOffset(for: row) + start
        fillCells(.empty, count: end - start, at: offset)
        guard tracksPreciseRowEncodingHints else { return }
        markRowEncodingHintDirty(row)
    }

    /// Clear entire row.
    func clearRow(_ row: Int) {
        guard row >= 0, row < rows else { return }
        clearPhysicalRow(physicalRow(for: row))
    }

    /// Clear entire grid.
    func clearAll() {
        cells = Array(repeating: Cell.empty, count: rows * cols)
        rowEncodingHintStates = Array(repeating: .blankDefault, count: rows)
        rowOrder.removeAll(keepingCapacity: true)
        hasRowPermutation = false
        rowOrderHead = 0
        physicalWrappedFlags = Array(repeating: false, count: rows)
        physicalLineAttributes = Array(repeating: .singleWidth, count: rows)
        nonSingleWidthLineCount = 0
        physicalMayContainProtectedCells = Array(repeating: false, count: rows)
        physicalBlankRows = Array(repeating: true, count: rows)
        physicalSparseCompactDefaultPrefixCounts = Array(repeating: 0, count: rows)
        debugAssertInternalInvariants()
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

        if count == 1 {
            ensureRowOrderMaterialized()
            if top == 0 && bottom == rows - 1 {
                let clearedPhysicalRow = rowOrder[rowOrderHead]
                rowOrderHead += 1
                if rowOrderHead == rows {
                    rowOrderHead = 0
                }
                clearPhysicalRow(clearedPhysicalRow)
            } else {
                rotateRowOrder(in: top...bottom, leftBy: 1)
                hasRowPermutation = true
                clearPhysicalRow(physicalRow(for: bottom))
            }
            hasRowPermutation = true
            debugAssertInternalInvariants()
            return
        }

        if top == 0 && bottom == rows - 1 {
            ensureRowOrderMaterialized()
            rowOrderHead = (rowOrderHead + count) % rows
            hasRowPermutation = true
            var rowOrderIndex = rowOrderHead - count
            if rowOrderIndex < 0 {
                rowOrderIndex += rows
            }
            for _ in 0..<count {
                clearPhysicalRow(rowOrder[rowOrderIndex])
                rowOrderIndex += 1
                if rowOrderIndex == rows {
                    rowOrderIndex = 0
                }
            }
            debugAssertInternalInvariants()
            return
        }

        ensureRowOrderMaterialized()
        rotateRowOrder(in: top...bottom, leftBy: count)
        hasRowPermutation = true

        // Clear newly exposed lines at bottom
        for row in (bottom - count + 1)...bottom {
            clearPhysicalRow(physicalRow(for: row))
        }
        debugAssertInternalInvariants()
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

        if top == 0 && bottom == rows - 1 {
            ensureRowOrderMaterialized()
            var rowOrderIndex = rowOrderHead - count
            if rowOrderIndex < 0 {
                rowOrderIndex += rows
            }
            rowOrderHead -= count
            if rowOrderHead < 0 {
                rowOrderHead += rows
            }
            hasRowPermutation = true
            for _ in 0..<count {
                clearPhysicalRow(rowOrder[rowOrderIndex])
                rowOrderIndex += 1
                if rowOrderIndex == rows {
                    rowOrderIndex = 0
                }
            }
            debugAssertInternalInvariants()
            return
        }

        ensureRowOrderMaterialized()
        rotateRowOrder(in: top...bottom, rightBy: count)
        hasRowPermutation = true

        // Clear newly exposed lines at top
        for row in top..<(top + count) {
            clearPhysicalRow(physicalRow(for: row))
        }
        debugAssertInternalInvariants()
    }

    @inline(__always)
    func scrollUpOneFullScreenForAlternateScreen() {
        ensureRowOrderMaterialized()
        let clearedPhysicalRow = rowOrder[rowOrderHead]
        rowOrderHead += 1
        if rowOrderHead == rows {
            rowOrderHead = 0
        }
        clearPhysicalRow(clearedPhysicalRow)
        hasRowPermutation = true
        debugAssertInternalInvariants()
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
        var newLineAttributes = [TerminalLineAttribute]()
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
                newLineAttributes.append(.singleWidth)
            }
        }

        // 4. Trim or pad to newRows
        var totalRows = newCells.count / newCols
        var trimmedRows: [TrimmedRow] = []

        // When a wider viewport introduced trailing padding rows below the
        // cursor, consume those rows first on shrink before pushing actual
        // terminal content into scrollback.
        while totalRows > newRows,
              totalRows - 1 > newCursorRow,
              !newWrapped.isEmpty {
            let lastRowIndex = totalRows - 1
            let start = lastRowIndex * newCols
            let rowCells = newCells[start..<(start + newCols)]
            let isBlankPaddingRow = !newWrapped[lastRowIndex] && rowCells.allSatisfy { cell in
                cell.codepoint == Cell.empty.codepoint &&
                cell.attributes == Cell.empty.attributes &&
                cell.width == Cell.empty.width &&
                cell.isWideContinuation == Cell.empty.isWideContinuation
            }
            guard isBlankPaddingRow else { break }
            newCells.removeLast(newCols)
            newWrapped.removeLast()
            newLineAttributes.removeLast()
            totalRows -= 1
        }

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
            newLineAttributes.removeFirst(excessRows)
            newCursorRow -= excessRows
        } else if totalRows < newRows {
            let padRows = newRows - totalRows
            newCells.append(contentsOf:
                Array(repeating: Cell.empty, count: padRows * newCols))
            newWrapped.append(contentsOf:
                Array(repeating: false, count: padRows))
            newLineAttributes.append(contentsOf:
                Array(repeating: .singleWidth, count: padRows))
        }

        self.rows = newRows
        self.cols = newCols
        self.cells = newCells
        self.emptyRowTemplate = Array(repeating: Cell.empty, count: newCols)
        self.rowEncodingHintStates = Array(repeating: .dirty, count: newRows)
        self.rowOrder.removeAll(keepingCapacity: true)
        self.hasRowPermutation = false
        self.rowOrderHead = 0
        self.setWrappedFlags(newWrapped)
        self.physicalLineAttributes = newLineAttributes
        self.nonSingleWidthLineCount = newLineAttributes.reduce(into: 0) { count, attribute in
            if attribute.isDoubleWidth {
                count += 1
            }
        }
        self.physicalMayContainProtectedCells = stride(from: 0, to: newCells.count, by: newCols).map { start in
            newCells[start..<(start + newCols)].contains { $0.attributes.decProtected }
        }
        self.physicalBlankRows = stride(from: 0, to: newCells.count, by: newCols).map { start in
            newCells[start..<(start + newCols)].allSatisfy { cell in
                cell.codepoint == Cell.empty.codepoint &&
                cell.attributes == .default &&
                cell.width == Cell.empty.width &&
                !cell.isWideContinuation
            }
        }
        self.physicalSparseCompactDefaultPrefixCounts = Array(repeating: 0, count: newRows)
        self.scrollTop = 0
        self.scrollBottom = newRows - 1

        let clampedRow = max(0, min(newRows - 1, newCursorRow))
        let clampedCol = max(0, min(newCols - 1, newCursorCol))
        debugAssertInternalInvariants()
        return ResizeResult(cursorRow: clampedRow, cursorCol: clampedCol, trimmedRows: trimmedRows)
    }

    /// Simple row-only resize (column count unchanged).
    private func resizeRowsOnly(newRows: Int, cursorRow: Int, cursorCol: Int) -> ResizeResult {
        var newCursorRow = cursorRow
        var trimmedRows: [TrimmedRow] = []
        var logicalRows = (0..<rows).map { Array(rowCells($0)) }
        var wrappedFlags = wrappedFlagsArray(startingAt: 0, count: rows)
        var lineAttributes = (0..<rows).map(lineAttribute(at:))

        if newRows < rows {
            // Shrinking: if cursor is below new bottom, scroll content up
            if cursorRow >= newRows {
                let scrollAmount = cursorRow - newRows + 1
                // Capture rows being scrolled out
                for i in 0..<scrollAmount {
                    trimmedRows.append(TrimmedRow(cells: logicalRows[i], isWrapped: wrappedFlags[i]))
                }
                let existingRows = Array(logicalRows[scrollAmount..<rows])
                let paddingRows = Array(
                    repeating: Array(repeating: Cell.empty, count: cols),
                    count: scrollAmount
                )
                logicalRows = existingRows + paddingRows
                wrappedFlags = Array(wrappedFlags[scrollAmount..<rows]) + Array(repeating: false, count: scrollAmount)
                lineAttributes = Array(lineAttributes[scrollAmount..<rows]) + Array(repeating: .singleWidth, count: scrollAmount)
                newCursorRow -= scrollAmount
            }
            // Trim to newRows
            logicalRows = Array(logicalRows.prefix(newRows))
            wrappedFlags = Array(wrappedFlags.prefix(newRows))
            lineAttributes = Array(lineAttributes.prefix(newRows))
        } else if newRows > rows {
            // Growing: add empty rows at bottom
            let padRows = newRows - rows
            logicalRows.append(contentsOf:
                Array(repeating: Array(repeating: Cell.empty, count: cols), count: padRows))
            wrappedFlags.append(contentsOf: Array(repeating: false, count: padRows))
            lineAttributes.append(contentsOf: Array(repeating: .singleWidth, count: padRows))
        }

        cells = logicalRows.flatMap { $0 }
        emptyRowTemplate = Array(repeating: Cell.empty, count: cols)
        rowEncodingHintStates = Array(repeating: .dirty, count: newRows)
        rowOrder.removeAll(keepingCapacity: true)
        hasRowPermutation = false
        rowOrderHead = 0
        self.rows = newRows
        setWrappedFlags(wrappedFlags)
        physicalLineAttributes = lineAttributes
        nonSingleWidthLineCount = lineAttributes.reduce(into: 0) { count, attribute in
            if attribute.isDoubleWidth {
                count += 1
            }
        }
        physicalMayContainProtectedCells = logicalRows.map { row in
            row.contains { $0.attributes.decProtected }
        }
        physicalBlankRows = logicalRows.map { row in
            row.allSatisfy { cell in
                cell.codepoint == Cell.empty.codepoint &&
                cell.attributes == .default &&
                cell.width == Cell.empty.width &&
                !cell.isWideContinuation
            }
        }
        physicalSparseCompactDefaultPrefixCounts = Array(repeating: 0, count: newRows)
        self.scrollTop = 0
        self.scrollBottom = newRows - 1

        debugAssertInternalInvariants()
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
            let rowCells = Array(rowCells(row))

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
        let dimensions = readableDimensions()
        guard row >= 0, row < dimensions.rows,
              let physicalRow = readablePhysicalRow(for: row, readableRowCount: dimensions.rows) else { return [] }
        if isPhysicalRowBlank(physicalRow) {
            return ArraySlice(emptyRowTemplate)
        }
        let start = physicalRow * dimensions.cols
        let sparsePrefixCount = physicalSparseCompactDefaultPrefixCounts[physicalRow]
        if sparsePrefixCount > 0 {
            let end = min(start + sparsePrefixCount, cells.count)
            return cells[start..<end]
        }
        let end = min(start + dimensions.cols, cells.count)
        return cells[start..<end]
    }

    /// Return only the cells that scrollback serialization actually needs.
    /// Compact rows can skip trailing blanks and avoid copying a full viewport-width row.
    func scrollbackCells(_ row: Int, encodingHint: ScrollbackBuffer.RowEncodingHint) -> [Cell] {
        guard row >= 0, row < rows else { return [] }
        let physicalRow = physicalRow(for: row)
        if isPhysicalRowBlank(physicalRow) {
            switch encodingHint.kind {
            case .compactDefault, .compactUniformAttributes:
                return []
            case .full, .unknown:
                return emptyRowTemplate
            }
        }
        let start = rowBaseOffset(for: row)
        switch encodingHint.kind {
        case .compactDefault(let serializedCount):
            guard serializedCount > 0 else { return [] }
            return Array(cells[start..<(start + min(serializedCount, cols))])
        case .compactUniformAttributes(_, let serializedCount):
            guard serializedCount > 0 else { return [] }
            return Array(cells[start..<(start + min(serializedCount, cols))])
        case .full, .unknown:
            return Array(cells[start..<(start + cols)])
        }
    }


    func rowEncodingHint(_ row: Int) -> ScrollbackBuffer.RowEncodingHint {
        guard row >= 0, row < rows else { return .unknown }
        let physicalRow = physicalRow(for: row)
        switch rowEncodingHintStates[physicalRow] {
        case .blankDefault:
            return ScrollbackBuffer.RowEncodingHint(kind: .compactDefault(serializedCount: 0))
        case .compactDefault(let serializedCount):
            return ScrollbackBuffer.RowEncodingHint(kind: .compactDefault(serializedCount: serializedCount))
        case .dirty:
            let hint = recomputeRowEncodingHint(forPhysicalRow: physicalRow)
            rowEncodingHintStates[physicalRow] = rowEncodingHintState(from: hint)
            return hint
        }
    }


    /// Insert blank cells at column, shifting existing cells right.
    func insertBlanks(row: Int, col: Int, count: Int) {
        guard row >= 0, row < rows, col >= 0, col < cols else { return }
        materializeRowIfNeeded(row)
        let offset = rowBaseOffset(for: row)
        let shift = min(count, cols - col)

        // Shift cells right
        for c in stride(from: cols - 1, through: col + shift, by: -1) {
            cells[offset + c] = cells[offset + c - shift]
        }

        // Fill inserted cells with empty
        for c in col..<min(col + shift, cols) {
            cells[offset + c] = Cell.empty
        }
        markRowEncodingHintDirty(row)
    }

    /// Delete cells at column, shifting remaining cells left.
    func deleteCells(row: Int, col: Int, count: Int) {
        guard row >= 0, row < rows, col >= 0, col < cols else { return }
        materializeRowIfNeeded(row)
        let offset = rowBaseOffset(for: row)
        let shift = min(count, cols - col)

        // Shift cells left
        for c in col..<(cols - shift) {
            cells[offset + c] = cells[offset + c + shift]
        }

        // Fill vacated cells at end with empty
        for c in (cols - shift)..<cols {
            cells[offset + c] = Cell.empty
        }
        markRowEncodingHintDirty(row)
    }

    func scrollLineLeft(row: Int, count: Int) {
        deleteCells(row: row, col: 0, count: count)
    }

    func scrollLineRight(row: Int, count: Int) {
        insertBlanks(row: row, col: 0, count: count)
    }

    private func setWrappedFlags(_ wrappedFlags: [Bool]) {
        physicalWrappedFlags = Array(wrappedFlags.prefix(rows))
        if physicalWrappedFlags.count < rows {
            physicalWrappedFlags.append(contentsOf: repeatElement(false, count: rows - physicalWrappedFlags.count))
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

    /// Return an immutable copy of the grid contents for diagnostics and benchmarks.
    func snapshot() -> TerminalGrid {
        let copy = TerminalGrid(rows: rows, cols: cols, allocateStorage: false)
        copy.cells = cells
        copy.emptyRowTemplate = emptyRowTemplate
        copy.rowEncodingHintStates = rowEncodingHintStates
        copy.hasRowPermutation = hasRowPermutation
        if hasRowPermutation {
            copy.rowOrder = rowOrder
            copy.rowOrderHead = rowOrderHead
        }
        copy.physicalWrappedFlags = physicalWrappedFlags
        copy.physicalLineAttributes = physicalLineAttributes
        copy.nonSingleWidthLineCount = nonSingleWidthLineCount
        copy.physicalMayContainProtectedCells = physicalMayContainProtectedCells
        copy.physicalBlankRows = physicalBlankRows
        copy.physicalSparseCompactDefaultPrefixCounts = physicalSparseCompactDefaultPrefixCounts
        copy.scrollTop = scrollTop
        copy.scrollBottom = scrollBottom
        copy.tracksPreciseRowEncodingHints = tracksPreciseRowEncodingHints
        return copy
    }

    @inline(__always)
    private func physicalRow(for logicalRow: Int) -> Int {
        guard hasRowPermutation else { return logicalRow }
        let index = rowOrderHead + logicalRow
        return rowOrder[index < rows ? index : index - rows]
    }

    @inline(__always)
    func readableDimensions() -> (rows: Int, cols: Int) {
        guard cols > 0 else { return (rows: 0, cols: 0) }
        var readableRows = rows
        readableRows = min(readableRows, cells.count / cols)
        readableRows = min(readableRows, rowEncodingHintStates.count)
        readableRows = min(readableRows, physicalWrappedFlags.count)
        readableRows = min(readableRows, physicalLineAttributes.count)
        readableRows = min(readableRows, physicalMayContainProtectedCells.count)
        readableRows = min(readableRows, physicalBlankRows.count)
        readableRows = min(readableRows, physicalSparseCompactDefaultPrefixCounts.count)
        if hasRowPermutation {
            readableRows = min(readableRows, rowOrder.count)
        }
        return (rows: max(0, readableRows), cols: cols)
    }

    @inline(__always)
    private func readablePhysicalRow(for logicalRow: Int, readableRowCount: Int) -> Int? {
        guard logicalRow >= 0, logicalRow < readableRowCount else { return nil }
        guard hasRowPermutation else { return logicalRow }
        let index = rowOrderHead + logicalRow
        let wrappedIndex = index < rowOrder.count ? index : index - rowOrder.count
        guard wrappedIndex >= 0, wrappedIndex < rowOrder.count else { return nil }
        let physicalRow = rowOrder[wrappedIndex]
        guard physicalRow >= 0, physicalRow < readableRowCount else { return nil }
        return physicalRow
    }

    func debugCorruptReadableStateForTesting(
        rowOrder: [Int]? = nil,
        hasRowPermutation: Bool? = nil,
        rowOrderHead: Int? = nil,
        physicalWrappedFlags: [Bool]? = nil,
        physicalLineAttributes: [TerminalLineAttribute]? = nil,
        physicalMayContainProtectedCells: [Bool]? = nil,
        physicalBlankRows: [Bool]? = nil,
        physicalSparseCompactDefaultPrefixCounts: [Int]? = nil,
        rowEncodingHintStatesCount: Int? = nil
    ) {
        if let rowOrder {
            self.rowOrder = rowOrder
        }
        if let hasRowPermutation {
            self.hasRowPermutation = hasRowPermutation
        }
        if let rowOrderHead {
            self.rowOrderHead = rowOrderHead
        }
        if let physicalWrappedFlags {
            self.physicalWrappedFlags = physicalWrappedFlags
        }
        if let physicalLineAttributes {
            self.physicalLineAttributes = physicalLineAttributes
        }
        if let physicalMayContainProtectedCells {
            self.physicalMayContainProtectedCells = physicalMayContainProtectedCells
        }
        if let physicalBlankRows {
            self.physicalBlankRows = physicalBlankRows
        }
        if let physicalSparseCompactDefaultPrefixCounts {
            self.physicalSparseCompactDefaultPrefixCounts = physicalSparseCompactDefaultPrefixCounts
        }
        if let rowEncodingHintStatesCount {
            self.rowEncodingHintStates = Array(repeating: .dirty, count: rowEncodingHintStatesCount)
        }
    }

    func debugValidateInternalInvariants() -> [String] {
        var issues: [String] = []
        if rows < 0 {
            issues.append("rows is negative: \(rows)")
        }
        if cols < 0 {
            issues.append("cols is negative: \(cols)")
        }
        if cols == 0 {
            if !cells.isEmpty {
                issues.append("cells is non-empty while cols is zero")
            }
        } else if cells.count != rows * cols {
            issues.append("cells.count (\(cells.count)) != rows * cols (\(rows * cols))")
        }
        if emptyRowTemplate.count != cols {
            issues.append("emptyRowTemplate.count (\(emptyRowTemplate.count)) != cols (\(cols))")
        }
        if rowEncodingHintStates.count != rows {
            issues.append("rowEncodingHintStates.count (\(rowEncodingHintStates.count)) != rows (\(rows))")
        }
        if physicalWrappedFlags.count != rows {
            issues.append("physicalWrappedFlags.count (\(physicalWrappedFlags.count)) != rows (\(rows))")
        }
        if physicalLineAttributes.count != rows {
            issues.append("physicalLineAttributes.count (\(physicalLineAttributes.count)) != rows (\(rows))")
        }
        if physicalMayContainProtectedCells.count != rows {
            issues.append("physicalMayContainProtectedCells.count (\(physicalMayContainProtectedCells.count)) != rows (\(rows))")
        }
        if physicalBlankRows.count != rows {
            issues.append("physicalBlankRows.count (\(physicalBlankRows.count)) != rows (\(rows))")
        }
        if physicalSparseCompactDefaultPrefixCounts.count != rows {
            issues.append("physicalSparseCompactDefaultPrefixCounts.count (\(physicalSparseCompactDefaultPrefixCounts.count)) != rows (\(rows))")
        }
        if scrollTop < 0 || scrollTop >= rows, rows > 0 {
            issues.append("scrollTop (\(scrollTop)) is out of bounds for rows (\(rows))")
        }
        if scrollBottom < 0 || scrollBottom >= rows, rows > 0 {
            issues.append("scrollBottom (\(scrollBottom)) is out of bounds for rows (\(rows))")
        }
        if rows > 0, scrollTop > scrollBottom {
            issues.append("scrollTop (\(scrollTop)) > scrollBottom (\(scrollBottom))")
        }
        if hasRowPermutation {
            if rowOrder.count != rows {
                issues.append("rowOrder.count (\(rowOrder.count)) != rows (\(rows)) while permutation is active")
            }
            if rowOrderHead < 0 || rowOrderHead >= max(rows, 1) {
                issues.append("rowOrderHead (\(rowOrderHead)) is out of bounds for rows (\(rows))")
            }
            if rowOrder.count == rows {
                var seen = Set<Int>()
                for physicalRow in rowOrder {
                    if physicalRow < 0 || physicalRow >= rows {
                        issues.append("rowOrder contains out-of-bounds physical row \(physicalRow)")
                        break
                    }
                    if !seen.insert(physicalRow).inserted {
                        issues.append("rowOrder contains duplicate physical row \(physicalRow)")
                        break
                    }
                }
            }
        } else if !rowOrder.isEmpty || rowOrderHead != 0 {
            issues.append("rowOrder state should be empty/reset when permutation is inactive")
        }
        for (physicalRow, sparsePrefixCount) in physicalSparseCompactDefaultPrefixCounts.enumerated() {
            if sparsePrefixCount < 0 || sparsePrefixCount > cols {
                issues.append("physicalSparseCompactDefaultPrefixCounts[\(physicalRow)] = \(sparsePrefixCount) is outside 0...\(cols)")
                break
            }
        }
        let expectedNonSingleWidthLineCount = physicalLineAttributes.reduce(into: 0) { count, attribute in
            if attribute.isDoubleWidth {
                count += 1
            }
        }
        if nonSingleWidthLineCount != expectedNonSingleWidthLineCount {
            issues.append("nonSingleWidthLineCount (\(nonSingleWidthLineCount)) != expected count (\(expectedNonSingleWidthLineCount))")
        }
        return issues
    }

    @inline(__always)
    private func debugAssertInternalInvariants(
        file: StaticString = #file,
        line: UInt = #line
    ) {
        #if DEBUG
        let issues = debugValidateInternalInvariants()
        if !issues.isEmpty {
            assertionFailure("TerminalGrid invariant failure: \(issues.joined(separator: " | "))", file: file, line: line)
        }
        #endif
    }

    private func markRowEncodingHintDirty(_ logicalRow: Int) {
        let physicalRow = physicalRow(for: logicalRow)
        physicalBlankRows[physicalRow] = false
        physicalSparseCompactDefaultPrefixCounts[physicalRow] = 0
        rowEncodingHintStates[physicalRow] = .dirty
    }

    private func setRowEncodingHintBlank(_ logicalRow: Int) {
        let physicalRow = physicalRow(for: logicalRow)
        physicalSparseCompactDefaultPrefixCounts[physicalRow] = 0
        rowEncodingHintStates[physicalRow] = .blankDefault
    }

    private func updateCompactDefaultHintIfPossible(
        row: Int,
        startCol: Int,
        scalarProvider: (Int) -> UInt32,
        count: Int,
        attributes: CellAttributes
    ) {
        guard attributes == .default else {
            markRowEncodingHintDirty(row)
            return
        }

        let physicalRow = physicalRow(for: row)
        physicalBlankRows[physicalRow] = false
        physicalSparseCompactDefaultPrefixCounts[physicalRow] = 0
        let priorSerializedCount: Int
        switch rowEncodingHintStates[physicalRow] {
        case .blankDefault:
            priorSerializedCount = 0
        case .compactDefault(let serializedCount):
            priorSerializedCount = serializedCount
        case .dirty:
            return
        }

        var lastNonBlankColumn = priorSerializedCount
        for index in 0..<count {
            let codepoint = scalarProvider(index)
            if codepoint != Cell.empty.codepoint {
                lastNonBlankColumn = max(lastNonBlankColumn, startCol + index + 1)
            } else if startCol + index < priorSerializedCount {
                rowEncodingHintStates[physicalRow] = .dirty
                return
            }
        }
        rowEncodingHintStates[physicalRow] = lastNonBlankColumn == 0
            ? .blankDefault
            : .compactDefault(serializedCount: lastNonBlankColumn)
    }

    private func updateCompactDefaultHintForDefaultCodepoints(
        row: Int,
        startCol: Int,
        codepoints: UnsafePointer<UInt32>,
        count: Int
    ) {
        let physicalRow = physicalRow(for: row)
        physicalBlankRows[physicalRow] = false
        physicalSparseCompactDefaultPrefixCounts[physicalRow] = 0
        let priorSerializedCount: Int
        switch rowEncodingHintStates[physicalRow] {
        case .blankDefault:
            priorSerializedCount = 0
        case .compactDefault(let serializedCount):
            priorSerializedCount = serializedCount
        case .dirty:
            return
        }

        if startCol >= priorSerializedCount {
            var trailingCount = count
            while trailingCount > 0,
                  codepoints[trailingCount - 1] == Cell.empty.codepoint {
                trailingCount -= 1
            }

            let serializedCount = trailingCount == 0
                ? priorSerializedCount
                : startCol + trailingCount
            rowEncodingHintStates[physicalRow] = serializedCount == 0
                ? .blankDefault
                : .compactDefault(serializedCount: serializedCount)
            return
        }

        var lastNonBlankColumn = priorSerializedCount
        for index in 0..<count {
            let codepoint = codepoints[index]
            if codepoint != Cell.empty.codepoint {
                lastNonBlankColumn = startCol + index + 1
            } else if startCol + index < priorSerializedCount {
                rowEncodingHintStates[physicalRow] = .dirty
                return
            }
        }
        rowEncodingHintStates[physicalRow] = lastNonBlankColumn == 0
            ? .blankDefault
            : .compactDefault(serializedCount: lastNonBlankColumn)
    }

    private func recomputeRowEncodingHint(forPhysicalRow physicalRow: Int) -> ScrollbackBuffer.RowEncodingHint {
        if isPhysicalRowBlank(physicalRow) {
            return ScrollbackBuffer.RowEncodingHint(kind: .compactDefault(serializedCount: 0))
        }
        let sparsePrefixCount = physicalSparseCompactDefaultPrefixCounts[physicalRow]
        if sparsePrefixCount > 0 {
            return ScrollbackBuffer.RowEncodingHint(kind: .compactDefault(serializedCount: sparsePrefixCount))
        }
        let start = physicalRow * cols
        let end = start + cols
        let rowSlice = cells[start..<end]
        var serializedCount = rowSlice.count
        for cell in rowSlice {
            if cell.attributes != .default || cell.width != 1 || cell.isWideContinuation {
                return .unknown
            }
        }
        while serializedCount > 0 {
            let cell = rowSlice[rowSlice.index(rowSlice.startIndex, offsetBy: serializedCount - 1)]
            guard cell.codepoint == Cell.empty.codepoint else { break }
            serializedCount -= 1
        }
        return ScrollbackBuffer.RowEncodingHint(kind: .compactDefault(serializedCount: serializedCount))
    }

    private func rowEncodingHintState(from hint: ScrollbackBuffer.RowEncodingHint) -> RowEncodingHintState {
        switch hint.kind {
        case .compactDefault(let serializedCount):
            return serializedCount == 0 ? .blankDefault : .compactDefault(serializedCount: serializedCount)
        case .compactUniformAttributes, .full, .unknown:
            return .dirty
        }
    }

    private func ensureRowOrderMaterialized() {
        guard !hasRowPermutation, rowOrder.isEmpty else { return }
        rowOrder = Array(0..<rows)
        rowOrderHead = 0
    }

    private func normalizeRowOrderIfNeeded() {
        guard hasRowPermutation, rowOrderHead != 0, !rowOrder.isEmpty else { return }
        rowOrder.rotateLeft(by: rowOrderHead)
        rowOrderHead = 0
    }

    @inline(__always)
    private func initializeSingleWidthCells(
        at offset: Int,
        codepoints: UnsafePointer<UInt32>,
        count: Int,
        attributes: CellAttributes
    ) {
        cells.withUnsafeMutableBufferPointer { buffer in
            guard var destination = buffer.baseAddress?.advanced(by: offset) else { return }
            var source = codepoints
            var remaining = count
            while remaining > 0 {
                destination.pointee = Cell(
                    codepoint: source.pointee,
                    attributes: attributes,
                    width: 1,
                    isWideContinuation: false
                )
                destination += 1
                source += 1
                remaining -= 1
            }
        }
    }

    @inline(__always)
    private func initializeSingleWidthASCIIBytes(
        at offset: Int,
        bytes: UnsafePointer<UInt8>,
        count: Int,
        attributes: CellAttributes
    ) {
        cells.withUnsafeMutableBufferPointer { buffer in
            guard var destination = buffer.baseAddress?.advanced(by: offset) else { return }
            var source = bytes
            var remaining = count
            while remaining > 0 {
                destination.pointee = Cell(
                    codepoint: UInt32(source.pointee),
                    attributes: attributes,
                    width: 1,
                    isWideContinuation: false
                )
                destination += 1
                source += 1
                remaining -= 1
            }
        }
    }

    @inline(__always)
    private func initializeDefaultASCIIBytes(
        at offset: Int,
        bytes: UnsafePointer<UInt8>,
        count: Int
    ) {
        cells.withUnsafeMutableBufferPointer { destinationBuffer in
            guard var destination = destinationBuffer.baseAddress?.advanced(by: offset) else { return }
            Self.defaultASCIIByteCells.withUnsafeBufferPointer { lookupBuffer in
                guard let lookup = lookupBuffer.baseAddress else { return }
                var source = bytes
                var remaining = count
                while remaining > 0 {
                    destination.pointee = lookup[Int(source.pointee)]
                    destination += 1
                    source += 1
                    remaining -= 1
                }
            }
        }
    }

    @inline(__always)
    private func initializeSingleWidthDefaultCells(
        at offset: Int,
        codepoints: UnsafePointer<UInt32>,
        count: Int
    ) {
        cells.withUnsafeMutableBufferPointer { buffer in
            guard var destination = buffer.baseAddress?.advanced(by: offset) else { return }
            var source = codepoints
            var remaining = count
            while remaining > 0 {
                destination.pointee = Cell(
                    codepoint: source.pointee,
                    attributes: .default,
                    width: 1,
                    isWideContinuation: false
                )
                destination += 1
                source += 1
                remaining -= 1
            }
        }
    }

    @inline(__always)
    private func initializeSingleWidthDefaultCellsTrackingSerializedCount(
        at offset: Int,
        codepoints: UnsafePointer<UInt32>,
        count: Int,
        startCol: Int,
        priorSerializedCount: Int
    ) -> Int {
        cells.withUnsafeMutableBufferPointer { buffer in
            guard var destination = buffer.baseAddress?.advanced(by: offset) else { return -1 }
            var source = codepoints
            var remaining = count
            var column = startCol
            var serializedCount = priorSerializedCount

            while remaining > 0 {
                let codepoint = source.pointee
                destination.pointee = Cell(
                    codepoint: codepoint,
                    attributes: .default,
                    width: 1,
                    isWideContinuation: false
                )
                if codepoint != Cell.empty.codepoint {
                    serializedCount = column + 1
                } else if column < priorSerializedCount {
                    return -1
                }

                destination += 1
                source += 1
                remaining -= 1
                column += 1
            }

            return serializedCount
        }
    }

    @inline(__always)
    private func fillCells(
        _ cell: Cell,
        count: Int,
        at offset: Int
    ) {
        cells.withUnsafeMutableBufferPointer { buffer in
            guard let destination = buffer.baseAddress?.advanced(by: offset) else { return }
            destination.update(repeating: cell, count: count)
        }
    }

    @inline(__always)
    private func initializeDoubleWidthCells(
        at offset: Int,
        codepoints: UnsafePointer<UInt32>,
        count: Int,
        attributes: CellAttributes
    ) {
        cells.withUnsafeMutableBufferPointer { buffer in
            guard var destination = buffer.baseAddress?.advanced(by: offset) else { return }
            var source = codepoints
            var remaining = count
            while remaining > 0 {
                destination.pointee = Cell(
                    codepoint: source.pointee,
                    attributes: attributes,
                    width: 2,
                    isWideContinuation: false
                )
                destination.advanced(by: 1).pointee = Cell(
                    codepoint: 0,
                    attributes: attributes,
                    width: 0,
                    isWideContinuation: true
                )
                destination += 2
                source += 1
                remaining -= 1
            }
        }
    }

    @inline(__always)
    private func initializeDoubleWidthDefaultCells(
        at offset: Int,
        codepoints: UnsafePointer<UInt32>,
        count: Int
    ) {
        cells.withUnsafeMutableBufferPointer { buffer in
            guard var destination = buffer.baseAddress?.advanced(by: offset) else { return }
            var source = codepoints
            var remaining = count
            let continuation = Self.defaultWideContinuationCell
            while remaining > 0 {
                destination.pointee = Cell(
                    codepoint: source.pointee,
                    attributes: .default,
                    width: 2,
                    isWideContinuation: false
                )
                destination.advanced(by: 1).pointee = continuation
                destination += 2
                source += 1
                remaining -= 1
            }
        }
    }

    @inline(__always)
    private func rowBaseOffset(for row: Int) -> Int {
        physicalRow(for: row) * cols
    }

    @inline(__always)
    private func isPhysicalRowBlank(_ physicalRow: Int) -> Bool {
        physicalBlankRows[physicalRow]
    }

    @inline(__always)
    func rowMayContainProtectedCells(_ row: Int) -> Bool {
        guard row >= 0, row < rows else { return false }
        return physicalMayContainProtectedCells[physicalRow(for: row)]
    }

    @inline(__always)
    private func setPhysicalRowBlank(_ physicalRow: Int) {
        physicalBlankRows[physicalRow] = true
        physicalSparseCompactDefaultPrefixCounts[physicalRow] = 0
    }

    @inline(__always)
    private func clearPhysicalRow(_ physicalRow: Int) {
        setPhysicalRowBlank(physicalRow)
        physicalWrappedFlags[physicalRow] = false
        let previous = physicalLineAttributes[physicalRow]
        if previous.isDoubleWidth {
            nonSingleWidthLineCount -= 1
        }
        physicalLineAttributes[physicalRow] = .singleWidth
        physicalMayContainProtectedCells[physicalRow] = false
        rowEncodingHintStates[physicalRow] = .blankDefault
    }

    @inline(__always)
    private func materializeRowIfNeeded(_ logicalRow: Int) {
        materializePhysicalRowIfNeeded(physicalRow(for: logicalRow))
    }

    @inline(__always)
    private func materializePhysicalRowIfNeeded(_ physicalRow: Int) {
        let sparsePrefixCount = physicalSparseCompactDefaultPrefixCounts[physicalRow]
        if sparsePrefixCount > 0 {
            let offset = physicalRow * cols + sparsePrefixCount
            let remainingCount = cols - sparsePrefixCount
            if remainingCount > 0 {
                fillCells(.empty, count: remainingCount, at: offset)
            }
            physicalSparseCompactDefaultPrefixCounts[physicalRow] = 0
            return
        }
        guard physicalBlankRows[physicalRow] else { return }
        let offset = physicalRow * cols
        fillCells(.empty, count: cols, at: offset)
        physicalBlankRows[physicalRow] = false
    }

    private func cellIndex(row: Int, col: Int) -> Int {
        rowBaseOffset(for: row) + col
    }

    private func rotateRowOrder(in range: ClosedRange<Int>, leftBy amount: Int) {
        normalizeRowOrderIfNeeded()
        var segment = Array(rowOrder[range])
        segment.rotateLeft(by: amount)
        rowOrder.replaceSubrange(range, with: segment)
    }

    private func rotateRowOrder(in range: ClosedRange<Int>, rightBy amount: Int) {
        normalizeRowOrderIfNeeded()
        var segment = Array(rowOrder[range])
        segment.rotateRight(by: amount)
        rowOrder.replaceSubrange(range, with: segment)
    }
}

private extension Array where Element == Int {
    mutating func rotateLeft(by rawAmount: Int) {
        guard !isEmpty else { return }
        let amount = rawAmount % count
        guard amount > 0 else { return }
        self = Array(self[amount...]) + self[..<amount]
    }

    mutating func rotateLeftByOneInPlace() {
        guard count > 1 else { return }
        let elementCount = count
        let first = self[0]
        self.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for index in 0..<(elementCount - 1) {
                base[index] = base[index + 1]
            }
            base[elementCount - 1] = first
        }
    }

    mutating func rotateRight(by rawAmount: Int) {
        guard !isEmpty else { return }
        let amount = rawAmount % count
        guard amount > 0 else { return }
        rotateLeft(by: count - amount)
    }
}
